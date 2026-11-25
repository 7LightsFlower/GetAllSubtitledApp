"""Start-up: default user, state initialisation; exposes `app`/`application`.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import importlib
import logging

from .config import jobs, sessions, users, videos
from .state import (
    clean_missing_videos,
    cleanup_orphaned_data,
    load_state,
    rebuild_videos_from_disk,
    regenerate_missing_thumbnails,
)


# Importing every module registers all routes on the shared Flask app
# (they use @app.route), in the same order as the former backend.py.
# importlib, not `from . import …`: module names must never shadow the
# shared stores imported above (e.g. `videos`, `jobs`).
_MODULES = [
    importlib.import_module(".flask_app", __package__),
    importlib.import_module(".servers", __package__),
    importlib.import_module(".live", __package__),
    importlib.import_module(".config", __package__),
    importlib.import_module(".state", __package__),
    importlib.import_module(".utils", __package__),
    importlib.import_module(".progress", __package__),
    importlib.import_module(".job_routes", __package__),
    importlib.import_module(".video", __package__),
    importlib.import_module(".downloads", __package__),
    importlib.import_module(".tts", __package__),
    importlib.import_module(".transcripts", __package__),
    importlib.import_module(".exports", __package__),
    importlib.import_module(".routes_exports", __package__),
    importlib.import_module(".routes_tts", __package__),
    importlib.import_module(".routes_sessions", __package__),
    importlib.import_module(".kit_messages", __package__),
    importlib.import_module(".session_worker", __package__),
    importlib.import_module(".media", __package__),
    importlib.import_module(".settings", __package__),
    importlib.import_module(".auth", __package__),
    importlib.import_module(".video_routes", __package__),
    importlib.import_module(".session_output", __package__),
    importlib.import_module(".youtube", __package__),
    importlib.import_module(".session_sync", __package__),
    importlib.import_module(".youtube_upload", __package__),
    importlib.import_module(".uploader", __package__),
    importlib.import_module(".misc_routes", __package__),
]
from .flask_app import app  # noqa: E402

# Each module binds the names it uses from modules loaded after it.
for _module in _MODULES:
    getattr(_module, "_link_late_names", lambda: None)()


# Test account, prefilled on the login screen (lib/constants.dart:
# dummyEmail / dummyPassword — keep both in step).
users["guest@lecture-translator.kit.edu"] = {
    "name": "Guest",
    "password": "go in and check",
}


# ─────────────────────────────────────────────────────────────────────
# Startup initialisation
#
# Gunicorn imports this module and runs the top-level code, but it never
# runs the `if __name__ == "__main__":` block below (that only fires when
# the file is executed directly). Without this call, `load_state()` is
# skipped under gunicorn and the process starts with empty `videos`,
# `sessions`, etc. — even though server_state.pkl on the volume is full.
#
# Must run *after* every route and helper is defined, and *after* the
# module-level `users[...]` seeding above.
# ─────────────────────────────────────────────────────────────────────
def _initialise_state_once() -> None:
    """Load persisted state and reconcile with disk. Idempotent."""
    state = _initialise_state_once.__dict__
    if state.get("_done", False):
        return
    state["_done"] = True

    try:
        loaded = load_state()
        logging.info(
            "startup: load_state() -> %s (users=%d videos=%d jobs=%d sessions=%d)",
            loaded,
            len(users),
            len(videos),
            len(jobs),
            len(sessions),
        )
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        logging.exception("startup: load_state() failed; continuing with empty state")

    # Reconciliation: safe to run every startup. Adding missing entries,
    # pruning deleted files, regenerating thumbnails.
    try:
        rebuild_videos_from_disk()
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        logging.exception("startup: rebuild_videos_from_disk() failed")

    try:
        clean_missing_videos()
        cleanup_orphaned_data()
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError):
        logging.exception("startup: cleanup failed")

    try:
        regenerate_missing_thumbnails()
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError):
        logging.exception("startup: thumbnail regeneration failed")


_initialise_state_once()


# WSGI entry points: `gunicorn backend.app:application` (or `:app`).
application = app
