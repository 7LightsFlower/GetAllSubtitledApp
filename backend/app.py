"""Flask application factory and entry point."""

from __future__ import annotations

import datetime
import logging
import os
import shutil
import sys

from flask import Flask, g, jsonify, request
from flask_cors import CORS

from . import config
from .logging_setup import install as install_panel_log_handler
from .progress import _log_target
from .routes import register_all
from .state import (
    _state, jobs, load_state, save_state, sessions, videos, users,
)

# Session-scoped endpoints: bind the request's log records to this
# session's JobProgressPanel entry.
_SESSION_SCOPED_ENDPOINTS = {
    "get_session_output", "session_refresh", "session_resync",
    "job_progress", "session_transcript_save_vtt", "download_session_zip",
    "session_messages_json", "session_tts", "extract_video_subtitles",
    "update_video_subtitles", "session_languages", "session_transcript_json",
    "session_file", "session_export", "session_export_txt",
    "session_export_docx", "session_export_rtf",
    "session_export_structured_json", "session_export_all_languages",
}


def create_app() -> Flask:
    logging.basicConfig(level=logging.INFO)
    logging.getLogger("urllib3").setLevel(logging.INFO)

    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = config.MAX_CONTENT_LENGTH
    app.config["DEBUG"] = True

    CORS(
        app,
        origins=config.CORS_ORIGINS,
        supports_credentials=True,
        methods=config.CORS_METHODS,
        allow_headers=config.CORS_ALLOW_HEADERS,
        expose_headers=config.CORS_EXPOSE_HEADERS,
    )

    install_panel_log_handler()
    register_all(app)
    _register_before_after(app)

    _initialise_state_once()
    _seed_default_user()
    return app


# ─── request hooks ─────────────────────────────────────────────────────
def _register_before_after(app: Flask) -> None:
    @app.after_request
    def add_no_cache_for_api(response):
        if request.path.startswith((
            "/job_progress/", "/job-progress/",
            "/session_output/", "/session-output/",
            "/session_file/", "/session-file/",
            "/session_languages/", "/session-languages/",
            "/session_transcript_json/", "/session-transcript-json/",
            "/session_tts/", "/session-tts/",
            "/api/",
        )):
            response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
            response.headers["Pragma"] = "no-cache"
            response.headers["Expires"] = "0"
        return response

    @app.before_request
    def _route_logs_to_session_panel():
        endpoint = request.endpoint or ""
        if endpoint not in _SESSION_SCOPED_ENDPOINTS:
            return
        session_id = (request.view_args or {}).get("session_id")
        if not session_id:
            return
        setattr(g, "_panel_log_token", _log_target.set(("job", session_id)))

    @app.before_request
    def _capture_auth_token():
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            token = auth[7:].strip()
            if token:
                _state["token"] = token
                return
        cookie = request.cookies.get("_forward_auth", "")
        if cookie:
            _state["token"] = cookie

    @app.teardown_request
    def _unroute_logs_from_session_panel(_exc):
        if getattr(g, "panel_log_reset", False):
            return
        token = getattr(g, "_panel_log_token", None)
        if token is None:
            return
        g.panel_log_reset = True
        try:
            _log_target.reset(token)
        except (ValueError, LookupError, RuntimeError):
            pass


# ─── startup ───────────────────────────────────────────────────────────
def _seed_default_user() -> None:
    users.setdefault("testuser@example.com",
                     {"name": "Test User", "password": "YourSecurePassword123"})


def rebuild_videos_from_disk() -> None:
    """Add `videos` entries for MP4s on disk that aren't tracked yet."""
    from .utils import file_mtime_iso
    from .video import get_video_metadata

    if not os.path.isdir(config.UPLOAD_FOLDER):
        return
    known = {v.get("file_name") for v in videos if v.get("file_name")}
    added = 0
    for filename in sorted(os.listdir(config.UPLOAD_FOLDER)):
        if not filename.lower().endswith(".mp4"):
            continue
        if "__greenscreen" in filename or "_converted" in filename:
            continue
        if filename in known:
            continue
        file_path = os.path.join(config.UPLOAD_FOLDER, filename)
        if not os.path.isfile(file_path):
            continue
        try:
            size = os.path.getsize(file_path)
            uploaded = file_mtime_iso(file_path)
        except OSError:
            continue
        if size < 1000:
            continue

        stem = os.path.splitext(filename)[0]
        thumb_name = f"{stem}_thumb.jpg"
        thumb_path = os.path.join(config.UPLOAD_FOLDER, thumb_name)
        thumbnail_url = (f"/thumbnails/{thumb_name}"
                         if os.path.exists(thumb_path) else None)

        try:
            duration, fps, codec = get_video_metadata(file_path)
        except (OSError, ValueError, TypeError):
            duration, fps, codec = 0.0, 0.0, ""

        source = "Imported (YouTube)" if "youtube" in filename.lower() \
            else "Desktop Upload"
        videos.append({
            "key": __import__("uuid").uuid4().hex,
            "name": stem, "file_name": filename, "uploaded": uploaded,
            "last_opened": None, "duration": duration, "fps": fps,
            "codec": codec, "file_size": size,
            "segment_count": 0, "languages": ["en"],
            "thumbnail_url": thumbnail_url,
            "segmentation_done": False, "segmentation_progress": 0,
            "_recovered": True, "source": source,
        })
        added += 1
    if added:
        save_state()


def _initialise_state_once() -> None:
    state = _initialise_state_once.__dict__
    if state.get("_done", False):
        return
    state["_done"] = True

    try:
        load_state()
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        logging.exception("startup: load_state failed")

    try:
        rebuild_videos_from_disk()
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        logging.exception("startup: rebuild_videos_from_disk failed")

    try:
        _clean_missing_videos()
        _cleanup_orphaned_data()
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError):
        logging.exception("startup: cleanup failed")


def _clean_missing_videos() -> None:
    from .utils import session_dir as _sd  # not needed here; kept for parity
    if not videos:
        return
    valid = []
    for video in videos:
        fn = video.get("file_name")
        if not fn:
            continue
        if os.path.exists(os.path.join(config.UPLOAD_FOLDER, fn)):
            valid.append(video)
        else:
            thumb = f"{os.path.splitext(fn)[0]}_thumb.jpg"
            tp = os.path.join(config.UPLOAD_FOLDER, thumb)
            if os.path.exists(tp):
                try:
                    os.remove(tp)
                except OSError:
                    pass
    if len(valid) != len(videos):
        videos[:] = valid
        save_state()


def _cleanup_orphaned_data() -> None:
    valid_keys = {v.get("key") for v in videos if v.get("key")}
    from .utils import session_dir as sd
    for sid in [s for s, m in sessions.items()
                if m.get("video_key") and m["video_key"] not in valid_keys]:
        d = sd(sid)
        if os.path.exists(d):
            try:
                shutil.rmtree(d)
            except OSError:
                pass
        sessions.pop(sid, None)
    for jid in [j for j, m in jobs.items()
                if m.get("video_key") and m["video_key"] not in valid_keys]:
        jobs.pop(jid, None)
    save_state()


# ─── module-level app object (for gunicorn) ────────────────────────────
app = create_app()


if __name__ == "__main__":
    logging.info("Starting merged server on 0.0.0.0:5000")
    logging.info("State file: %s", config.STATE_FILE)
    app.run(host="0.0.0.0", port=5000, debug=True)