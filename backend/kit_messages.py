"""KIT archive messages: language codes, completeness checks, paging.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import json
import logging
import os
import re
import threading
import time
import requests

from .servers import INTERNAL_SERVER_URL
from .config import LANGUAGE_NAMES, _LANG_CODE_RE, sessions, videos
from .utils import _short_sid
from .progress import _clear_404, _note_404


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


def _remote_size(url: str, token: str, timeout: int = 30) -> tuple[int, int]:
    """Return (size, status_code). size=0 on error.

    KIT's server does not reliably implement HEAD on /archivemediafile
    (it 500s or times out), so we send a one-byte ranged GET and read
    Content-Range instead. Content-Range looks like
        bytes 0-0/12345
    and the number after the slash is the total size.
    """
    headers = _internal_headers(token)
    headers["Range"] = "bytes=0-0"

    for attempt in range(1, 3):
        try:
            r = requests.get(
                url,
                headers=headers,
                cookies=_internal_cookies(token),
                verify=False,
                timeout=(10, timeout),
                allow_redirects=True,
                stream=True,  # never download the body
            )
            status = r.status_code

            # Preferred: Content-Range header on a 206 response.
            cr = r.headers.get("Content-Range")
            if cr and "/" in cr:
                total = cr.rsplit("/", 1)[-1].strip()
                if total.isdigit():
                    return int(total), status

            # Fallback: Content-Length on a normal 200.
            cl = r.headers.get("Content-Length")
            if cl:
                try:
                    return int(cl), status
                except ValueError:
                    pass

            return 0, status

        except requests.exceptions.ReadTimeout as e:
            if attempt == 1:
                logging.info(
                    "ranged GET read timeout for %s (attempt %d/2), retrying",
                    url,
                    attempt,
                )
                time.sleep(1)
                continue
            logging.warning(
                "ranged GET read timeout for %s after %d attempts: %s",
                url,
                attempt,
                e,
            )
            return 0, 0
        except requests.exceptions.RequestException as e:
            logging.warning("ranged GET failed for %s: %s", url, e)
            return 0, 0

    return 0, 0


# ─── SESSION COMPLETENESS GATES ─────────────────────────────────────────
MIN_MESSAGES_BYTES = 5_000  # bytes; used in _messages_look_done
MIN_MESSAGES_COUNT = 1  # messages; used in wait_for_session_ready
_STABLE_NEEDED = 3

# How many bytes of growth in one poll still count as "quiet". Below
# this, we treat the file as not having moved. Above it, the quiet
# timer resets. 2 KB is small enough to catch the trickle of a
# finishing session, large enough to ignore buffered-flush noise.
_STABLE_GROWTH_BYTES = 2_000

# How long the file has to stay quiet before we trust it and run the
# content check. 30 s is generous enough for a slow KIT server to
# flush the last segment.
_STABLE_QUIET_SECONDS = 30.0


def _fetch_messages_json_size(session_id, token, server_url=None):
    """Cheap HEAD-style size probe against the internal messages.json.

    Returns (size, status_code). size=0 on error.
    """
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")
    url = f"{server_url}/archivemediafile/{session_id}/messages.json"

    size, status = _remote_size(url, token)

    if status == 404:
        _note_404(session_id, url)
    elif status == 200:
        _clear_404(session_id)

    return size, status


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
            _clear_404(session_id)
            return r.content
        if r.status_code == 404:
            # Route through the shared counter so a wrong id doesn't
            # re-log here after the size probe already complained.
            _note_404(session_id, url)
        else:
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

        1. ASR content present (>=5 messages, some with an `end` time).
        2. At least one MT track if the caller asked for any.
        3. Every existing MT track ends close to the ASR end.

      That catches the "translation stops at minute 3 of a 45-minute
      video" problem without relying on a mapping we don't have.
    """
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
    mt_tracks: dict[str, float] = {}  # sender -> max end seen for that track

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
        if log:
            logging.info(
                "messages.json stable but MT tracks still short: %s",
                "; ".join(incomplete),
            )
        return False

    if mt_tracks and log:
        logging.info(
            "messages.json: %d MT track(s), all covering up to %.0fs",
            len(mt_tracks),
            asr_max_end,
        )
    return True


def _mt_track_status(raw: bytes) -> tuple[float, dict]:
    """(asr_end, {mt sender: end}) from a full messages dump."""
    asr_end = 0.0
    tracks: dict = {}
    try:
        data = json.loads(raw) if raw else []
    except (json.JSONDecodeError, TypeError, ValueError):
        return asr_end, tracks
    for item in data if isinstance(data, list) else []:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict) or not str(m.get("seq", "")).strip():
            continue
        try:
            end = float(m.get("end", 0) or 0)
        except (ValueError, TypeError):
            end = 0.0
        sender = str(m.get("sender", ""))
        if sender.startswith("asr:"):
            asr_end = max(asr_end, end)
        elif sender.startswith("mt:") or sender.startswith("translation:"):
            if end > tracks.get(sender, 0.0):
                tracks[sender] = end
    return asr_end, tracks


