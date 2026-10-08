"""Global mutable state, plus pickle-based persistence.

Everything that used to be a module-level global in backend.py lives
here. Other modules import *names* (`from .state import videos`), so
never rebind these — mutate in place instead.
"""

from __future__ import annotations

import datetime
import hashlib
import logging
import os
import pickle

from .config import STATE_FILE

# ─── The mutable containers ────────────────────────────────────────────
users: dict = {}
videos: list = []
chunk_storage: dict = {}
jobs: dict = {}
sessions: dict = {}

_state = {"token": None}
_warned_senders: set[str] = set()

# Hash of the last payload we wrote to disk; used by save_state() to
# skip redundant writes.
_state_cache = {"last_hash": None}


def _state_payload() -> dict:
    return {
        "users": users,
        "videos": videos,
        "jobs": jobs,
        "sessions": sessions,
    }


def save_state(force: bool = False) -> None:
    try:
        payload = _state_payload()
        blob = pickle.dumps(payload)
        digest = hashlib.sha256(blob).hexdigest()
        if not force and digest == _state_cache["last_hash"]:
            return
        state = {**payload, "timestamp": datetime.datetime.now().isoformat()}
        with open(STATE_FILE, "wb") as f:
            pickle.dump(state, f)
        _state_cache["last_hash"] = digest
        logging.info("State saved to %s", STATE_FILE)
    except (OSError, pickle.PickleError, TypeError, ValueError) as e:
        logging.error("Failed to save state: %s", e)


def load_state() -> bool:
    if not os.path.exists(STATE_FILE):
        logging.info("No state file found. Starting with default state.")
        return False
    try:
        with open(STATE_FILE, "rb") as f:
            state = pickle.load(f)

        users.update(state.get("users", {}))
        videos[:] = state.get("videos", [])
        jobs.update(state.get("jobs", {}))
        sessions.update(state.get("sessions", {}))

        logging.info("State loaded from %s", STATE_FILE)
        logging.info("  - Users: %d", len(users))
        logging.info("  - Videos: %d", len(videos))
        logging.info("  - Jobs: %d", len(jobs))
        logging.info("  - Sessions: %d", len(sessions))

        # Flag videos whose file is missing on disk (do not remove — that
        # is clean_missing_videos()'s job).
        from .config import UPLOAD_FOLDER
        for video in videos:
            fn = video.get("file_name")
            if not fn:
                continue
            path = os.path.join(UPLOAD_FOLDER, fn)
            video["file_missing"] = not os.path.exists(path)
            if video["file_missing"]:
                logging.warning("Video file missing: %s", path)

        return True
    except (FileNotFoundError, OSError, pickle.PickleError, EOFError,
            AttributeError, TypeError, ValueError) as e:
        logging.error("Failed to load state: %s", e)
        return False