"""In-memory progress stores for downloads and jobs.

Also hosts the contextvar that routes log records to the right
JobProgressPanel entry in the Flutter UI.
"""

from __future__ import annotations

import contextvars
import datetime
import logging
import threading
import time

from .config import JOB_TTL, PROGRESS_TTL  # noqa: F401

# ─── Download progress (YouTube imports) ───────────────────────────────
download_progress: dict = {}
download_progress_lock = threading.Lock()


def _progress_init(download_id: str, url: str) -> None:
    with download_progress_lock:
        download_progress[download_id] = {
            "download_id": download_id,
            "url": url,
            "stage": "starting",
            "progress": 0.0,
            "message": "Starting…",
            "details": {
                "title": None,
                "duration": None,
                "filename": None,
                "filesize": None,
                "has_audio": None,
                "codec": None,
                "converted": None,
            },
            "events": [],
            "done": False,
            "error": None,
            "started_at": time.time(),
        }


def _progress_event(
    download_id, message, *, level="info", stage=None, progress=None, details=None
) -> None:
    if not download_id:
        return
    with download_progress_lock:
        entry = download_progress.get(download_id)
        if entry is None:
            return
        entry["events"].append(
            {
                "time": datetime.datetime.now().strftime("%H:%M:%S"),
                "level": level,
                "message": message,
            }
        )
        if stage is not None:
            entry["stage"] = stage
        if progress is not None:
            entry["progress"] = float(progress)
        if details:
            entry["details"].update(details)
        entry["message"] = message


def _progress_finish(download_id, *, error=None, details=None) -> None:
    if not download_id:
        return
    with download_progress_lock:
        entry = download_progress.get(download_id)
        if entry is None:
            return
        if details:
            entry["details"].update(details)
        entry["done"] = True
        entry["error"] = error
        entry["stage"] = "error" if error else "done"
        if error:
            entry["events"].append(
                {
                    "time": datetime.datetime.now().strftime("%H:%M:%S"),
                    "level": "error",
                    "message": error,
                }
            )


def _progress_cleanup_old() -> None:
    cutoff = time.time() - PROGRESS_TTL
    with download_progress_lock:
        stale = [
            k
            for k, v in download_progress.items()
            if v.get("done") and v.get("started_at", 0) < cutoff
        ]
        for k in stale:
            download_progress.pop(k, None)


# ─── Job progress (per session) ────────────────────────────────────────
_job_progress_store: dict = {}
job_progress_lock = threading.Lock()

_cancelled_sessions: set[str] = set()
_cancelled_sessions_lock = threading.Lock()

_consecutive_404s: dict[str, int] = {}
_consecutive_404s_lock = threading.Lock()


def _request_cancel(session_id: str) -> None:
    with _cancelled_sessions_lock:
        _cancelled_sessions.add(session_id)


def _is_cancelled(session_id: str) -> bool:
    with _cancelled_sessions_lock:
        return session_id in _cancelled_sessions


def _clear_cancel(session_id: str) -> None:
    with _cancelled_sessions_lock:
        _cancelled_sessions.discard(session_id)


def _note_404(session_id: str, url: str) -> int:
    with _consecutive_404s_lock:
        n = _consecutive_404s.get(session_id, 0) + 1
        _consecutive_404s[session_id] = n
    if n == 1:
        logging.warning(
            "messages.json 404 for session %s (%s)", session_id[:8] + "…", url
        )
    elif n == 5:
        logging.warning(
            "messages.json still 404 for session %s after %d attempts; "
            "further 404s for this session will be silenced",
            session_id[:8] + "…",
            n,
        )
    return n


def _clear_404(session_id: str) -> None:
    with _consecutive_404s_lock:
        _consecutive_404s.pop(session_id, None)


