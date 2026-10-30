"""Paths, in-memory stores, language names.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import json
import logging
import os
import re
import requests

from .paths import DATA_DIR
from .servers import INTERNAL_SERVER_URL


# ─── UPLOAD MODES ─────────────────────────────────────────
# When True, upload a tiny solid-colour video that carries the audio
# instead of the full video. The KIT server only processes the audio
# track, so this is a 100× reduction in upload size.
# Set env USE_GREEN_SCREEN_UPLOAD=0 to fall back to uploading the
# original video through the same multipart code path.
USE_GREEN_SCREEN_UPLOAD = os.environ.get("USE_GREEN_SCREEN_UPLOAD", "1") == "1"

# Some internal proxies reject chunked multipart uploads. Keep this
# configurable so callers can toggle Transfer-Encoding: chunked when
# needed without hitting a NameError during request handling.
USE_CHUNKED_UPLOAD = os.environ.get("USE_CHUNKED_UPLOAD", "0") == "1"


TARGET_URL = f"{INTERNAL_SERVER_URL}/upload_lecture"
BASE_URL = INTERNAL_SERVER_URL
UPLOAD_FOLDER = os.path.join(DATA_DIR, "uploads")
SESSION_FOLDER = os.path.join(DATA_DIR, "sessions")
STATE_FILE = os.path.join(DATA_DIR, "state", "server_state.pkl")
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(SESSION_FOLDER, exist_ok=True)
os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)

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
