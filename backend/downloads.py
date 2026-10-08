"""Download a completed KIT session into its local folder."""

from __future__ import annotations

import json
import logging
import os
import re
import threading

import requests

from .config import (
    INTERNAL_SERVER_URL,
    MIN_MESSAGES_BYTES as _MIN_MESSAGES_BYTES,
    MIN_WAV_BYTES,
    MT_COVERAGE_MIN_FRACTION as _MT_COVERAGE_MIN_FRACTION,
    MT_COVERAGE_SLACK_SECONDS as _MT_COVERAGE_SLACK_SECONDS,
)
from .http import curl_download, internal_cookies, internal_headers
from .progress import (
    _is_cancelled,
    _job_add_file,
    _job_log,
)
from .state import sessions
from .transcripts import (
    extract_transcripts_from_messages,
    generate_vtt_files_from_transcripts,
    save_transcripts_to_files,
)
from .tts import download_tts_files
from .utils import (
    effective_token,
    is_meaningful_file,
    looks_like_wav,
    session_dir,
    short_sid,
)

_session_download_locks: dict[str, threading.Lock] = {}
_session_download_locks_guard = threading.Lock()


class JobCancelled(Exception):
    """Raised when a session is cancelled mid-download."""


def _get_session_download_lock(session_id: str) -> threading.Lock:
    with _session_download_locks_guard:
        lock = _session_download_locks.get(session_id)
        if lock is None:
            lock = threading.Lock()
            _session_download_locks[session_id] = lock
        return lock


def get_actual_file_url(session_id, filename, server_url, html_content=None) -> str:
    """Resolve a downloaded filename to the URL used by the server."""
    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")
    url = None

    if html_content:
        patterns = []
        if filename == "video.mp4":
            patterns.append(r'<source src="([^"]+)"')
        elif filename.startswith("subtitles_") and filename.endswith(".vtt"):
            label = filename.replace("subtitles_", "").replace(".vtt", "")
            patterns.append(
                rf'<track label="{label}" kind="subtitles" src="([^"]+)"'
            )
        elif filename.endswith(".wav"):
            patterns.append(r'<source src="([^"]+)"[^>]*type="audio/')

        for pattern in patterns:
            match = re.search(pattern, html_content)
            if match:
                url = match.group(1)
                break

    if url is None:
        if filename == "messages.json":
            url = f"/archivemediafile/{session_id}/messages.json"
        elif filename.endswith(".vtt"):
            label = filename.replace(".vtt", "")
            url = f"/archivemedia/{session_id}/vtt/{label}"
        elif filename == "video.mp4":
            url = f"/archivemediafile/{session_id}/video.mp4"
        elif filename.endswith(".wav"):
            encoded = filename.replace(" ", "%20")
            url = f"/archivemediafile/{session_id}/{encoded}"
        else:
            encoded = filename.replace(" ", "%20")
            url = f"/archivesession/{session_id}/{encoded}"

    return f"{server_url}{url}" if url.startswith("/") else url


def _session_files_look_incomplete(session_dir_path: str) -> bool:
    messages = os.path.join(session_dir_path, "messages.json")
    transcripts = os.path.join(session_dir_path, "transcripts.json")

    if not os.path.exists(transcripts):
        return True
    if not os.path.exists(messages) or os.path.getsize(messages) < 5000:
        return True

    try:
        with open(transcripts, "r", encoding="utf-8") as f:
            ts = json.load(f)
    except (json.JSONDecodeError, TypeError, ValueError):
        return True

    languages_with_text = [
        t
        for t in ts
        if any(seg.get("text", "").strip() for seg in t.get("segments", []))
    ]
    vtt_files = [
        f
        for f in os.listdir(session_dir_path)
        if f.startswith("subtitles_")
        and f.endswith(".vtt")
        and os.path.getsize(os.path.join(session_dir_path, f)) > 20
    ]
    if len(vtt_files) < len(languages_with_text):
        return True
    if not _local_transcripts_cover_full_span(session_dir_path):
        return True

    vtt_langs = {
        f[len("subtitles_") : -len(".vtt")]
        for f in vtt_files
        if f != "subtitles_Transcript.vtt"
    }
    tts_langs = {
        f[len("tts_") : -len(".wav")]
        for f in os.listdir(session_dir_path)
        if f.startswith("tts_")
        and f.endswith(".wav")
        and os.path.getsize(os.path.join(session_dir_path, f)) > MIN_WAV_BYTES
        and looks_like_wav(os.path.join(session_dir_path, f))
    }
    if vtt_langs - tts_langs:
        return True
    return False