def _mt_summary(asr_end: float, tracks: dict) -> tuple[str, float, list]:
    """Human summary, average coverage (0..1) and the unfinished tracks."""
    if not tracks or asr_end <= 0:
        return "", 0.0, []
    unfinished = sorted(
        (t for t, e in tracks.items() if not _coverage_is_ok(e, asr_end)),
        key=lambda t: tracks[t],
    )
    done = len(tracks) - len(unfinished)
    avg = sum(min(e / asr_end, 1.0) for e in tracks.values()) / len(tracks)
    text = f"Translations: {done} of {len(tracks)} languages complete"
    if unfinished:
        slow = unfinished[0]
        text += (
            f" — slowest {slow} at {tracks[slow]:.0f}s of {asr_end:.0f}s"
        )
    return text, avg, unfinished


# No new message from KIT for this long while some translations are still
# short → stop waiting and download what is there (env-configurable).
_MT_STALL_SECONDS = float(os.environ.get("MT_STALL_SECONDS", "900"))


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


def _fetch_archive_messages_page(session_id, token, server_url, page, limit=1000):
    """Fetch one page from KIT's live transcript endpoint.

    IMPORTANT: `page` is 1-based. `page=0` returns `data: []` even
    though `total` is non-zero. Always start at page=1.
    """
    if not server_url:
        server_url = INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")

    url = f"{server_url}/archive_messages/{session_id}"
    try:
        r = requests.get(
            url,
            params={"page": page, "limit": limit},
            headers=_internal_headers(token),
            cookies=_internal_cookies(token),
            verify=False,
            timeout=60,
            allow_redirects=True,
        )
        if r.status_code != 200:
            logging.info(
                "_fetch_archive_messages_page: %s page=%d -> HTTP %s",
                url,
                page,
                r.status_code,
            )
            return None
        return r.json()
    except (
        requests.exceptions.RequestException,
        json.JSONDecodeError,
        ValueError,
    ) as e:
        logging.warning(
            "_fetch_archive_messages_page: page=%d failed: %s",
            page,
            e,
        )
        return None


# Last total reported per session, so the "reports total=N" line is
# printed only when the count actually changes. Keyed by session id.
_last_reported_total: dict[str, int] = {}
_last_reported_total_lock = threading.Lock()


def _fetch_all_archive_messages(
    session_id, token, server_url, limit=1000, max_pages=50
):
    """Page through /archive_messages/<sid> and return the concatenated list.

    The return value has the same shape as `messages.json`: a list of
    `[lang_id, "<message_json>"]` pairs. It is a drop-in replacement
    for the data that `extract_transcripts_from_messages` reads.
    """
    all_messages = []
    page = 1  # 1-based!
    total = None
    while page <= max_pages:
        payload = _fetch_archive_messages_page(
            session_id,
            token,
            server_url,
            page,
            limit,
        )
        if payload is None:
            break
        if total is None:
            try:
                total = int(payload.get("total", 0))
            except (TypeError, ValueError):
                total = 0

        with _last_reported_total_lock:
            previous = _last_reported_total.get(session_id)
            if previous != total:
                _last_reported_total[session_id] = total
                should_log = True
            else:
                should_log = False
        if should_log:
            logging.info(
                "archive_messages: session %s reports total=%d",
                _short_sid(session_id),
                total,
            )
        chunk = payload.get("data") or []
        all_messages.extend(chunk)
        if not chunk or len(chunk) < limit:
            break
        if total is not None and page * limit >= total:
            break
        page += 1
    return all_messages


def _fetch_latest_archive_page(session_id, token, server_url, limit=1000):
    """Fetch only the highest-numbered page of /archive_messages/.

    Uses the `total` from page 1 to compute which page is last, then
    fetches that one. Returns the list of messages on that page.
    """
    probe = _fetch_archive_messages_page(
        session_id,
        token,
        server_url,
        page=1,
        limit=1,
    )
    if probe is None:
        return []
    try:
        total = int(probe.get("total", 0))
    except (TypeError, ValueError):
        total = 0
    if total <= 0:
        return []
    last_page = max(1, (total + limit - 1) // limit)
    payload = _fetch_archive_messages_page(
        session_id,
        token,
        server_url,
        page=last_page,
        limit=limit,
    )
    if payload is None:
        return []
    return payload.get("data") or []


# How often to re-fetch messages.json purely to refresh the progress
# bar. The stability check already fetches it occasionally; this adds
# a periodic tick so the bar moves even while the file is growing.
_PROGRESS_FETCH_INTERVAL = 30.0  # was 30.0

# If neither the file size nor the ASR/MT second counts have moved for
# this long, emit one short heartbeat line so the panel doesn't look
# frozen. Rare enough that it doesn't spam.
_PROGRESS_HEARTBEAT_SECONDS = 180.0
