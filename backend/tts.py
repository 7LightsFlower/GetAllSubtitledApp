"""Download and serve per-language TTS WAV files."""

from __future__ import annotations

import html as _html_mod
import json
import logging
import os
import re
import time
import urllib.parse

from .config import INTERNAL_SERVER_URL, MIN_WAV_BYTES
from .http import curl_download
from .progress import _job_add_file, _job_log
from .utils import (
    effective_token,
    extract_simple_language_name,
    looks_like_wav,
    session_dir,
    short_sid,
)


def _tts_urls_from_html(
    _session_id: str, session_dir_path: str, server_url: str
) -> dict[str, str]:
    """Parse index.html for TTS <source> URLs.

    Returns {label: absolute_url}, where label is the dropdown label
    ("Korean Audio") and absolute_url is the fully-qualified KIT URL
    that the archive page itself would play.

    KIT's own archive page builds the audio-source <select> from these
    tags, so whatever it emits is — by definition — the correct URL.
    Scraping is strictly more reliable than guessing the path shape.
    """
    index_path = os.path.join(session_dir_path, "index.html")
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

        if src.startswith("/"):
            absolute = f"{server_url}{src}"
        elif src.startswith("http"):
            absolute = src
        else:
            absolute = f"{server_url}/{src.lstrip('/')}"

        tail = src.rstrip("/").rsplit("/", 1)[-1]
        label = _html_mod.unescape(tail)
        label = urllib.parse.unquote(label)
        if label.lower().endswith(".wav"):
            label = label[:-4]
        if not label:
            continue

        urls[label] = absolute

    return urls


def download_tts_files(
    session_id,
    token,
    server_url=None,
    languages=None,
    *,
    retries=4,
    delay=20,
) -> list[str]:
    """Download TTS WAV files for the requested languages."""
    # pylint: disable=too-many-arguments,too-many-locals,too-many-branches,too-many-statements
    sdir = session_dir(session_id)
    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

    # ── Ask KIT's own archive page which URLs are real ──────────
    scraped = _tts_urls_from_html(session_id, sdir, server_url)
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
            short_sid(session_id),
        )

    if languages is None:
        json_path = os.path.join(sdir, "transcripts.json")
        if not os.path.exists(json_path):
            return []
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)
        except (OSError, ValueError, TypeError):
            return []
        languages = [t.get("language", "") for t in transcripts]

    wanted: list[tuple[str, str]] = []
    seen: set[str] = set()
    for lang in languages:
        if not lang:
            continue
        if lang == "Transcript" or "Original ASR" in lang:
            continue
        simple = extract_simple_language_name(lang)
        if not simple or simple == "Unknown":
            continue
        label = f"{simple} Audio"
        if label in seen:
            continue
        seen.add(label)
        wanted.append((simple, label))

    if not wanted:
        return []

    referer = f"{server_url}/archivesession/{session_id}"
    downloaded: list[str] = []
    remaining = list(wanted)

    for attempt in range(1, retries + 1):
        still_missing = []
        for simple, label in remaining:
            local_name = f"tts_{simple}.wav"
            local_path = os.path.join(sdir, local_name)

            if (
                os.path.exists(local_path)
                and os.path.getsize(local_path) > MIN_WAV_BYTES
                and looks_like_wav(local_path)
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

            # Resolve a token on first need. `effective_token` prefers
            # the token recorded on the session, then the caller's, then
            # the last one we saw on any request.
            if not token:
                token = effective_token(session_id, fallback="")
            if not token:
                logging.warning(
                    "download_tts_files: no token for %s — skipping TTS",
                    short_sid(session_id),
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

            if ok and looks_like_wav(local_path):
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
                short_sid(session_id),
                delay,
                attempt,
                retries,
                [t[1] for t in still_missing],
            )
            time.sleep(delay)

    if remaining:
        logging.warning(
            "download_tts_files: gave up on %s after %d attempt(s): %s",
            short_sid(session_id),
            retries,
            [t[1] for t in remaining],
        )

    return downloaded