def _local_transcripts_cover_full_span(session_dir_path: str) -> bool:
    messages_path = os.path.join(session_dir_path, "messages.json")
    if not os.path.exists(messages_path):
        return False
    try:
        with open(messages_path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    if not raw or len(raw) < _MIN_MESSAGES_BYTES:
        return False
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return False
    if not isinstance(data, list):
        return False

    asr_max_end = 0.0
    mt_tracks: dict[str, float] = {}
    for item in data:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict) or not m.get("seq", "").strip():
            continue
        try:
            end = float(m.get("end", 0) or 0)
        except (ValueError, TypeError):
            end = 0.0
        sender = m.get("sender", "")
        if sender.startswith("asr:"):
            asr_max_end = max(asr_max_end, end)
        elif sender.startswith(("mt:", "translation:")):
            mt_tracks[sender] = max(mt_tracks.get(sender, 0.0), end)

    if not mt_tracks or asr_max_end <= 0:
        return False
    for mt_end in mt_tracks.values():
        if (
            mt_end >= asr_max_end - _MT_COVERAGE_SLACK_SECONDS
            or (mt_end / asr_max_end) >= _MT_COVERAGE_MIN_FRACTION
        ):
            continue
        return False
    return True


def download_session_files(session_id, token, server_url=None) -> bool:
    """Download the session files, skipping work already in progress or complete."""
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")
    effective = effective_token(session_id, fallback=token)

    lock = _get_session_download_lock(session_id)
    if not lock.acquire(blocking=False):
        lock.acquire()
        lock.release()
        logging.info(
            "download_session_files: %s already being downloaded, skipping",
            short_sid(session_id),
        )
        return True
    try:
        sdir = session_dir(session_id)
        if not _session_files_look_incomplete(sdir):
            logging.info(
                "download_session_files: %s already complete, skipping",
                short_sid(session_id),
            )
            return True
        return _download_locked(session_id, effective, server_url)
    finally:
        lock.release()


