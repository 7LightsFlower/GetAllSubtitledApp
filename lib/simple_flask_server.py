#!/usr/bin/env python3
"""Merged Flask server combining mock server and upload proxy functionality."""

import base64
import contextvars
import datetime
from email.utils import quote
import importlib
import hashlib
import io
import json
import logging
import mimetypes
import os
import pickle
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile
from urllib.parse import quote

import requests
import yt_dlp
from flask import Flask, g, jsonify, request, send_file
from flask_cors import CORS
from docx import Document
from docx.shared import Pt, RGBColor

# BeautifulSoup is imported only when needed for HTML parsing
has_bs4 = False
try:
    from bs4 import BeautifulSoup

    has_bs4 = True
except ImportError:
    logging.warning("BeautifulSoup not installed. Export functions will be limited.")

logging.basicConfig(level=logging.DEBUG)
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 1024 * 1024 * 1024
app.config["DEBUG"] = True

CORS(
    app,
    origins=[
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://localhost:5000",
        "http://127.0.0.1:5000",
        "https://getallsubtitledapp.isl.iar.kit.edu",
    ],
    supports_credentials=True,
    methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=[
        "Content-Type",
        "Authorization",
        "X-Forwarded-User",
        "Accept",
        "Cache-Control",
        "Pragma",
        "Expires",
        "Range",
    ],
    expose_headers=["Location", "Content-Disposition"],
)


@app.after_request
def add_no_cache_for_api(response):
    """Never let the browser or any proxy cache API / session responses.

    The web tier (index.html, main.dart.js, ...) is served by nginx and
    gets its own cache policy. Everything Flask returns is dynamic and
    must always be re-fetched.
    """
    if request.path.startswith(
        (
            "/job_progress/",
            "/session_output/",
            "/session_file/",
            "/session_languages/",
            "/session_transcript_json/",
            "/api/",
        )
    ):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response


# Servers we are willing to forward uploads to. The client may only
# pick from this list.
ALLOWED_TARGET_SERVERS = {
    "https://lt2srv-sscherrer.isl.iar.kit.edu",
    "https://lecture-translator.kit.edu",
    "https://lt2srv-backup.iar.kit.edu",
}
INTERNAL_SERVER_URL = "https://lt2srv-sscherrer.isl.iar.kit.edu"  # default


def _resolve_target_url(requested: str | None) -> str:
    """Pick a target upload URL, restricted to the allow-list."""
    if requested and requested.rstrip("/") in ALLOWED_TARGET_SERVERS:
        return f"{requested.rstrip('/')}/upload_lecture"
    if requested:
        logging.warning("Rejected unknown target server: %r", requested)
    return f"{INTERNAL_SERVER_URL}/upload_lecture"


TARGET_URL = f"{INTERNAL_SERVER_URL}/upload_lecture"
BASE_URL = INTERNAL_SERVER_URL
UPLOAD_FOLDER = os.path.join(os.path.dirname(__file__), "uploads")
SESSION_FOLDER = os.path.join(os.path.dirname(__file__), "sessions")
STATE_FILE = os.path.join(os.path.dirname(__file__), "server_state.pkl")
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(SESSION_FOLDER, exist_ok=True)

users = {}
videos = []
chunk_storage = {}
jobs = {}
sessions = {}
internal_session = requests.Session()
internal_session.verify = False
_state = {"token": None}
_warned_senders: set[str] = set()


_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_LANGUAGES_JSON = os.path.normpath(
    os.path.join(_SCRIPT_DIR, "..", "assets", "languages.json")
)


def _load_language_names() -> dict:
    """Load code -> name from assets/languages.json.

    Falls back to an empty dict (with a warning) if the file is missing,
    so the server still starts in an emergency.
    """
    try:
        with open(_LANGUAGES_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
        names = data.get("names") or {}
        if not isinstance(names, dict) or not names:
            raise ValueError("languages.json has no 'names' object")
        logging.info("Loaded %d language names from %s", len(names), _LANGUAGES_JSON)
        return {str(k): str(v) for k, v in names.items()}
    except (OSError, json.JSONDecodeError, ValueError) as e:
        logging.error("Could not load %s: %s", _LANGUAGES_JSON, e)
        return {}


LANGUAGE_NAMES = _load_language_names()

# Regex for a bare 2-letter code
_LANG_CODE_RE = re.compile(r"^([a-z]{2})$", re.IGNORECASE)


def full_language_name(code_or_name: str) -> str:
    """Return the full English name for a code, else the input unchanged."""
    if not code_or_name:
        return code_or_name or ""
    key = code_or_name.strip().lower()
    return LANGUAGE_NAMES.get(key, code_or_name.strip())


# ─── STATE PERSISTENCE ──────────────────────────────────────────────────


# Hash of the last state we actually wrote to disk. Used by save_state()
# to skip redundant writes when nothing meaningful changed.
# Store this in a mutable container so save_state() can update it without
# using a module-level global statement.
_state_cache = {"last_hash": None}


def _state_payload() -> dict:
    """The part of the state that actually matters for persistence.

    Kept separate from the on-disk blob so the 'timestamp' field does not
    invalidate the dedup hash on every call.
    """
    return {
        "users": users,
        "videos": videos,
        "jobs": jobs,
        "sessions": sessions,
    }


def save_state(force: bool = False):
    """Save server state to disk.

    Skips the write entirely when the meaningful state is byte-identical
    to the last successful save, unless `force=True` is passed.
    """
    try:
        payload = _state_payload()
        blob = pickle.dumps(payload)
        digest = hashlib.sha256(blob).hexdigest()

        if not force and digest == _state_cache["last_hash"]:
            # Nothing changed since the last write — don't touch the disk
            # and don't spam the log.
            return

        state = {
            **payload,
            "timestamp": datetime.datetime.now().isoformat(),
        }
        with open(STATE_FILE, "wb") as f:
            pickle.dump(state, f)

        _state_cache["last_hash"] = digest
        logging.info("State saved to %s", STATE_FILE)
    except (OSError, pickle.PickleError, TypeError, ValueError) as e:
        logging.error("Failed to save state: %s", e)


def load_state():
    """Load server state from disk."""
    if not os.path.exists(STATE_FILE):
        logging.info("No state file found. Starting with default state.")
        return False

    try:
        with open(STATE_FILE, "rb") as f:
            state = pickle.load(f)

        loaded_state = {
            "users": state.get("users", {}),
            "videos": state.get("videos", []),
            "jobs": state.get("jobs", {}),
            "sessions": state.get("sessions", {}),
        }
        globals().update(loaded_state)

        logging.info("State loaded from %s", STATE_FILE)
        logging.info("  - Users: %d", len(users))
        logging.info("  - Videos: %d", len(videos))
        logging.info("  - Jobs: %d", len(jobs))
        logging.info("  - Sessions: %d", len(sessions))

        # Verify video files still exist and update status
        for video in videos:
            file_name = video.get("file_name")
            if file_name:
                file_path = os.path.join(UPLOAD_FOLDER, file_name)
                if not os.path.exists(file_path):
                    logging.warning("Video file missing: %s", file_path)
                    video["file_missing"] = True
                else:
                    video["file_missing"] = False

        return True
    except (
        FileNotFoundError,
        OSError,
        pickle.PickleError,
        EOFError,
        AttributeError,
        TypeError,
        ValueError,
    ) as e:
        logging.error("Failed to load state: %s", e)
        return False


def clean_missing_videos():
    """Remove video entries whose files no longer exist on disk."""
    if not videos:
        return

    valid_videos = []
    removed_count = 0

    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            # Skip entries without a filename
            removed_count += 1
            logging.warning(
                "Removing video entry with no filename: %s",
                video.get("name", "Unknown"),
            )
            continue

        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if os.path.exists(file_path):
            valid_videos.append(video)
        else:
            removed_count += 1
            logging.warning(
                "Removing missing video: %s (key: %s)",
                file_name,
                video.get("key", "N/A"),
            )

            # Also remove any associated thumbnail
            thumb_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
            thumb_path = os.path.join(UPLOAD_FOLDER, thumb_filename)
            if os.path.exists(thumb_path):
                try:
                    os.remove(thumb_path)
                    logging.info("Removed orphaned thumbnail: %s", thumb_filename)
                except OSError as e:
                    logging.warning(
                        "Could not remove thumbnail %s: %s", thumb_filename, e
                    )

    if removed_count > 0:
        videos[:] = valid_videos
        save_state()
        logging.info(
            "🧹 Cleaned up %d missing video(s). %d video(s) remain.",
            removed_count,
            len(videos),
        )
    else:
        logging.info("✅ All %d video(s) are valid.", len(videos))


def cleanup_orphaned_data():
    """Remove orphaned sessions and jobs that reference non-existent videos."""
    # These dictionaries are mutated in place; rebinding their module-level
    # names is not necessary.
    session_store = sessions
    job_store = jobs

    # Get valid video keys
    valid_video_keys = {video.get("key") for video in videos if video.get("key")}

    # Clean up sessions
    orphaned_sessions = []
    for session_id, session in session_store.items():
        video_key = session.get("video_key")
        if video_key and video_key not in valid_video_keys:
            orphaned_sessions.append(session_id)
            logging.warning(
                "Removing orphaned session %s (video_key: %s)",
                _short_sid(session_id),
                video_key,
            )

            # Also remove session files if they exist
            session_dir = os.path.join(SESSION_FOLDER, session_id)
            if os.path.exists(session_dir):
                try:
                    shutil.rmtree(session_dir)
                    logging.info("Removed session directory: %s", session_dir)
                except OSError as e:
                    logging.warning(
                        "Could not remove session directory %s: %s", session_dir, e
                    )

    for session_id in orphaned_sessions:
        del session_store[session_id]

    # Clean up jobs
    orphaned_jobs = []
    for job_id, job in job_store.items():
        video_key = job.get("video_key")
        if video_key and video_key not in valid_video_keys:
            orphaned_jobs.append(job_id)
            logging.warning(
                "Removing orphaned job %s (video_key: %s)", job_id, video_key
            )

    for job_id in orphaned_jobs:
        del job_store[job_id]

    if orphaned_sessions or orphaned_jobs:
        save_state()
        logging.info(
            "🧹 Cleaned up %d orphaned session(s) and %d orphaned job(s)",
            len(orphaned_sessions),
            len(orphaned_jobs),
        )


def regenerate_missing_thumbnails():
    """Regenerate thumbnails for videos whose thumbnail file is missing.

    The previous version only checked whether `thumbnail_url` was set,
    which meant a deleted `_thumb.jpg` was never rebuilt. We now verify
    the file actually exists on disk before skipping.
    """
    if not videos:
        return

    regenerated = 0
    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            continue

        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if not os.path.exists(file_path):
            continue

        thumbnail_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
        thumb_url = video.get("thumbnail_url")

        # URL claims a thumbnail exists AND the file is actually there → OK.
        if thumb_url and thumb_url != "None" and os.path.exists(thumbnail_path):
            continue

        # Otherwise (re)generate it.
        if generate_video_thumbnail(file_path, thumbnail_path):
            video["thumbnail_url"] = f"/thumbnails/{thumbnail_filename}"
            regenerated += 1
            logging.info("Generated thumbnail for %s", file_name)
        else:
            video["thumbnail_url"] = None

    if regenerated > 0:
        save_state()
        logging.info("🖼️ Regenerated %d thumbnail(s)", regenerated)


def parse_html_with_bs4(html_content):
    """Parse HTML content using BeautifulSoup if available."""
    if has_bs4 and html_content:
        try:
            soup = BeautifulSoup(html_content, "html.parser")
            return soup
        except (TypeError, ValueError) as e:
            logging.warning("Failed to parse HTML with BeautifulSoup: %s", e)
    return None


def ensure_authenticated(token: str) -> bool:
    """Check if the current session has a valid cookie."""
    if token == _state["token"] and internal_session.cookies:
        try:
            resp = internal_session.get(
                INTERNAL_SERVER_URL, allow_redirects=False, timeout=5
            )
            if resp.status_code == 200 and "dex" not in resp.url:
                return True
        except requests.exceptions.RequestException:
            pass
    headers = {"Authorization": f"Bearer {token}"}
    try:
        resp = internal_session.get(
            INTERNAL_SERVER_URL, headers=headers, allow_redirects=False, timeout=10
        )
        if resp.status_code == 200 and "dex" not in resp.url:
            _state["token"] = token
            return True
        return False
    except requests.exceptions.RequestException:
        return False


def utc_now_iso():
    """Return current UTC time in ISO 8601 with milliseconds and 'Z'."""
    return (
        datetime.datetime.now(datetime.UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _public_base_url() -> str:
    """Base URL the browser should use, honouring the proxy chain.

    nginx fronts this container over plain HTTP and sets
    ``X-Forwarded-Proto: $scheme`` (= "http") unconditionally, so that
    header carries no information here. What *is* reliable is the host:
    if the browser reached us through a real hostname, the outer proxy
    terminated TLS, so the URL we hand back must be https. If the host
    is localhost / 127.0.0.1 we're in local development and http is right.
    """
    fwd_host = request.headers.get("X-Forwarded-Host")
    if fwd_host:
        bare = fwd_host.split(":", 1)[0]
        proto = "http" if bare in ("localhost", "127.0.0.1") else "https"
        return f"{proto}://{fwd_host}".rstrip("/")
    return request.host_url.rstrip("/")


def _thumbnail_absolute_url(video: dict) -> str | None:
    """Build a browser-usable, percent-encoded thumbnail URL.

    Stored `thumbnail_url` values are relative ("/thumbnails/x.jpg")
    and may contain spaces / non-ASCII characters from the original
    video title. Concatenating them onto the base URL verbatim
    produces an invalid URL that Image.network silently rejects.
    """
    thumb = video.get("thumbnail_url")
    if not thumb or not thumb.startswith("/thumbnails/"):
        return thumb
    filename = thumb[len("/thumbnails/"):]
    return f"{_public_base_url()}/thumbnails/{quote(filename, safe='')}"


def _short_sid(session_id: str | None, keep: int = 8) -> str:
    """First N chars of a session id, for logs.

    Session ids here are base64-encoded paths and can be 120+ chars.
    Logging them in full drowns out everything else. The full id is
    still used for filesystem paths and HTTP responses.
    """
    if not session_id:
        return "<none>"
    return session_id[:keep] + "…"


# Which panel entry (if any) this thread's log lines should be routed to.
# Value is either ('job', session_id) or ('download', download_id), or None.
_log_target: contextvars.ContextVar = contextvars.ContextVar("log_target", default=None)
_local = threading.local()  # re-entrancy guard


class _PanelLogHandler(logging.Handler):
    # Substrings that should go to the console only, not to the panel.
    # The polling chatter from wait_for_session_ready is useful in the
    # terminal but drowns out everything else in the panel.
    _CONSOLE_ONLY_SUBSTRINGS = (
        "messages.json size=",
        "size stable but content",
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


@app.teardown_request
def _unroute_logs_from_session_panel(_exc):
    """Restore the previous _log_target after the request finishes."""
    token = getattr(g, "_panel_log_token", None)
    if token is None:
        return
    try:
        _log_target.reset(token)
    except (ValueError, LookupError):
        # Token was created in a different context — safe to ignore.
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


def _job_start(session_id: str, video_key: str | None, session_name: str | None):
    """Create a fresh job-progress entry for a session."""
    with job_progress_lock:
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


@app.route("/job_progress/<path:session_id>", methods=["GET", "OPTIONS"])
def job_progress(session_id):
    """Progress endpoint polled by JobProgressPanel."""
    if request.method == "OPTIONS":
        r = jsonify({"message": "OK"})
        r.headers.add("Access-Control-Allow-Origin", "*")
        r.headers.add("Access-Control-Allow-Headers", "Content-Type,Authorization")
        r.headers.add("Access-Control-Allow-Methods", "GET,OPTIONS")
        return r, 200

    _job_cleanup()

    # ── 1. Disk state ─────────────────────────────────────────────
    session_dir = os.path.join(SESSION_FOLDER, session_id)
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
    if (
        persisted is not None
        and persisted.get("status") == "processing"
        and not persisted.get("_recovery_started")
    ):
        token = request.headers.get("Authorization", "").replace("Bearer ", "")
        if token:
            persisted["_recovery_started"] = True
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


@app.route("/cancel_session/<path:session_id>", methods=["POST", "OPTIONS"])
def cancel_session(session_id):
    """Ask the background worker for this session to stop.

    Sets a flag; the worker checks it in its wait loop and between file
    downloads. This call does not block waiting for the worker to die —
    the panel reflects the change on the next poll.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    logging.info("🛑 Cancel requested for session %s", _short_sid(session_id))

    _request_cancel(session_id)

    # Update persisted state immediately so a page reload or a cold
    # panel poll sees the cancelled status right away.
    job = jobs.get(session_id)
    if job and job.get("status") == "processing":
        job["status"] = "cancelled"
    _job_cancel(session_id)
    save_state()

    return jsonify({"success": True, "session_id": session_id}), 200


def process_job(job_id):
    """Simulate background job processing with progress updates."""
    job = jobs.get(job_id)
    if not job:
        return

    # Get the video key and find the original video
    video_key = job.get("video_key")
    original_video = None
    if video_key:
        for video in videos:
            if video.get("key") == video_key:
                original_video = video
                break

    # Persist the "processing" status once, so a restart during the job
    # can still see that this video was mid-flight.
    save_state()

    progress = 0.0
    while progress < 1.0:
        time.sleep(1)
        progress += 0.1
        if progress > 1.0:
            progress = 1.0
        job["progress"] = progress

    # Loop is done — finalise the job.
    job["status"] = "completed"
    job["transcript"] = generate_mock_transcript()
    job["segments"] = generate_mock_segments()

    # Update the original video with processing results — DON'T create a new one
    if original_video:
        original_video["segmentation_done"] = True
        original_video["segmentation_progress"] = 100
        original_video["segment_count"] = len(job["segments"])
        original_video["languages"] = ["en"]
        logging.info("✅ Updated video %s with job results", original_video.get("name"))
    else:
        logging.warning("⚠️ No original video found for job %s", job_id)

    # Single write at the end of the job.
    save_state()


def generate_video_thumbnail(video_path, thumbnail_path, time_offset=1.0):
    """
    Generate a thumbnail from a video file using ffmpeg.
    Returns True if successful, False otherwise.
    """
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        cmd = [
            "ffmpeg",
            "-i",
            video_path,
            "-ss",
            str(time_offset),
            "-vframes",
            "1",
            "-vf",
            "scale=320:-1",
            "-q:v",
            "2",
            "-y",
            thumbnail_path,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        )
        if result.returncode == 0 and os.path.exists(thumbnail_path):
            return True
        logging.warning("FFmpeg failed: %s", result.stderr)
        return False
    except subprocess.TimeoutExpired:
        logging.warning("FFmpeg timeout generating thumbnail")
        return False
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logging.warning("FFmpeg error: %s", e)
        return False


def get_video_metadata(video_path):
    """
    Extract video metadata using ffprobe.
    Returns (duration, fps) or (120.0, 30.0) if failed.
    """
    try:
        cmd = [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=duration,r_frame_rate",
            "-of",
            "json",
            video_path,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=10, check=False
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            streams = data.get("streams", [])
            if streams:
                stream = streams[0]
                duration = float(stream.get("duration", 120.0))
                fps_str = stream.get("r_frame_rate", "30/1")
                if "/" in fps_str:
                    num, den = fps_str.split("/")
                    fps = float(num) / float(den) if float(den) > 0 else 30.0
                else:
                    fps = float(fps_str)
                return duration, fps
    except (
        subprocess.SubprocessError,
        FileNotFoundError,
        json.JSONDecodeError,
        TypeError,
        ValueError,
        OSError,
    ) as e:
        logging.warning("Failed to get video metadata: %s", e)
    return 120.0, 30.0


def curl_download(url, output_path, token):
    """
    Download a file using curl with authentication.
    Returns True if successful, False otherwise.
    """
    try:
        cmd = [
            "curl",
            "-s",
            "-L",
            "--insecure",
            "-H",
            f"X-Forward-Auth: {token}",
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "User-Agent: Mozilla/5.0 (compatible; LT-Uploader/1.0)",
            "--cookie",
            f"_forward_auth={token}",
            "-o",
            output_path,
            url,
        ]
        subprocess.run(cmd, capture_output=True, text=True, timeout=300, check=False)
        if os.path.exists(output_path) and os.path.getsize(output_path) > 1000:
            return True
        if os.path.exists(output_path):
            os.remove(output_path)
        return False
    except subprocess.TimeoutExpired as e:
        logging.warning("Curl timeout for %s: %s", url, str(e))
        return False
    except OSError as e:
        logging.warning("Curl error for %s: %s", url, str(e))
        return False


def curl_download_with_headers(url, output_path, token):
    """
    Download a file using curl with additional headers for authentication.
    """
    try:
        cmd = [
            "curl",
            "-s",
            "-L",
            "--insecure",
            "-H",
            f"X-Forward-Auth: {token}",
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "Accept: application/json",
            "-H",
            "User-Agent: Mozilla/5.0 (compatible; LT-Uploader/1.0)",
            "--cookie",
            f"_forward_auth={token}",
            "-o",
            output_path,
            url,
        ]
        subprocess.run(cmd, capture_output=True, text=True, timeout=300, check=False)
        if os.path.exists(output_path) and os.path.getsize(output_path) > 1000:
            return True
        if os.path.exists(output_path):
            os.remove(output_path)
        return False
    except subprocess.TimeoutExpired as e:
        logging.warning("Curl timeout for %s: %s", url, str(e))
        return False
    except OSError as e:
        logging.warning("Curl error for %s: %s", url, str(e))
        return False


def extract_text_from_file(file_path):
    """Extract transcript text from a file."""
    if not os.path.exists(file_path):
        return None
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    try:
        data = json.loads(content)
        text = extract_text_from_json(data)
        if text:
            return text
    except json.JSONDecodeError:
        pass
    if file_path.endswith((".vtt", ".srt")):
        text = extract_text_from_subtitle(content)
        if text:
            return text
    if content and len(content) > 10:
        return content
    return None


def extract_text_from_json(data):
    """Extract text from JSON data."""
    if isinstance(data, dict):
        for key in ["text", "content", "transcript", "seq"]:
            if key in data and data[key] and isinstance(data[key], str):
                return data[key]
        if "messages" in data and isinstance(data["messages"], list):
            texts = []
            for msg in data["messages"]:
                if isinstance(msg, dict):
                    text = extract_text_from_json(msg)
                    if text:
                        texts.append(text)
            if texts:
                return "\n".join(texts)
        if "data" in data and isinstance(data["data"], list):
            texts = []
            for item in data["data"]:
                text = extract_text_from_json(item)
                if text:
                    texts.append(text)
            if texts:
                return "\n".join(texts)
        for key, value in data.items():
            if isinstance(value, (dict, list)):
                text = extract_text_from_json(value)
                if text:
                    return text
    elif isinstance(data, list):
        texts = []
        for item in data:
            text = extract_text_from_json(item)
            if text:
                texts.append(text)
        if texts:
            return "\n".join(texts)
    return None


def extract_text_from_subtitle(content):
    """Extract text from VTT or SRT subtitle file."""
    lines = content.split("\n")
    text_lines = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if "-->" in line:
            continue
        if line.isdigit():
            continue
        if line.startswith("WEBVTT"):
            continue
        if line.startswith("Kind:"):
            continue
        if line.startswith("Language:"):
            continue
        text_lines.append(line)
    return " ".join(text_lines) if text_lines else None


def get_actual_file_url(session_id, filename, server_url, html_content=None):
    """
    Determine the correct URL for a file based on its type.

    `server_url` is the base URL of the internal server that owns the
    session (e.g. "https://lecture-translator.kit.edu"). Every returned
    URL is built against it, so a session that lives on a non-default
    server is downloaded from the right host.
    """
    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

    if html_content:
        if filename == "video.mp4":
            match = re.search(r'<source src="([^"]+)"', html_content)
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{server_url}{url}"
                return url
        if filename.startswith("subtitles_") and filename.endswith(".vtt"):
            label = filename.replace("subtitles_", "").replace(".vtt", "")
            match = re.search(
                rf'<track label="{label}" kind="subtitles" src="([^"]+)"',
                html_content,
            )
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{server_url}{url}"
                return url
        if filename.endswith(".wav"):
            match = re.search(r'<source src="([^"]+)"[^>]*type="audio/', html_content)
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{server_url}{url}"
                return url

    if filename == "messages.json":
        return f"{server_url}/archivemediafile/{session_id}/messages.json"
    if filename.endswith(".vtt"):
        label = filename.replace(".vtt", "")
        return f"{server_url}/archivemedia/{session_id}/vtt/{label}"
    if filename == "video.mp4":
        return f"{server_url}/archivemediafile/{session_id}/video.mp4"
    if filename.endswith(".wav"):
        encoded_name = filename.replace(" ", "%20")
        return f"{server_url}/archivemediafile/{session_id}/{encoded_name}"
    encoded_name = filename.replace(" ", "%20")
    return f"{server_url}/archivesession/{session_id}/{encoded_name}"


# pylint: disable=too-many-locals,too-many-branches,too-many-statements
_session_download_locks: dict[str, threading.Lock] = {}
_session_download_locks_guard = threading.Lock()


def _get_session_download_lock(session_id: str) -> threading.Lock:
    """One lock per session so /session_output and the BG worker
    never write the same files at the same time."""
    with _session_download_locks_guard:
        lock = _session_download_locks.get(session_id)
        if lock is None:
            lock = threading.Lock()
            _session_download_locks[session_id] = lock
        return lock


def download_session_files(session_id, token, server_url=None):
    """Download the media files and transcripts associated with a session."""
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")

    lock = _get_session_download_lock(session_id)
    if not lock.acquire(blocking=False):
        lock.acquire()
        lock.release()
        logging.info(
            "download_session_files: %s already downloaded by another "
            "thread, skipping",
            _short_sid(session_id),
        )
        return True

    try:
        session_dir = os.path.join(SESSION_FOLDER, session_id)
        if not _session_files_look_incomplete(session_dir):
            logging.info(
                "download_session_files: %s is already complete, skipping",
                _short_sid(session_id),
            )
            return True
        return _download_session_files_locked(session_id, token, server_url)
    finally:
        lock.release()


def _download_session_files_locked(session_id, token, server_url):
    """Download the media files and transcripts associated with a session."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    os.makedirs(session_dir, exist_ok=True)

    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before download"
        )

    logging.info("=" * 60)
    logging.info("Downloading session %s from %s", session_id, server_url)
    _job_log(
        session_id, "Downloading session files…", stage="downloading", progress=0.35
    )

    html_path = os.path.join(session_dir, "index.html")
    html_url = f"{server_url}/archivesession/{session_id}"

    if curl_download(html_url, html_path, token):
        logging.info("Downloaded index.html")
        _job_add_file(session_id, "index.html", os.path.getsize(html_path))
    else:
        _job_log(session_id, "Failed to download index.html", level="warning")
        return False

    html_content = ""
    try:
        with open(html_path, "r", encoding="utf-8") as f:
            html_content = f.read()
    except (OSError, UnicodeDecodeError):
        pass

    # Video
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before video download"
        )
    video_url = get_actual_file_url(session_id, "video.mp4", server_url, html_content)
    video_path = os.path.join(session_dir, "video.mp4")
    if curl_download(video_url, video_path, token):
        logging.info("Downloaded video.mp4")
        _job_log(
            session_id,
            f"Downloaded video.mp4 " f"({os.path.getsize(video_path)} bytes)",
            progress=0.5,
        )
        _job_add_file(session_id, "video.mp4", os.path.getsize(video_path))
    else:
        _job_log(session_id, "Failed to download video.mp4", level="warning")

    # Subtitles
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before subtitle download"
        )
    try:
        track_matches = re.findall(
            r'<track label="([^"]+)" kind="subtitles" src="([^"]+)"',
            html_content,
        )
        for label, src in track_matches:
            if src.startswith("/"):
                src = f"{server_url}{src}"
            file_name = f"subtitles_{label}.vtt"
            file_path = os.path.join(session_dir, file_name)
            if curl_download(src, file_path, token):
                logging.info("Downloaded %s", file_name)
                _job_log(
                    session_id,
                    f"Downloaded {file_name} " f"({os.path.getsize(file_path)} bytes)",
                )
                _job_add_file(session_id, file_name, os.path.getsize(file_path))
    except (OSError, re.error) as e:
        logging.warning("Could not download subtitles: %s", e)

    # Audio (if present)
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before audio download"
        )
    try:
        audio_match = re.search(r'<source src="([^"]+)"[^>]*type="audio/', html_content)
        if audio_match:
            audio_url = audio_match.group(1)
            if audio_url.startswith("/"):
                audio_url = f"{server_url}{audio_url}"
            audio_path = os.path.join(session_dir, "audio.wav")
            if curl_download(audio_url, audio_path, token):
                logging.info("Downloaded audio.wav")
                _job_add_file(session_id, "audio.wav", os.path.getsize(audio_path))
    except (OSError, re.error) as e:
        logging.warning("Could not download audio: %s", e)

    # messages.json
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before messages.json download"
        )
    messages_url = f"{server_url}/archivemediafile/{session_id}/messages.json"
    messages_path = os.path.join(session_dir, "messages.json")
    if curl_download(messages_url, messages_path, token):
        logging.info(
            "Downloaded messages.json (%d bytes)", os.path.getsize(messages_path)
        )
        _job_log(
            session_id,
            f"Downloaded messages.json " f"({os.path.getsize(messages_path)} bytes)",
            progress=0.85,
        )
        _job_add_file(session_id, "messages.json", os.path.getsize(messages_path))
    else:
        logging.warning("Failed to download messages.json")

    # Transcripts
    _job_log(session_id, "Extracting transcripts…", stage="extracting", progress=0.9)
    transcripts = extract_transcripts_from_messages(messages_path)
    if transcripts:
        save_transcripts_to_files(session_dir, transcripts)
        logging.info("Extracted %d transcripts from messages.json", len(transcripts))
        _job_add_file(
            session_id,
            "transcripts.json",
            os.path.getsize(os.path.join(session_dir, "transcripts.json")),
        )
        _job_add_file(
            session_id,
            "transcript.txt",
            os.path.getsize(os.path.join(session_dir, "transcript.txt")),
        )

        # ── NEW: generate VTTs from the transcripts we just wrote ──
        for vtt_name in generate_vtt_files_from_transcripts(session_dir):
            vtt_path = os.path.join(session_dir, vtt_name)
            _job_add_file(session_id, vtt_name, os.path.getsize(vtt_path))
            _job_log(session_id, f"Generated {vtt_name}")
    else:
        _job_log(session_id, "No transcripts extracted", level="warning")

    files = [
        f
        for f in os.listdir(session_dir)
        if os.path.isfile(os.path.join(session_dir, f))
        and _is_meaningful_file(os.path.join(session_dir, f))
    ]

    logging.info("=" * 60)
    logging.info(
        "Session %s: Downloaded %s files total", _short_sid(session_id), len(files)
    )
    for f in files:
        size = os.path.getsize(os.path.join(session_dir, f))
        logging.info("  - %s (%d bytes)", f, size)
    logging.info("=" * 60)

    _job_log(
        session_id,
        f"Session ready: {len(files)} files downloaded",
        stage="ready",
        progress=1.0,
    )
    return len(files) > 0


