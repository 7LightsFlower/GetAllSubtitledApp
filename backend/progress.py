"""404 bookkeeping, per-session log panel, download + job progress stores.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import contextvars
import datetime
import logging
import os
import threading
import time
from flask import g, jsonify, request

from .flask_app import app
from .servers import INTERNAL_SERVER_URL
from .config import _state, jobs, sessions
from .utils import _log_token_email, _session_dir, _short_sid


# Consecutive HTTP 404s per session. Used to keep a wrong or stale
# session id from spamming the log and the progress panel while the
# background worker spins. Reset as soon as the session responds.
def _note_404(session_id: str, url: str) -> int:
    """Bump and return the consecutive-404 counter for a session.

    Logs the first and fifth occurrence, then silences the rest so a
    stale session id doesn't fill the log with one line every poll.
    Returns the new count so the caller can decide whether to give up.
    """
    with _consecutive_404s_lock:
        n = _consecutive_404s.get(session_id, 0) + 1
        _consecutive_404s[session_id] = n

    if n == 1:
        logging.warning(
            "messages.json 404 for session %s (%s)",
            _short_sid(session_id),
            url,
        )
    elif n == 5:
        logging.warning(
            "messages.json still 404 for session %s after %d attempts; "
            "further 404s for this session will be silenced",
            _short_sid(session_id),
            n,
        )
    return n


def _clear_404(session_id: str) -> None:
    """Forget the 404 counter for a session once it starts responding."""
    with _consecutive_404s_lock:
        _consecutive_404s.pop(session_id, None)


# Which panel entry (if any) this thread's log lines should be routed to.
# Value is either ('job', session_id) or ('download', download_id), or None.
_log_target: contextvars.ContextVar = contextvars.ContextVar("log_target", default=None)
_local = threading.local()  # re-entrancy guard


class _PanelLogHandler(logging.Handler):
    # Substrings that should go to the console only, not to the panel.
    # The polling chatter from wait_for_session_ready is useful in the
    # terminal but drowns out everything else in the panel.
    _CONSOLE_ONLY_SUBSTRINGS = (
        "messages=",
        "size stable but content",
        "reports total=",
    )

    def emit(self, record):
        # Never recurse into ourselves.
        if getattr(_local, "inside", False):
            return
        _local.inside = True
        try:
            # Skip noisy werkzeug request logs ("GET /job_progress/...").
            if record.name.startswith("werkzeug"):
                return

            target = _log_target.get()
            if not target:
                return

            kind, ident = target
            msg = record.getMessage()

            # Check if the log message should only go to the console.
            if any(substring in msg for substring in self._CONSOLE_ONLY_SUBSTRINGS):
                return

            lvl = (record.levelname or "info").lower()
            if lvl not in ("info", "warning", "error"):
                lvl = "info"

            if kind == "job":
                _job_log(ident, msg, level=lvl)
            elif kind == "download":
                _progress_event(ident, msg, level=lvl)
        except (AttributeError, TypeError, ValueError, KeyError):
            # Logging must never crash the app.
            pass
        finally:
            _local.inside = False


# Install it on the root logger. The Flask console handler is still there,
# so you keep seeing everything in the terminal as before.
_panel_handler = _PanelLogHandler()
_panel_handler.setLevel(logging.INFO)
logging.getLogger().addHandler(_panel_handler)


# ─── ROUTE REQUEST LOGS TO THE RIGHT PANEL ────────────────────────────
# Any endpoint whose URL carries a session_id. When Flask handles one
# of these, we set _log_target so logging.* calls made during that
# request show up in that session's JobProgressPanel — not just in the
# console.
_SESSION_SCOPED_ENDPOINTS = {
    "get_session_output",
    "session_refresh",
    "session_resync",
    "job_progress",
    "session_transcript_save_vtt",
    "download_session_zip",
    "session_messages_json",
    "session_tts",
    "extract_video_subtitles",
    "update_video_subtitles",
    "session_languages",
    "session_transcript_json",
    "session_file",
    "session_export",
    "session_export_txt",
    "session_export_docx",
    "session_export_rtf",
    "session_export_structured_json",
    "session_export_all_languages",
}


@app.before_request
def _route_logs_to_session_panel():
    """Bind the current request's logging to its session's panel."""
    endpoint = request.endpoint or ""
    if endpoint not in _SESSION_SCOPED_ENDPOINTS:
        return
    session_id = (request.view_args or {}).get("session_id")
    if not session_id:
        return
    # Stash the token so teardown can restore the previous value.
    setattr(g, "_panel_log_token", _log_target.set(("job", session_id)))


@app.before_request
def _capture_auth_token():
    """Remember the most recent bearer token we saw.
    ...
    """
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        token = auth[7:].strip()
        if token:
            logging.debug(
                "before_request: token email = %r",
                token.split("|")[-1].strip() if "|" in token else "<none>",
            )
            _state["token"] = token
            return
    cookie = request.cookies.get("_forward_auth", "")
    if cookie:
        _log_token_email(cookie, "before_request(cookie)")
        _state["token"] = cookie


@app.teardown_request
def _unroute_logs_from_session_panel(_exc):
    """Restore the previous _log_target after the request finishes.

    Flask calls this twice for streaming responses (`stream_with_context`
    keeps the request context alive across the generator, so both the
    initial and the streamed context get popped). The token we stashed
    in before_request can only be reset once, so guard against the
    second call with a flag on `g`.
    """
    if getattr(g, "panel_log_reset", False):
        return

    token = getattr(g, "_panel_log_token", None)
    if token is None:
        return

    g.panel_log_reset = True
    try:
        _log_target.reset(token)
    except (ValueError, LookupError, RuntimeError):
        # Token was already reset (streaming teardown) or came from a
        # different context. Both are safe to ignore.
        pass


def generate_mock_transcript():
    """Return a static sample transcript."""
    return (
        "This is a sample transcript generated by the mock server.\n"
        "It contains multiple sentences that demonstrate the output format.\n"
        "The lecture covers important topics in artificial intelligence "
        "and machine learning.\n"
        "Deep learning models have revolutionized the field of "
        "natural language processing.\n"
        "Transformers, in particular, have become the backbone of "
        "modern AI systems."
    )


def generate_mock_segments():
    """Return a list of mock transcript segments with timestamps."""
    return [
        {
            "text": "This is a sample transcript generated by the mock server.",
            "start": 0.0,
            "end": 5.2,
            "language": "en",
        },
        {
            "text": "It contains multiple sentences that demonstrate "
            "the output format.",
            "start": 5.2,
            "end": 10.8,
            "language": "en",
        },
        {
            "text": "The lecture covers important topics in artificial "
            "intelligence and machine learning.",
            "start": 10.8,
            "end": 16.5,
            "language": "en",
        },
        {
            "text": "Deep learning models have revolutionized the field of "
            "natural language processing.",
            "start": 16.5,
            "end": 22.3,
            "language": "en",
        },
        {
            "text": "Transformers, in particular, have become the backbone of "
            "modern AI systems.",
            "start": 22.3,
            "end": 28.0,
            "language": "en",
        },
    ]


# ─── DOWNLOAD PROGRESS TRACKING ────────────────────────────────────────
download_progress: dict = {}
download_progress_lock = threading.Lock()
_PROGRESS_TTL = 3600  # keep finished entries for 1 hour


def _progress_init(download_id: str, url: str):
    """Create a new progress entry."""
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
    download_id: str,
    message: str,
    *,
    level: str = "info",
    stage: str | None = None,
    progress: float | None = None,
    details: dict | None = None,
):
    """Append a log line / update the state for a download."""
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


def _progress_finish(
    download_id: str, *, error: str | None = None, details: dict | None = None
):
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


def _progress_cleanup_old():
    """Drop entries older than _PROGRESS_TTL."""
    cutoff = time.time() - _PROGRESS_TTL
    with download_progress_lock:
        stale = [
            k
            for k, v in download_progress.items()
            if v.get("done") and v.get("started_at", 0) < cutoff
        ]
        for k in stale:
            download_progress.pop(k, None)


@app.route("/api/download-progress/<download_id>", methods=["GET", "OPTIONS"])
def download_progress_status(download_id):
    """Return the current state of an in-flight YouTube download."""
    if request.method == "OPTIONS":
        return ("", 204)

    _progress_cleanup_old()

    with download_progress_lock:
        entry = download_progress.get(download_id)

    if entry is None:
        return jsonify({"error": "not_found", "download_id": download_id}), 404

    return jsonify(entry), 200


# ─── JOB PROGRESS TRACKING (per session) ───────────────────────────────
_job_progress_store: dict = {}
job_progress_lock = threading.Lock()
_JOB_TTL = 7200  # keep finished entries for 2 hours


# Sessions whose background worker has been asked to stop. The worker
# checks this set between poll iterations and again before each file
# download; the /cancel_session endpoint adds to it.
_cancelled_sessions: set[str] = set()
_cancelled_sessions_lock = threading.Lock()


# ─── ADD THIS ──────────────────────────────────────────────────────────
# Consecutive HTTP 404s per session. Used to keep a wrong or stale
# session id from spamming the log and the progress panel while the
# background worker spins. Reset as soon as the session responds.
_consecutive_404s: dict[str, int] = {}
_consecutive_404s_lock = threading.Lock()
# ───────────────────────────────────────────────────────────────────────


class _JobCancelled(Exception):
    """Raised inside a background worker when its session is cancelled."""


def _request_cancel(session_id: str) -> None:
    with _cancelled_sessions_lock:
        _cancelled_sessions.add(session_id)


def _is_cancelled(session_id: str) -> bool:
    with _cancelled_sessions_lock:
        return session_id in _cancelled_sessions


def _clear_cancel(session_id: str) -> None:
    with _cancelled_sessions_lock:
        _cancelled_sessions.discard(session_id)


# Sessions where the user pressed "Finish now": stop waiting for slow
# translation tracks and download whatever KIT has produced so far.
_finish_now_sessions: set[str] = set()


def _request_finish_now(session_id: str) -> None:
    with _cancelled_sessions_lock:
        _finish_now_sessions.add(session_id)


def _take_finish_now(session_id: str) -> bool:
    """True once if "Finish now" was requested (clears the flag)."""
    with _cancelled_sessions_lock:
        if session_id in _finish_now_sessions:
            _finish_now_sessions.discard(session_id)
            return True
        return False


def _job_start(session_id: str, video_key: str | None, session_name: str | None):
    """Create a job-progress entry for a session.

    Idempotent: if an entry for this session already exists it is left
    alone. That matters because the upload handler pre-creates the entry
    before returning (so the panel's first poll finds it), and the
    background worker also calls this — the second call must not wipe
    events the first one may have written in between.
    """
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


def _job_log(
    session_id: str,
    message: str,
    *,
    level: str = "info",
    stage: str | None = None,
    progress: float | None = None,
):
    """Append a log line / update the state for a session's job."""
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
            # Monotonic: never let the bar move backwards. The
            # translation phase reports coverage of the video, and the
            # download phase that follows reports its own smaller
            # numbers — the bar should stay where it was.
            if new_prog > entry.get("progress", 0.0):
                entry["progress"] = new_prog
        entry["message"] = message
        entry["updated_at"] = time.time()
        # Bound memory: keep the last 500 events per session
        if len(entry["events"]) > 500:
            entry["events"] = entry["events"][-500:]


def _job_add_file(session_id: str, name: str, size: int):
    if not session_id:
        return
    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        if entry is None:
            return
        entry["files"].append({"name": name, "size": size})
        entry["total_files"] = len(entry["files"])
        entry["updated_at"] = time.time()


def _job_finish(session_id: str, *, error: str | None = None):
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


def _job_cancel(session_id: str):
    """Mark a session's progress entry as cancelled (a third state —
    distinct from both 'complete' and 'error')."""
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


def _job_cleanup():
    cutoff = time.time() - _JOB_TTL
    with job_progress_lock:
        stale = [
            k
            for k, v in _job_progress_store.items()
            if v.get("done") and v.get("updated_at", 0) < cutoff
        ]
        for k in stale:
            _job_progress_store.pop(k, None)


@app.route("/job-progress/<path:session_id>", methods=["GET", "OPTIONS"])
def job_progress(session_id):
    """Progress endpoint polled by JobProgressPanel."""
    if request.method == "OPTIONS":
        origin = request.headers.get("Origin", "")
        r = jsonify({"message": "OK"})
        r.headers["Access-Control-Allow-Origin"] = origin
        r.headers["Access-Control-Allow-Headers"] = "Content-Type,Authorization"
        r.headers["Access-Control-Allow-Methods"] = "GET,OPTIONS"
        r.headers["Access-Control-Allow-Credentials"] = "true"
        return r, 200

    _job_cleanup()

    # ── 1. Disk state ─────────────────────────────────────────────
    session_dir = _session_dir(session_id)
    disk_files = []
    if os.path.exists(session_dir):
        disk_files = [
            {"name": f, "size": os.path.getsize(os.path.join(session_dir, f))}
            for f in os.listdir(session_dir)
            if os.path.isfile(os.path.join(session_dir, f))
            and _is_meaningful_file(os.path.join(session_dir, f))
        ]
    disk_names = {f["name"] for f in disk_files}
    has_transcript = "transcripts.json" in disk_names or "messages.json" in disk_names

    # ── 2. Rich in-memory entry ───────────────────────────────────
    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        snapshot = dict(entry) if entry else None

    if snapshot is not None:
        merged = {f["name"]: f for f in snapshot.get("files", [])}
        for f in disk_files:
            merged[f["name"]] = f
        snapshot["files"] = list(merged.values())
        snapshot["total_files"] = len(snapshot["files"])

        if has_transcript and not snapshot.get("done"):
            snapshot["done"] = True
            snapshot["progress"] = 1.0
            snapshot["stage"] = "ready"
            snapshot["error"] = None

        return jsonify(snapshot), 200

    # ── 3. Disk has files, no memory entry (post-restart) ────────
    if has_transcript:
        return (
            jsonify(
                {
                    "session_id": session_id,
                    "stage": "ready",
                    "progress": 1.0,
                    "done": True,
                    "error": None,
                    "message": f"Ready — {len(disk_files)} files",
                    "files": disk_files,
                    "total_files": len(disk_files),
                    "events": [],
                }
            ),
            200,
        )

    # ── 4. No memory entry, no disk files ────────────────────────
    # If a persisted job for this session is still marked "processing",
    # the worker thread was almost certainly killed by a server restart.
    # Restart it once, using the bearer token the panel is sending.
    persisted = jobs.get(session_id)
    if persisted is not None and persisted.get("status") == "processing":
        token = request.headers.get("Authorization", "").replace("Bearer ", "")
        if token:
            # Atomically claim the recovery slot. Without this, two
            # concurrent polls can both see `_recovery_started == False`
            # and both spawn a worker.
            with job_progress_lock:
                claimed = not persisted.get("_recovery_started")
                if claimed:
                    persisted["_recovery_started"] = True

            if claimed:
                video_key = persisted.get("video_key")
                server_url = (
                    sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
                )
                expected_mt = sessions.get(session_id, {}).get("expected_mt")
                logging.info(
                    "♻️ Restarting background worker for %s on %s "
                    "(waiting for translations: %s)",
                    _short_sid(session_id),
                    server_url,
                    expected_mt or "any",
                )
                threading.Thread(
                    target=process_session_in_background,
                    args=(session_id, token, video_key, server_url),
                    daemon=True,
                ).start()
                return (
                    jsonify(
                        {
                            "session_id": session_id,
                            "stage": "starting",
                            "progress": 0.0,
                            "done": False,
                            "error": None,
                            "message": "Resuming after server restart…",
                            "files": disk_files,
                            "total_files": len(disk_files),
                            "events": [],
                        }
                    ),
                    200,
                )
            # else: another request already claimed recovery. Fall
            # through to the "resuming" response below.

    # ── 5. Truly unknown — stop the panel from polling forever ───
    # Either a stale session id, or the persisted job already finished.
    if persisted is None or persisted.get("status") != "processing":
        return (
            jsonify(
                {
                    "session_id": session_id,
                    "stage": "error",
                    "progress": 0.0,
                    "done": True,  # ← releases the panel
                    "error": (
                        "Session tracking lost. The server was restarted during "
                        "processing. Click 'Check Status' to retry the download."
                    ),
                    "message": "Session tracking lost",
                    "files": disk_files,
                    "total_files": len(disk_files),
                    "events": [],
                }
            ),
            200,
        )

    # ── 6. Recovery already started, just waiting ────────────────
    return (
        jsonify(
            {
                "session_id": session_id,
                "stage": "starting",
                "progress": 0.0,
                "done": False,
                "error": None,
                "message": "Resuming after server restart…",
                "files": disk_files,
                "total_files": len(disk_files),
                "events": [],
            }
        ),
        200,
    )


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global _is_meaningful_file, process_session_in_background
    from .session_worker import process_session_in_background
    from .video_routes import _is_meaningful_file