def _download_locked(session_id, token, server_url) -> bool:
    sdir = session_dir(session_id)
    os.makedirs(sdir, exist_ok=True)
    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

    if _is_cancelled(session_id):
        raise JobCancelled(f"Session {short_sid(session_id)} cancelled before download")

    _job_log(
        session_id, "Downloading session files…", stage="downloading", progress=0.35
    )

    html_path = os.path.join(sdir, "index.html")
    html_url = f"{server_url}/archivesession/{session_id}"
    if curl_download(html_url, html_path, token):
        _job_add_file(session_id, "index.html", os.path.getsize(html_path))
    else:
        _job_log(session_id, "Failed to download index.html", level="warning")
        return False

    html_content = ""
    try:
        with open(html_path, "r", encoding="utf-8") as f:
            html_content = f.read()
    except (OSError, UnicodeDecodeError):
        pass

    if _is_cancelled(session_id):
        raise JobCancelled(
            f"Session {short_sid(session_id)} cancelled before video download"
        )

    video_url = get_actual_file_url(session_id, "video.mp4", server_url, html_content)
    video_path = os.path.join(sdir, "video.mp4")
    if curl_download(video_url, video_path, token):
        _job_log(
            session_id,
            f"Downloaded video.mp4 ({os.path.getsize(video_path)} bytes)",
            progress=0.5,
        )
        _job_add_file(session_id, "video.mp4", os.path.getsize(video_path))
    else:
        _job_log(session_id, "Failed to download video.mp4", level="warning")

    if _is_cancelled(session_id):
        raise JobCancelled(
            f"Session {short_sid(session_id)} cancelled before subtitle download"
        )

    try:
        track_matches = re.findall(
            r'<track label="([^"]+)" kind="subtitles" src="([^"]+)"', html_content
        )
        for label, src in track_matches:
            if src.startswith("/"):
                src = f"{server_url}{src}"
            file_name = f"subtitles_{label}.vtt"
            file_path = os.path.join(sdir, file_name)
            if curl_download(src, file_path, token):
                _job_log(
                    session_id,
                    f"Downloaded {file_name} ({os.path.getsize(file_path)} bytes)",
                )
                _job_add_file(session_id, file_name, os.path.getsize(file_path))
    except (OSError, re.error) as e:
        logging.warning("Could not download subtitles: %s", e)

    if _is_cancelled(session_id):
        raise JobCancelled(
            f"Session {short_sid(session_id)} cancelled before audio download"
        )

    try:
        audio_match = re.search(r'<source src="([^"]+)"[^>]*type="audio/', html_content)
        if audio_match:
            audio_url = audio_match.group(1)
            if audio_url.startswith("/"):
                audio_url = f"{server_url}{audio_url}"
            audio_path = os.path.join(sdir, "audio.wav")
            if curl_download(audio_url, audio_path, token):
                _job_add_file(session_id, "audio.wav", os.path.getsize(audio_path))
    except (OSError, re.error) as e:
        logging.warning("Could not download audio: %s", e)

    if _is_cancelled(session_id):
        raise JobCancelled(
            f"Session {short_sid(session_id)} cancelled before messages.json"
        )

    messages_path = os.path.join(sdir, "messages.json")
    messages = _fetch_all_archive_messages(session_id, token, server_url)
    if messages:
        with open(messages_path, "w", encoding="utf-8") as f:
            json.dump(messages, f, ensure_ascii=False)
        size = os.path.getsize(messages_path)
        _job_log(
            session_id,
            f"Downloaded {len(messages)} messages ({size} bytes)",
            progress=0.85,
        )
        _job_add_file(session_id, "messages.json", size)

    _job_log(session_id, "Extracting transcripts…", stage="extracting", progress=0.9)
    transcripts = extract_transcripts_from_messages(messages_path)
    if transcripts:
        save_transcripts_to_files(sdir, transcripts)
        _job_add_file(
            session_id,
            "transcripts.json",
            os.path.getsize(os.path.join(sdir, "transcripts.json")),
        )
        _job_add_file(
            session_id,
            "transcript.txt",
            os.path.getsize(os.path.join(sdir, "transcript.txt")),
        )
        for vtt_name in generate_vtt_files_from_transcripts(sdir):
            vtt_path = os.path.join(sdir, vtt_name)
            _job_add_file(session_id, vtt_name, os.path.getsize(vtt_path))
            _job_log(session_id, f"Generated {vtt_name}")
    else:
        _job_log(session_id, "No transcripts extracted", level="warning")

    if _is_cancelled(session_id):
        raise JobCancelled(
            f"Session {short_sid(session_id)} cancelled before TTS download"
        )

    _job_log(
        session_id, "Downloading TTS audio tracks…", stage="downloading", progress=0.95
    )
    try:
        tts_files = download_tts_files(session_id, token, server_url)
        if tts_files:
            _job_log(
                session_id, f"Downloaded {len(tts_files)} TTS track(s)", progress=0.97
            )
        else:
            _job_log(
                session_id, "No TTS tracks available for this session", level="warning"
            )
    except (OSError, ValueError, TypeError) as e:
        _job_log(session_id, f"TTS download failed: {e}", level="warning")

    files = [
        f
        for f in os.listdir(sdir)
        if os.path.isfile(os.path.join(sdir, f))
        and is_meaningful_file(os.path.join(sdir, f))
    ]
    _job_log(
        session_id,
        f"Session ready: {len(files)} files downloaded",
        stage="ready",
        progress=1.0,
    )
    return len(files) > 0


# ─── /archive_messages/ pagination ─────────────────────────────────────
def _fetch_archive_messages_page(session_id, token, server_url, page, limit=1000):
    if not server_url:
        server_url = INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")
    url = f"{server_url}/archive_messages/{session_id}"
    try:
        r = requests.get(
            url,
            params={"page": page, "limit": limit},
            headers=internal_headers(token),
            cookies=internal_cookies(token),
            verify=False,
            timeout=60,
            allow_redirects=True,
        )
        if r.status_code != 200:
            return None
        return r.json()
    except requests.RequestException:
        return None


def _fetch_all_archive_messages(
    session_id, token, server_url, limit=1000, max_pages=50
) -> list:
    all_messages: list = []
    page = 1
    total = None
    while page <= max_pages:
        payload = _fetch_archive_messages_page(
            session_id, token, server_url, page, limit
        )
        if payload is None:
            break
        if total is None:
            try:
                total = int(payload.get("total", 0))
            except (TypeError, ValueError):
                total = 0
        chunk = payload.get("data") or []
        all_messages.extend(chunk)
        if not chunk or len(chunk) < limit:
            break
        if total is not None and page * limit >= total:
            break
        page += 1
    return all_messages


def _fetch_latest_archive_page(session_id, token, server_url, limit=1000) -> list:
    probe = _fetch_archive_messages_page(session_id, token, server_url, page=1, limit=1)
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
        session_id, token, server_url, page=last_page, limit=limit
    )
    return (payload or {}).get("data") or []