def safe_float(value, default=0.0):
    """Safely convert a value to float, handling strings and None."""
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except (ValueError, TypeError):
            return default
    return default


def _format_vtt_timestamp(seconds):
    """Format seconds to VTT timestamp format: HH:MM:SS.mmm"""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds % 1) * 1000)

    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def extract_transcripts_from_messages(messages_path):
    """Extract transcripts from messages.json file with proper structure handling."""
    if not os.path.exists(messages_path) or os.path.getsize(messages_path) < 100:
        return []

    try:
        with open(messages_path, "r", encoding="utf-8") as f:
            messages_data = json.load(f)

        transcripts = []
        language_map = {}
        numeric_language_map = {}

        if isinstance(messages_data, list):
            for item in messages_data:
                if isinstance(item, list) and len(item) >= 2:
                    lang_id = item[0]
                    msg_str = item[1]
                    try:
                        if isinstance(msg_str, str):
                            msg_data = json.loads(msg_str)
                        elif isinstance(msg_str, dict):
                            msg_data = msg_str
                        else:
                            continue
                    except (json.JSONDecodeError, TypeError):
                        continue

                    if isinstance(msg_data, dict) and "sender" in msg_data:
                        sender = msg_data.get("sender", "")
                        lang_name = extract_language_from_sender(
                            sender, lang_id, numeric_language_map
                        )
                        if lang_id not in numeric_language_map:
                            numeric_language_map[lang_id] = lang_name
                        language_map[sender] = lang_name

        if isinstance(messages_data, list):
            for item in messages_data:
                if isinstance(item, list) and len(item) >= 2:
                    lang_id = item[0]
                    msg_str = item[1]

                    try:
                        if isinstance(msg_str, str):
                            msg_data = json.loads(msg_str)
                        elif isinstance(msg_str, dict):
                            msg_data = msg_str
                        else:
                            continue
                    except (json.JSONDecodeError, TypeError):
                        continue

                    # ── accept any of several text fields, not just "seq" ──
                    if isinstance(msg_data, dict):
                        sender = msg_data.get("sender", "")
                        text = (
                            msg_data.get("seq")
                            or msg_data.get("text")
                            or msg_data.get("translation")
                            or ""
                        )
                        text = text.strip() if isinstance(text, str) else ""

                        if not text:
                            # Messages that carry no `seq` / `text` /
                            # `translation` field fall into two buckets:
                            #
                            #  1. Mediator control/transport messages. They
                            #     have a fixed shape: 'message_id', 'session',
                            #     'tag', 'access', 'controll', 'directory',
                            #     'host', 'meta', 'time_arrive_mediator'.
                            #     No text is expected — this is normal.
                            #
                            #  2. Actual transcript messages whose field was
                            #     renamed. These are the ones we want to hear
                            #     about, so we log them once per sender.
                            looks_like_control = (
                                "message_id" in msg_data
                                and "session" in msg_data
                                and "tag" in msg_data
                            )
                            if (
                                sender
                                and sender not in _warned_senders
                                and not looks_like_control
                            ):
                                _warned_senders.add(sender)
                                logging.warning(
                                    "extract: message with no text field "
                                    "(sender=%r, keys=%s)",
                                    sender,
                                    sorted(msg_data.keys()),
                                )
                            continue

                        if sender in language_map:
                            lang_name = language_map[sender]
                        else:
                            lang_name = numeric_language_map.get(
                                lang_id
                            ) or get_language_name_from_sender(sender, lang_id)

                        existing = next(
                            (t for t in transcripts if t.get("language") == lang_name),
                            None,
                        )

                        start_val = msg_data.get("start", 0)
                        end_val = msg_data.get("end", 0)
                        try:
                            start_float = (
                                float(start_val) if start_val is not None else 0.0
                            )
                        except (ValueError, TypeError):
                            start_float = 0.0
                        try:
                            end_float = float(end_val) if end_val is not None else 0.0
                        except (ValueError, TypeError):
                            end_float = 0.0

                        segment_data = {
                            "text": text,
                            "start": start_float,
                            "end": end_float,
                            "sender": sender,
                            "markup": msg_data.get("markup"),
                            "words": msg_data.get("words"),
                            "word_id": msg_data.get("word_id"),
                            "source_tokens": msg_data.get("sourceTokens"),
                            "speaker_name": msg_data.get("speakerName"),
                            "refined_sentence_cluster": msg_data.get(
                                "refined_sentence_cluster"
                            ),
                            "unstable": msg_data.get("unstable", False),
                            "message_id": msg_data.get("message_id"),
                        }

                        if existing:
                            existing["text"] += "\n" + text
                            if "segments" not in existing:
                                existing["segments"] = []
                            existing["segments"].append(segment_data)
                        else:
                            transcripts.append(
                                {
                                    "language": lang_name,
                                    "source_file": f"lang_{lang_id}",
                                    "text": text,
                                    "sender": sender,
                                    "segments": [segment_data],
                                }
                            )

        organized_transcripts = organize_transcripts(transcripts)
        return organized_transcripts

    except json.JSONDecodeError as e:
        logging.warning("Could not parse messages.json: %s", e)
    except (OSError, KeyError, TypeError, AttributeError) as e:
        logging.warning("Could not extract transcripts from messages.json: %s", e)

    return []


def extract_language_from_sender(sender, lang_id, numeric_language_map):
    """Extract a full language name from a sender string."""
    if lang_id in numeric_language_map:
        return numeric_language_map[lang_id]

    if sender.startswith("asr:"):
        num_id = sender.replace("asr:", "")
        if num_id in numeric_language_map:
            return numeric_language_map[num_id]
        return f"Transcript (Original ASR - Language {lang_id})"

    if sender.startswith("mt:"):
        num_id = sender.replace("mt:", "")
        if num_id in numeric_language_map:
            return f"{numeric_language_map[num_id]} Translation"
        return f"{lang_id}"

    if sender.startswith("textstructurer:0_"):
        lang_code = sender.replace("textstructurer:0_", "").lower()
        full = LANGUAGE_NAMES.get(lang_code)
        if full:
            return f"Transcript (Structured - {full})"
        return f"Transcript (Structured - {lang_code})"

    if sender.startswith("saasr"):
        return f"Transcript (SAASR - Language {lang_id})"

    # Look for a 2-letter code anywhere in the sender
    for code, name in LANGUAGE_NAMES.items():
        if f"_{code}" in sender or f":{code}" in sender or f"-{code}" in sender:
            return f"Transcript ({name})"

    return f"Transcript (Language {lang_id})"


def get_language_name_from_sender(sender, lang_id):
    """Get a human-readable language name from a sender string (fallback)."""
    if not sender:
        lang_name = _lang_id_to_name(lang_id)
        return f"Language {lang_name}" if lang_name else f"Language {lang_id}"

    lang_name = _lang_id_to_name(lang_id)

    if sender.startswith("asr:"):
        return f"Original ASR ({lang_name})" if lang_name else "Original ASR"
    if sender.startswith("mt:"):
        return f"Translation ({lang_name})" if lang_name else "Translation"
    if sender.startswith("textstructurer:0_"):
        lang_code = sender.replace("textstructurer:0_", "").lower()
        full = LANGUAGE_NAMES.get(lang_code, lang_code)
        return f"Structured ({full})"
    if sender.startswith("saasr"):
        return f"SAASR ({lang_name})" if lang_name else "SAASR"

    for code, name in LANGUAGE_NAMES.items():
        if f"_{code}" in sender or f":{code}" in sender or f"-{code}" in sender:
            return f"Transcript ({name})"

    if lang_name:
        return f"Transcript ({lang_name})"
    return f"Transcript (Language {lang_id})"


def _lang_id_to_name(lang_id):
    """Resolve a lang_id ('en', 'English', ...) to a full language name."""
    if lang_id is None:
        return None
    if isinstance(lang_id, str):
        code = lang_id.strip().lower()
        if code in LANGUAGE_NAMES:
            return LANGUAGE_NAMES[code]
        if code in {n.lower() for n in LANGUAGE_NAMES.values()}:
            return lang_id.strip()
    return None


def organize_transcripts(transcripts):
    """Organize transcripts by language, combining related messages."""
    organized = {}

    for t in transcripts:
        lang = t.get("language", "Unknown")
        if lang not in organized:
            organized[lang] = {
                "language": lang,
                "text": "",
                "source_file": t.get("source_file", ""),
                "sender": t.get("sender", ""),
                "segments": [],
                "chapters": [],
                "summaries": [],
                "post_edited": [],
                "notes": [],
                "global_summaries": [],
                "speakers": {},
                "paragraph_breaks": [],
            }
        if organized[lang]["text"]:
            organized[lang]["text"] += "\n"
        organized[lang]["text"] += t.get("text", "")

        if "segments" in t:
            organized[lang]["segments"].extend(t.get("segments", []))

    for lang, transcript in organized.items():
        if "segments" in transcript:
            transcript["segments"].sort(key=lambda x: safe_float(x.get("start", 0)))

    result = list(organized.values())

    def sort_key(item):
        lang = item.get("language", "")
        if "Original" in lang:
            return 0
        if "Structured" in lang:
            return 1
        if "Translation" in lang:
            return 2
        return 3

    result.sort(key=sort_key)
    return result


def _is_original_asr_language(language: str) -> bool:
    """True for the ASR track that reflects what the speaker actually said."""
    if not language:
        return False
    lower = language.lower()
    return "original" in lower or "asr" in lower


def generate_vtt_files_from_transcripts(session_dir):
    """Materialise per-language .vtt files from transcripts.json."""
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return []

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
    except (OSError, ValueError, TypeError):
        return []

    if not transcripts:
        return []

    written = []
    default_path = None  # was: english_path

    for transcript in transcripts:
        language = transcript.get("language", "")
        segments = transcript.get("segments", [])
        if not segments:
            continue

        is_original = _is_original_asr_language(language)

        if is_original:
            # Stable, predictable name for the speaker's own language
            vtt_filename = "subtitles_Transcript.vtt"
        else:
            simple_name = _extract_simple_language_name(language)
            clean = simple_name.replace(" ", "_").replace("(", "").replace(")", "")
            vtt_filename = f"subtitles_{clean}.vtt"

        vtt_path = os.path.join(session_dir, vtt_filename)

        lines = ["WEBVTT", ""]
        cue_index = 0
        for seg in sorted(segments, key=lambda x: safe_float(x.get("start", 0))):
            text = seg.get("text", "")
            if not text or not text.strip():
                continue
            if seg.get("markup") in ("chapterBreak", "paragraphBreak", "heading"):
                continue
            start = safe_float(seg.get("start", 0))
            end = safe_float(seg.get("end", 0))
            cue_index += 1
            lines.append(str(cue_index))
            lines.append(
                f"{_format_vtt_timestamp(start)} --> {_format_vtt_timestamp(end)}"
            )
            speaker = seg.get("speakerName") or seg.get("speaker_name")
            if speaker and speaker.strip():
                lines.append(f"<v {speaker}>{text}</v>")
            else:
                lines.append(text)
            lines.append("")

        if cue_index == 0:
            # Don't write a header-only VTT
            logging.info("generate_vtt: no cues for language %r, skipping", language)
            continue

        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        written.append(vtt_filename)

        # Original ASR wins; anything else is only used if no original exists.
        if default_path is None or is_original:
            default_path = vtt_path

    if written:
        logging.info("Generated %d VTT file(s)", len(written))
    return written


