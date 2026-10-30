"""Downloading TTS tracks (WAV) from the KIT archive.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import html as _html_mod
import json
import logging
import os
import re
import time
import urllib

from .servers import INTERNAL_SERVER_URL
from .utils import _effective_token, _session_dir, _short_sid
from .progress import _job_add_file, _job_log
from .downloads import curl_download


# Minimum plausible size for a real KIT TTS WAV. The HTML error page
# KIT returns for a TTS track that is not yet available (or that we
# are not authorized to fetch) is ~1.3 KB and starts with "<!DOCTYPE".
# A real TTS WAV is tens of MB. 50 KB sits comfortably between.
# _MIN_WAV_BYTES and _looks_like_wav are defined near the TTS
# download helpers, above — they are used by /session-tts and
# _session_files_look_incomplete too.
_MIN_WAV_BYTES = 50_000


def _looks_like_wav(path: str) -> bool:
    """True iff the file starts with the RIFF/WAVE magic bytes.

    KIT returns a 200 with an HTML status page when a TTS track is
    not (yet) available. The page is ~1.3 KB and starts with
    '<!DOCTYPE html>'. Saving that as a .wav poisons the session:
    the browser then fails to decode it and audioplayers raises
    WebAudioError Code 4. This check is the gate that stops it.
    """
    try:
        with open(path, "rb") as f:
            header = f.read(12)
    except OSError:
        return False
    if len(header) < 12:
        return False
    return header[0:4] == b"RIFF" and header[8:12] == b"WAVE"


def _tts_urls_from_html(
    _session_id: str, session_dir: str, server_url: str
) -> dict[str, str]:
    """Parse index.html for TTS <source> URLs.

    Returns {label: absolute_url}, where label is the dropdown label
    ("Korean Audio") and absolute_url is the fully-qualified KIT URL
    that the archive page itself would play.

    KIT's own archive page builds the audio-source <select> from these
    tags, so whatever it emits is — by definition — the correct URL.
    Scraping is strictly more reliable than guessing the path shape.
    """
    index_path = os.path.join(session_dir, "index.html")
    if not os.path.exists(index_path):
        return {}

    try:
        with open(index_path, "r", encoding="utf-8", errors="ignore") as f:
            page = f.read()
    except OSError:
        return {}

    server_url = server_url.rstrip("/")
    urls: dict[str, str] = {}

    # Match <source src="…" type="audio/…">, in either attribute order.
    # Capture both the src and the filename's trailing "/<Label>" part.
    pattern = re.compile(
        r'<source\s+[^>]*?src=["\']([^"\']+)["\'][^>]*?'
        r'type=["\']audio/[^"\']*["\']'
        r'|<source\s+[^>]*?type=["\']audio/[^"\']*["\'][^>]*?'
        r'src=["\']([^"\']+)["\']',
        re.IGNORECASE,
    )

    for m in pattern.finditer(page):
        src = m.group(1) or m.group(2)
        if not src:
            continue
        src = _html_mod.unescape(src)

        # Absolute URL for the browser / curl.
        if src.startswith("/"):
            absolute = f"{server_url}{src}"
        elif src.startswith("http"):
            absolute = src
        else:
            absolute = f"{server_url}/{src.lstrip('/')}"

        # Label = last path segment, percent-decoded, with any trailing
        # ".wav" stripped so it matches what the UI calls it.
        tail = src.rstrip("/").rsplit("/", 1)[-1]
        label = _html_mod.unescape(tail)
        # KIT sometimes percent-encodes the whole label, sometimes not.
        label = urllib.parse.unquote(label)
        if label.lower().endswith(".wav"):
            label = label[:-4]
        if not label:
            continue

        urls[label] = absolute

    return urls


def download_tts_files(
    session_id, token, server_url=None, languages=None, *, retries=4, delay=20
):
    """Download per-language TTS WAVs into the session folder.

    Two things about KIT's TTS endpoint, both learned from its own
    archive page (see the <source> tags in any session's index.html):

      1. The URL is <server>/archivemediafile/<sid>/<Label> Audio.wav.
         The space between the label and "Audio" is a *literal space*,
         not %20. KIT's page emits it unescaped; the browser tolerates
         it, so we should too.

      2. No credentials of any kind go with the request. Not a header,
         not a cookie. The base64 session id in the path *is* the
         credential — it decodes to /home/<email>/<session name> and
         is unguessable.

    The previous version sent a bearer token as a _forward_auth cookie
    and percent-encoded the space. KIT rejected both with HTTP 200 +
    an HTML login page.
    """
    session_dir = _session_dir(session_id)
    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

    # ── NEW: ask KIT's own archive page which URLs are real ─────
    scraped = _tts_urls_from_html(session_id, session_dir, server_url)
    if scraped:
        logging.info(
            "download_tts_files: index.html advertises %d TTS track(s): %s",
            len(scraped),
            sorted(scraped.keys()),
        )
    else:
        logging.info(
            "download_tts_files: index.html has no TTS <source> tags "
            "for %s — will fall back to guessed URLs",
            _short_sid(session_id),
        )

    # ---- which languages do we want? -------------------------------
    if languages is None:
        json_path = os.path.join(session_dir, "transcripts.json")
        if not os.path.exists(json_path):
            return []
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)
        except (OSError, ValueError, TypeError):
            return []
        languages = [t.get("language", "") for t in transcripts]

    wanted = []
    seen = set()
    for lang in languages:
        if not lang:
            continue
        if lang == "Transcript" or "Original ASR" in lang:
            continue
        simple = _extract_simple_language_name(lang)
        if not simple or simple == "Unknown":
            continue
        label = f"{simple} Audio"
        if label in seen:
            continue
        seen.add(label)
        wanted.append((simple, label))

    if not wanted:
        logging.info(
            "download_tts_files: no TTS-eligible languages for %s",
            _short_sid(session_id),
        )
        return []

    logging.info(
        "download_tts_files: want TTS for %d language(s) on %s: %s",
        len(wanted),
        _short_sid(session_id),
        [w[1] for w in wanted],
    )

    referer = f"{server_url}/archivesession/{session_id}"
    downloaded = []
    remaining = list(wanted)

    for attempt in range(1, retries + 1):
        still_missing = []

        for simple, label in remaining:
            local_name = f"tts_{simple}.wav"
            local_path = os.path.join(session_dir, local_name)

            # Already on disk and valid → count it, skip the fetch.
            if (
                os.path.exists(local_path)
                and os.path.getsize(local_path) > _MIN_WAV_BYTES
                and _looks_like_wav(local_path)
            ):
                if local_name not in downloaded:
                    downloaded.append(local_name)
                continue

            if os.path.exists(local_path):
                try:
                    os.remove(local_path)
                except OSError:
                    pass

             # ── Prefer the URL KIT's own page uses ────────────────
            kit_url = scraped.get(label)
            if kit_url:
                logging.info(
                    "download_tts_files: using scraped URL for %r: %s",
                    label,
                    kit_url,
                )
            else:
                # Fall back to the guessed shape.
                kit_name = f"{label}.wav"
                kit_url = (
                    f"{server_url}/archivemediafile/{session_id}/{kit_name}"
                )
                if scraped:
                    logging.warning(
                        "download_tts_files: %r not advertised by index.html; "
                        "falling back to guessed URL %s",
                        label,
                        kit_url,
                    )

            logging.info(
                "download_tts_files: GET %s (attempt %d/%d)",
                kit_url,
                attempt,
                retries,
            )

            if not token:
                token = _effective_token(session_id, fallback="")
            if not token:
                logging.warning(
                    "download_tts_files: no token for %s — skipping TTS",
                    _short_sid(session_id),
                )
                return []

            ok = curl_download(
                kit_url,
                local_path,
                token,
                cookie_only=True,   # _forward_auth cookie, no headers
                media=True,
                referer=referer,
            )

            if ok and _looks_like_wav(local_path):
                size = os.path.getsize(local_path)
                logging.info(
                    "download_tts_files: wrote %s (%d bytes)",
                    local_name,
                    size,
                )
                _job_log(session_id, f"Downloaded {local_name}")
                _job_add_file(session_id, local_name, size)
                downloaded.append(local_name)
            else:
                if os.path.exists(local_path):
                    try:
                        os.remove(local_path)
                    except OSError:
                        pass
                still_missing.append((simple, label))

        if not still_missing:
            break

        remaining = still_missing
        if attempt < retries:
            logging.info(
                "download_tts_files: %d track(s) still missing on %s "
                "— retrying in %ds (attempt %d/%d): %s",
                len(still_missing),
                _short_sid(session_id),
                delay,
                attempt,
                retries,
                [t[1] for t in still_missing],
            )
            time.sleep(delay)

    if remaining:
        logging.warning(
            "download_tts_files: gave up on %s after %d attempt(s): %s",
            _short_sid(session_id),
            retries,
            [t[1] for t in remaining],
        )

    return downloaded


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global _extract_simple_language_name
    from .routes_sessions import _extract_simple_language_name