def _job_start(session_id, video_key, session_name) -> None:
    with job_progress_lock:
        if session_id in _job_progress_store:
            return
        _job_progress_store[session_id] = {
            "session_id": session_id,
            "video_key": video_key,
            "session_name": session_name or session_id,
            "stage": "starting",
            "progress": 0.0,
            "message": "Starting…",
            "events": [],
            "files": [],
            "total_files": 0,
            "done": False,
            "error": None,
            "started_at": time.time(),
            "updated_at": time.time(),
        }


def _job_log(session_id, message, *, level="info", stage=None, progress=None) -> None:
    if not session_id:
        return
    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        if entry is None:
            return
        entry["events"].append(
            {
                "time": datetime.datetime.now().strftime("%H:%M:%S"),
                "level": level,
                "message": message,
            }
        )
        if stage is not None:
            entry["stage"] = stage
        if progress is not None:
            new_prog = float(progress)
            if new_prog > entry.get("progress", 0.0):
                entry["progress"] = new_prog
        entry["message"] = message
        entry["updated_at"] = time.time()
        if len(entry["events"]) > 500:
            entry["events"] = entry["events"][-500:]


def _job_add_file(session_id: str, name: str, size: int) -> None:
    if not session_id:
        return
    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        if entry is None:
            return
        entry["files"].append({"name": name, "size": size})
        entry["total_files"] = len(entry["files"])
        entry["updated_at"] = time.time()


def _job_finish(session_id: str, *, error: str | None = None) -> None:
    if not session_id:
        return
    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        if entry is None:
            return
        entry["done"] = True
        entry["error"] = error
        entry["stage"] = "error" if error else "complete"
        if error is None:
            entry["progress"] = 1.0
        entry["updated_at"] = time.time()
        entry["events"].append(
            {
                "time": datetime.datetime.now().strftime("%H:%M:%S"),
                "level": "error" if error else "info",
                "message": error if error else "✅ Processing complete",
            }
        )


def _job_cancel(session_id: str) -> None:
    if not session_id:
        return
    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        if entry is None:
            return
        entry["done"] = True
        entry["error"] = None
        entry["stage"] = "cancelled"
        entry["message"] = "Cancelled by user"
        entry["updated_at"] = time.time()
        entry["events"].append(
            {
                "time": datetime.datetime.now().strftime("%H:%M:%S"),
                "level": "warning",
                "message": "🛑 Cancelled by user",
            }
        )


def _job_cleanup() -> None:
    cutoff = time.time() - JOB_TTL
    with job_progress_lock:
        stale = [
            k
            for k, v in _job_progress_store.items()
            if v.get("done") and v.get("updated_at", 0) < cutoff
        ]
        for k in stale:
            _job_progress_store.pop(k, None)


# ─── Panel log handler + routing ───────────────────────────────────────
# Which panel entry (if any) this thread's log lines go to.
# Value: ("job", session_id) | ("download", download_id) | None
_log_target: contextvars.ContextVar = contextvars.ContextVar("log_target", default=None)

_local = threading.local()


class PanelLogHandler(logging.Handler):
    """Route application log records to the active panel."""

    _CONSOLE_ONLY_SUBSTRINGS = (
        "messages=",
        "size stable but content",
        "reports total=",
    )

    def emit(self, record: logging.LogRecord) -> None:
        if getattr(_local, "inside", False):
            return
        _local.inside = True
        try:
            if record.name.startswith("werkzeug"):
                return
            target = _log_target.get()
            if not target:
                return
            kind, ident = target
            msg = record.getMessage()
            if any(s in msg for s in self._CONSOLE_ONLY_SUBSTRINGS):
                return
            lvl = (record.levelname or "info").lower()
            if lvl not in ("info", "warning", "error"):
                lvl = "info"
            if kind == "job":
                _job_log(ident, msg, level=lvl)
            elif kind == "download":
                _progress_event(ident, msg, level=lvl)
        except (AttributeError, TypeError, ValueError, KeyError):
            pass
        finally:
            _local.inside = False