def save_transcripts_to_files(session_dir, transcripts):
    """Save transcripts to JSON and TXT files."""
    if not transcripts:
        return

    json_path = os.path.join(session_dir, "transcripts.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(transcripts, f, ensure_ascii=False, indent=2)
    logging.info("Saved transcripts to %s", json_path)

    txt_path = os.path.join(session_dir, "transcript.txt")
    with open(txt_path, "w", encoding="utf-8") as f:
        for t in transcripts:
            f.write(f"{'=' * 60}\n")
            f.write(f"Language: {t.get('language', 'Unknown')}\n")
            f.write(f"{'=' * 60}\n\n")
            segments = t.get("segments", [])
            segments.sort(key=lambda x: safe_float(x.get("start", 0)))
            for seg in segments:
                start = safe_float(seg.get("start", 0))
                end = safe_float(seg.get("end", 0))
                sender = seg.get("sender", "")
                text = seg.get("text", "")
                msg_markup = seg.get("markup", "")
                # Skip empty segments but don't skip based on <br> tags
                if not text or not text.strip():
                    continue
                if msg_markup:
                    f.write(
                        f"[{start:.1f}s - {end:.1f}s] [{sender}] [{msg_markup}] {text}\n"
                    )
                else:
                    f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
            f.write("\n")
    logging.info("Saved plain text to %s", txt_path)


def extract_structured_data_from_session(session_dir, language_filter=None):
    """
    Extract fully structured data from a session matching the window view.
    """
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return None

    with open(json_path, "r", encoding="utf-8") as f:
        all_transcripts = json.load(f)

    if language_filter:
        transcripts = [
            t for t in all_transcripts if t.get("language") == language_filter
        ]
    else:
        transcripts = all_transcripts

    messages_path = os.path.join(session_dir, "messages.json")
    structured_messages = []
    if os.path.exists(messages_path):
        try:
            with open(messages_path, "r", encoding="utf-8") as f:
                messages_data = json.load(f)
            if isinstance(messages_data, list):
                for item in messages_data:
                    if isinstance(item, list) and len(item) >= 2:
                        try:
                            msg_data = (
                                json.loads(item[1])
                                if isinstance(item[1], str)
                                else item[1]
                            )
                            if isinstance(msg_data, dict):
                                structured_messages.append(msg_data)
                        except (json.JSONDecodeError, TypeError):
                            pass
        except (json.JSONDecodeError, TypeError, OSError):
            pass

    structured_data = {
        "transcripts": [],
        "chapters": [],
        "summaries": [],
        "speakers": {},
        "post_edited": [],
        "notes": [],
        "global_summaries": [],
        "paragraph_breaks": [],
    }

    for t in transcripts:
        transcript_entry = {
            "language": t.get("language", "Unknown"),
            "text": t.get("text", ""),
            "segments": sorted(
                t.get("segments", []), key=lambda x: safe_float(x.get("start", 0))
            ),
            "sender": t.get("sender", ""),
        }
        structured_data["transcripts"].append(transcript_entry)

    chapter_stack = []
    for msg in sorted(structured_messages, key=lambda x: safe_float(x.get("start", 0))):
        markup = msg.get("markup")
        sender = msg.get("sender", "")
        seq = msg.get("seq", "")
        start = safe_float(msg.get("start", 0))
        end = safe_float(msg.get("end", 0))

        if markup == "chapterBreak":
            chapter = {
                "start": start,
                "end": end,
                "index": len(structured_data["chapters"]),
                "heading": "",
                "segments": [],
            }
            structured_data["chapters"].append(chapter)
            chapter_stack.append(chapter)

        elif markup == "heading" and chapter_stack:
            chapter_stack[-1]["heading"] = seq

        elif markup == "paragraphBreak":
            structured_data["paragraph_breaks"].append({"start": start, "end": end})

        elif markup == "summary":
            structured_data["summaries"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "sender": sender,
                }
            )

        elif markup == "postedited":
            compression_rate = "90"
            if ":" in sender:
                parts = sender.split(":")
                if len(parts) > 1 and "_" in parts[1]:
                    compression_rate = parts[1].split("_")[0]
            structured_data["post_edited"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "compression_rate": compression_rate,
                    "sender": sender,
                }
            )

        elif markup == "notes":
            structured_data["notes"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "nested_level": msg.get("nested_level", 0),
                    "chapter_index": msg.get("chapter_index", 0),
                }
            )

        elif markup == "global_summary":
            structured_data["global_summaries"].append(
                {
                    "text": seq,
                    "sender": sender,
                }
            )

        if "refined_sentence_cluster" in msg:
            speaker = msg.get("refined_sentence_cluster")
            if speaker:
                if speaker.startswith("unk-"):
                    speaker = f"Anonymous-{speaker.split('-')[1]}"
                structured_data["speakers"][speaker] = {
                    "name": speaker,
                    "last_seen": datetime.datetime.now().isoformat(),
                }

    for transcript in structured_data["transcripts"]:
        for seg in transcript.get("segments", []):
            seg_start = safe_float(seg.get("start", 0))
            for ch in structured_data["chapters"]:
                ch_start = safe_float(ch.get("start", 0))
                ch_end = safe_float(ch.get("end", 0))
                if ch_start <= seg_start < ch_end or (
                    ch == structured_data["chapters"][-1] and seg_start >= ch_start
                ):
                    if "segments" not in ch:
                        ch["segments"] = []
                    ch["segments"].append(seg)
                    break

    return structured_data


# ─── HELPER FUNCTIONS FOR EXPORT ──────────────────────────────────────


def clean_html_tags(text):
    """Remove HTML tags only, preserve everything else including music notes."""
    if not text:
        return ""
    # Remove HTML tags only (replace with space)
    clean = re.sub(r"<[^>]+>", " ", text)
    # Remove multiple spaces (but keep single spaces)
    clean = re.sub(r"\s+", " ", clean)
    # Trim leading/trailing spaces
    return clean.strip()


def escape_rtf(text):
    """Escape special characters for RTF format, preserving Unicode characters."""
    if not text:
        return ""
    # Escape backslashes and braces
    escaped = text.replace("\\", "\\\\")
    escaped = escaped.replace("{", "\\{")
    escaped = escaped.replace("}", "\\}")
    # Handle Unicode characters (preserve them)
    result = []
    for char in escaped:
        code = ord(char)
        if code > 127:
            result.append(f"\\u{code}?")
        else:
            result.append(char)
    return "".join(result)


def get_paragraph_number(sender):
    """
    Convert textstructurer: tags to sequential paragraph numbers.
    Only textstructurer: tags get numbers.
    """
    if not sender:
        return 0

    # Only textstructurer gets paragraph numbers
    if sender.startswith("textstructurer:"):
        if ":" in sender:
            parts = sender.split(":")
            if len(parts) >= 2:
                second_part = parts[1]
                match = re.search(r"^(\d+)", second_part)
                if match:
                    return int(match.group(1)) + 1
    return 0


def is_asr_or_mt(sender):
    """Check if sender is ASR or MT type."""
    if not sender:
        return False
    return (
        sender.startswith("asr:")
        or sender.startswith("mt:")
        or sender.startswith("translation:")
    )


def is_textstructurer(sender):
    """Check if sender is textstructurer type."""
    if not sender:
        return False
    return sender.startswith("textstructurer:")


def is_summarizer(sender):
    """Check if sender is summarizer type."""
    if not sender:
        return False
    return sender.startswith("summarizer:")


def format_sender_for_export(sender):
    """
    Format sender tag for export:
    - textstructurer: -> [1], [2], [3] (paragraph numbers)
    - asr: and mt: -> plain text (no marker)
    - Other senders -> [sender]
    """
    if not sender:
        return ""

    # textstructurer gets paragraph numbers
    if is_textstructurer(sender):
        num = get_paragraph_number(sender)
        if num > 0:
            return f"[{num}]"

    # asr and mt are plain text - return nothing (they're just markers)
    if is_asr_or_mt(sender):
        return ""

    # Other senders (summarizer, etc.) keep their name
    if is_summarizer(sender):
        return f"[{sender}]"

    return f"[{sender}]"


def format_text_for_export(text, sender):
    """
    Format text based on sender type:
    - textstructurer: -> keep as is (paragraph text)
    - summarizer: -> format with "Summary:" prefix
    - asr: / mt: -> plain text
    """
    clean_text = clean_html_tags(text)
    if not clean_text:
        return ""

    # Summarizer gets special formatting
    if is_summarizer(sender):
        return f"Summary: {clean_text}"

    # textstructurer is paragraph text
    if is_textstructurer(sender):
        return clean_text

    # asr and mt are plain text
    return clean_text


def extract_lang_code(language_name):
    """Extract language code from language name."""
    if not language_name:
        return None
    for code in [
        "en",
        "de",
        "fr",
        "es",
        "it",
        "pt",
        "nl",
        "ru",
        "ja",
        "ko",
        "zh",
        "ar",
        "hi",
        "pl",
        "tr",
        "uk",
        "vi",
        "th",
        "id",
        "ms",
    ]:
        if f"({code})" in language_name or f" - {code}" in language_name:
            return code
    return None


def filter_summaries_by_language(summaries, lang_code):
    """Filter summaries by language code."""
    if not lang_code:
        return summaries
    filtered = []
    for s in summaries:
        sender = s.get("sender", "")
        if f"_{lang_code}" in sender:
            filtered.append(s)
    return filtered if filtered else summaries


def format_structured_text(structured_data, language_filter=None):
    """Format structured data to match the website view, preserving music notes."""
    if not structured_data:
        return "No structured data available."

    lines = []

    # Get the language-specific data
    transcripts_data = structured_data.get("transcripts", [])

    # If we have a language filter, find the specific transcript
    selected_transcript = None
    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        # No filter - use first transcript
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code for filename
    lang_code = None
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents (only if chapters exist)
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        lines.append("TABLE OF CONTENTS")
        lines.append("-" * 40)
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                lines.append(f"  {idx}. {heading}")
            else:
                lines.append(f"  {idx}. Chapter {idx}")
        lines.append("")

    # Transcript with chapters
    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    # Track paragraph numbering for textstructurer
    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                lines.append(f"--- Chapter {idx}: {heading} ---")
            else:
                lines.append(f"--- Chapter {idx} ---")

            segments = ch.get("segments", [])
            current_sender = None
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                # Only clean HTML tags, preserve everything else
                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                # For textstructurer: show as paragraph with number
                if is_textstructurer(sender):
                    paragraph_counter += 1
                    lines.append(f"[{paragraph_counter}]")
                    lines.append(clean_text)
                    lines.append("")  # Single blank line between paragraphs
                # For asr and mt: show as plain text (no marker)
                elif is_asr_or_mt(sender):
                    if clean_text:
                        lines.append(clean_text)
                # For summarizer: show with "Summary:" prefix
                elif is_summarizer(sender):
                    lines.append(f"Summary: {clean_text}")
                # For other senders: show with sender name
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        lines.append(f"[{sender}]")
                    lines.append(clean_text)

            if not has_content:
                lines.append("(No content yet)")

            lines.append("")  # Single blank line between chapters
    else:
        # No chapters - show all transcripts
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            lines.append(f"--- {lang} ---")
            segments = selected_transcript.get("segments", [])
            current_sender = None

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    lines.append(f"[{paragraph_counter}]")
                    lines.append(clean_text)
                    lines.append("")
                elif is_asr_or_mt(sender):
                    if clean_text:
                        lines.append(clean_text)
                elif is_summarizer(sender):
                    lines.append(f"Summary: {clean_text}")
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        lines.append(f"[{sender}]")
                    lines.append(clean_text)

    # Summaries (filtered by language) - formatted differently
    if filtered_summaries:
        lines.append("=" * 60)
        lines.append("SUMMARIES")
        lines.append("-" * 40)
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            lines.append(f"  📋 {text}")
        lines.append("")

    # Global Summaries (filtered by language) - formatted differently
    if filtered_global_summaries:
        lines.append("=" * 60)
        lines.append("GLOBAL SUMMARIES")
        lines.append("-" * 40)
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            lines.append(f"  🌐 {text}")
        lines.append("")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        lines.append("=" * 60)
        lines.append("POST-EDITED CONTENT")
        lines.append("-" * 40)
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            lines.append(f"  [Compression: {rate}%] {text}")
        lines.append("")

    # Remove trailing empty lines and join with single newlines
    return "\n".join(lines).strip()


