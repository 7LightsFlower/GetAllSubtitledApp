"""curl downloads and fetching a session's files from the KIT archive.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import json
import logging
import os
import re
import subprocess
import threading
import requests

from .flask_app import _curl_safe_url
from .servers import INTERNAL_SERVER_URL
from .config import sessions
from .utils import _effective_token, _session_dir, _short_sid
from .progress import _JobCancelled, _is_cancelled, _job_add_file, _job_log


def curl_download(
    url,
    output_path,
    token,
    *,
    cookie_only=False,
    media=False,
    referer=None,
    anonymous=False,
):
    """Download a file using curl.

    media=True      → send the headers an <audio> element would send.
    cookie_only=True → send only the `_forward_auth` cookie, no
                       Authorization / X-Forward-Auth headers.
    anonymous=True  → send no auth of any kind. Correct for
                       /archivemediafile/<sid>/<Language> Audio.wav,
                       which KIT serves purely on the strength of the
                       base64 session id in the path.
    """
    url = _curl_safe_url(url)
    try:
        auth_headers = []
        if not anonymous and not cookie_only:
            auth_headers = [
                "-H",
                f"X-Forward-Auth: {token}",
                "-H",
                f"Authorization: Bearer {token}",
            ]

        media_headers = []
        if media:
            media_headers = [
                "-H",
                "Accept: audio/webm,audio/ogg,audio/*;q=0.9,*/*;q=0.5",
                "-H",
                "Accept-Encoding: identity;q=1, *;q=0",
                "-H",
                "Range: bytes=0-",
            ]
            if referer:
                media_headers += ["-H", f"Referer: {referer}"]

        cmd = [
            "curl",
            "-s",
            "-L",
            "--insecure",
            "--connect-timeout",
            "30",
            "--max-time",
            "3600",
            *auth_headers,
            *media_headers,
            "-H",
            "User-Agent: Mozilla/5.0 (compatible; LT-Uploader/1.0)",
        ]

        # Only send the _forward_auth cookie when we were asked to use
        # one. anonymous=True is what we want for TTS.
        if not anonymous:
            cmd += ["--cookie", f"_forward_auth={token}"]

        cmd += [
            "-w",
            "%{http_code}",
            "-o",
            output_path,
            url,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=3660, check=False
        )
        status_str = (result.stdout or "").strip()
        try:
            status = int(status_str)
        except ValueError:
            status = 0

        if not status_str:
            logging.warning(
                "curl_download: curl produced no status for %s — rc=%s stderr=%r",
                url,
                result.returncode,
                (result.stderr or "")[:300],
            )

        if (
            status in (200, 206)
            and os.path.exists(output_path)
            and os.path.getsize(output_path) > 1000
        ):
            if not output_path.endswith(".html"):
                try:
                    with open(output_path, "rb") as f:
                        head = f.read(32)
                    stripped = head.lstrip().lower()
                    if (
                        stripped.startswith(b"<!doctype html")
                        or stripped.startswith(b"<html")
                        or stripped.startswith(b"<!doctype")
                    ):
                        logging.info(
                            "curl_download: %s → 200 but body is HTML; "
                            "treating as failure",
                            url,
                        )
                        os.remove(output_path)
                        return False
                except OSError:
                    pass
            return True

        if status not in (200, 206):
            logging.info("curl_download: %s → HTTP %s (discarding)", url, status)
        else:
            logging.info(
                "curl_download: %s → %s but body too small or HTML", url, status
            )

        if os.path.exists(output_path):
            os.remove(output_path)
        return False
    except subprocess.TimeoutExpired as e:
        logging.warning("Curl timeout for %s: %s", url, str(e))
        return False
    except OSError as e:
        logging.warning("Curl error for %s: %s", url, str(e))
        return False


def curl_download_with_headers(url, output_path, token):
    """Download a file using curl with an Accept: application/json header.

    Retained for parity with curl_download; currently unused. Rejects
    non-2xx responses the same way curl_download does.
    """
    try:
        cmd = [
            "curl",
            "-s",
            "-L",
            "--insecure",
            "-H",
            f"X-Forward-Auth: {token}",
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "Accept: application/json",
            "-H",
            "User-Agent: Mozilla/5.0 (compatible; LT-Uploader/1.0)",
            "--cookie",
            f"_forward_auth={token}",
            "-w",
            "%{http_code}",
            "-o",
            output_path,
            url,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=300, check=False
        )
        try:
            status = int((result.stdout or "").strip())
        except ValueError:
            status = 0

        if (
            status == 200
            and os.path.exists(output_path)
            and os.path.getsize(output_path) > 1000
        ):
            # KIT returns 200 with an HTML error page for files it does
            # not have. Refuse to treat that as a successful download,
            # otherwise the HTML is written into a .wav / .vtt / .mp4
            # slot and the browser chokes on it. index.html is
            # intentionally HTML, so skip the check for that filename.
            if not output_path.endswith(".html"):
                try:
                    with open(output_path, "rb") as f:
                        head = f.read(32)
                    stripped = head.lstrip().lower()
                    if (
                        stripped.startswith(b"<!doctype html")
                        or stripped.startswith(b"<html")
                        or stripped.startswith(b"<!doctype")
                    ):
                        logging.info(
                            "curl_download: %s → 200 but body is HTML; "
                            "treating as failure",
                            url,
                        )
                        os.remove(output_path)
                        return False
                except OSError:
                    pass
            return True
        if status != 200:
            logging.info(
                "curl_download_with_headers: %s → HTTP %s (discarding)",
                url,
                status,
            )
        if os.path.exists(output_path):
            os.remove(output_path)
        return False
    except subprocess.TimeoutExpired as e:
        logging.warning("Curl timeout for %s: %s", url, str(e))
        return False
    except OSError as e:
        logging.warning("Curl error for %s: %s", url, str(e))
        return False


def extract_text_from_file(file_path):
    """Extract transcript text from a file."""
    if not os.path.exists(file_path):
        return None
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    try:
        data = json.loads(content)
        text = extract_text_from_json(data)
        if text:
            return text
    except json.JSONDecodeError:
        pass
    if file_path.endswith((".vtt", ".srt")):
        text = extract_text_from_subtitle(content)
        if text:
            return text
    if content and len(content) > 10:
        return content
    return None


def extract_text_from_json(data):
    """Extract text from JSON data."""
    if isinstance(data, dict):
        for key in ["text", "content", "transcript", "seq"]:
            if key in data and data[key] and isinstance(data[key], str):
                return data[key]
        if "messages" in data and isinstance(data["messages"], list):
            texts = []
            for msg in data["messages"]:
                if isinstance(msg, dict):
                    text = extract_text_from_json(msg)
                    if text:
                        texts.append(text)
            if texts:
                return "\n".join(texts)
        if "data" in data and isinstance(data["data"], list):
            texts = []
            for item in data["data"]:
                text = extract_text_from_json(item)
                if text:
                    texts.append(text)
            if texts:
                return "\n".join(texts)
        for key, value in data.items():
            if isinstance(value, (dict, list)):
                text = extract_text_from_json(value)
                if text:
                    return text
    elif isinstance(data, list):
        texts = []
        for item in data:
            text = extract_text_from_json(item)
            if text:
                texts.append(text)
        if texts:
            return "\n".join(texts)
    return None


def extract_text_from_subtitle(content):
    """Extract text from VTT or SRT subtitle file."""
    lines = content.split("\n")
    text_lines = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if "-->" in line:
            continue
        if line.isdigit():
            continue
        if line.startswith("WEBVTT"):
            continue
        if line.startswith("Kind:"):
            continue
        if line.startswith("Language:"):
            continue
        text_lines.append(line)
    return " ".join(text_lines) if text_lines else None


def get_actual_file_url(session_id, filename, server_url, html_content=None):
    """
    Determine the correct URL for a file based on its type.

    `server_url` is the base URL of the internal server that owns the
    session (e.g. "https://lt2srv.iar.kit.edu"). Every returned
    URL is built against it, so a session that lives on a non-default
    server is downloaded from the right host.
    """
    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

    if html_content:
        if filename == "video.mp4":
            match = re.search(r'<source src="([^"]+)"', html_content)
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{server_url}{url}"
                return url
        if filename.startswith("subtitles_") and filename.endswith(".vtt"):
            label = filename.replace("subtitles_", "").replace(".vtt", "")
            match = re.search(
                rf'<track label="{label}" kind="subtitles" src="([^"]+)"',
                html_content,
            )
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{server_url}{url}"
                return url
        if filename.endswith(".wav"):
            match = re.search(r'<source src="([^"]+)"[^>]*type="audio/', html_content)
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{server_url}{url}"
                return url

    if filename == "messages.json":
        return f"{server_url}/archivemediafile/{session_id}/messages.json"
    if filename.endswith(".vtt"):
        label = filename.replace(".vtt", "")
        return f"{server_url}/archivemedia/{session_id}/vtt/{label}"
    if filename == "video.mp4":
        return f"{server_url}/archivemediafile/{session_id}/video.mp4"
    if filename.endswith(".wav"):
        encoded_name = filename.replace(" ", "%20")
        return f"{server_url}/archivemediafile/{session_id}/{encoded_name}"
    encoded_name = filename.replace(" ", "%20")
    return f"{server_url}/archivesession/{session_id}/{encoded_name}"


# pylint: disable=too-many-locals,too-many-branches,too-many-statements
_session_download_locks: dict[str, threading.Lock] = {}
_session_download_locks_guard = threading.Lock()


def _get_session_download_lock(session_id: str) -> threading.Lock:
    """One lock per session so /session_output and the BG worker
    never write the same files at the same time."""
    with _session_download_locks_guard:
        lock = _session_download_locks.get(session_id)
        if lock is None:
            lock = threading.Lock()
            _session_download_locks[session_id] = lock
        return lock


def download_session_files(session_id, token, server_url=None):
    """Download the media files and transcripts associated with a session."""
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")

    effective_token = _effective_token(session_id, fallback=token)

    lock = _get_session_download_lock(session_id)
    if not lock.acquire(blocking=False):
        lock.acquire()
        lock.release()
        logging.info(
            "download_session_files: %s already downloaded by another "
            "thread, skipping",
            _short_sid(session_id),
        )
        return True

    try:
        session_dir = _session_dir(session_id)
        if not _session_files_look_incomplete(session_dir):
            logging.info(
                "download_session_files: %s is already complete, skipping",
                _short_sid(session_id),
            )
            return True
        return _download_session_files_locked(session_id, effective_token, server_url)
    finally:
        lock.release()


def _download_session_files_locked(session_id, token, server_url):
    """Download the media files and transcripts associated with a session."""
    session_dir = _session_dir(session_id)
    os.makedirs(session_dir, exist_ok=True)

    server_url = (server_url or INTERNAL_SERVER_URL).rstrip("/")

    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before download"
        )

    logging.info("=" * 60)
    logging.info("Downloading session %s from %s", session_id, server_url)
    _job_log(
        session_id, "Downloading session files…", stage="downloading", progress=0.35
    )

    html_path = os.path.join(session_dir, "index.html")
    html_url = f"{server_url}/archivesession/{session_id}"

    if curl_download(html_url, html_path, token):
        logging.info("Downloaded index.html")
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

    # Video
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before video download"
        )
    video_url = get_actual_file_url(session_id, "video.mp4", server_url, html_content)
    video_path = os.path.join(session_dir, "video.mp4")
    if curl_download(video_url, video_path, token):
        logging.info("Downloaded video.mp4")
        _job_log(
            session_id,
            f"Downloaded video.mp4 " f"({os.path.getsize(video_path)} bytes)",
            progress=0.5,
        )
        _job_add_file(session_id, "video.mp4", os.path.getsize(video_path))
    else:
        _job_log(session_id, "Failed to download video.mp4", level="warning")

    # Subtitles
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before subtitle download"
        )
    try:
        track_matches = re.findall(
            r'<track label="([^"]+)" kind="subtitles" src="([^"]+)"',
            html_content,
        )
        for label, src in track_matches:
            if src.startswith("/"):
                src = f"{server_url}{src}"
            file_name = f"subtitles_{label}.vtt"
            file_path = os.path.join(session_dir, file_name)
            if curl_download(src, file_path, token):
                logging.info("Downloaded %s", file_name)
                _job_log(
                    session_id,
                    f"Downloaded {file_name} " f"({os.path.getsize(file_path)} bytes)",
                )
                _job_add_file(session_id, file_name, os.path.getsize(file_path))
    except (OSError, re.error) as e:
        logging.warning("Could not download subtitles: %s", e)

    # Audio (if present)
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before audio download"
        )
    try:
        audio_match = re.search(r'<source src="([^"]+)"[^>]*type="audio/', html_content)
        if audio_match:
            audio_url = audio_match.group(1)
            if audio_url.startswith("/"):
                audio_url = f"{server_url}{audio_url}"
            audio_path = os.path.join(session_dir, "audio.wav")
            if curl_download(audio_url, audio_path, token):
                logging.info("Downloaded audio.wav")
                _job_add_file(session_id, "audio.wav", os.path.getsize(audio_path))
    except (OSError, re.error) as e:
        logging.warning("Could not download audio: %s", e)

    # messages.json
    # messages.json — fetched from KIT's live /archive_messages/
    # endpoint, not from the static archive file (which is not
    # populated on lt2srv.iar.kit.edu for public sessions).
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before messages.json download"
        )
    messages_path = os.path.join(session_dir, "messages.json")
    messages = _fetch_all_archive_messages(session_id, token, server_url)
    if messages:
        with open(messages_path, "w", encoding="utf-8") as f:
            json.dump(messages, f, ensure_ascii=False)
        size = os.path.getsize(messages_path)
        logging.info(
            "Downloaded %d messages via /archive_messages (%d bytes)",
            len(messages),
            size,
        )
        _job_log(
            session_id,
            f"Downloaded {len(messages)} messages " f"({size} bytes)",
            progress=0.85,
        )
        _job_add_file(session_id, "messages.json", size)
    else:
        logging.warning(
            "No messages returned by /archive_messages for session %s",
            _short_sid(session_id),
        )

    # Transcripts
    _job_log(session_id, "Extracting transcripts…", stage="extracting", progress=0.9)
    transcripts = extract_transcripts_from_messages(messages_path)
    if transcripts:
        save_transcripts_to_files(session_dir, transcripts)
        logging.info("Extracted %d transcripts from messages.json", len(transcripts))
        _job_add_file(
            session_id,
            "transcripts.json",
            os.path.getsize(os.path.join(session_dir, "transcripts.json")),
        )
        _job_add_file(
            session_id,
            "transcript.txt",
            os.path.getsize(os.path.join(session_dir, "transcript.txt")),
        )

        # ── NEW: generate VTTs from the transcripts we just wrote ──
        for vtt_name in generate_vtt_files_from_transcripts(session_dir):
            vtt_path = os.path.join(session_dir, vtt_name)
            _job_add_file(session_id, vtt_name, os.path.getsize(vtt_path))
            _job_log(session_id, f"Generated {vtt_name}")

    else:
        _job_log(session_id, "No transcripts extracted", level="warning")

    # ── Pull TTS WAVs alongside the VTTs, so playback no longer
    #    depends on a live KIT token. ─────────────────────────────
    if _is_cancelled(session_id):
        raise _JobCancelled(
            f"Session {_short_sid(session_id)} cancelled before TTS download"
        )
    _job_log(
        session_id,
        "Downloading TTS audio tracks…",
        stage="downloading",
        progress=0.95,
    )
    try:
        tts_files = download_tts_files(session_id, token, server_url)
        if tts_files:
            logging.info(
                "Downloaded %d TTS file(s) for %s: %s",
                len(tts_files),
                _short_sid(session_id),
                tts_files,
            )
            _job_log(
                session_id,
                f"Downloaded {len(tts_files)} TTS track(s)",
                progress=0.97,
            )
            # KIT joins the TTS pieces back to back; put them at the
            # times of the original (see tts_sync.py).
            try:
                from .tts_sync import sync_session

                for r in sync_session(_session_dir(session_id)):
                    if r.get("status") == "synced":
                        _job_log(
                            session_id,
                            f"Synchronized {r['file']} with the original "
                            f"({r['kit_length_s']:.0f} s → {r['length_s']:.0f} s)",
                        )
            except Exception as e:  # never fail the job over this
                logging.warning("TTS sync failed for %s: %s",
                                _short_sid(session_id), e)
        else:
            logging.info(
                "No TTS files downloaded for %s "
                "(languages may not have TTS available)",
                _short_sid(session_id),
            )
            _job_log(
                session_id,
                "No TTS tracks available for this session",
                level="warning",
            )
    except (OSError, ValueError, TypeError, requests.exceptions.RequestException) as e:
        logging.warning("TTS download failed for %s: %s", _short_sid(session_id), e)
        _job_log(
            session_id,
            f"TTS download failed: {e}",
            level="warning",
        )

    files = [
        f
        for f in os.listdir(session_dir)
        if os.path.isfile(os.path.join(session_dir, f))
        and _is_meaningful_file(os.path.join(session_dir, f))
    ]

    logging.info("=" * 60)
    logging.info(
        "Session %s: Downloaded %s files total", _short_sid(session_id), len(files)
    )
    for f in files:
        size = os.path.getsize(os.path.join(session_dir, f))
        logging.info("  - %s (%d bytes)", f, size)
    logging.info("=" * 60)

    _job_log(
        session_id,
        f"Session ready: {len(files)} files downloaded",
        stage="ready",
        progress=1.0,
    )
    return len(files) > 0


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global _fetch_all_archive_messages, _is_meaningful_file
    global _session_files_look_incomplete, download_tts_files
    global extract_transcripts_from_messages
    global generate_vtt_files_from_transcripts, save_transcripts_to_files
    from .tts import download_tts_files
    from .transcripts import (
        extract_transcripts_from_messages,
        generate_vtt_files_from_transcripts,
        save_transcripts_to_files,
    )
    from .kit_messages import _fetch_all_archive_messages
    from .video_routes import _is_meaningful_file
    from .session_sync import _session_files_look_incomplete
