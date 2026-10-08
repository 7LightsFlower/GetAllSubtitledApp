"""Constants, paths, server allow-lists, tuning knobs."""

from __future__ import annotations

import json
import logging
import os
import re

# ─── Paths ─────────────────────────────────────────────────────────────
_BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.dirname(_BACKEND_DIR)

UPLOAD_FOLDER = os.path.join(_BACKEND_DIR, "uploads")
SESSION_FOLDER = os.path.join(_BACKEND_DIR, "sessions")
STATE_FILE = os.path.join(_BACKEND_DIR, "state", "server_state.pkl")
_LANGUAGES_JSON = os.path.normpath(
    os.path.join(_PROJECT_ROOT, "assets", "languages.json")
)

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(SESSION_FOLDER, exist_ok=True)
os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)

# ─── Internal servers ──────────────────────────────────────────────────
INTERNAL_SERVER_URL = "https://lt2srv.iar.kit.edu"
TARGET_URL = f"{INTERNAL_SERVER_URL}/upload_lecture"
BASE_URL = INTERNAL_SERVER_URL

_ALLOWED_SERVER_RE = re.compile(
    r"^https://(?:"
    r"lt2srv\.iar\.kit\.edu"
    r"|lt2srv-[a-z0-9]+(?:-[a-z0-9]+)*\.iar\.kit\.edu"
    r"|lt2srv-[a-z0-9]+(?:-[a-z0-9]+)*\.isl\.iar\.kit\.edu"
    r")$"
)

_KNOWN_SERVERS = {
    "https://lt2srv.iar.kit.edu",
    "https://lt2srv-backup.iar.kit.edu",
    "https://lt2srv-sscherrer.isl.iar.kit.edu",
}

_SERVER_LABELS = {
    "https://lt2srv.iar.kit.edu": "KIT Lecture Translator",
    "https://lt2srv-backup.iar.kit.edu": "Backup Server",
    "https://lt2srv-sscherrer.isl.iar.kit.edu": "Developer's Own (SScherrer)",
}

ALLOWED_TARGET_SERVERS = frozenset(_KNOWN_SERVERS)


def is_allowed_server(url: str | None) -> bool:
    """Return whether a URL is an allowed target server."""
    if not url:
        return False
    candidate = url.rstrip("/")
    return candidate in ALLOWED_TARGET_SERVERS or bool(
        _ALLOWED_SERVER_RE.match(candidate)
    )


def resolve_target_url(requested: str | None) -> str:
    """Resolve a requested server URL to its lecture upload endpoint."""
    if requested:
        candidate = requested.rstrip("/")
        if is_allowed_server(candidate):
            return f"{candidate}/upload_lecture"
        logging.warning("Rejected unknown target server: %r", requested)
    return f"{INTERNAL_SERVER_URL}/upload_lecture"


def server_label(url: str) -> str:
    """Return a display label for a configured target server."""
    return _SERVER_LABELS.get(url, url)


# ─── Upload modes ──────────────────────────────────────────────────────
USE_GREEN_SCREEN_UPLOAD = os.environ.get("USE_GREEN_SCREEN_UPLOAD", "1") == "1"
USE_CHUNKED_UPLOAD = os.environ.get("USE_CHUNKED_UPLOAD", "0") == "1"

# ─── Optional KIT session cookie (media fetches) ───────────────────────
_KIT_SESSION_COOKIE = os.environ.get("KIT_SESSION_COOKIE", "").strip()


def media_cookie(token: str) -> str:
    """Return the configured KIT session cookie or the provided token."""
    return _KIT_SESSION_COOKIE or token


def media_cookie_is_dex() -> bool:
    """Return whether a configured KIT session cookie is available."""
    return bool(_KIT_SESSION_COOKIE)


# ─── App limits & CORS ─────────────────────────────────────────────────
MAX_CONTENT_LENGTH = 1024 * 1024 * 1024

CORS_ORIGINS = [
    "http://localhost:8080",
    "http://127.0.0.1:8080",
    "http://localhost:5000",
    "http://127.0.0.1:5000",
    "https://get-all-subtitled.isl.iar.kit.edu",
]

CORS_METHODS = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
CORS_ALLOW_HEADERS = [
    "Content-Type",
    "Authorization",
    "X-Forwarded-User",
    "Accept",
    "Cache-Control",
    "Pragma",
    "Expires",
    "Range",
]
CORS_EXPOSE_HEADERS = ["Location", "Content-Disposition"]

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# ─── Tuning constants ──────────────────────────────────────────────────
MIN_WAV_BYTES = 50_000
MIN_MESSAGES_BYTES = 5_000
MIN_MESSAGES_COUNT = 1
STABLE_NEEDED = 3
STABLE_GROWTH_BYTES = 2_000
STABLE_QUIET_SECONDS = 30.0
PROGRESS_FETCH_INTERVAL = 30.0
PROGRESS_HEARTBEAT_SECONDS = 180.0
MT_COVERAGE_MIN_FRACTION = 0.95
MT_COVERAGE_SLACK_SECONDS = 20.0
PROGRESS_TTL = 3600
JOB_TTL = 7200
MAX_JOB_HISTORY_ENTRIES = 20


# ─── Language names ────────────────────────────────────────────────────
def _load_language_names() -> dict:
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


LANGUAGE_NAMES: dict[str, str] = _load_language_names()

_LANG_CODE_RE = re.compile(r"^([a-z]{2})$", re.IGNORECASE)


def full_language_name(code_or_name: str) -> str:
    """Return the display name for a language code or configured name."""
    if not code_or_name:
        return code_or_name or ""
    key = code_or_name.strip().lower()
    return LANGUAGE_NAMES.get(key, code_or_name.strip())