def export_structured_txt(session_id, session_dir, language_filter=None):
    """Export structured data as plain text matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        return io.BytesIO(b"No structured data available.")

    text = format_structured_text(structured_data, language_filter)

    header = "=" * 80 + "\n"
    header += f"SESSION: {session_id}\n"
    if language_filter:
        header += f"FILTER: {language_filter}\n"
    header += f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    header += "=" * 80 + "\n\n"

    return io.BytesIO((header + text).encode("utf-8"))


def export_structured_docx(session_id, session_dir, language_filter=None):
    """Export session data as DOCX matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        doc = Document()
        doc.add_heading("No structured data available", 1)
        return io.BytesIO()

    doc = Document()

    title = f"Session: {session_id}"
    if language_filter:
        title += f" - {language_filter}"
    doc.add_heading(title, 0)

    doc.add_paragraph(f"Session ID: {session_id}")
    doc.add_paragraph(
        f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    )
    doc.add_paragraph("")

    # Get language-specific data
    transcripts_data = structured_data.get("transcripts", [])
    selected_transcript = None
    lang_code = None

    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        doc.add_heading("Table of Contents", level=1)
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            p = doc.add_paragraph()
            p.add_run(f"{idx}. ").bold = True
            if heading:
                p.add_run(f"{heading}")
            else:
                p.add_run(f"Chapter {idx}")
        doc.add_paragraph("")

    # Transcripts with chapters
    doc.add_heading("Transcript", level=1)

    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                doc.add_heading(f"Chapter {idx}: {heading}", level=2)
            else:
                doc.add_heading(f"Chapter {idx}", level=2)

            segments = ch.get("segments", [])
            current_sender = None
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                if not text or not text.strip():
                    continue

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                # textstructurer: paragraph with number
                if is_textstructurer(sender):
                    paragraph_counter += 1
                    p = doc.add_paragraph()
                    run = p.add_run(f"[{paragraph_counter}]")
                    run.bold = True
                    run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)

                # asr and mt: plain text (no marker)
                elif is_asr_or_mt(sender):
                    p = doc.add_paragraph()
                    p.add_run(clean_text)

                # summarizer: with "Summary:" prefix
                elif is_summarizer(sender):
                    p = doc.add_paragraph()
                    run = p.add_run("Summary: ")
                    run.bold = True
                    run.font.color.rgb = RGBColor(255, 165, 0)  # Orange
                    p.add_run(clean_text)

                # other senders
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        p = doc.add_paragraph()
                        run = p.add_run(f"[{sender}]")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)

                    p = doc.add_paragraph()
                    p.add_run(clean_text)

            if not has_content:
                p = doc.add_paragraph()
                run = p.add_run("(No content yet)")
                run.italic = True
                run.font.size = Pt(10)

            doc.add_paragraph("")
    else:
        # No chapters - show selected transcript
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            doc.add_heading(lang, level=2)
            segments = selected_transcript.get("segments", [])
            current_sender = None
            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                if not text or not text.strip():
                    continue

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    p = doc.add_paragraph()
                    run = p.add_run(f"[{paragraph_counter}]")
                    run.bold = True
                    run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)
                elif is_asr_or_mt(sender):
                    p = doc.add_paragraph()
                    p.add_run(clean_text)
                elif is_summarizer(sender):
                    p = doc.add_paragraph()
                    run = p.add_run("Summary: ")
                    run.bold = True
                    run.font.color.rgb = RGBColor(255, 165, 0)
                    p.add_run(clean_text)
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        p = doc.add_paragraph()
                        run = p.add_run(f"[{sender}]")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)

                    p = doc.add_paragraph()
                    p.add_run(clean_text)
            doc.add_paragraph("")

    # Summaries (filtered by language) - formatted with special style
    if filtered_summaries:
        doc.add_heading("Summaries", level=1)
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            p = doc.add_paragraph()
            p.add_run("📋 ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    # Global Summaries (filtered by language)
    if filtered_global_summaries:
        doc.add_heading("Global Summaries", level=1)
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            p = doc.add_paragraph()
            p.add_run("🌐 ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        doc.add_heading("Post-Edited Content", level=1)
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            p = doc.add_paragraph()
            p.add_run(f"[Compression: {rate}%] ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    doc_buffer = io.BytesIO()
    doc.save(doc_buffer)
    doc_buffer.seek(0)
    return doc_buffer


def export_structured_rtf(session_id, session_dir, language_filter=None):
    """Export structured data as RTF matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        return io.BytesIO(b"{\\rtf1\\ansi No structured data available.}")

    rtf_parts = [
        r"{\rtf1\ansi\deff0",
        r"{\fonttbl{\f0\fnil\fcharset0 Arial;}}",
        r"\f0\fs24",
        r"\b\fs32 Session: " + session_id + r"\b0\par\par",
    ]

    if language_filter:
        rtf_parts.append(r"\b\fs28 Filter: " + language_filter + r"\b0\par\par")

    rtf_parts.append(
        r"\b\fs28 Export Date: "
        + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        + r"\b0\par\par"
    )

    # Get language-specific data
    transcripts_data = structured_data.get("transcripts", [])
    selected_transcript = None
    lang_code = None

    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        rtf_parts.append(r"\b\fs26 Table of Contents\b0\par")
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            text = f"{idx}. "
            if heading:
                text += f"{heading}"
            else:
                text += f"Chapter {idx}"
            rtf_parts.append(r"\bullet " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Transcripts with chapters
    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                rtf_parts.append(
                    r"\b\fs24 Chapter "
                    + str(idx)
                    + ": "
                    + escape_rtf(heading)
                    + r"\b0\par"
                )
            else:
                rtf_parts.append(r"\b\fs24 Chapter " + str(idx) + r"\b0\par")

            segments = ch.get("segments", [])
            current_sender = None
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    rtf_parts.append(
                        r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par"
                    )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_asr_or_mt(sender):
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_summarizer(sender):
                    rtf_parts.append(
                        r"\b "
                        + "Summary: "
                        + r"\b0 "
                        + escape_rtf(clean_text)
                        + r"\par"
                    )
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        rtf_parts.append(
                            r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par"
                        )

                    rtf_parts.append(escape_rtf(clean_text) + r"\par")

            if not has_content:
                rtf_parts.append(r"\i (No content yet)\i0\par")

            rtf_parts.append(r"\par")
    else:
        # No chapters - show selected transcript
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            rtf_parts.append(r"\b\fs24 " + escape_rtf(lang) + r"\b0\par")
            segments = selected_transcript.get("segments", [])
            current_sender = None
            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    rtf_parts.append(
                        r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par"
                    )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_asr_or_mt(sender):
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_summarizer(sender):
                    rtf_parts.append(
                        r"\b "
                        + "Summary: "
                        + r"\b0 "
                        + escape_rtf(clean_text)
                        + r"\par"
                    )
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        rtf_parts.append(
                            r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par"
                        )

                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
            rtf_parts.append(r"\par")

    # Summaries (filtered by language) - formatted with special style
    if filtered_summaries:
        rtf_parts.append(r"\b\fs26 Summaries\b0\par")
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            if text:
                rtf_parts.append(r"\b " + "📋 " + r"\b0 " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Global Summaries (filtered by language)
    if filtered_global_summaries:
        rtf_parts.append(r"\b\fs26 Global Summaries\b0\par")
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            if text:
                rtf_parts.append(r"\b " + "🌐 " + r"\b0 " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        rtf_parts.append(r"\b\fs26 Post-Edited Content\b0\par")
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            if text:
                rtf_parts.append(
                    r"\b [Compression: "
                    + str(rate)
                    + r"%]\b0 "
                    + escape_rtf(text)
                    + r"\par"
                )
        rtf_parts.append(r"\par")

    rtf_parts.append("}")
    return io.BytesIO("".join(rtf_parts).encode("utf-8"))


def _resolve_export_language_name(session_dir, language):
    """Return the transcript language label for export filenames."""
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return "transcript"

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
    except (OSError, ValueError, TypeError):
        return "transcript"

    if not transcripts:
        return "transcript"

    if language:
        for transcript in transcripts:
            lang = str(transcript.get("language", "")).strip()
            if not lang:
                continue
            if lang == language or language.lower() in lang.lower():
                return lang

    first_lang = transcripts[0].get("language", "transcript")
    return first_lang if first_lang else "transcript"


@app.route("/session_export_txt/<path:session_id>", methods=["GET"])
def session_export_txt(session_id):
    """Export all session data as structured plain text matching the window view."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.txt"

    txt_buffer = export_structured_txt(session_id, session_dir, language)

    return send_file(
        txt_buffer,
        mimetype="text/plain",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session_export_docx/<path:session_id>", methods=["GET"])
def session_export_docx(session_id):
    """Export session as a structured DOCX file matching the window view."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.docx"

    try:
        doc_buffer = export_structured_docx(session_id, session_dir, language)
    except ImportError:
        return (
            jsonify(
                {
                    "error": "python-docx not installed",
                    "hint": "pip install python-docx",
                }
            ),
            500,
        )
    except (
        OSError,
        ValueError,
        TypeError,
        RuntimeError,
        KeyError,
        AttributeError,
    ) as e:
        logging.exception("DOCX export failed for %s: %s", session_id, e)
        return jsonify({"error": f"Export failed: {type(e).__name__}: {e}"}), 500

    return send_file(
        doc_buffer,
        mimetype="application/vnd.openxmlformats-officedocument"
        ".wordprocessingml.document",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session_export_rtf/<path:session_id>", methods=["GET"])
def session_export_rtf(session_id):
    """Export all session data as a structured RTF document."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.rtf"

    rtf_buffer = export_structured_rtf(session_id, session_dir, language)

    return send_file(
        rtf_buffer,
        mimetype="text/rtf",
        as_attachment=True,
        download_name=filename,
    )


def get_available_languages(session_dir):
    """Get list of available languages from transcripts.json."""
    json_path = os.path.join(session_dir, "transcripts.json")
    languages = []

    if os.path.exists(json_path):
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
        languages = list(set(t.get("language", "Unknown") for t in transcripts))
        languages.sort()

    return languages


# ─── EXPORT ROUTES ─────────────────────────────────────────────────────


@app.route("/session_export/<path:session_id>", methods=["GET"])
def session_export(session_id):
    """Export all session data as a formatted DOCX document."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")

    try:
        doc_buffer = export_structured_docx(session_id, session_dir, language)
    except ImportError:
        return (
            jsonify(
                {
                    "error": "python-docx not installed. "
                    "Please install: pip install python-docx"
                }
            ),
            500,
        )

    filename = f"session_{session_id}"
    if language:
        clean_lang = language.replace(" ", "_").replace("(", "").replace(")", "")
        filename = f"session_{session_id}_{clean_lang}"

    return send_file(
        doc_buffer,
        mimetype="application/vnd.openxmlformats-officedocument"
        ".wordprocessingml.document",
        as_attachment=True,
        download_name=f"{filename}.docx",
    )


@app.route("/session_export_structured_json/<path:session_id>", methods=["GET"])
def session_export_structured_json(session_id):
    """Export session as structured JSON with all metadata."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")

    structured_data = extract_structured_data_from_session(session_dir, language)
    if not structured_data:
        return jsonify({"error": "No structured data available"}), 404

    json_str = json.dumps(structured_data, ensure_ascii=False, indent=2)

    # Get the actual language name from transcripts.json
    actual_lang_name = None
    json_path = os.path.join(session_dir, "transcripts.json")
    if os.path.exists(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)
            if transcripts:
                if language:
                    for t in transcripts:
                        lang = t.get("language", "")
                        if lang == language or language.lower() in lang.lower():
                            actual_lang_name = lang
                            break
                if not actual_lang_name:
                    actual_lang_name = transcripts[0].get("language", "transcript")
        except (OSError, TypeError, ValueError):
            actual_lang_name = "transcript"
    else:
        actual_lang_name = "transcript"

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.json"

    return send_file(
        io.BytesIO(json_str.encode("utf-8")),
        mimetype="application/json",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session_export_all_languages/<path:session_id>", methods=["GET"])
def session_export_all_languages(session_id):
    """Export all languages as separate files in a ZIP archive."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    export_format = request.args.get("format", "all").lower()

    languages = get_available_languages(session_dir)
    if not languages:
        return jsonify({"error": "No transcript data found"}), 404

    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zipf:
        for lang in languages:
            clean_lang = lang.replace(" ", "_").replace("(", "").replace(")", "")
            clean_lang = clean_lang.replace("/", "_").replace("\\", "_")
            if len(clean_lang) > 50:
                clean_lang = clean_lang[:50]

            formats_to_export = []
            if export_format == "all":
                formats_to_export = ["txt", "rtf", "docx", "json"]
            elif export_format in ["txt", "rtf", "docx", "json"]:
                formats_to_export = [export_format]
            else:
                formats_to_export = ["txt"]

            if "txt" in formats_to_export:
                txt_buffer = export_structured_txt(session_id, session_dir, lang)
                zipf.writestr(f"{clean_lang}.txt", txt_buffer.getvalue())

            if "rtf" in formats_to_export:
                rtf_buffer = export_structured_rtf(session_id, session_dir, lang)
                zipf.writestr(f"{clean_lang}.rtf", rtf_buffer.getvalue())

            if "docx" in formats_to_export:
                try:
                    doc_buffer = export_structured_docx(session_id, session_dir, lang)
                    zipf.writestr(f"{clean_lang}.docx", doc_buffer.getvalue())
                except ImportError:
                    logging.warning("python-docx not installed, skipping DOCX")

            if "json" in formats_to_export:
                structured_data = extract_structured_data_from_session(
                    session_dir, lang
                )
                if structured_data:
                    zipf.writestr(
                        f"{clean_lang}.json",
                        json.dumps(
                            structured_data, ensure_ascii=False, indent=2
                        ).encode("utf-8"),
                    )

    zip_buffer.seek(0)

    return send_file(
        zip_buffer,
        mimetype="application/zip",
        as_attachment=True,
        download_name="transcript_all_languages.zip",
    )


@app.route("/session_languages/<path:session_id>", methods=["GET"])
def session_languages(session_id):
    """Get list of available languages for a session."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    languages = get_available_languages(session_dir)
    return jsonify({"languages": languages}), 200


@app.route("/session_transcript_json/<path:session_id>", methods=["GET"])
def session_transcript_json(session_id):
    """Export session transcripts as JSON."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    json_path = os.path.join(session_dir, "transcripts.json")
    if os.path.exists(json_path):
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return jsonify(data), 200

    return jsonify({"error": "No transcript data found"}), 404


@app.route("/session_messages_json/<path:session_id>", methods=["GET"])
def session_messages_json(session_id):
    """Download the raw messages.json file from the session."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    if token:
        local_path = os.path.join(session_dir, "messages.json")
        if not os.path.exists(local_path) or os.path.getsize(local_path) < 1000:
            url = f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
            logging.info("Downloading messages.json from %s", url)
            if curl_download(url, local_path, token):
                logging.info("Successfully downloaded messages.json")

    json_path = os.path.join(session_dir, "messages.json")
    if os.path.exists(json_path) and os.path.getsize(json_path) > 1000:
        return send_file(
            json_path,
            as_attachment=True,
            download_name=f"messages_{session_id}.json",
            mimetype="application/json",
        )

    return jsonify({"error": "messages.json not found"}), 404


@app.route("/session_zip/<path:session_id>", methods=["GET"])
def download_session_zip(session_id):
    """Download all files from a session as a ZIP archive."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    if token:
        json_path = os.path.join(session_dir, "messages.json")
        if not os.path.exists(json_path) or os.path.getsize(json_path) < 1000:
            url = f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
            curl_download(url, json_path, token)

    # Sanitize session_id before using it in a filename
    safe_id = re.sub(r"[^A-Za-z0-9_.-]", "_", session_id)[:80]
    zip_path = os.path.join(tempfile.gettempdir(), f"session_{safe_id}.zip")

    try:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for root, _, files in os.walk(session_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    try:
                        if os.path.getsize(file_path) > 1000:
                            zipf.write(
                                file_path,
                                os.path.relpath(file_path, session_dir),
                            )
                    except OSError:
                        continue

        return send_file(
            zip_path,
            as_attachment=True,
            download_name=f"session_{safe_id}.zip",
            mimetype="application/zip",
        )
    finally:
        # Clean up after Flask has actually sent the file
        try:
            if os.path.exists(zip_path):
                os.remove(zip_path)
        except OSError:
            pass


@app.route("/session_transcript_save_vtt/<path:session_id>", methods=["POST"])
def session_transcript_save_vtt(session_id):
    """Save edited transcript segments and rewrite the corresponding VTT file.

    Naming rules:
      - Original ASR track   -> subtitles_Transcript.vtt  (and mirrored to
                                subtitles.vtt, the generic default)
      - Any other language   -> subtitles_<SimpleName>.vtt
      - Explicit `filename` in the payload always wins.
    """
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Invalid JSON data"}), 400

        language = data.get("language")
        segments = data.get("segments", [])
        filename = data.get("filename")

        if not language:
            return jsonify({"error": "Language is required"}), 400
        if not segments:
            return jsonify({"error": "No segments provided"}), 400

        # Filter out structural / empty segments
        filtered_segments = []
        for seg in segments:
            if seg.get("start", 0) == 0 and seg.get("end", 0) == 0:
                continue
            if seg.get("markup") in ["paragraphBreak", "chapterBreak", "heading"]:
                continue
            if not seg.get("text", "").strip():
                continue
            filtered_segments.append(seg)

        if not filtered_segments:
            return jsonify({"error": "No valid segments to save"}), 400

        # --- 1. Update transcripts.json -----------------------------------
        json_path = os.path.join(session_dir, "transcripts.json")
        transcripts = []
        if os.path.exists(json_path):
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)

        updated = False
        for i, transcript in enumerate(transcripts):
            if transcript.get("language") == language:
                transcript["segments"] = filtered_segments
                transcript["text"] = " ".join(
                    s.get("text", "") for s in filtered_segments
                )
                transcripts[i] = transcript
                updated = True
                break

        if not updated:
            transcripts.append(
                {
                    "language": language,
                    "text": " ".join(s.get("text", "") for s in filtered_segments),
                    "segments": filtered_segments,
                    "sender": (
                        filtered_segments[0].get("sender", "")
                        if filtered_segments
                        else ""
                    ),
                }
            )

        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(transcripts, f, ensure_ascii=False, indent=2)

        # --- 2. Decide which VTT file to write ----------------------------
        if filename:
            # Caller was explicit — trust them.
            vtt_filename = filename

        elif _is_original_asr_language(language):
            # Speaker's own language always goes to the same predictable
            # filename, so generator / save / sync all agree.
            vtt_filename = "subtitles_Transcript.vtt"

        else:
            # Non-ASR track: reuse an existing VTT for this language if
            # one exists, otherwise create a new one from the simple name.
            existing_vtt = None
            simple_name = _extract_simple_language_name(language)

            for f in os.listdir(session_dir):
                if not f.endswith(".vtt"):
                    continue
                if (
                    simple_name in f
                    or language in f
                    or f.startswith(f"subtitles_{simple_name}")
                ):
                    existing_vtt = f
                    break

            if existing_vtt:
                vtt_filename = existing_vtt
            else:
                clean_lang = (
                    simple_name.replace(" ", "_").replace("(", "").replace(")", "")
                )
                vtt_filename = f"subtitles_{clean_lang}.vtt"

        # --- 3. Build the VTT content -------------------------------------
        vtt_lines = ["WEBVTT", ""]
        cue_index = 0
        for seg in filtered_segments:
            start = safe_float(seg.get("start", 0))
            end = safe_float(seg.get("end", 0))
            text = seg.get("text", "")

            if not text or not text.strip():
                continue

            cue_index += 1
            vtt_lines.append(str(cue_index))
            vtt_lines.append(
                f"{_format_vtt_timestamp(start)} --> " f"{_format_vtt_timestamp(end)}"
            )

            speaker_name = seg.get("speakerName") or seg.get("speaker_name")
            if speaker_name and speaker_name.strip():
                vtt_lines.append(f"<v {speaker_name}>{text}</v>")
            else:
                vtt_lines.append(text)
            vtt_lines.append("")

        vtt_content = "\n".join(vtt_lines)

        # Write the per-language file
        vtt_path = os.path.join(session_dir, vtt_filename)
        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write(vtt_content)

        # --- 4. Update transcript.txt -------------------------------------
        txt_path = os.path.join(session_dir, "transcript.txt")
        with open(txt_path, "w", encoding="utf-8") as f:
            for t in transcripts:
                f.write(f"{'=' * 60}\n")
                f.write(f"Language: {t.get('language', 'Unknown')}\n")
                f.write(f"{'=' * 60}\n\n")
                segs = t.get("segments", [])
                segs.sort(key=lambda x: safe_float(x.get("start", 0)))
                for seg in segs:
                    start = safe_float(seg.get("start", 0))
                    end = safe_float(seg.get("end", 0))
                    sender = seg.get("sender", "")
                    text = seg.get("text", "")
                    markup = seg.get("markup", "")
                    if not text or not text.strip():
                        continue
                    if markup:
                        f.write(
                            f"[{start:.1f}s - {end:.1f}s] [{sender}] "
                            f"[{markup}] {text}\n"
                        )
                    else:
                        f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
                f.write("\n")

        logging.info(
            "Saved transcript and updated VTT for language '%s' in session %s",
            language,
            _short_sid(session_id),
        )

        # --- 5. Return the refreshed file list ----------------------------
        files = []
        for file in os.listdir(session_dir):
            file_path = os.path.join(session_dir, file)
            if os.path.isfile(file_path) and _is_meaningful_file(file_path):
                mtime = os.path.getmtime(file_path)
                mod_time = datetime.datetime.fromtimestamp(mtime).isoformat()
                files.append(
                    {
                        "name": file,
                        "size": os.path.getsize(file_path),
                        "url": f"/session_file/{session_id}/{file}",
                        "modified": mod_time,
                    }
                )

        save_state()

        return (
            jsonify(
                {
                    "success": True,
                    "message": f"Transcript saved and VTT updated: {vtt_filename}",
                    "language": language,
                    "vtt_filename": vtt_filename,
                    "segments_count": len(filtered_segments),
                    "files": files,
                }
            ),
            200,
        )

    except json.JSONDecodeError as e:
        return jsonify({"error": f"Invalid JSON: {str(e)}"}), 400
    except (OSError, TypeError, KeyError) as e:
        logging.error("Error saving transcript: %s", e, exc_info=True)
        return jsonify({"error": f"Failed to save: {str(e)}"}), 500


def _extract_simple_language_name(language):
    """Extract a full, human-readable language name.

    Handles strings like:
      "Translation (Language de)"        -> "German"
      "Transcript (Structured - en)"     -> "English"
      "Original ASR - Language English"  -> "English"
      "de"                               -> "German"
      "English"                          -> "English"
    """
    if not language:
        return "Unknown"

    # 1. Code inside parentheses, e.g. "(de)"
    match = re.search(r"\(([^)]+)\)", language)
    if match:
        candidate = match.group(1).strip()
        # "(Language de)" -> "de"
        if candidate.lower().startswith("language "):
            candidate = candidate.split(" ", 1)[1].strip()
        name = LANGUAGE_NAMES.get(candidate.lower())
        if name:
            return name

    # 2. Strip the wrapper phrases
    clean = language
    for prefix in (
        "Translation (Language ",
        "Transcript (Original ASR - ",
        "Transcript (Structured - ",
        "Transcript (",
    ):
        clean = clean.replace(prefix, "")
    clean = clean.replace(")", "").strip()

    # 3. A bare code, e.g. "de"
    if _LANG_CODE_RE.match(clean):
        return LANGUAGE_NAMES.get(clean.lower(), clean)

    # 4. "Language English" -> "English"
    if clean.lower().startswith("language "):
        clean = clean.split(" ", 1)[1].strip()
        if _LANG_CODE_RE.match(clean):
            return LANGUAGE_NAMES.get(clean.lower(), clean)

    return clean or "Unknown"


@app.route("/update_video_subtitles/<path:session_id>", methods=["POST"])
def update_video_subtitles(session_id):
    """
    Update the embedded subtitles in video.mp4 with the edited VTT files.
    Also updates messages.json to reflect the changes.
    """
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    video_path = os.path.join(session_dir, "video.mp4")

    logging.info(
        "update_video_subtitles: session=%r dir_exists=%s video_exists=%s",
        _short_sid(session_id),
        os.path.isdir(session_dir),
        os.path.exists(video_path),
    )

    if not os.path.exists(video_path):
        logging.warning(
            "update_video_subtitles: video.mp4 missing for session %s",
            _short_sid(session_id),
        )
        return jsonify({"error": "video.mp4 not found"}), 404

    try:
        # --- 1. Get list of VTT files in the session ---
        vtt_files = []
        for f in os.listdir(session_dir):
            if f.endswith(".vtt"):
                file_path = os.path.join(session_dir, f)
                # Extract language from filename
                lang = f.replace("subtitles_", "").replace(".vtt", "")
                vtt_files.append(
                    {
                        "filename": f,
                        "path": file_path,
                        "language": lang,
                        "size": os.path.getsize(file_path),
                        "modified": os.path.getmtime(file_path),
                    }
                )

        if not vtt_files:
            return jsonify({"error": "No VTT files found to embed"}), 404

        # --- 2. Update messages.json with the edited content ---
        messages_path = os.path.join(session_dir, "messages.json")
        updated_count = 0
        if os.path.exists(messages_path):
            try:
                with open(messages_path, "r", encoding="utf-8") as f:
                    messages_data = json.load(f)

                json_path = os.path.join(session_dir, "transcripts.json")
                if os.path.exists(json_path):
                    with open(json_path, "r", encoding="utf-8") as f:
                        transcripts = json.load(f)

                    language_segments = {}
                    for transcript in transcripts:
                        lang = transcript.get("language", "")
                        if lang:
                            segments = transcript.get("segments", [])
                            language_segments[lang] = segments

                    if isinstance(messages_data, list):
                        for i, item in enumerate(messages_data):
                            if isinstance(item, list) and len(item) >= 2:
                                msg_lang = item[0]
                                matching_segments = None
                                for lang_key, segments in language_segments.items():
                                    if (
                                        msg_lang.lower() in lang_key.lower()
                                        or lang_key.lower() in msg_lang.lower()
                                    ):
                                        matching_segments = segments
                                        break

                                if matching_segments:
                                    try:
                                        msg_str = item[1]
                                        if isinstance(msg_str, str):
                                            msg_data = json.loads(msg_str)
                                        elif isinstance(msg_str, dict):
                                            msg_data = msg_str
                                        else:
                                            continue

                                        if (
                                            "seq" in msg_data
                                            and "start" in msg_data
                                            and "end" in msg_data
                                        ):
                                            start_time = msg_data.get("start", 0)
                                            if isinstance(start_time, str):
                                                try:
                                                    start_time = float(start_time)
                                                except ValueError:
                                                    start_time = 0

                                            matched_seg = None
                                            for seg in matching_segments:
                                                seg_start = seg.get("start", 0)
                                                if isinstance(seg_start, str):
                                                    try:
                                                        seg_start = float(seg_start)
                                                    except ValueError:
                                                        seg_start = 0
                                                if abs(seg_start - start_time) < 0.01:
                                                    matched_seg = seg
                                                    break

                                            if matched_seg:
                                                msg_data["seq"] = matched_seg.get(
                                                    "text", ""
                                                )
                                                if "markup" in matched_seg:
                                                    msg_data["markup"] = (
                                                        matched_seg.get("markup")
                                                    )
                                                if "speakerName" in matched_seg:
                                                    msg_data["speakerName"] = (
                                                        matched_seg.get("speakerName")
                                                    )
                                                if "words" in matched_seg:
                                                    msg_data["words"] = matched_seg.get(
                                                        "words"
                                                    )
                                                if "word_id" in matched_seg:
                                                    msg_data["word_id"] = (
                                                        matched_seg.get("word_id")
                                                    )

                                                if isinstance(msg_str, str):
                                                    messages_data[i][1] = json.dumps(
                                                        msg_data
                                                    )
                                                else:
                                                    messages_data[i][1] = msg_data
                                                updated_count += 1
                                    except (
                                        json.JSONDecodeError,
                                        TypeError,
                                        ValueError,
                                    ) as e:
                                        logging.warning(
                                            "Could not update message %d: %s", i, e
                                        )
                                        continue

                        if updated_count > 0:
                            with open(messages_path, "w", encoding="utf-8") as f:
                                json.dump(
                                    messages_data, f, ensure_ascii=False, indent=2
                                )
                            logging.info(
                                "Updated %d messages in messages.json", updated_count
                            )
            except (json.JSONDecodeError, TypeError, OSError) as e:
                logging.warning("Could not update messages.json: %s", e)

        # --- 3. Write the new video to a fixed temp name ---
        temp_output = os.path.join(session_dir, "video_subtitled_tmp.mp4")
        # Clean up any leftover from a previous interrupted run
        if os.path.exists(temp_output):
            try:
                os.remove(temp_output)
            except OSError:
                pass

        # ffmpeg input: the current best version
        original_video = os.path.join(session_dir, "video.mp4")
        modified_video = os.path.join(session_dir, "video_subtitled.mp4")
        video_path = (
            modified_video if os.path.exists(modified_video) else original_video
        )
        logging.info("update_video_subtitles: ffmpeg input = %s", video_path)

        # --- 4. Build ffmpeg command to embed subtitles ---
        # Start with basic command
        cmd = ["ffmpeg", "-y"]

        # Add input video
        cmd.extend(["-i", video_path])

        # Add validated subtitle files as inputs
        valid_vtt_files = []
        for vtt in vtt_files:
            # Validate VTT file first
            try:
                with open(vtt["path"], "r", encoding="utf-8") as f:
                    content = f.read()
                if not content.strip():
                    logging.warning("Skipping empty VTT: %s", vtt["filename"])
                    continue
                if "WEBVTT" not in content.upper():
                    logging.warning(
                        "Skipping invalid VTT (no WEBVTT header): %s", vtt["filename"]
                    )
                    continue
            except (OSError, UnicodeError) as e:
                logging.warning("Skipping VTT %s: %s", vtt["filename"], e)
                continue

            cmd.extend(["-i", vtt["path"]])
            valid_vtt_files.append(vtt)

        # Build subtitle stream mapping
        # Video stream: 0:v:0, Audio stream: 0:a:0
        cmd.extend(["-map", "0:v:0"])
        cmd.extend(["-map", "0:a:0"])

        # Map all subtitle streams from the additional inputs
        # They start at index 1 (since we have 1 input file)
        for i, vtt in enumerate(valid_vtt_files):
            cmd.extend(["-map", f"{i + 1}:s"])
            stream_idx = 2 + i

            # Human-readable label, e.g. "Russian", "German", "Transcript"
            display_name = _extract_simple_language_name(vtt["language"])
            if not display_name or display_name == "Unknown":
                display_name = vtt["language"]

            # Match the original KIT style: set title only, no language code.
            cmd.extend([f"-metadata:s:{stream_idx}", f"title={display_name}"])

        # Remove any existing subtitle streams from the input
        # This prevents duplication issues
        cmd.extend(["-map", "-0:s?"])

        # Output options
        cmd.extend(["-c", "copy"])
        cmd.extend(["-c:s", "mov_text"])
        cmd.append(temp_output)

        # Log the command for debugging (sanitize to avoid huge logs)
        logging.info(
            "FFmpeg command: %s", " ".join(cmd[:5]) + " ... " + " ".join(cmd[-5:])
        )

        # --- 5. Run ffmpeg with error handling ---
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=300, check=False
            )

            if result.returncode != 0:
                error_msg = result.stderr if result.stderr else "Unknown ffmpeg error"
                logging.error("FFmpeg error: %s", error_msg)
                logging.error(
                    "FFmpeg stdout: %s",
                    result.stdout[:500] if result.stdout else "None",
                )
                return (
                    jsonify(
                        {
                            "error": "ffmpeg failed",
                            "stderr": error_msg[:500],
                            "stdout": result.stdout[:500] if result.stdout else None,
                        }
                    ),
                    500,
                )

        except subprocess.TimeoutExpired:
            logging.error("ffmpeg timed out for session %s", session_id)
            return jsonify({"error": "ffmpeg timed out"}), 500
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            logging.error("ffmpeg exception: %s", e, exc_info=True)
            return jsonify({"error": str(e)}), 500

        # --- 6. Atomically replace video_subtitled.mp4 with the new file ---
        target = os.path.join(session_dir, "video_subtitled.mp4")
        max_attempts = 5
        attempt_delay = 3  # seconds

        replaced = False
        for attempt in range(1, max_attempts + 1):
            try:
                os.replace(temp_output, target)
                replaced = True
                logging.info(
                    "update_video_subtitles: replaced %s (attempt %d/%d)",
                    target,
                    attempt,
                    max_attempts,
                )
                break
            except PermissionError:
                logging.warning(
                    "update_video_subtitles: %s is locked (attempt %d/%d)",
                    target,
                    attempt,
                    max_attempts,
                )
                if attempt < max_attempts:
                    time.sleep(attempt_delay)
            except OSError as e:
                logging.error("update_video_subtitles: os.replace failed: %s", e)
                return jsonify({"error": f"Could not replace video: {e}"}), 500

        if not replaced:
            logging.error(
                "update_video_subtitles: giving up after %d attempts; "
                "new video kept at %s",
                max_attempts,
                temp_output,
            )
            return (
                jsonify(
                    {
                        "error": "video_locked",
                        "message": (
                            "The current video is being played in another tab. "
                            "Close it and try saving again. Your new version is "
                            "saved as video_subtitled_tmp.mp4 and will be "
                            "applied automatically on the next successful save."
                        ),
                        "pending_file": "video_subtitled_tmp.mp4",
                    }
                ),
                423,  # HTTP 423 Locked
            )

        # --- 7. Save state ---
        save_state()

        logging.info("Successfully updated video subtitles for session %s", session_id)

        return (
            jsonify(
                {
                    "success": True,
                    "message": "Video subtitles and messages.json updated successfully",
                    "embedded_subtitles": [
                        {
                            "language": vtt["language"],
                            "filename": vtt["filename"],
                        }
                        for vtt in valid_vtt_files
                    ],
                    "video": "video_subtitled.mp4",
                    "messages_updated": updated_count,
                }
            ),
            200,
        )

    # This is the endpoint boundary: unexpected failures must be converted to
    # an HTTP response instead of escaping Flask.
    # pylint: disable=broad-exception-caught
    except (
        AttributeError,
        KeyError,
        OSError,
        TypeError,
        ValueError,
        RuntimeError,
        yt_dlp.utils.DownloadError,
    ) as e:
        logging.error("Error updating video subtitles: %s", e, exc_info=True)
        return jsonify({"error": str(e)}), 500


def _get_language_code(language_name):
    """Map any language label to its 2-letter ISO-639-1 code, or None."""
    if not language_name:
        return None

    name_to_code = {name.lower(): code for code, name in LANGUAGE_NAMES.items()}
    raw = language_name.strip()

    if _LANG_CODE_RE.match(raw):
        return raw.lower()
    if raw.lower() in name_to_code:
        return name_to_code[raw.lower()]

    match = re.search(r"\(([^)]+)\)", raw)
    if match:
        candidate = match.group(1).strip()
        if candidate.lower().startswith("language "):
            candidate = candidate.split(" ", 1)[1].strip()
        if _LANG_CODE_RE.match(candidate):
            return candidate.lower()
        if candidate.lower() in name_to_code:
            return name_to_code[candidate.lower()]

    code_match = re.search(r"[\s:\-_]([a-z]{2})\b", raw, re.IGNORECASE)
    if code_match:
        return code_match.group(1).lower()

    lower_raw = raw.lower()
    for name, code in name_to_code.items():
        if name in lower_raw:
            return code

    return None


_ISO2_TO_ISO3 = {
    "en": "eng",
    "de": "deu",
    "fr": "fra",
    "es": "spa",
    "it": "ita",
    "pt": "por",
    "nl": "nld",
    "ru": "rus",
    "ja": "jpn",
    "ko": "kor",
    "zh": "zho",
    "ar": "ara",
    "hi": "hin",
    "pl": "pol",
    "tr": "tur",
    "uk": "ukr",
    "vi": "vie",
    "th": "tha",
    "id": "ind",
    "ms": "msa",
    "fa": "fas",
}


def _get_language_code_iso3(language_name):
    """3-letter ISO-639-2/T code for ffmpeg / MP4 metadata."""
    iso2 = _get_language_code(language_name)
    return _ISO2_TO_ISO3.get(iso2) if iso2 else None


def _internal_headers(token: str) -> dict:
    """Standard headers for requests to the internal server."""
    return {
        "X-Forward-Auth": token,
        "Authorization": f"Bearer {token}",
        "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
    }


def _internal_cookies(token: str) -> dict:
    return {"_forward_auth": token}


def _remote_size(url: str, token: str, timeout: int = 20) -> tuple[int, int]:
    """Return (size, status_code). size=0 on error."""
    headers = _internal_headers(token)
    headers["Range"] = "bytes=0-0"

    try:
        with requests.get(
            url,
            headers=headers,
            cookies=_internal_cookies(token),
            verify=False,
            timeout=timeout,
            stream=True,
            allow_redirects=True,
        ) as r:
            status = r.status_code
            cr = r.headers.get("Content-Range", "")
            if "/" in cr:
                try:
                    return int(cr.rsplit("/", 1)[-1]), status
                except ValueError:
                    pass
            cl = r.headers.get("Content-Length")
            if cl:
                try:
                    n = int(cl)
                    if n > 1:
                        return n, status
                except ValueError:
                    pass
            return 0, status
    except requests.exceptions.RequestException as e:
        logging.warning("Range GET failed for %s: %s", url, e)
    return 0, 0


# ─── SESSION COMPLETENESS GATES ─────────────────────────────────────────
MIN_MESSAGES_BYTES = 5_000  # tune to your smallest realistic session
_STABLE_NEEDED = 3


def _fetch_messages_json_size(session_id, token, server_url=None):
    """Cheap HEAD-style size probe against the internal messages.json.

    Returns (size, status_code). size=0 on error.
    """
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")
    url = f"{server_url}/archivemediafile/{session_id}/messages.json"
    return _remote_size(url, token)


def _fetch_messages_json_bytes(session_id, token, server_url=None):
    """Download the full messages.json from the internal server."""
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")
    url = f"{server_url}/archivemediafile/{session_id}/messages.json"
    try:
        r = requests.get(
            url,
            headers=_internal_headers(token),
            cookies=_internal_cookies(token),
            verify=False,
            timeout=30,
            allow_redirects=True,
        )
        if r.status_code == 200:
            return r.content
        logging.warning("fetch_messages_json: HTTP %s for %s", r.status_code, url)
    except requests.exceptions.RequestException as e:
        logging.warning("fetch_messages_json failed: %s", e)
    return b""


def _extract_translation_codes(raw: bytes) -> set[str]:
    """Return the set of language codes for every `mt:`/`translation:` track.

    A code is derived from the sender via `_get_language_code` (which
    understands `"mt:de"`, `"mt:German"`, `"de"`, etc.). If no ISO code
    can be resolved, the raw suffix is used instead so that distinct
    opaque tracks (e.g. `mt:42`) are still distinguishable.
    """
    codes: set[str] = set()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return codes
    if not isinstance(data, list):
        return codes

    for item in data:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict):
            continue
        if not m.get("seq", "").strip():
            continue
        sender = m.get("sender", "")
        if not (sender.startswith("mt:") or sender.startswith("translation:")):
            continue
        code = _get_language_code(sender)
        if code:
            codes.add(code.lower())
            continue
        suffix = sender.split(":", 1)[1].strip() if ":" in sender else sender
        codes.add(suffix.lower() or sender.lower())
    return codes


def _normalise_expected_codes(expected_langs) -> set[str]:
    """Turn whatever the client sent (codes, names, mixes) into a set of
    lowercase codes. Unknown entries are kept as-is so they still show up
    in the log when we report what's missing.
    """
    result: set[str] = set()
    if not expected_langs:
        return result
    if isinstance(expected_langs, str):
        expected_langs = [expected_langs]
    for lang in expected_langs:
        if not lang:
            continue
        code = _get_language_code(lang)
        result.add(code.lower() if code else str(lang).lower())
    return result


# How close a translation's last cue must be to the ASR track's last
# cue before we consider the translation "complete". Two thresholds,
# both accepted: an absolute slack (seconds) for short videos, and a
# fraction of the total for long ones.
_MT_COVERAGE_MIN_FRACTION = 0.95
_MT_COVERAGE_SLACK_SECONDS = 20.0


def _coverage_is_ok(mt_end: float, asr_end: float) -> bool:
    """True when mt_end is 'close enough' to the end of the ASR track."""
    if asr_end <= 0:
        return True
    if mt_end >= asr_end - _MT_COVERAGE_SLACK_SECONDS:
        return True
    return (mt_end / asr_end) >= _MT_COVERAGE_MIN_FRACTION


def _messages_look_done(raw: bytes, expected_langs=None, log: bool = True) -> bool:
    """Return True once every MT track covers the ASR span.

    Language-ID caveat:
      In messages.json the internal server identifies translation tracks
      by *numeric* IDs (`mt:0`, `mt:1`, …), not ISO codes. Those IDs are
      only resolvable to language names via the outer `[lang_id, payload]`
      pairing, which is not available here. So we do NOT try to match
      `expected_langs` against individual tracks. Instead we require:

        1. ASR content present (>=5 messages).
        2. At least one MT track if the caller asked for any.
        3. Every existing MT track ends close to the ASR end.

      That catches the "translation stops at minute 3 of a 45-minute
      video" problem without relying on a mapping we don't have.
    """

    ...
    if expected_langs and not mt_tracks:
        if log:
            logging.info("messages.json has ASR but no MT tracks yet")
        return False

        incomplete = []
    for sender, mt_end in mt_tracks.items():
        if not _coverage_is_ok(mt_end, asr_max_end):
            incomplete.append(f"{sender} covers {mt_end:.0f}s of {asr_max_end:.0f}s")

    if incomplete:
        if log:
            logging.info(
                "messages.json stable but MT tracks still short: %s",
                "; ".join(incomplete),
            )
        return False
    ...

    if not raw or len(raw) < MIN_MESSAGES_BYTES:
        return False
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return False
    if not isinstance(data, list) or not data:
        return False

    asr_count = 0
    asr_max_end = 0.0
    # sender -> max end seen for that track
    mt_tracks: dict[str, float] = {}

    for item in data:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict):
            continue
        if not m.get("seq", "").strip():
            continue
        try:
            end = float(m.get("end", 0) or 0)
        except (ValueError, TypeError):
            end = 0.0
        sender = m.get("sender", "")

        if sender.startswith("asr:"):
            asr_count += 1
            if end > asr_max_end:
                asr_max_end = end
        elif sender.startswith("mt:") or sender.startswith("translation:"):
            if end > mt_tracks.get(sender, 0.0):
                mt_tracks[sender] = end

    if asr_count < 5 or asr_max_end <= 0:
        return False

    if expected_langs and not mt_tracks:
        if log:
            logging.info("messages.json has ASR but no MT tracks yet")
        return False

    incomplete = []
    for sender, mt_end in mt_tracks.items():
        if not _coverage_is_ok(mt_end, asr_max_end):
            incomplete.append(f"{sender} covers {mt_end:.0f}s of {asr_max_end:.0f}s")

    if incomplete:
        logging.info(
            "messages.json stable but MT tracks still short: %s",
            "; ".join(incomplete),
        )
        return False

    if mt_tracks:
        logging.info(
            "messages.json: %d MT track(s), all covering up to %.0fs",
            len(mt_tracks),
            asr_max_end,
        )
    return True


# How often to re-fetch messages.json purely to refresh the progress
# bar. The stability check already fetches it occasionally; this adds
# a periodic tick so the bar moves even while the file is growing.
_PROGRESS_FETCH_INTERVAL = 30.0


def _compute_translation_progress(raw: bytes) -> tuple[float, float]:
    """Return (mt_max_end_seconds, asr_max_end_seconds).

    Either value may be 0.0 when the corresponding track has not
    produced any segment yet.
    """
    mt_max_end = 0.0
    asr_max_end = 0.0
    if not raw:
        return mt_max_end, asr_max_end
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return mt_max_end, asr_max_end
    if not isinstance(data, list):
        return mt_max_end, asr_max_end

    for item in data:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict):
            continue
        if not m.get("seq", "").strip():
            continue
        try:
            end = float(m.get("end", 0) or 0)
        except (ValueError, TypeError):
            end = 0.0
        sender = m.get("sender", "")
        if sender.startswith("asr:"):
            if end > asr_max_end:
                asr_max_end = end
        elif sender.startswith("mt:") or sender.startswith("translation:"):
            if end > mt_max_end:
                mt_max_end = end
    return mt_max_end, asr_max_end


def _session_video_duration(session_id: str) -> float:
    """Look up the source video duration for a session, in seconds."""
    sess = sessions.get(session_id) or {}
    video_key = sess.get("video_key")
    if not video_key:
        return 0.0
    for v in videos:
        if v.get("key") == video_key:
            try:
                return float(v.get("duration") or 0.0)
            except (TypeError, ValueError):
                return 0.0
    return 0.0


def _count_messages(raw: bytes) -> int:
    """Best-effort count of messages inside a messages.json blob."""
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return 0
    if isinstance(data, list):
        return len(data)
    if isinstance(data, dict):
        msgs = data.get("messages")
        if isinstance(msgs, list):
            return len(msgs)
        return len(data)
    return 0

# How often to re-fetch messages.json purely to refresh the progress
# bar. The stability check already fetches it occasionally; this adds
# a periodic tick so the bar moves even while the file is growing.
_PROGRESS_FETCH_INTERVAL = 60.0  # was 30.0

# If neither the file size nor the ASR/MT second counts have moved for
# this long, emit one short heartbeat line so the panel doesn't look
# frozen. Rare enough that it doesn't spam.
_PROGRESS_HEARTBEAT_SECONDS = 180.0

def wait_for_session_ready(
    session_id, token, server_url=None, expected_langs=None, timeout=1800
):
    """Block until the internal server finishes producing messages.json.

    Emits panel progress only when the observed second value actually
    advances. An idle translation track — or a stall in ASR before any
    translation has started — will not repeatedly re-print the same
    line. A slow heartbeat is emitted every _PROGRESS_HEARTBEAT_SECONDS
    while waiting, so the user can tell the job is still alive.
    """
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")

    started = time.time()
    last_size = -1
    stable_count = 0
    unauthorized_count = 0

    # Progress-tick bookkeeping. The "reported" values are the ones the
    # panel has already seen; we only emit a new event when they move.
    last_progress_fetch = 0.0
    last_reported_mt_end = 0.0
    last_reported_asr_end = 0.0
    last_heartbeat = started

    # Only surface "has ASR but no MT yet" once per session.
    reported_no_mt = False

    # Cooldown between two events of the same kind. Complements the
    # value-advance check below.
    while True:
        if _is_cancelled(session_id):
            raise _JobCancelled(f"Session {_short_sid(session_id)} cancelled by user")

        elapsed = time.time() - started
        if elapsed > timeout:
            raise TimeoutError(
                f"Session {_short_sid(session_id)} not ready after {timeout}s"
            )

        # Give the internal server a moment to accept the upload before
        # we start hammering it.
        if elapsed < 15:
            time.sleep(1)
            continue

        size, status = _fetch_messages_json_size(session_id, token, server_url)

        if status == 401:
            unauthorized_count += 1
            if unauthorized_count >= 5:
                raise PermissionError(
                    f"Token rejected by {server_url} (HTTP 401). "
                    f"The token is either expired or was issued by a "
                    f"different server."
                )
        else:
            unauthorized_count = 0

        size_changed = size != last_size

        plausible = size >= MIN_MESSAGES_BYTES
        if plausible and size == last_size:
            stable_count += 1
        else:
            stable_count = 0
        last_size = size

        # ── Console-only chatter ────────────────────────────────────
        # Only log size changes, or the first/last poll of a stability
        # window. The panel filters these out via
        # _CONSOLE_ONLY_SUBSTRINGS; they stay here for debugging.
        if size_changed or stable_count in (1, _STABLE_NEEDED):
            logging.info(
                "Session %s: messages.json size=%d status=%d (stable=%d/%d)",
                _short_sid(session_id),
                size,
                status,
                stable_count,
                _STABLE_NEEDED,
            )

        # ── Progress tick ────────────────────────────────────────────
        # Fetch the file and push a fraction of the video duration to
        # the panel, but only when the observed value has advanced.
        now = time.time()
        if now - last_progress_fetch >= _PROGRESS_FETCH_INTERVAL:
            last_progress_fetch = now
            raw_for_progress = _fetch_messages_json_bytes(
                session_id, token, server_url
            )
            mt_end, asr_end = _compute_translation_progress(raw_for_progress)
            video_dur = _session_video_duration(session_id)

            if video_dur > 0:
                if mt_end > last_reported_mt_end:
                    last_reported_mt_end = mt_end
                    prog = min(mt_end / video_dur, 0.99)
                    _job_log(
                        session_id,
                        f"Translations cover {mt_end:.0f}s / "
                        f"{video_dur:.0f}s ({prog * 100:.0f}%)",
                        stage="translating",
                        progress=prog,
                    )
                elif (
                    mt_end <= 0
                    and asr_end > last_reported_asr_end
                ):
                    last_reported_asr_end = asr_end
                    prog = min((asr_end / video_dur) * 0.05, 0.05)
                    _job_log(
                        session_id,
                        f"Transcribing… {asr_end:.0f}s / {video_dur:.0f}s",
                        stage="transcribing",
                        progress=prog,
                    )

        # ── Heartbeat ────────────────────────────────────────────────
        # If nothing has been reported for a while — neither the size
        # nor the ASR/MT values are moving — emit one short line so the
        # user knows we are still polling and not wedged.
        if now - last_heartbeat >= _PROGRESS_HEARTBEAT_SECONDS:
            last_heartbeat = now
            if last_reported_mt_end > 0:
                _job_log(
                    session_id,
                    f"Waiting — translation still at {last_reported_mt_end:.0f}s",
                    stage="translating",
                )
            elif last_reported_asr_end > 0:
                _job_log(
                    session_id,
                    f"Waiting — transcription still at {last_reported_asr_end:.0f}s",
                    stage="transcribing",
                )
            else:
                _job_log(
                    session_id,
                    "Waiting for the internal server…",
                    stage="starting",
                )

        # ── Readiness gate ───────────────────────────────────────────
        if stable_count >= _STABLE_NEEDED:
            raw = _fetch_messages_json_bytes(session_id, token, server_url)
            if _messages_look_done(raw, expected_langs):
                # Confirm once more after a short pause. A single
                # passing check can be a lucky moment during a
                # mid-stream stall; two in a row five seconds apart is
                # a much stronger signal that the server is really done.
                time.sleep(5)
                raw2 = _fetch_messages_json_bytes(session_id, token, server_url)
                if _messages_look_done(raw2, expected_langs):
                    logging.info(
                        "✅ Session %s appears complete (%d bytes, %d msgs)",
                        _short_sid(session_id),
                        len(raw2),
                        _count_messages(raw2),
                    )
                    return True
                logging.info(
                    "Session %s: first ready check passed but the "
                    "second did not — still growing, continuing to wait",
                    _short_sid(session_id),
                )
            else:
                logging.warning(
                    "Session %s: size stable but content invalid, "
                    "resetting stability counter",
                    _short_sid(session_id),
                )

            # _messages_look_done logged why it failed, at most once.
            # Remember that we've heard it and reset the stability gate.
            reported_no_mt = True
            stable_count = 0

        time.sleep(2)


def process_session_in_background(
    session_id, token, video_key, server_url=None, expected_mt=None
):
    """Wait for the internal server to finish, then download the session.

    Runs in a daemon thread, started right after a successful upload.
    Everything logged from this thread is auto-routed to this session's
    JobProgressPanel via the _log_target contextvar, so the Flutter UI
    sees the same stream as the terminal.

    `expected_mt` is the list of translation target languages the client
    asked for. The readiness gate will not fire until every one of them
    has at least one message in messages.json.
    """
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")

    # Fall back to what the upload endpoint recorded for this session.
    if not expected_mt:
        expected_mt = sessions.get(session_id, {}).get("expected_mt")
    if isinstance(expected_mt, str):
        expected_mt = [expected_mt]

    # Clear any stale cancel flag so a rerun of the same session id
    # doesn't get killed instantly.
    _clear_cancel(session_id)

    token_cv = _log_target.set(("job", session_id))
    try:
        logging.info(
            "🟢 [BG] Starting background processing for %s on %s "
            "(waiting for translations: %s)",
            _short_sid(session_id),
            server_url,
            expected_mt or "any",
        )
        session_name = sessions.get(session_id, {}).get("name", session_id)
        _job_start(session_id, video_key, session_name)
        _job_log(
            session_id,
            "Job registered — contacting internal server…",
            stage="starting",
            progress=0.02,
        )

        ready = wait_for_session_ready(
            session_id, token, server_url, expected_langs=expected_mt
        )
        if not ready:
            logging.warning(
                "Session %s never stabilized; downloading what we have",
                _short_sid(session_id),
            )

        ok = download_session_files(session_id, token, server_url)

        job = jobs.get(session_id)
        if job:
            job["status"] = "completed" if ok else "partial"
            job["progress"] = 1.0
        save_state()

        _job_finish(session_id, error=None if ok else "Partial download")
        logging.info("✅ Background download finished for %s", _short_sid(session_id))

    except _JobCancelled as e:
        logging.warning(
            "🛑 Background processing cancelled for %s: %s",
            _short_sid(session_id),
            e,
        )
        job = jobs.get(session_id)
        if job:
            job["status"] = "cancelled"
            job["progress"] = 0.0
        _job_cancel(session_id)
        save_state()
    except (
        requests.exceptions.RequestException,
        OSError,
        subprocess.SubprocessError,
        TimeoutError,
        ValueError,
        TypeError,
        KeyError,
        RuntimeError,
    ) as e:
        logging.error(
            "Background session processing failed for %s: %s",
            _short_sid(session_id),
            e,
            exc_info=True,
        )
        _job_finish(session_id, error=f"{type(e).__name__}: {e}")
    finally:
        _log_target.reset(token_cv)


@app.route("/extract_video_subtitles/<path:session_id>", methods=["GET"])
def extract_video_subtitles(session_id):
    """Extract embedded subtitles from video.mp4 to VTT files."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    video_path = os.path.join(session_dir, "video.mp4")

    if not os.path.exists(video_path):
        return jsonify({"error": "video.mp4 not found"}), 404

    try:
        # First, get info about subtitle streams
        probe_cmd = [
            "ffprobe",
            "-i",
            video_path,
            "-show_entries",
            "stream=index,codec_type,codec_name,language,tags",
            "-select_streams",
            "s",
            "-of",
            "json",
        ]

        result = subprocess.run(
            probe_cmd, capture_output=True, text=True, timeout=30, check=False
        )
        if result.returncode != 0:
            return jsonify({"error": "ffprobe failed", "stderr": result.stderr}), 500

        probe_data = json.loads(result.stdout)
        streams = probe_data.get("streams", [])

        extracted = []
        for i, stream in enumerate(streams):
            stream_index = stream.get("index")
            language = stream.get("language", f"stream_{i}")

            # Extract subtitle to VTT
            output_file = os.path.join(
                session_dir, f"extracted_subtitle_{i}_{language}.vtt"
            )

            extract_cmd = [
                "ffmpeg",
                "-i",
                video_path,
                "-map",
                f"0:{stream_index}",
                "-c",
                "copy",
                "-y",
                output_file,
            ]

            subprocess.run(extract_cmd, capture_output=True, timeout=60, check=False)

            if os.path.exists(output_file):
                extracted.append(
                    {
                        "stream_index": stream_index,
                        "language": language,
                        "filename": os.path.basename(output_file),
                        "size": os.path.getsize(output_file),
                    }
                )

        return (
            jsonify({"success": True, "extracted": extracted, "total": len(extracted)}),
            200,
        )

    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, OSError) as e:
        return jsonify({"error": str(e)}), 500


def _file_has_audio_stream(path):
    """Return True if the file has at least one audio stream."""
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "a",
                "-show_entries",
                "stream=index",
                "-of",
                "csv=p=0",
                path,
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        return bool(result.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        return False


# ─── AUTH ENDPOINTS ─────────────────────────────────────────────────────


@app.route("/register", methods=["POST"])
def register():
    """Register a new user with email and password."""
    email = request.form.get("email")
    password = request.form.get("password")
    name = request.form.get("name", "")
    if not email or not password:
        return jsonify({"message": "Email and password required"}), 400
    if email in users:
        return jsonify({"message": "User already exists"}), 400
    users[email] = {"name": name, "password": password}
    save_state()
    return (
        jsonify(
            {"token": str(uuid.uuid4()), "message": "User registered successfully"}
        ),
        201,
    )


@app.route("/login", methods=["POST"])
def login():
    """Log in an existing user and return an auth token."""
    email = request.form.get("email")
    password = request.form.get("password")
    if not email or not password:
        return jsonify({"message": "Email and password required"}), 400
    user = users.get(email)
    if not user or user["password"] != password:
        return jsonify({"message": "Invalid credentials"}), 401
    return jsonify({"token": str(uuid.uuid4()), "message": "Login successful"}), 200


# ─── VIDEO ENDPOINTS ────────────────────────────────────────────────────


@app.route("/videos", methods=["GET"])
def get_videos():
    """Return the list of uploaded videos with storage usage info."""
    # ============ DEDUPLICATION LOGIC ============
    # Group videos by filename (without UUID prefix)
    video_groups = {}

    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            continue

        # Check if this is a UUID-prefixed file
        uuid_match = re.match(
            r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_", file_name
        )

        # Determine the "clean" filename (without UUID prefix)
        if uuid_match:
            clean_name = file_name[
                36:
            ]  # Remove UUID prefix (8+1+4+1+4+1+4+1+12 = 36 chars)
            # If clean_name is empty or just extension, keep the original
            if not clean_name or clean_name.startswith("."):
                clean_name = file_name
        else:
            clean_name = file_name

        # Store in groups by clean_name
        if clean_name not in video_groups:
            video_groups[clean_name] = []
        video_groups[clean_name].append(video)

    # For each group, keep only the best video
    unique_videos = []
    for clean_name, group in video_groups.items():
        if len(group) == 1:
            # Only one video, keep it
            unique_videos.append(group[0])
        else:
            # Multiple videos with same name - keep the best one
            best_video = group[0]
            for video in group[1:]:
                # Prefer video with:
                # - segmentation_done == True
                # - thumbnail_url exists
                # - larger file_size
                # - no UUID prefix (prefer clean filename)
                current_score = 0
                best_score = 0

                # Check current video (best_video)
                if best_video.get("segmentation_done"):
                    best_score += 10
                if best_video.get("thumbnail_url"):
                    best_score += 5
                if best_video.get("file_size", 0) > 0:
                    best_score += min(
                        best_video.get("file_size", 0) / 1000000, 10
                    )  # Up to 10 points for size
                # Prefer clean filename (no UUID)
                if not re.match(
                    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
                    best_video.get("file_name", ""),
                ):
                    best_score += 3

                # Check candidate video (video)
                if video.get("segmentation_done"):
                    current_score += 10
                if video.get("thumbnail_url"):
                    current_score += 5
                if video.get("file_size", 0) > 0:
                    current_score += min(video.get("file_size", 0) / 1000000, 10)
                if not re.match(
                    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
                    video.get("file_name", ""),
                ):
                    current_score += 3

                if current_score > best_score:
                    best_video = video

            # Also log which ones were removed
            for video in group:
                if video != best_video:
                    logging.info(
                        "🗑️ Removing duplicate video: %s (keeping: %s)",
                        video.get("file_name"),
                        best_video.get("file_name"),
                    )

            unique_videos.append(best_video)
    # ========================================

    # Build absolute thumbnail URLs from the incoming request so they work
    # behind any host/proxy (localhost, Nginx, public domain, ...).
    # Do NOT mutate the stored dicts: their thumbnail_url stays relative.
    unique_videos_serialized = []
    for video in unique_videos:
        v = dict(video)  # shallow copy
        v["thumbnail_url"] = _thumbnail_absolute_url(video)
        unique_videos_serialized.append(v)
    unique_videos = unique_videos_serialized

    storage_used_gb = sum(v.get("file_size", 0) for v in unique_videos) / (1024.0**3)
    return (
        jsonify(
            {
                "projects": unique_videos,
                "storage_used_gb": round(storage_used_gb, 2),
                "storage_limit_gb": 50.0,
            }
        ),
        200,
    )


@app.route("/video_detail/<video_key>", methods=["GET"])
def video_detail(video_key):
    """Return details for a specific video by its key."""
    for project in videos:
        if project["key"] == video_key:
            detail = project.copy()
            detail["thumbnail_url"] = _thumbnail_absolute_url(project)
            detail["segments"] = detail.get("segments", [])
            detail["video_url"] = None
            return jsonify(detail), 200
    return jsonify({"error": "Video not found"}), 404


@app.route("/media/<video_key>")
def serve_video(video_key):
    """Serve the video file for the given video key."""
    project = next((p for p in videos if p["key"] == video_key), None)
    if not project:
        return jsonify({"error": "Video not found"}), 404
    file_name = project.get("file_name")
    if not file_name:
        return jsonify({"error": "File name not available"}), 404
    file_path = os.path.join(UPLOAD_FOLDER, file_name)
    if not os.path.exists(file_path):
        return jsonify({"error": f'File "{file_name}" not found on disk'}), 404
    return send_file(file_path, as_attachment=False)


@app.route("/thumbnails/<filename>")
def serve_thumbnail(filename):
    """Serve thumbnail images."""
    if ".." in filename or "/" in filename or "\\" in filename:
        return jsonify({"error": "Invalid filename"}), 400

    thumbnail_path = os.path.join(UPLOAD_FOLDER, filename)
    if not os.path.exists(thumbnail_path):
        return jsonify({"error": "Thumbnail not found"}), 404

    return send_file(thumbnail_path, mimetype="image/jpeg")


@app.route("/upload-chunk", methods=["POST"])
def upload_chunk():
    """Receive a chunk of a file upload for chunked uploads."""
    file = request.files.get("file")
    filename = request.form.get("filename")
    chunk_index = int(request.form.get("chunk_index", 0))
    total_chunks = int(request.form.get("total_chunks", 1))
    if not file or not filename:
        return jsonify({"message": "Missing file or filename"}), 400
    if filename not in chunk_storage:
        chunk_storage[filename] = [None] * total_chunks
    chunk_storage[filename][chunk_index] = file.read()
    return jsonify({"message": "Chunk uploaded"}), 200


@app.route("/finish-upload", methods=["POST"])
def finish_upload():
    """Complete a chunked upload and persist the file to disk."""
    data = request.get_json()
    original_filename = data.get("filename")
    auto_segmentation = data.get("auto_segmentation", False)
    if not original_filename:
        return jsonify({"message": "Missing filename"}), 400

    # chunk_storage is keyed by whatever name /upload-chunk was called
    # with — look it up under that name, not the normalised one.
    chunks = chunk_storage.get(original_filename)
    if not chunks or any(chunk is None for chunk in chunks):
        return jsonify({"message": "Incomplete upload"}), 400
    combined = b"".join(chunks)

    # ============ FIX: Ensure .mp4 extension ============
    # Only used for the on-disk filename; the storage key stays as-is.
    filename = original_filename
    if not filename.lower().endswith(".mp4"):
        base_name = os.path.splitext(filename)[0]
        filename = f"{base_name}.mp4"
    # ====================================================

    file_path = os.path.join(UPLOAD_FOLDER, filename)
    with open(file_path, "wb") as f:
        f.write(combined)
    file_size = len(combined)

    thumbnail_filename = f"{os.path.splitext(filename)[0]}_thumb.jpg"
    thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
    thumbnail_url = None

    # Generate thumbnail with proper path
    if generate_video_thumbnail(file_path, thumbnail_path):
        thumbnail_url = f"/thumbnails/{thumbnail_filename}"
        logging.info("Generated thumbnail: %s", thumbnail_filename)
    else:
        logging.warning("Failed to generate thumbnail for %s", filename)

    duration, fps = get_video_metadata(file_path)

    project = {
        "key": str(uuid.uuid4()),
        "name": filename.rsplit(".", 1)[0] if "." in filename else filename,
        "file_name": filename,
        "uploaded": utc_now_iso(),
        "last_opened": None,
        "duration": duration,
        "fps": fps,
        "file_size": file_size,
        "segment_count": 0,
        "languages": ["en"],
        "thumbnail_url": thumbnail_url,
        "segmentation_done": auto_segmentation,
        "segmentation_progress": 100 if auto_segmentation else 0,
    }
    videos.append(project)

    # Remove the chunk buffer under the key the client actually used.
    # pop() instead of del so a duplicate /finish-upload call can't crash
    # the second time around.
    chunk_storage.pop(original_filename, None)

    save_state()
    return jsonify({"message": "Upload finished", "project": project}), 200


# ─── PROJECT MANAGEMENT (no auth) ──────────────────────────────────────


@app.route("/delete_video/<video_key>", methods=["POST", "DELETE", "OPTIONS"])
def delete_video(video_key):
    """Delete a single project: file, thumbnail, sessions and jobs."""
    if request.method == "OPTIONS":
        return ("", 204)

    target = next((v for v in videos if v.get("key") == video_key), None)
    if not target:
        return jsonify({"error": "Video not found"}), 404

    file_name = target.get("file_name")

    # 1. Delete the video file from disk
    if file_name:
        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if os.path.exists(file_path):
            try:
                os.remove(file_path)
                logging.info("🗑️ Deleted video file: %s", file_path)
            except OSError as e:
                logging.warning("Could not delete %s: %s", file_path, e)

        # 2. Delete the thumbnail
        thumb_name = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        thumb_path = os.path.join(UPLOAD_FOLDER, thumb_name)
        if os.path.exists(thumb_path):
            try:
                os.remove(thumb_path)
                logging.info("🗑️ Deleted thumbnail: %s", thumb_path)
            except OSError as e:
                logging.warning("Could not delete %s: %s", thumb_path, e)

    # 3. Delete any sessions and jobs that belong to this video
    session_ids_to_remove = [
        sid for sid, s in sessions.items() if s.get("video_key") == video_key
    ]
    for sid in session_ids_to_remove:
        session_dir = os.path.join(SESSION_FOLDER, sid)
        if os.path.isdir(session_dir):
            try:
                shutil.rmtree(session_dir)
                logging.info("🗑️ Deleted session dir: %s", session_dir)
            except OSError as e:
                logging.warning("Could not delete session dir %s: %s", session_dir, e)
        sessions.pop(sid, None)

    job_ids_to_remove = [
        jid for jid, j in jobs.items() if j.get("video_key") == video_key
    ]
    for jid in job_ids_to_remove:
        jobs.pop(jid, None)

    # 4. Remove the video entry itself
    videos.remove(target)
    save_state()

    logging.info("✅ Deleted project '%s' (key=%s)", target.get("name"), video_key)

    return jsonify({"success": True, "deleted_key": video_key}), 200


@app.route("/update_project_name/<video_key>", methods=["POST", "OPTIONS"])
def update_project_name(video_key):
    """Rename a project in place (no auth)."""
    if request.method == "OPTIONS":
        return ("", 204)

    data = request.get_json(silent=True) or {}
    new_name = (data.get("project_name") or "").strip()
    if not new_name:
        return jsonify({"error": "project_name is required"}), 400

    target = next((v for v in videos if v.get("key") == video_key), None)
    if not target:
        return jsonify({"error": "Video not found"}), 404

    target["name"] = new_name
    save_state()
    return jsonify({"success": True, "project": target}), 200


@app.route("/stop_segmentation/<video_key>", methods=["POST", "OPTIONS"])
def stop_segmentation(video_key):
    """Mark any running segmentation jobs for this video as stopped."""
    if request.method == "OPTIONS":
        return ("", 204)

    stopped = 0
    for job in jobs.values():
        if job.get("video_key") == video_key and job.get("status") == "processing":
            job["status"] = "stopped"
            stopped += 1

    if stopped:
        save_state()

    return jsonify({"success": True, "stopped_jobs": stopped}), 200


# ─── JOB ENDPOINTS ──────────────────────────────────────────────────────


@app.route("/start_job/<video_key>", methods=["POST"])
def start_job(video_key):
    """Start a background transcription job for the given video."""
    data = request.get_json()
    job_id = str(uuid.uuid4())
    job = {
        "id": job_id,
        "video_key": video_key,
        "status": "processing",
        "progress": 0.0,
        "transcript": None,
        "segments": None,
        "created_at": utc_now_iso(),
        "config": data,
    }
    jobs[job_id] = job
    threading.Thread(target=process_job, args=(job_id,), daemon=True).start()
    save_state()
    return jsonify({"job_id": job_id, "status": "processing"}), 200


@app.route("/job_status/<job_id>", methods=["GET"])
def job_status(job_id):
    """Return the current status of a transcription job."""
    job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404
    return (
        jsonify(
            {
                "status": job["status"],
                "progress": job["progress"],
                "transcript": job.get("transcript"),
                "segments": job.get("segments"),
            }
        ),
        200,
    )


# ─── SESSION OUTPUT ENDPOINTS ──────────────────────────────────────────
def _is_meaningful_file(path: str) -> bool:
    """Files worth showing in the UI. VTTs can be tiny for short videos."""
    name = os.path.basename(path).lower()
    try:
        size = os.path.getsize(path)
    except OSError:
        return False

    if name.endswith(".vtt") or name.endswith(".txt") or name.endswith(".json"):
        return size > 20
    return size > 1000


@app.route("/session_output/<path:session_id>", methods=["GET"])
def get_session_output(session_id):
    """Get the session output as a JSON response with file URLs."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    # Only download if files don't exist or are very small
    server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    if token and _session_files_look_incomplete(session_dir):
        logging.info(
            "Session %s looks incomplete — re-downloading from %s",
            _short_sid(session_id),
            server_url,
        )
        download_session_files(session_id, token, server_url)

    files = []
    if os.path.exists(session_dir):
        for file in os.listdir(session_dir):
            file_path = os.path.join(session_dir, file)
            if os.path.isfile(file_path) and _is_meaningful_file(file_path):
                mtime = os.path.getmtime(file_path)
                mod_time = datetime.datetime.fromtimestamp(mtime).isoformat()

                # For VTT files, use the local file URL
                if file.endswith(".vtt"):
                    url = f"/session_file/{session_id}/{file}"
                else:
                    url = f"/session_file/{session_id}/{file}"

                files.append(
                    {
                        "name": file,
                        "size": os.path.getsize(file_path),
                        "url": url,
                        "modified": mod_time,
                    }
                )

    with job_progress_lock:
        job_snapshot = _job_progress_store.get(session_id)

    status = "ready" if files else "processing"
    return (
        jsonify(
            {
                "session_id": session_id,
                "files": files,
                "total_files": len(files),
                "session_url": f"{INTERNAL_SERVER_URL}/archivesession/{session_id}",
                "status": status,
                "job": job_snapshot,  # 👈 new
            }
        ),
        200,
    )


@app.route("/session_file/<path:session_id>/<filename>", methods=["GET"])
def get_session_file(session_id, filename):
    """Download a specific file from the session."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    file_path = os.path.join(session_dir, filename)

    # Check if file exists
    if not os.path.exists(file_path):
        return jsonify({"error": "File not found"}), 404

    # For VTT files, serve with correct MIME type and no cache
    if filename.endswith(".vtt"):
        response = send_file(
            file_path, as_attachment=False, mimetype="text/vtt", download_name=filename
        )
        # Add headers to prevent caching
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response

    if filename.lower().endswith(".mp4"):
        # A request for "video.mp4" is served from the subtitled version
        # if it exists, otherwise the original.
        actual_path = file_path
        if filename == "video.mp4":
            modified = os.path.join(session_dir, "video_subtitled.mp4")
            if os.path.exists(modified):
                actual_path = modified
        return send_file(
            actual_path,
            as_attachment=False,
            mimetype="video/mp4",
            conditional=True,
        )

    return send_file(file_path, as_attachment=True, conditional=True)


# ─── YOUTUBE DOWNLOADER FUNCTIONS ──────────────────────────────────────


def extract_youtube_video_id(url):
    """Extract YouTube video ID from various URL formats."""
    patterns = [
        r"youtube\.com/watch\?v=([^&]+)",
        r"youtu\.be/([^?]+)",
        r"youtube\.com/shorts/([^?]+)",
        r"youtube\.com/embed/([^?]+)",
        r"youtube\.com/v/([^?]+)",
        r"youtube\.com/e/([^?]+)",
        r"m\.youtube\.com/watch\?v=([^&]+)",
    ]
    for pattern in patterns:
        match = re.search(pattern, url)
        if match:
            return match.group(1)
    return None


def is_youtube_url(url):
    """Check if a URL is a YouTube URL."""
    youtube_patterns = [
        "youtube.com/watch?v=",
        "youtu.be/",
        "youtube.com/shorts/",
        "youtube.com/embed/",
        "youtube.com/v/",
        "youtube.com/e/",
        "m.youtube.com/watch?v=",
    ]
    return any(pattern in url.lower() for pattern in youtube_patterns)


def get_youtube_video_info(youtube_url):
    """
    Get video info from YouTube using yt-dlp.
    Returns video info including URL, title, duration, etc.
    """
    try:
        # First check if it's a YouTube URL
        if not is_youtube_url(youtube_url):
            return {"success": False, "error": "Not a valid YouTube URL"}

        video_id = extract_youtube_video_id(youtube_url)
        if not video_id:
            return {"success": False, "error": "Could not extract video ID"}

        # Configure yt-dlp options
        ydl_opts = {
            "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            "quiet": True,
            "no_warnings": True,
            "extract_flat": False,
            "http_headers": {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-us,en;q=0.5",
                "Sec-Fetch-Mode": "navigate",
            },
        }

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            # Extract info without downloading
            info = ydl.extract_info(youtube_url, download=False)

            if not info:
                return {
                    "success": False,
                    "error": "Could not extract video information",
                }

            # Get the video URL
            video_url = info.get("url")
            if not video_url:
                # Try to get URL from formats
                formats = info.get("formats", [])
                for fmt in formats:
                    # Prefer MP4 with video and audio
                    if fmt.get("ext") == "mp4" and fmt.get("vcodec") != "none":
                        video_url = fmt.get("url")
                        break
                    elif fmt.get("ext") == "mp4" and fmt.get("acodec") != "none":
                        video_url = fmt.get("url")
                        break

                # If still no URL, try the first format
                if not video_url and formats:
                    video_url = formats[0].get("url")

            if not video_url:
                return {"success": False, "error": "Could not find video URL"}

            # Get title and other metadata
            title = info.get("title", "video")
            # Clean title for filename
            title = re.sub(r'[\\/*?:"<>|]', "_", title)

            # Get duration
            duration = info.get("duration", 0)

            # Get thumbnail
            thumbnail = info.get("thumbnail", "")

            return {
                "success": True,
                "url": video_url,
                "title": title,
                "duration": duration,
                "thumbnail": thumbnail,
                "video_id": video_id,
                "format": info.get("format", "mp4"),
                "ext": info.get("ext", "mp4"),
                "filesize": info.get("filesize", 0),
            }

    except yt_dlp.utils.DownloadError as e:
        logging.error("yt-dlp download error: %s", str(e))
        return {"success": False, "error": f"Download error: {str(e)}"}
    except yt_dlp.utils.ExtractorError as e:
        logging.error("yt-dlp extractor error: %s", str(e))
        return {"success": False, "error": f"Extractor error: {str(e)}"}
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as e:
        logging.error("YouTube error: %s", str(e), exc_info=True)
        return {"success": False, "error": f"Error: {str(e)}"}


def download_youtube_video_adaptive(youtube_url, output_dir, filename=None):
    """
    Download a YouTube video with audio, using yt-dlp's format merging.
    Prefers mp4/m4a for direct container compatibility.
    """
    try:
        if not is_youtube_url(youtube_url):
            return {"success": False, "error": "Not a valid YouTube URL"}

        os.makedirs(output_dir, exist_ok=True)

        logging.info("🔍 Preparing download for: %s", youtube_url)

        # Prefer mp4 video + m4a audio; fall back to any best video+audio.
        # 'bv*' = best video-only, 'ba' = best audio-only.
        # The '/' chain tries each option left to right.
        format_selector = (
            "bv*[ext=mp4]+ba[ext=m4a]/"  # mp4 video + m4a audio (fastest)
            "bv*[ext=mp4]+ba/"  # mp4 video + any audio
            "bv*+ba/"  # any video + any audio
            "b[ext=mp4]/b"  # single progressive file (<=720p)
        )

        ydl_opts = {
            "format": format_selector,
            "outtmpl": os.path.join(output_dir, "%(title)s.%(ext)s"),
            "quiet": True,
            "no_warnings": True,
            "ignoreerrors": True,
            "merge_output_format": "mp4",
            "http_headers": {
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36"
                ),
            },
            # Requires ffmpeg on PATH to mux video+audio into mp4
            "postprocessors": [
                {
                    "key": "FFmpegVideoConvertor",
                    "preferedformat": "mp4",
                }
            ],
        }

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            logging.info("📥 Downloading video + audio...")
            info = ydl.extract_info(youtube_url, download=True)

            if not info:
                return {"success": False, "error": "Could not download video"}

            title = info.get("title", "video")
            title = re.sub(r'[\\/*?:"<>|]', "_", title)

            # yt-dlp will produce <title>.mp4 after merging
            downloaded_file = None
            for ext in (".mp4", ".mkv", ".webm"):
                candidate = os.path.join(output_dir, f"{title}{ext}")
                if os.path.exists(candidate):
                    downloaded_file = candidate
                    break

            # Fallback: any recently created video file in the folder
            if not downloaded_file:
                newest = None
                newest_mtime = 0
                for f in os.listdir(output_dir):
                    if f.endswith((".mp4", ".mkv", ".webm")):
                        fp = os.path.join(output_dir, f)
                        m = os.path.getmtime(fp)
                        if m > time.time() - 600 and m > newest_mtime:
                            newest = fp
                            newest_mtime = m
                downloaded_file = newest

            if not downloaded_file:
                return {"success": False, "error": "Downloaded file not found"}

            # Rename if a specific filename was requested
            if filename and os.path.exists(downloaded_file):
                _, ext = os.path.splitext(downloaded_file)
                new_filename = filename
                if not new_filename.endswith(ext):
                    new_filename = f"{new_filename}{ext}"
                new_path = os.path.join(output_dir, new_filename)
                if os.path.abspath(new_path) != os.path.abspath(downloaded_file):
                    # Avoid overwriting an existing file of the same name
                    if os.path.exists(new_path):
                        os.remove(new_path)
                    os.rename(downloaded_file, new_path)
                downloaded_file = new_path

            file_size = os.path.getsize(downloaded_file)
            logging.info(
                "✅ Download complete: %s (%s bytes)",
                os.path.basename(downloaded_file),
                file_size,
            )

            # Verify audio actually exists
            has_audio = _file_has_audio_stream(downloaded_file)
            logging.info("🎵 Audio present: %s", has_audio)
            if not has_audio:
                logging.warning(
                    "⚠️ Downloaded file has NO audio stream: %s",
                    downloaded_file,
                )

            return {
                "success": True,
                "file_path": downloaded_file,
                "title": title,
                "filename": os.path.basename(downloaded_file),
                "duration": info.get("duration", 0),
                "filesize": file_size,
                "has_audio": has_audio,
            }

    except yt_dlp.utils.DownloadError as e:
        logging.error("yt-dlp download error: %s", str(e))
        return {"success": False, "error": f"Download error: {str(e)}"}
    except (OSError, RuntimeError, ValueError, TypeError, KeyError) as e:
        logging.error("YouTube download error: %s", str(e), exc_info=True)
        return {"success": False, "error": f"Error: {str(e)}"}


# ─── YOUTUBE API ROUTES ────────────────────────────────────────────────


@app.route("/api/youtube-info", methods=["POST", "OPTIONS"])
def youtube_info():
    """
    Get YouTube video information without downloading.
    """
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

    try:
        data = request.get_json()
        if not data or "url" not in data:
            return jsonify({"error": "URL is required"}), 400

        youtube_url = data["url"]
        result = get_youtube_video_info(youtube_url)

        if result.get("success"):
            return (
                jsonify(
                    {
                        "success": True,
                        "video_id": result.get("video_id"),
                        "title": result.get("title"),
                        "duration": result.get("duration"),
                        "thumbnail": result.get("thumbnail"),
                        "format": result.get("format"),
                        "url": result.get("url"),
                    }
                ),
                200,
            )
        else:
            return (
                jsonify(
                    {"success": False, "error": result.get("error", "Unknown error")}
                ),
                400,
            )

    except (ValueError, TypeError, KeyError) as e:
        logging.error("YouTube info error: %s", str(e), exc_info=True)
        return jsonify({"error": str(e)}), 500


def convert_video_to_browser_compatible(input_path, output_path):
    """
    Convert video to browser-compatible format (H.264/AAC in MP4 container).
    Returns True if successful, False otherwise.
    """
    try:
        # Check if ffmpeg is available
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)

        # Convert to H.264/AAC in MP4 container
        cmd = [
            "ffmpeg",
            "-i",
            input_path,
            "-c:v",
            "libx264",  # H.264 video codec
            "-c:a",
            "aac",  # AAC audio codec
            "-movflags",
            "+faststart",  # Optimize for web streaming
            "-profile:v",
            "main",  # Main profile for better compatibility
            "-level",
            "3.1",  # Level 3.1 for broad compatibility
            "-pix_fmt",
            "yuv420p",  # YUV 4:2:0 for compatibility
            "-crf",
            "23",  # Quality level (18-28, 23 is good)
            "-preset",
            "medium",  # Encoding speed vs quality
            "-y",  # Overwrite output file
            output_path,
        ]

        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=300
        )

        if (
            result.returncode == 0
            and os.path.exists(output_path)
            and os.path.getsize(output_path) > 0
        ):
            logging.info(
                "✅ Video converted to browser-compatible format: %s", output_path
            )
            return True
        else:
            logging.error("❌ Video conversion failed: %s", result.stderr)
            return False

    except subprocess.TimeoutExpired:
        logging.error("❌ Video conversion timeout")
        return False
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logging.error("❌ Video conversion error: %s", e)
        return False


@app.route("/session_refresh/<path:session_id>", methods=["POST"])
def session_refresh(session_id):
    """Force a re-download of a session from the internal server."""
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")
    if not token:
        return jsonify({"error": "No token provided"}), 401

    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if os.path.exists(session_dir):
        shutil.rmtree(session_dir)
    os.makedirs(session_dir, exist_ok=True)

    download_session_files(session_id, token)
    return jsonify({"success": True, "session_id": session_id}), 200


@app.route("/session_resync/<path:session_id>", methods=["POST"])
def session_resync(session_id):
    """Force a full re-download of a session from the internal server."""
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        return jsonify({"error": "No token"}), 401
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if os.path.exists(session_dir):
        shutil.rmtree(session_dir)
    os.makedirs(session_dir, exist_ok=True)
    download_session_files(session_id, token)
    return jsonify({"success": True, "session_id": session_id}), 200


def _session_files_look_incomplete(session_dir):
    messages = os.path.join(session_dir, "messages.json")
    transcripts = os.path.join(session_dir, "transcripts.json")

    if not os.path.exists(transcripts):
        return True
    if not os.path.exists(messages) or os.path.getsize(messages) < 5000:
        return True

    try:
        with open(transcripts, "r", encoding="utf-8") as f:
            ts = json.load(f)
    except (json.JSONDecodeError, TypeError, ValueError):
        return True

    # How many languages did we actually extract text for?
    languages_with_text = [
        t
        for t in ts
        if any(seg.get("text", "").strip() for seg in t.get("segments", []))
    ]

    vtt_files = [
        f
        for f in os.listdir(session_dir)
        if f.startswith("subtitles_")
        and f.endswith(".vtt")
        and os.path.getsize(os.path.join(session_dir, f)) > 20
    ]

    # If we have more languages with text than VTTs, we're behind.
    if len(vtt_files) < len(languages_with_text):
        return True

    # If the local messages.json still shows short MT tracks, we're behind.
    if not _local_transcripts_cover_full_span(session_dir):
        logging.info(
            "_session_files_look_incomplete: %s — local MT coverage "
            "is short, will re-download",
            _short_sid(os.path.basename(session_dir)),
        )
        return True

    return False


def _local_transcripts_cover_full_span(session_dir) -> bool:
    """True if the local messages.json shows every MT track ending close
    to the ASR end. Used to decide whether a re-download is warranted.

    This is the local counterpart of _messages_look_done: same coverage
    rule, but reading from disk instead of from the internal server.
    """
    messages_path = os.path.join(session_dir, "messages.json")
    if not os.path.exists(messages_path):
        return False
    try:
        with open(messages_path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    if not raw or len(raw) < MIN_MESSAGES_BYTES:
        return False

    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return False
    if not isinstance(data, list):
        return False

    asr_max_end = 0.0
    mt_tracks: dict[str, float] = {}
    for item in data:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict):
            continue
        if not m.get("seq", "").strip():
            continue
        try:
            end = float(m.get("end", 0) or 0)
        except (ValueError, TypeError):
            end = 0.0
        sender = m.get("sender", "")
        if sender.startswith("asr:"):
            if end > asr_max_end:
                asr_max_end = end
        elif sender.startswith("mt:") or sender.startswith("translation:"):
            if end > mt_tracks.get(sender, 0.0):
                mt_tracks[sender] = end

    if not mt_tracks or asr_max_end <= 0:
        return False
    return all(_coverage_is_ok(mt_end, asr_max_end) for mt_end in mt_tracks.values())


@app.route("/api/youtube-download-and-upload", methods=["POST", "OPTIONS"])
def youtube_download_and_upload():
    """Download a YouTube video and register it as an uploadable project."""
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

    download_id = None
    try:
        data = request.get_json()
        if not data or "url" not in data:
            return jsonify({"error": "URL is required"}), 400

        youtube_url = data["url"]
        auto_segmentation = data.get("auto_segmentation", True)
        download_id = data.get("download_id")

        if download_id:
            _progress_init(download_id, youtube_url)

        _progress_event(
            download_id, "Starting YouTube download", stage="info", progress=0.02
        )
        logging.info("=" * 60)
        logging.info("📥 Starting YouTube download: %s", youtube_url)
        logging.info("=" * 60)

        # ── 1. Get video info ────────────────────────────────────────
        _progress_event(download_id, "Getting video info…", stage="info", progress=0.05)
        try:
            logging.info("📋 Getting video info...")
            ydl_opts = {
                "quiet": True,
                "no_warnings": True,
                "http_headers": {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36",
                },
            }
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(youtube_url, download=False)
                title = info.get("title", "youtube_video")
                duration = info.get("duration", 0)

            clean_title = re.sub(r'[\\/*?:"<>|]+', "_", title).strip()
            clean_title = re.sub(r"\s+", "_", clean_title)   # spaces → _
            filename = f"{clean_title}.mp4"
            if len(filename) > 200:
                name, ext = os.path.splitext(filename)
                filename = f"{name[:195]}{ext}"

            logging.info("📹 Video: %s", title)
            logging.info("📹 Duration: %s seconds", duration)
            logging.info("📹 Filename: %s", filename)

            _progress_event(
                download_id,
                f"Video: {title}",
                stage="info",
                progress=0.08,
                details={
                    "title": title,
                    "duration": duration,
                    "filename": filename,
                },
            )
            _progress_event(
                download_id, f"Duration: {duration} s", stage="info", progress=0.08
            )
        except (
            yt_dlp.utils.DownloadError,
            OSError,
            ValueError,
            TypeError,
            KeyError,
        ) as e:
            msg = f"Info error: {e}"
            logging.error("❌ %s", msg, exc_info=True)
            _progress_finish(download_id, error=msg)
            return jsonify({"success": False, "error": msg}), 400

        # ── 2. Download ──────────────────────────────────────────────
        _progress_event(
            download_id,
            "Downloading video + audio…",
            stage="downloading",
            progress=0.15,
        )
        try:
            download_result = download_youtube_video_adaptive(
                youtube_url, UPLOAD_FOLDER, filename
            )
        except (
            yt_dlp.utils.DownloadError,
            OSError,
            ValueError,
            TypeError,
            KeyError,
        ) as e:
            msg = f"Download error: {e}"
            logging.error("❌ %s", msg, exc_info=True)
            _progress_finish(download_id, error=msg)
            return jsonify({"success": False, "error": msg}), 400

        if not download_result.get("success"):
            msg = download_result.get("error", "Download failed")
            logging.error("❌ Download error: %s", msg)
            _progress_finish(download_id, error=msg)
            return jsonify({"success": False, "error": msg}), 400

        file_path = download_result.get("file_path")
        if not file_path or not os.path.exists(file_path):
            msg = "Downloaded file not found"
            _progress_finish(download_id, error=msg)
            return jsonify({"error": msg}), 500

        file_size = download_result.get("filesize", 0)
        duration = download_result.get("duration", duration)
        actual_filename = download_result.get("filename", filename)
        has_audio = download_result.get("has_audio", False)

        logging.info("✅ Video downloaded: %s (%s bytes)", file_path, file_size)
        logging.info("🎵 Has audio: %s", has_audio)

        _progress_event(
            download_id,
            f"Download complete: {actual_filename} ({file_size} bytes)",
            stage="downloaded",
            progress=0.45,
            details={
                "filename": actual_filename,
                "filesize": file_size,
                "duration": duration,
                "has_audio": has_audio,
            },
        )
        _progress_event(
            download_id,
            f"Audio present: {has_audio}",
            stage="downloaded",
            progress=0.45,
        )

        if file_size < 1000:
            msg = "Downloaded file is too small (corrupted)"
            logging.error("❌ %s", msg)
            if os.path.exists(file_path):
                try:
                    os.remove(file_path)
                except OSError:
                    pass
            _progress_finish(download_id, error=msg)
            return jsonify({"error": msg}), 500

        # ── 3. Codec check + conversion ──────────────────────────────
        codec = ""
        try:
            probe_cmd = [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=codec_name",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                file_path,
            ]
            result = subprocess.run(
                probe_cmd, capture_output=True, text=True, timeout=10, check=False
            )
            codec = result.stdout.strip() if result.returncode == 0 else ""
            logging.info("📹 Video codec: %s", codec)
            _progress_event(
                download_id,
                f"Video codec: {codec or 'unknown'}",
                stage="probing",
                progress=0.50,
                details={"codec": codec},
            )
        except (OSError, subprocess.SubprocessError, ValueError, TypeError) as e:
            logging.warning("⚠️ Could not probe codec: %s", e)

        if codec and codec != "h264":
            _progress_event(
                download_id,
                "Converting video to browser-compatible format…",
                stage="converting",
                progress=0.55,
            )
            logging.info("🔄 Converting video to browser-compatible format...")
            try:
                base_name = os.path.splitext(actual_filename)[0]
                converted_filename = f"{base_name}_converted.mp4"
                converted_path = os.path.join(UPLOAD_FOLDER, converted_filename)

                if convert_video_to_browser_compatible(file_path, converted_path):
                    backup_path = file_path + ".backup"
                    os.rename(file_path, backup_path)
                    os.rename(converted_path, file_path)
                    file_size = os.path.getsize(file_path)
                    actual_filename = os.path.basename(file_path)

                    _progress_event(
                        download_id,
                        f"Conversion complete: {actual_filename}",
                        stage="converted",
                        progress=0.70,
                        details={
                            "filename": actual_filename,
                            "filesize": file_size,
                            "converted": True,
                        },
                    )
                    logging.info("✅ Video converted successfully: %s", actual_filename)

                    if os.path.exists(backup_path):
                        try:
                            os.remove(backup_path)
                        except OSError:
                            pass
                else:
                    _progress_event(
                        download_id,
                        "Conversion failed — using original file",
                        level="warning",
                        stage="converted",
                        progress=0.70,
                    )
                    logging.warning("⚠️ Video conversion failed, using original")
                    if os.path.exists(converted_path):
                        try:
                            os.remove(converted_path)
                        except OSError:
                            pass
            except (OSError, subprocess.SubprocessError, ValueError, TypeError) as e:
                logging.warning("⚠️ Could not convert video: %s", e)
                _progress_event(
                    download_id,
                    f"Conversion error: {e}",
                    level="warning",
                    stage="converted",
                    progress=0.70,
                )
        else:
            _progress_event(
                download_id,
                "Video already browser-compatible (H.264)",
                stage="converted",
                progress=0.70,
                details={"converted": False},
            )

        # ── 4. Thumbnail ─────────────────────────────────────────────
        _progress_event(
            download_id, "Generating thumbnail…", stage="thumbnail", progress=0.78
        )
        try:
            thumb_filename = f"{os.path.splitext(actual_filename)[0]}_thumb.jpg"
            thumb_path = os.path.join(UPLOAD_FOLDER, thumb_filename)
            thumbnail_url = None
            thumbnail_generated = False

            try:
                if generate_video_thumbnail_simple(file_path, thumb_path):
                    thumbnail_url = f"/thumbnails/{thumb_filename}"
                    thumbnail_generated = True
                    logging.info("✅ Thumbnail generated with ffmpeg")
                    _progress_event(
                        download_id,
                        "Thumbnail generated",
                        stage="thumbnail",
                        progress=0.82,
                    )
            except (OSError, RuntimeError, ValueError, TypeError) as e:
                logging.warning("⚠️ FFmpeg thumbnail failed: %s", e)

            if not thumbnail_generated:
                try:
                    cv2 = importlib.import_module("cv2")
                    cap = cv2.VideoCapture(file_path)
                    ret, frame = cap.read()
                    if ret:
                        cv2.imwrite(thumb_path, frame)
                        thumbnail_url = f"/thumbnails/{thumb_filename}"
                        thumbnail_generated = True
                        _progress_event(
                            download_id,
                            "Thumbnail generated (OpenCV)",
                            stage="thumbnail",
                            progress=0.82,
                        )
                    cap.release()
                except (ImportError, OSError, RuntimeError, ValueError, TypeError) as e:
                    logging.warning("⚠️ OpenCV thumbnail failed: %s", e)

            if not thumbnail_generated:
                _progress_event(
                    download_id,
                    "No thumbnail generated",
                    level="warning",
                    stage="thumbnail",
                    progress=0.82,
                )
        except (OSError, RuntimeError, ValueError, TypeError) as e:
            logging.warning("⚠️ Thumbnail generation error: %s", e)
            thumbnail_url = None

        # ── 5. Metadata ──────────────────────────────────────────────
        try:
            if duration == 0:
                duration, fps = get_video_metadata(file_path)
            else:
                fps = 30.0
        except (OSError, RuntimeError, ValueError, TypeError):
            duration = duration or 120.0
            fps = 30.0

        # ── 6. Save project ──────────────────────────────────────────
        _progress_event(download_id, "Saving project…", stage="saving", progress=0.90)
        video_key = str(uuid.uuid4())
        project = {
            "key": video_key,
            "name": clean_title,
            "file_name": actual_filename,
            "uploaded": utc_now_iso(),
            "last_opened": None,
            "duration": duration,
            "fps": fps,
            "file_size": file_size,
            "segment_count": 0,
            "languages": ["en"],
            "thumbnail_url": thumbnail_url,
            "segmentation_done": auto_segmentation,
            "segmentation_progress": 100 if auto_segmentation else 0,
        }
        videos.append(project)
        save_state()

        # ── 7. Optional segmentation job ─────────────────────────────
        if auto_segmentation:
            job_id = str(uuid.uuid4())
            job = {
                "id": job_id,
                "video_key": video_key,
                "status": "processing",
                "progress": 0.0,
                "transcript": None,
                "segments": None,
                "created_at": utc_now_iso(),
                "config": {"auto_segmentation": True},
            }
            jobs[job_id] = job
            threading.Thread(target=process_job, args=(job_id,), daemon=True).start()
            save_state()

        _progress_event(
            download_id, f'Imported "{clean_title}"', stage="done", progress=1.0
        )
        _progress_finish(
            download_id,
            details={
                "title": clean_title,
                "video_key": video_key,
            },
        )

        logging.info("=" * 60)
        logging.info("✅ YouTube video uploaded successfully: %s", clean_title)
        logging.info("=" * 60)

        return (
            jsonify(
                {
                    "success": True,
                    "video_info": {
                        "title": clean_title,
                        "duration": duration,
                        "file_size": file_size,
                        "thumbnail": thumbnail_url,
                        "has_audio": has_audio,
                    },
                    "project": project,
                    "message": f'Video "{clean_title}" imported successfully',
                    "filename": actual_filename,
                    "video_key": video_key,
                }
            ),
            200,
        )

    except (
        OSError,
        RuntimeError,
        ValueError,
        TypeError,
        KeyError,
        yt_dlp.utils.DownloadError,
    ) as e:
        logging.error("❌ YouTube download error: %s", e, exc_info=True)
        _progress_finish(download_id, error=f"Server error: {e}")
        return jsonify({"success": False, "error": f"Server error: {e}"}), 500


def generate_video_thumbnail_simple(video_path, thumbnail_path):
    """
    Generate a thumbnail using ffmpeg with multiple attempts.
    """
    try:
        # Check if ffmpeg is available
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)

        # Get video duration
        duration = 0
        try:
            probe_cmd = [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                video_path,
            ]
            result = subprocess.run(
                probe_cmd, capture_output=True, text=True, timeout=10, check=False
            )
            if result.returncode == 0 and result.stdout.strip():
                duration = float(result.stdout.strip())
        except (OSError, ValueError, subprocess.SubprocessError):
            pass

        # Try different positions
        positions = [1.0, 5.0, 10.0]
        if duration > 30:
            positions.append(duration * 0.5)
        if duration > 60:
            positions.append(duration * 0.25)
            positions.append(duration * 0.75)

        for pos in positions:
            if pos >= duration:
                continue

            cmd = [
                "ffmpeg",
                "-ss",
                str(pos),
                "-i",
                video_path,
                "-vframes",
                "1",
                "-vf",
                "scale=320:-1:flags=lanczos",
                "-q:v",
                "2",
                "-y",
                thumbnail_path,
            ]

            result = subprocess.run(
                cmd, capture_output=True, text=True, check=False, timeout=30
            )

            if (
                result.returncode == 0
                and os.path.exists(thumbnail_path)
                and os.path.getsize(thumbnail_path) > 1000
            ):
                logging.info("✅ Thumbnail generated at %ss", pos)
                return True

        # Fallback: first frame
        cmd = [
            "ffmpeg",
            "-i",
            video_path,
            "-vframes",
            "1",
            "-vf",
            "scale=320:-1:flags=lanczos",
            "-q:v",
            "2",
            "-y",
            thumbnail_path,
        ]

        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        )

        if (
            result.returncode == 0
            and os.path.exists(thumbnail_path)
            and os.path.getsize(thumbnail_path) > 1000
        ):
            logging.info("✅ Thumbnail generated from first frame")
            return True

        return False

    except (OSError, ValueError, subprocess.SubprocessError) as e:
        logging.warning("⚠️ Thumbnail generation error: %s", str(e))
        return False


