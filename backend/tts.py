"""Download and serve per-language TTS WAV files."""

from __future__ import annotations

import json
import logging
import os
import time

from .config import INTERNAL_SERVER_URL, MIN_WAV_BYTES
from .http import curl_download
from .progress import _job_add_file, _job_log
from .utils import (
    extract_simple_language_name,
    looks_like_wav,
    session_dir,
    short_sid,
)


def download_tts_files(
    session_id, _token, server_url=None, languages=None, *, retries=4, delay=20
) -> list[str]:
    """Download TTS WAV files for the requested languages."""
    # pylint: disable=too-many-arguments,too-many-locals,too-many-branches,too-many-statements
    sdir = session_dir(session_id)
    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

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

            kit_name = f"{label}.wav"
            kit_url = f"{server_url}/archivemediafile/{session_id}/{kit_name}"

            ok = curl_download(
                kit_url,
                local_path,
                "",
                anonymous=True,
                media=True,
                referer=referer,
            )
            if ok and looks_like_wav(local_path):
                size = os.path.getsize(local_path)
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
            time.sleep(delay)

    if remaining:
        logging.warning(
            "download_tts_files: gave up on %s after %d attempt(s)",
            short_sid(session_id),
            retries,
        )
    return downloaded
