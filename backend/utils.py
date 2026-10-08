"""Small helpers: tokens, session-id extraction, files, time."""

from __future__ import annotations

import datetime
import json
import logging
import os
import re
from urllib.parse import quote, urlsplit, urlunsplit

from flask import request

from .config import (
    SESSION_FOLDER,
    LANGUAGE_NAMES,
    _LANG_CODE_RE,
)
from .state import _state, sessions


# ─── Time helpers ──────────────────────────────────────────────────────
def utc_now_iso() -> str:
    """Return the current UTC time as an ISO-8601 string."""
    return (
        datetime.datetime.now(datetime.UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def file_mtime_iso(path: str) -> str:
    """Return the file modification time as an ISO-8601 UTC string."""
    return (
        datetime.datetime.fromtimestamp(
            os.path.getmtime(path), tz=datetime.timezone.utc
        )
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


# ─── Request helpers ───────────────────────────────────────────────────
def _public_base_url() -> str:
    fwd_host = request.headers.get("X-Forwarded-Host")
    if fwd_host:
        bare = fwd_host.split(":", 1)[0]
        proto = "http" if bare in ("localhost", "127.0.0.1") else "https"
        return f"{proto}://{fwd_host}".rstrip("/")
    return request.host_url.rstrip("/")


def thumbnail_absolute_url(video: dict) -> str | None:
    """Return an absolute URL for a local thumbnail, preserving other URLs."""
    thumb = video.get("thumbnail_url")
    if not thumb or not thumb.startswith("/thumbnails/"):
        return thumb
    filename = thumb[len("/thumbnails/") :]
    return f"{_public_base_url()}/thumbnails/{quote(filename, safe='')}"


def short_sid(session_id: str | None, keep: int = 8) -> str:
    """Return a compact, user-friendly preview of a session identifier."""
    if not session_id:
        return "<none>"
    return session_id[:keep] + "…"


# ─── Token helpers ─────────────────────────────────────────────────────
def email_from_token(token: str) -> str:
    """Extract the email address from a token containing user metadata."""
    if not token:
        return ""
    parts = token.split("|")
    if len(parts) >= 3:
        email = parts[-1].strip()
        if "@" in email:
            return email
    return ""


def log_token_email(token: str, where: str) -> None:
    """Log the email encoded in a token, without exposing the token itself."""
    if not token:
        logging.info("%s: token is empty", where)
        return
    parts = token.split("|")
    if len(parts) >= 3:
        logging.info(
            "%s: token email = %r (token length %d)",
            where,
            parts[-1].strip(),
            len(token),
        )
    else:
        logging.info("%s: token has %d fields, cannot extract email", where, len(parts))


def user_home_path(token: str) -> str:
    """Return the home directory encoded in a token."""
    if not token:
        raise ValueError("Cannot derive the upload path: no token was supplied.")
    parts = token.split("|")
    if len(parts) < 3:
        raise ValueError(
            f"Cannot derive the upload path: token has {len(parts)} "
            f"pipe-separated fields, need at least 3."
        )
    email = parts[-1].strip()
    if "@" not in email:
        raise ValueError(
            f"Cannot derive the upload path: last token field "
            f"{email!r} does not contain '@'."
        )
    return f"/home/{email}"


def effective_token(session_id: str, fallback: str = "") -> str:
    """Return the token that owns this session."""
    stored = (sessions.get(session_id) or {}).get("token")
    return stored or fallback or (_state.get("token") or "")


# ─── Session id extraction ─────────────────────────────────────────────
_SESSION_ID_PATTERNS = [
    re.compile(r"/archivesession/([A-Za-z0-9_\-=]+)"),
    re.compile(r"/session/([A-Za-z0-9_\-=]+)"),
    re.compile(r'content=["\'][^"\']*url=([^"\']+)["\']', re.IGNORECASE),
    re.compile(
        r"""
        (?:window\.location(?:\.href)?|location\.assign\(|location\.replace\()
        \s*[=("]\s*
        ["\']([^"\']+)["\']
        """,
        re.VERBOSE,
    ),
    re.compile(r'<form[^>]*action=["\']([^"\']+)["\']', re.IGNORECASE),
    re.compile(
        r'data-(?:session[-_]?id|session|id)=["\']([^"\']+)["\']',
        re.IGNORECASE,
    ),
    re.compile(r'["\']session(?:_?id)?["\']\s*:\s*["\']([^"\']+)["\']'),
]

_QS_PARAM_RE = re.compile(r'[?&](?:session(?:_?id)?|id)=([^&"\'\s<>]+)', re.IGNORECASE)


def session_id_from_any_url(url: str) -> str | None:
    """Extract a session identifier from a URL."""
    if not url:
        return None
    for marker in ("/archivesession/", "/session/"):
        if marker in url:
            sid = url.split(marker, 1)[-1].split("/")[0].split("?")[0].strip()
            if sid:
                return sid
    m = _QS_PARAM_RE.search(url)
    return m.group(1) if m else None


def extract_session_id(resp) -> str | None:
    """Extract a session identifier from a response URL, payload, or body."""
    sid = session_id_from_any_url(resp.url or "")
    if sid:
        return sid

    try:
        payload = resp.json()
    except (ValueError, TypeError):
        payload = None

    def _from_dict(d: dict) -> str | None:
        for key in (
            "session_id",
            "sessionId",
            "session",
            "id",
            "session_uuid",
            "sessionid",
            "session_name",
            "archive_session_id",
            "archiveSessionId",
        ):
            value = d.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        for key in ("session_url", "url", "link"):
            value = d.get(key)
            if isinstance(value, str):
                found = session_id_from_any_url(value)
                if found:
                    return found
        return None

    def _from_payload(value) -> str | None:
        if not isinstance(value, dict):
            return None
        sid = _from_dict(value)
        if sid:
            return sid
        nested = value.get("data")
        return _from_dict(nested) if isinstance(nested, dict) else None

    sid = _from_payload(payload)
    if sid:
        return sid

    body = resp.text or ""
    sid = session_id_from_any_url(body)
    if not sid:
        for pattern in _SESSION_ID_PATTERNS:
            match = pattern.search(body)
            if not match:
                continue
            candidate = match.group(1).strip()
            sid = session_id_from_any_url(candidate)
            if not sid and candidate and len(candidate) <= 200 and " " not in candidate:
                sid = candidate
            if sid:
                break

    if not sid:
        match = re.search(
            r"<script[^>]*>\s*(?:var|const|let)\s+\w+\s*=\s*({[^<]+})",
            body,
        )
        if match:
            try:
                blob = json.loads(match.group(1))
                sid = _from_payload(blob)
            except (json.JSONDecodeError, TypeError):
                pass

    if not sid:
        logging.warning(
            "extract_session_id: no match. status=%s final_url=%s "
            "content_type=%r body_len=%d",
            resp.status_code,
            resp.url,
            resp.headers.get("Content-Type", "<none>"),
            len(body),
        )
    return sid


# ─── On-disk path naming ───────────────────────────────────────────────
def safe_local_name(name: str) -> str:
    """Return a filesystem-safe name derived from the provided name."""
    if not name:
        return ""
    safe = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name)
    safe = re.sub(r"\s+", " ", safe).strip(". ")
    if len(safe) > 150:
        safe = safe[:150].rstrip(". ")
    return safe


def unique_local_name(name: str) -> str:
    """Return a filesystem-safe name that does not collide with existing sessions."""
    base = safe_local_name(name) or "session"
    taken = {s.get("local_name") for s in sessions.values() if s.get("local_name")}
    if base not in taken:
        return base
    counter = 2
    while f"{base}_{counter}" in taken:
        counter += 1
    return f"{base}_{counter}"


def session_dir(session_id: str) -> str:
    """Return the directory for a session, using its local name when available."""
    sess = sessions.get(session_id) or {}
    local_name = sess.get("local_name")
    if local_name:
        return os.path.join(SESSION_FOLDER, local_name)
    return os.path.join(SESSION_FOLDER, session_id)


# ─── Lazy field initialisers ───────────────────────────────────────────
def ensure_greenscreen_fields(project: dict) -> dict:
    """Ensure a project has the default greenscreen fields when missing."""
    project.setdefault("greenscreen_file_name", None)
    project.setdefault("greenscreen_status", "pending")
    project.setdefault("greenscreen_progress", 0)
    return project


def ensure_source_field(project: dict) -> dict:
    """Ensure a project has a source value when one is missing."""
    if not project.get("source"):
        fname = (project.get("file_name") or "").lower()
        if "youtube" in fname:
            project["source"] = "Imported (YouTube)"
        else:
            project["source"] = "Desktop Upload"
    return project


def ensure_codec_field(project: dict) -> dict:
    """Ensure a project has an empty codec value when one is missing."""
    project.setdefault("codec", "")
    return project


def ensure_job_history(project: dict) -> dict:
    """Ensure a project has an empty job history list."""
    project.setdefault("job_history", [])
    return project


# ─── Language helpers ──────────────────────────────────────────────────
def extract_simple_language_name(language: str) -> str:
    """Extract a readable language name from a provider-specific label."""
    if not language:
        return "Unknown"

    match = re.search(r"\(([^)]+)\)", language)
    if match:
        candidate = match.group(1).strip()
        if candidate.lower().startswith("language "):
            candidate = candidate.split(" ", 1)[1].strip()
        name = LANGUAGE_NAMES.get(candidate.lower())
        if name:
            return name

    clean = language
    stripped = False
    for prefix in (
        "Translation (Language ",
        "Transcript (Original ASR - ",
        "Transcript (Structured - ",
        "Transcript (",
    ):
        if prefix in clean:
            clean = clean.replace(prefix, "")
            stripped = True
    clean = clean.rstrip(")").strip() if stripped else clean.strip()

    if _LANG_CODE_RE.match(clean):
        return LANGUAGE_NAMES.get(clean.lower(), clean)
    if clean.lower().startswith("language "):
        clean = clean.split(" ", 1)[1].strip()
        if _LANG_CODE_RE.match(clean):
            return LANGUAGE_NAMES.get(clean.lower(), clean)
    return clean or "Unknown"


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


def get_language_code(language_name: str) -> str | None:
    """Return the ISO language code represented by a language name or label."""
    if not language_name:
        return None

    name_to_code = {name.lower(): code for code, name in LANGUAGE_NAMES.items()}
    raw = language_name.strip()
    candidates = [raw]

    match = re.search(r"\(([^)]+)\)", raw)
    if match:
        candidate = match.group(1).strip()
        if candidate.lower().startswith("language "):
            candidate = candidate.split(" ", 1)[1].strip()
        candidates.append(candidate)

    code_match = re.search(r"[\s:\-_]([a-z]{2})\b", raw, re.IGNORECASE)
    if code_match:
        candidates.append(code_match.group(1).lower())

    for candidate in candidates:
        normalized = candidate.lower()
        if _LANG_CODE_RE.match(candidate):
            return normalized
        if normalized in name_to_code:
            return name_to_code[normalized]

    lower_raw = raw.lower()
    for name, code in name_to_code.items():
        if name in lower_raw:
            return code

    return None


def get_language_code_iso3(language_name: str) -> str | None:
    """Convert a language name to its ISO 3 language code."""
    iso2 = get_language_code(language_name)
    return _ISO2_TO_ISO3.get(iso2) if iso2 else None


def safe_float(value, default: float = 0.0) -> float:
    """Convert a value to float, returning the fallback for invalid input."""
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


def format_vtt_timestamp(seconds: float) -> str:
    """Format a seconds value as a WebVTT timestamp."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds % 1) * 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def is_meaningful_file(path: str) -> bool:
    """Return whether a path points to a sufficiently large supported file."""
    name = os.path.basename(path).lower()
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    if name.endswith((".vtt", ".txt", ".json")):
        return size > 20
    return size > 1000


def looks_like_wav(path: str) -> bool:
    """Return whether a path points to a WAV file."""
    try:
        with open(path, "rb") as f:
            header = f.read(12)
    except OSError:
        return False
    return len(header) >= 12 and header[0:4] == b"RIFF" and header[8:12] == b"WAVE"


def sanitize_session_name_for_kit(name: str) -> str:
    """Normalize a session name for use in the kit."""
    if not name:
        return name
    for src, dst in {
        "\u2022": "-",
        "\u2013": "-", 
        "\u2014": "-",
        "\u2018": "'",
        "\u2019": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u00a0": " ",
    }.items():
        name = name.replace(src, dst)
    return re.sub(r"\s+", " ", name).strip()


def norm_session_name(s: str) -> str:
    """Normalize typographic characters and whitespace in a session name."""
    for src, dst in {
        "\u2018": "'",
        "\u2019": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u2013": "-",
        "\u2014": "-",
        "\u2022": "-",
        "\u00a0": " ",
    }.items():
        s = s.replace(src, dst)
    return re.sub(r"\s+", " ", s).strip()


def curl_safe_url(url: str) -> str:
    """Return a URL whose path and query are safe for curl."""
    parts = urlsplit(url)
    path = quote(parts.path, safe="/%=")
    query = quote(parts.query, safe="=&%")
    return urlunsplit((parts.scheme, parts.netloc, path, query, parts.fragment))
