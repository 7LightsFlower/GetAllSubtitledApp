"""Small helpers: HTML parsing, KIT cookies, session ids, names, paths.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import datetime
import json
import logging
import os
import re
from urllib.parse import quote
import requests
from flask import request

from .flask_app import BeautifulSoup, has_bs4
from .servers import INTERNAL_SERVER_URL
from .config import SESSION_FOLDER, _state, internal_session, sessions


def parse_html_with_bs4(html_content):
    """Parse HTML content using BeautifulSoup if available."""
    if has_bs4 and html_content:
        try:
            soup = BeautifulSoup(html_content, "html.parser")
            return soup
        except (TypeError, ValueError) as e:
            logging.warning("Failed to parse HTML with BeautifulSoup: %s", e)
    return None


# Dex session cookie for the internal server. When set, TTS and other
# media fetches send this cookie instead of the bearer token — which is
# what a browser does when it plays audio from the archive page. The
# bearer token continues to be used for /upload_lecture and
# /archive_messages/, where it is required.
#
# Extract the cookie from a signed-in browser:
#   DevTools → Application → Cookies → https://lt2srv.iar.kit.edu
#   copy the value of `_forward_auth`.
#
# When empty, the backend falls back to the bearer token in the cookie
# slot, which is what the rest of the code already does.
_kit_session_cookie: str = os.environ.get("KIT_SESSION_COOKIE", "").strip()


def _media_cookie(token: str) -> str:
    """Return the cookie value to use for a media fetch.

    Prefers the Dex session cookie when one is configured; otherwise
    falls back to the bearer token, matching legacy behaviour.
    """
    return _kit_session_cookie or token


def _media_cookie_is_dex() -> bool:
    """True when the configured media cookie is a Dex session cookie."""
    return bool(_kit_session_cookie)


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


def file_mtime_iso(path: str) -> str:
    """File mtime as an ISO 8601 string with a 'Z' suffix (UTC).

    Explicitly tagged as UTC so the client can convert to the
    browser's local timezone for display. Without the suffix,
    `DateTime.parse` in Dart treats the value as local time and the
    displayed time is off by the viewer's offset from UTC.
    """
    return (
        datetime.datetime.fromtimestamp(
            os.path.getmtime(path), tz=datetime.timezone.utc
        )
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


_SESSION_ID_PATTERNS = [
    # <a href="/archivesession/XYZ">…</a>   (and /session/)
    re.compile(r"/archivesession/([A-Za-z0-9_\-=]+)"),
    re.compile(r"/session/([A-Za-z0-9_\-=]+)"),
    # <meta http-equiv="refresh" content="0; url=/archivesession/XYZ">
    re.compile(r'content=["\'][^"\']*url=([^"\']+)["\']', re.IGNORECASE),
    # window.location = "/archivesession/XYZ"  (or .href = …)
    re.compile(
        r"""
        (?:window\.location(?:\.href)?|location\.assign\(|location\.replace\()
        \s*[=("]\s*
        ["\']([^"\']+)["\']
        """,
        re.VERBOSE,
    ),
    # <form action="/something">  → we'll resolve this to a session id later
    re.compile(r'<form[^>]*action=["\']([^"\']+)["\']', re.IGNORECASE),
    # data-session-id="XYZ", data-session="XYZ", data-id="XYZ"
    re.compile(
        r'data-(?:session[-_]?id|session|id)=["\']([^"\']+)["\']',
        re.IGNORECASE,
    ),
    # Bare "session_id":"XYZ" inside <script>…</script>
    re.compile(r'["\']session(?:_?id)?["\']\s*:\s*["\']([^"\']+)["\']'),
]

# Query-string form:  /archivesession?id=XYZ  or  ?session=XYZ
_QS_PARAM_RE = re.compile(r'[?&](?:session(?:_?id)?|id)=([^&"\'\s<>]+)', re.IGNORECASE)


def _session_id_from_any_url(url: str) -> str | None:
    """Pull a session id out of any URL, path or query string."""
    if not url:
        return None
    for marker in ("/archivesession/", "/session/"):
        if marker in url:
            sid = url.split(marker, 1)[-1].split("/")[0].split("?")[0].strip()
            if sid:
                return sid
    m = _QS_PARAM_RE.search(url)
    if m:
        return m.group(1)
    return None


def _extract_session_id(resp: requests.Response) -> str | None:
    """Find the session id the internal server assigned to an upload.

    Tries, in order:
      1. the final redirect URL,
      2. JSON body fields (top level, then under "data"),
      3. any URL or link in the JSON that contains /archivesession/,
      4. several HTML patterns (see _SESSION_ID_PATTERNS),
      5. a session id in a <script>…</script> JSON blob.
    """
    # 1. Redirect URL
    sid = _session_id_from_any_url(resp.url or "")
    if sid:
        return sid

    # 2./3. JSON body
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
            v = d.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
        for key in ("session_url", "url", "link"):
            v = d.get(key)
            if isinstance(v, str):
                found = _session_id_from_any_url(v)
                if found:
                    return found
        return None

    if isinstance(payload, dict):
        sid = _from_dict(payload)
        if sid:
            return sid
        nested = payload.get("data")
        if isinstance(nested, dict):
            sid = _from_dict(nested)
            if sid:
                return sid

    # 4. HTML body patterns
    body = resp.text or ""
    for pattern in _SESSION_ID_PATTERNS:
        m = pattern.search(body)
        if not m:
            continue
        candidate = m.group(1).strip()
        # The pattern might have captured a URL rather than a bare id.
        resolved = _session_id_from_any_url(candidate)
        if resolved:
            return resolved
        # Or it might already be a bare id (data-attr / JS-object cases).
        # Reject obviously non-id-looking matches (paths, long strings).
        if candidate and len(candidate) <= 200 and " " not in candidate:
            return candidate

    # ── 5. Inline <script> JSON blob ─────────────────────────────
    # KIT sometimes embeds the session as a JS object literal rather
    # than as a data-attribute or a plain <a href>. Look for the
    # first `<script>` that assigns a JSON object to a variable and
    # try to pull a session id out of it.
    m = re.search(
        r"<script[^>]*>\s*(?:var|const|let)\s+\w+\s*=\s*({[^<]+})",
        body,
    )
    if m:
        try:
            blob = json.loads(m.group(1))
            sid = _from_dict(blob)
            if sid:
                return sid
            # Some KIT pages nest the session one level deeper.
            nested = blob.get("data") if isinstance(blob, dict) else None
            if isinstance(nested, dict):
                sid = _from_dict(nested)
                if sid:
                    return sid
        except (json.JSONDecodeError, TypeError):
            pass

    sid = _session_id_from_any_url(body)
    if sid:
        logging.info("_extract_session_id: matched bare URL in body")
        return sid

    logging.warning(
        "_extract_session_id: no match. status=%s final_url=%s "
        "content_type=%r body_len=%d",
        resp.status_code,
        resp.url,
        resp.headers.get("Content-Type", "<none>"),
        len(body),
    )
    return None


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
    filename = thumb[len("/thumbnails/") :]
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


def _log_token_email(token: str, where: str) -> None:
    """Log the email field of a bearer token, for forensics only.

    Never rewrites the token. Never caches the result. Purely a
    diagnostic so the backend log shows, at upload time, exactly
    which spelling KIT will see.
    """
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
        logging.info(
            "%s: token has %d fields, cannot extract email",
            where,
            len(parts),
        )


def _email_from_token(token: str) -> str:
    """Extract the email from a KIT bearer token of the form
    ``<opaque>|<expiry>|<email>``.

    Returns an empty string when the token is missing or malformed,
    so the caller can store whatever it has without special-casing.
    """
    if not token:
        return ""
    parts = token.split("|")
    if len(parts) >= 3:
        email = parts[-1].strip()
        if "@" in email:
            return email
    return ""

# ─── Subfolder inside the user's KIT home where every session lives ────
# Every session uploaded through this backend is placed under
# /home/<email>/GetAllSubtitledApp/<session_name>. Set the env var to
# "" to fall back to /home/<email> (the old behaviour).
KIT_SUBFOLDER = os.environ.get("KIT_SUBFOLDER", "GetAllSubtitledApp").strip().strip("/")

def _user_home_path(token: str) -> str:
    """Build the LTKIT upload path from the authenticated user.

    Returns ``/home/<email>`` or ``/home/<email>/<KIT_SUBFOLDER>``.
    The email is copied verbatim out of the bearer token — no domain
    normalisation, no case-folding, no trimming beyond outer whitespace.
    """
    if not token:
        raise ValueError("Cannot derive the upload path: no token was supplied.")

    parts = token.split("|")
    if len(parts) < 3:
        raise ValueError(
            f"Cannot derive the upload path: token has {len(parts)} "
            f"pipe-separated fields, need at least 3 "
            f"('<opaque>|<expiry>|<email>')."
        )

    email = parts[-1].strip()
    if "@" not in email:
        raise ValueError(
            f"Cannot derive the upload path: last token field "
            f"{email!r} does not contain '@'."
        )

    base = f"/home/{email}"
    if KIT_SUBFOLDER:
        return f"{base}/{KIT_SUBFOLDER}"
    return base


def _safe_local_name(name: str) -> str:
    """Turn a session name into a filesystem-safe folder name.

    Handles the characters that are illegal on Windows or awkward on
    POSIX (``/ \\ : * ? " < > |``), strips trailing dots/spaces, and
    caps the length so we stay well clear of PATH_MAX.
    """
    if not name:
        return ""
    safe = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name)
    safe = re.sub(r"\s+", " ", safe).strip(". ")
    if len(safe) > 150:
        safe = safe[:150].rstrip(". ")
    return safe


def _unique_local_name(name: str) -> str:
    """Pick a filesystem-safe folder name for a new session.

    If two sessions would otherwise share a name (the same lecture
    uploaded twice, say), the second one gets a ``_2`` suffix.
    """
    base = _safe_local_name(name) or "session"
    taken = {s.get("local_name") for s in sessions.values() if s.get("local_name")}
    if base not in taken:
        return base
    counter = 2
    while f"{base}_{counter}" in taken:
        counter += 1
    return f"{base}_{counter}"


def _session_dir(session_id: str) -> str:
    """On-disk directory holding a session's downloaded files.

    Prefers the human-readable ``local_name`` recorded on the session
    dict; falls back to the raw session id for sessions saved before
    ``local_name`` existed (i.e. any pre-existing state file).
    """
    sess = sessions.get(session_id) or {}
    local_name = sess.get("local_name")
    if local_name:
        return os.path.join(SESSION_FOLDER, local_name)
    return os.path.join(SESSION_FOLDER, session_id)


def _effective_token(session_id: str, fallback: str = "") -> str:
    """Return the token that owns this session.

    KIT sessions are user-scoped: only the bearer that created a
    session can read it back. We record that token on the session
    record at upload time and reuse it for every subsequent KIT
    call, regardless of which user is currently logged in to the
    web UI.
    """
    stored = (sessions.get(session_id) or {}).get("token")
    return stored or fallback or (_state.get("token") or "")


def _ensure_greenscreen_fields(project: dict) -> dict:
    """Make sure every project carries the green-screen bookkeeping fields.

    Old state files predate these fields; rather than migrating the
    pickle, we add them lazily on read. Idempotent.
    """
    project.setdefault("greenscreen_file_name", None)
    project.setdefault("greenscreen_status", "pending")
    project.setdefault("greenscreen_progress", 0)
    return project


def _ensure_source_field(project: dict) -> dict:
    """Make sure every project carries a `source` string.

    Old state files predate this field. We seed a sensible default
    instead of re-probing, because /videos must stay fast and the
    user can always edit the value from the card. Idempotent.
    """
    if not project.get("source"):
        fname = (project.get("file_name") or "").lower()
        if "youtube" in fname:
            project["source"] = "Imported (YouTube)"
        else:
            project["source"] = "Desktop Upload"
    return project


def _ensure_codec_field(project: dict) -> dict:
    """Make sure every project carries a `codec` string.

    Old state files predate this field. We do NOT re-probe here —
    that would stall /videos for every project whose codec is
    missing. An empty string means "unknown", and the UI handles
    that case explicitly. Idempotent.
    """
    project.setdefault("codec", "")
    return project


def _ensure_job_history(project: dict) -> dict:
    """Make sure every project carries a `job_history` list.

    Old state files predate this field; add lazily on read. The list
    is stored newest-first and capped client- and server-side at
    MAX_JOB_HISTORY_ENTRIES. Idempotent.
    """
    project.setdefault("job_history", [])
    return project


# Cap on how many job-history entries we keep per video. Matches the
# client-side cap so the two never drift.
MAX_JOB_HISTORY_ENTRIES = 20