# ─── UPLOAD ENDPOINT ────────────────────────────────────────────────────


@app.route("/upload", methods=["POST", "OPTIONS"])
def upload_lecture():
    """Upload a video file to the internal server using streaming."""
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

    # ─── 1. Validate inputs ─────────────────────────────────────────
    token = request.form.get("token", "")
    if not token:
        return jsonify({"error": "Missing token"}), 400
    if "videofile" not in request.files:
        return jsonify({"error": "No video file provided"}), 400

    file_storage = request.files["videofile"]
    if file_storage.filename == "":
        return jsonify({"error": "Empty filename"}), 400

    session_name = request.form.get("name", file_storage.filename)

    # ─── 2. Normalize filename (force .mp4) ────────────────────────
    original_filename = file_storage.filename
    if not original_filename.lower().endswith(".mp4"):
        name_without_ext = os.path.splitext(original_filename)[0]
        original_filename = f"{name_without_ext}.mp4"
        logging.info("📹 Added .mp4 extension: %s", original_filename)

    # ─── 3. Reuse existing project or create a new one ────────────
    existing_video = None
    for video in videos:
        if video.get("file_name") == original_filename:
            existing_video = video
            break

    file_size = 0
    local_filename = original_filename
    local_path = os.path.join(UPLOAD_FOLDER, local_filename)
    project = None
    video_key = None

    if existing_video:
        video_key = existing_video["key"]
        project = existing_video
        logging.info(
            "📹 Using existing video: %s (key: %s)", original_filename, video_key
        )

        if not os.path.exists(local_path):
            file_storage.save(local_path)
            file_size = os.path.getsize(local_path)
            project["file_size"] = file_size
            logging.info("✅ Restored video file: %s", local_filename)
        else:
            file_size = os.path.getsize(local_path)
            project["file_size"] = file_size
            logging.info(
                "✅ Using existing file: %s (%d bytes)", local_filename, file_size
            )
    else:
        # New video — pick a unique filename
        base_name, ext = os.path.splitext(original_filename)
        if not ext:
            ext = ".mp4"
        counter = 1
        while os.path.exists(os.path.join(UPLOAD_FOLDER, local_filename)):
            local_filename = f"{base_name}_{counter}{ext}"
            counter += 1

        local_path = os.path.join(UPLOAD_FOLDER, local_filename)
        file_storage.save(local_path)
        file_size = os.path.getsize(local_path)
        logging.info("✅ New video saved: %s (%d bytes)", local_filename, file_size)

        video_key = str(uuid.uuid4())
        project = {
            "key": video_key,
            "name": session_name,
            "file_name": local_filename,
            "uploaded": utc_now_iso(),
            "last_opened": None,
            "duration": 120.0,
            "fps": 30.0,
            "file_size": file_size,
            "segment_count": 0,
            "languages": request.form.getlist("language") or ["en"],
            "thumbnail_url": None,
            "segmentation_done": False,
            "segmentation_progress": 0,
        }
        videos.append(project)

    # ─── 4. Build the data dict for the internal server ────────────
    data = {}
    for key in request.form.keys():
        if key == "token":
            continue
        values = request.form.getlist(key)
        data[key] = values[0] if len(values) == 1 else values
    if "path" not in data:
        data["path"] = "/home/admin@example.com"

    headers = {
        "X-Forward-Auth": token,
        "Authorization": f"Bearer {token}",
        "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
    }
    cookies = {"_forward_auth": token}

    # ─── 5. Build the multipart body into a temp file ──────────────
    #     We build it explicitly so we can send an explicit Content-Length.
    #     Many proxies and the internal server reject chunked uploads.
    #
    #     IMPORTANT (Windows): NamedTemporaryFile holds an exclusive lock
    #     on the file until its handle is closed. If we try to reopen the
    #     file for reading while the write handle is still open, Windows
    #     raises PermissionError → Flask returns 500. Using `with` here
    #     guarantees the handle is released before we re-open for reading.
    temp_multipart_path = None
    try:
        # Resolve which internal server this upload should go to.
        # Form value wins, but only if it is on the allow-list.
        target_url = _resolve_target_url(request.form.get("targetServer"))
        base_url = target_url.rsplit("/upload_lecture", 1)[0]

        logging.info("Uploading to internal server: %s", target_url)
        logging.info("Data keys: %s", list(data.keys()))
        logging.info("File size: %d bytes", file_size)

        boundary = f"----WebKitFormBoundary{uuid.uuid4().hex[:16]}"
        content_type = f"multipart/form-data; boundary={boundary}"

        total_size = 0

        with tempfile.NamedTemporaryFile(delete=False) as temp_multipart:
            temp_multipart_path = temp_multipart.name

            # Form fields
            for key, value in data.items():
                if isinstance(value, list):
                    for v in value:
                        part = (
                            f"--{boundary}\r\n"
                            f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
                            f"{v}\r\n"
                        ).encode("utf-8")
                        temp_multipart.write(part)
                        total_size += len(part)
                else:
                    part = (
                        f"--{boundary}\r\n"
                        f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
                        f"{value}\r\n"
                    ).encode("utf-8")
                    temp_multipart.write(part)
                    total_size += len(part)

            # File header
            upload_filename = file_storage.filename
            mimetype = mimetypes.guess_type(upload_filename)[0] or "video/mp4"
            file_header = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="videofile"; '
                f'filename="{upload_filename}"\r\n'
                f"Content-Type: {mimetype}\r\n\r\n"
            ).encode("utf-8")
            temp_multipart.write(file_header)
            total_size += len(file_header)

            # File content, streamed in 1 MB chunks
            with open(local_path, "rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    temp_multipart.write(chunk)
                    total_size += len(chunk)

            # Trailer
            trailer = f"\r\n--{boundary}--\r\n".encode("utf-8")
            temp_multipart.write(trailer)
            total_size += len(trailer)

        # `with` closed the handle here — safe to reopen on Windows now.
        logging.info("Multipart body prepared: %d bytes total", total_size)

        # ─── 6. POST to the internal server ────────────────────────
        headers_with_length = {
            **headers,
            "Content-Type": content_type,
            "Content-Length": str(total_size),
        }

        with open(temp_multipart_path, "rb") as body_file:
            resp = requests.post(
                target_url,
                data=body_file,
                headers=headers_with_length,
                cookies=cookies,
                timeout=(60, 3600),
                verify=False,
                allow_redirects=True,
            )

        logging.info("Response status: %s", resp.status_code)
        logging.info("Response URL: %s", resp.url)

        if resp.status_code >= 400:
            logging.error(
                "Internal server rejected upload: %s\nBody: %s",
                resp.status_code,
                resp.text[:2000],
            )

        # ─── 7. Extract session id ─────────────────────────────────
        final_url = resp.url
        session_id = None

        if "/archivesession/" in final_url:
            session_id = final_url.split("/archivesession/")[-1].split("/")[0]
            logging.info("Extracted session ID from URL: %s", session_id)
        elif "/session/" in final_url:
            session_id = final_url.split("/session/")[-1].split("/")[0]
            logging.info("Extracted session ID from URL: %s", session_id)

        if not session_id and session_name and resp.status_code < 400:
            user_email = data.get("path", "/home/admin@example.com")
            user_email = user_email.strip("/").split("/")[-1]
            path = f"/home/{user_email}/{session_name}"
            session_id = base64.b64encode(path.encode()).decode()
            logging.info("Generated fallback session ID: %s", session_id)

        if not session_id:
            logging.error(
                "Upload to %s returned %s without a session id. Body: %s",
                target_url,
                resp.status_code,
                resp.text[:500],
            )
            return (
                jsonify(
                    {
                        "error": "Upload did not produce a session id",
                        "status_code": resp.status_code,
                        "response_preview": resp.text[:500],
                    }
                ),
                502,
            )

        content = resp.text

        # ─── 8. Register session + start background download ──────
        if session_id:
            project["session_id"] = session_id
            project["session_url"] = f"{base_url}/archivesession/{session_id}"

            # Collect the requested target languages *before* recording
            # the session, so both stay in sync.
            expected_mt = request.form.getlist("mtLanguage") or ["de"]
            logging.info("Expected translation languages: %s", expected_mt)

            _clear_cancel(session_id)

            sessions[session_id] = {
                "id": session_id,
                "name": session_name,
                "video_key": video_key,
                "created_at": utc_now_iso(),
                "url": f"{base_url}/archivesession/{session_id}",
                "server": base_url,
                "expected_mt": expected_mt,
            }
            logging.info("Session created: %s", session_id)

            job = {
                "id": session_id,
                "video_key": video_key,
                "status": "processing",
                "progress": 0.0,
                "transcript": None,
                "segments": None,
                "created_at": utc_now_iso(),
                "config": dict(request.form),
            }
            jobs[session_id] = job

            # collect the requested target languages for the readiness gate
            expected_mt = request.form.getlist("mtLanguage") or ["de"]
            logging.info("Expected translation languages: %s", expected_mt)

            threading.Thread(
                target=process_session_in_background,
                args=(session_id, token, video_key, base_url, expected_mt),
                daemon=True,
            ).start()
            save_state()

        # ─── 9. Respond to the client ─────────────────────────────
        try:
            response_data = json.loads(content)
            if session_id:
                response_data.update(
                    {
                        "session_id": session_id,
                        "video_key": video_key,
                        "session_url": f"{base_url}/archivesession/{session_id}",
                        "output_url": f"/session_output/{session_id}",
                        "download_url": f"/session_zip/{session_id}",
                    }
                )
            return jsonify(response_data), resp.status_code
        except json.JSONDecodeError:
            if session_id:
                return (
                    jsonify(
                        {
                            "status": "success",
                            "session_id": session_id,
                            "video_key": video_key,
                            "session_url": f"{base_url}/archivesession/{session_id}",
                            "output_url": f"/session_output/{session_id}",
                            "download_url": f"/session_zip/{session_id}",
                            "message": "Upload successful!",
                            "response": content[:500],
                        }
                    ),
                    resp.status_code,
                )
            return (
                jsonify(
                    {
                        "status": "error",
                        "message": "No session ID received",
                        "response": content[:1000],
                        "status_code": resp.status_code,
                        "url": resp.url,
                    }
                ),
                500,
            )

    except requests.exceptions.Timeout:
        logging.error("Request to internal server timed out", exc_info=True)
        return jsonify({"error": "Request timeout - file may be too large"}), 504
    except requests.exceptions.RequestException as e:
        logging.error("Request error (%s): %s", type(e).__name__, e, exc_info=True)
        return (
            jsonify(
                {
                    "error": f"Request failed: {type(e).__name__}: {e}",
                }
            ),
            500,
        )
    except OSError as e:
        logging.error("Upload error (%s): %s", type(e).__name__, e, exc_info=True)
        return (
            jsonify(
                {
                    "error": f"Upload failed: {type(e).__name__}: {e}",
                }
            ),
            500,
        )
    finally:
        # Always clean up the temp multipart body, even on success.
        if temp_multipart_path and os.path.exists(temp_multipart_path):
            try:
                os.unlink(temp_multipart_path)
            except OSError:
                pass


# ─── PROXY ENDPOINTS ────────────────────────────────────────────────────
@app.route("/forward_to_internal/<video_key>", methods=["POST", "OPTIONS"])
def forward_to_internal(video_key):
    """Forward a locally-stored video to the internal KIT server.

    Called by the Flutter client after /upload-chunk + /finish-upload
    have stored the file locally. Uploads to the KIT server, creates a
    session, spawns the background download worker, and returns the
    session id so the client can start polling /job_progress.
    """
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "POST,OPTIONS")
        return response, 200

    # ─── 1. Token ──────────────────────────────────────────────
    data_in = request.get_json(silent=True) or {}
    token = (data_in.get("token") or "").strip()
    if not token:
        token = request.headers.get("Authorization", "").replace("Bearer ", "").strip()
    if not token:
        return jsonify({"error": "Missing token"}), 400

    session_name = (data_in.get("name") or "").strip()

    # ─── 2. Look up the video ─────────────────────────────────
    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        return jsonify({"error": "Video not found", "video_key": video_key}), 404

    file_name = project.get("file_name")
    if not file_name:
        return jsonify({"error": "Video has no file_name"}), 400

    local_path = os.path.join(UPLOAD_FOLDER, file_name)
    if not os.path.exists(local_path):
        return jsonify({"error": f'File "{file_name}" not found on disk'}), 404

    file_size = os.path.getsize(local_path)
    if file_size < 1000:
        return jsonify({"error": "File is too small to upload"}), 400

    if not session_name:
        session_name = project.get("name") or os.path.splitext(file_name)[0]

    # ─── 3. Build the KIT form fields ─────────────────────────
    # Defaults mirror what job_configuration_screen.dart sends.
    user_email = "admin@example.com"

    form_data = {
        "path": f"/home/{user_email}",
        "name": session_name,
        "topicname": session_name,
        "date": datetime.datetime.now().strftime("%Y-%m-%d"),
        "speakername": "",
        "availability": "private",
        "format": "mixed",
        "smartChaptering": "online_dynamic",
        "errorCorrection": "None",
        "ttsQualityMode": "low_latency",
        "language": ["en"],
        "mtLanguage": ["de"],
        "audioLanguage": ["de"],
        "profanity": "1",
        "filter_music": "1",
        "summarization": "1",
        "logging": "1",
        "legals": "1",
        "profile": "profile_1",
        "profile_names": "",
        "shorten": "",
        "mute": "120",
        "pause": "2",
        "save_profile": "1",
    }

    boundary = f"----WebKitFormBoundary{uuid.uuid4().hex[:16]}"
    content_type = f"multipart/form-data; boundary={boundary}"

    temp_multipart_path = None
    try:
        # Resolve which internal server this upload should go to.
        # JSON body wins; fall back to a header; fall back to default.
        target_url = _resolve_target_url(
            data_in.get("targetServer") or request.headers.get("X-Target-Server")
        )
        base_url = target_url.rsplit("/upload_lecture", 1)[0]

        # ─── 4. Build the multipart body in a temp file ──────
        total_size = 0
        with tempfile.NamedTemporaryFile(delete=False) as temp_multipart:
            temp_multipart_path = temp_multipart.name

            for key, value in form_data.items():
                if isinstance(value, list):
                    for v in value:
                        part = (
                            f"--{boundary}\r\n"
                            f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
                            f"{v}\r\n"
                        ).encode("utf-8")
                        temp_multipart.write(part)
                        total_size += len(part)
                else:
                    part = (
                        f"--{boundary}\r\n"
                        f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
                        f"{value}\r\n"
                    ).encode("utf-8")
                    temp_multipart.write(part)
                    total_size += len(part)

            upload_filename = file_name
            if not upload_filename.lower().endswith(".mp4"):
                upload_filename = f"{upload_filename}.mp4"
            mimetype = mimetypes.guess_type(upload_filename)[0] or "video/mp4"
            file_header = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="videofile"; '
                f'filename="{upload_filename}"\r\n'
                f"Content-Type: {mimetype}\r\n\r\n"
            ).encode("utf-8")
            temp_multipart.write(file_header)
            total_size += len(file_header)

            with open(local_path, "rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    temp_multipart.write(chunk)
                    total_size += len(chunk)

            trailer = f"\r\n--{boundary}--\r\n".encode("utf-8")
            temp_multipart.write(trailer)
            total_size += len(trailer)

        logging.info(
            "forward_to_internal: uploading %s (%d bytes) to %s",
            file_name,
            file_size,
            target_url,
        )

        # ─── 5. POST to the internal server ───────────────────
        headers = {
            "X-Forward-Auth": token,
            "Authorization": f"Bearer {token}",
            "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
            "Content-Type": content_type,
            "Content-Length": str(total_size),
        }
        cookies = {"_forward_auth": token}

        with open(temp_multipart_path, "rb") as body_file:
            resp = requests.post(
                target_url,
                data=body_file,
                headers=headers,
                cookies=cookies,
                timeout=(60, 3600),
                verify=False,
                allow_redirects=True,
            )

        logging.info(
            "forward_to_internal: status=%s url=%s", resp.status_code, resp.url
        )

        if resp.status_code >= 400:
            logging.error(
                "forward_to_internal: internal server rejected: %s\nBody: %s",
                resp.status_code,
                resp.text[:2000],
            )
            return (
                jsonify(
                    {
                        "error": f"Internal server returned {resp.status_code}",
                        "response": resp.text[:1000],
                    }
                ),
                502,
            )

        # ─── 6. Extract the session id ────────────────────────
        final_url = resp.url
        session_id = None

        if "/archivesession/" in final_url:
            session_id = final_url.split("/archivesession/")[-1].split("/")[0]
        elif "/session/" in final_url:
            session_id = final_url.split("/session/")[-1].split("/")[0]

        if not session_id and session_name:
            path = f"/home/{user_email}/{session_name}"
            session_id = base64.b64encode(path.encode()).decode()

        if not session_id:
            return jsonify({"error": "No session id from internal server"}), 502

        # ─── 7. Clear stale local state for this session ──────
        session_dir = os.path.join(SESSION_FOLDER, session_id)
        if os.path.exists(session_dir):
            try:
                shutil.rmtree(session_dir)
                logging.info(
                    "forward_to_internal: cleared stale session dir %s",
                    session_dir,
                )
            except OSError as e:
                logging.warning("Could not clear %s: %s", session_dir, e)

        with job_progress_lock:
            _job_progress_store.pop(session_id, None)

        # ─── 8. Register session + spawn background worker ────
        # Normalise the requested translation targets before registering
        # the session, so the recovery path can find them later.
        expected_mt = data_in.get("mtLanguage") or data_in.get("mt_languages") or ["de"]
        if isinstance(expected_mt, str):
            expected_mt = [expected_mt]

        _clear_cancel(session_id)

        project["session_id"] = session_id
        project["session_url"] = f"{base_url}/archivesession/{session_id}"

        sessions[session_id] = {
            "id": session_id,
            "name": session_name,
            "video_key": video_key,
            "created_at": utc_now_iso(),
            "url": f"{base_url}/archivesession/{session_id}",
            "server": base_url,
            "expected_mt": expected_mt,
        }

        jobs[session_id] = {
            "id": session_id,
            "video_key": video_key,
            "status": "processing",
            "progress": 0.0,
            "transcript": None,
            "segments": None,
            "created_at": utc_now_iso(),
            "config": {"source": "forward_to_internal"},
            "expected_mt": expected_mt,
        }

        # forward_to_internal has no form fields, so fall back to the
        # defaults the Flutter client sends in /upload. If you ever add
        # mtLanguage to the JSON body, read it from data_in instead.
        expected_mt = data_in.get("mtLanguage") or data_in.get("mt_languages") or ["de"]
        if isinstance(expected_mt, str):
            expected_mt = [expected_mt]

        threading.Thread(
            target=process_session_in_background,
            args=(session_id, token, video_key, base_url, expected_mt),
            daemon=True,
        ).start()
        save_state()

        logging.info(
            "forward_to_internal: session %s registered, worker started",
            session_id,
        )

        return (
            jsonify(
                {
                    "success": True,
                    "session_id": session_id,
                    "video_key": video_key,
                    "session_url": f"{base_url}/archivesession/{session_id}",
                    "output_url": f"{base_url}/session_output/{session_id}",
                    "download_url": f"{base_url}/session_zip/{session_id}",
                }
            ),
            200,
        )

    except requests.exceptions.Timeout:
        logging.error("forward_to_internal: timeout", exc_info=True)
        return (
            jsonify({"error": "Timeout while uploading to internal server"}),
            504,
        )
    except requests.exceptions.RequestException as e:
        logging.error("forward_to_internal: request error %s", e, exc_info=True)
        return (
            jsonify({"error": f"Request failed: {type(e).__name__}: {e}"}),
            500,
        )
    except OSError as e:
        logging.error("forward_to_internal: OS error %s", e, exc_info=True)
        return (
            jsonify({"error": f"Upload failed: {type(e).__name__}: {e}"}),
            500,
        )
    finally:
        if temp_multipart_path and os.path.exists(temp_multipart_path):
            try:
                os.unlink(temp_multipart_path)
            except OSError:
                pass


@app.route("/check-session", methods=["GET"])
def check_session():
    """Forward a GET request to check if the session is authenticated."""
    headers = {}
    auth = request.headers.get("Authorization")
    if auth:
        headers["Authorization"] = auth
    forwarded_user = request.headers.get("X-Forwarded-User")
    if forwarded_user:
        headers["X-Forwarded-User"] = forwarded_user
    try:
        resp = requests.get(
            INTERNAL_SERVER_URL,
            headers=headers,
            allow_redirects=False,
            timeout=10,
            verify=False,
        )
        final_url = resp.url if hasattr(resp, "url") else INTERNAL_SERVER_URL
        is_login_page = resp.status_code == 200 and (
            "Log in to dex" in resp.text or "dex-container" in resp.text
        )
        authenticated = not (
            "dex" in final_url or resp.status_code == 302 or is_login_page
        )
        return jsonify({"authenticated": authenticated}), 200
    except requests.exceptions.RequestException:
        return jsonify({"authenticated": False, "error": "Request failed"}), 200


@app.route("/dex/token", methods=["POST"])
def dex_token():
    """Forward token exchange to the internal server's /dex/token endpoint."""
    try:
        headers = {k: v for k, v in request.headers if k.lower() != "host"}
        resp = requests.post(
            f"{INTERNAL_SERVER_URL}/dex/token",
            data=request.get_data(),
            headers=headers,
            allow_redirects=False,
            timeout=30,
            verify=False,
        )
        return (resp.content, resp.status_code, resp.headers.items())
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Proxy error: {str(e)}"}), 500


@app.route("/dex/userinfo", methods=["GET"])
def dex_userinfo():
    """Forward userinfo request to the internal server's /dex/userinfo endpoint."""
    try:
        headers = {k: v for k, v in request.headers if k.lower() != "host"}
        resp = requests.get(
            f"{INTERNAL_SERVER_URL}/dex/userinfo",
            headers=headers,
            allow_redirects=False,
            timeout=30,
            verify=False,
        )
        return (resp.content, resp.status_code, resp.headers.items())
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Proxy error: {str(e)}"}), 500


# ─── DEBUG ENDPOINTS ────────────────────────────────────────────────────


@app.route("/debug-videos", methods=["GET"])
def debug_videos():
    """Debug endpoint: return all video metadata (including duplicates)."""
    base = _public_base_url()
    serialized = []
    for video in videos:
        v = dict(video)
        thumb = v.get("thumbnail_url")
        if thumb and thumb.startswith("/thumbnails/"):
            v["thumbnail_url"] = _thumbnail_absolute_url(video)
        serialized.append(v)
    return jsonify({"count": len(videos), "projects": serialized}), 200


@app.route("/debug-jobs", methods=["GET"])
def debug_jobs():
    """Debug endpoint: return all jobs."""
    return jsonify({"count": len(jobs), "jobs": jobs}), 200


@app.route("/clear-videos", methods=["POST"])
def clear_videos():
    """Clear all uploaded videos, thumbnails and chunk/job state."""
    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            continue

        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if os.path.exists(file_path):
            try:
                os.remove(file_path)
            except OSError as e:
                logging.warning("Could not remove %s: %s", file_path, e)

        thumb_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        thumb_path = os.path.join(UPLOAD_FOLDER, thumb_filename)
        if os.path.exists(thumb_path):
            try:
                os.remove(thumb_path)
            except OSError as e:
                logging.warning("Could not remove %s: %s", thumb_path, e)

    videos.clear()
    chunk_storage.clear()
    jobs.clear()
    save_state()
    return jsonify({"message": "Cleared"}), 200


users["testuser@example.com"] = {
    "name": "Test User",
    "password": "YourSecurePassword123",
}


if __name__ == "__main__":
    try:
        import urllib3

        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    except ImportError:
        pass

    # Load saved state
    load_state()

    # Clean up missing videos and orphaned data
    clean_missing_videos()
    cleanup_orphaned_data()

    # Remove any stray files from the old versioned-name scheme, keep
    # only "video.mp4" and "video_subtitled.mp4".
    _KEEP_VIDEO_FILES = {"video.mp4", "video_subtitled.mp4"}

    for sess_id in list(sessions.keys()):
        sess_dir = os.path.join(SESSION_FOLDER, sess_id)
        if not os.path.isdir(sess_dir):
            continue
        for sess_filename in os.listdir(sess_dir):
            if not sess_filename.startswith("video") or not sess_filename.endswith(
                ".mp4"
            ):
                continue
            if sess_filename in _KEEP_VIDEO_FILES:
                continue
            try:
                os.remove(os.path.join(sess_dir, sess_filename))
                logging.info(
                    "🧹 Removed stale video %s in session %s",
                    sess_filename,
                    _short_sid(sess_id),
                )
            except OSError:
                pass

    # Regenerate missing thumbnails
    regenerate_missing_thumbnails()

    logging.info("Starting merged server on 0.0.0.0:5000")
    logging.info("State file: %s", STATE_FILE)
    app.run(host="0.0.0.0", port=5000, debug=True)
