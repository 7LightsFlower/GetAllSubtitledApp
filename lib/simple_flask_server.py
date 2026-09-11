#!/usr/bin/env python3
"""Merged Flask server combining mock server and upload proxy functionality."""

import base64
import datetime
import io
import json
import logging
import mimetypes
import os
import pickle
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile

import requests
import yt_dlp
from flask import Flask, jsonify, request, send_file
from flask_cors import CORS
from docx import Document
from docx.shared import Pt, RGBColor

# BeautifulSoup is imported only when needed for HTML parsing
has_bs4 = False
try:
    from bs4 import BeautifulSoup

    has_bs4 = True
except ImportError:
    logging.warning("BeautifulSoup not installed. Export functions will be limited.")

logging.basicConfig(level=logging.DEBUG)
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 1024 * 1024 * 1024
app.config["DEBUG"] = True

CORS(
    app,
    origins=[
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://localhost:5000",
        "http://127.0.0.1:5000",
        "https://getallsubtitledapp.isl.iar.kit.edu",
    ],
    supports_credentials=True,
    methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization", "X-Forwarded-User", "Accept"],
    expose_headers=["Location", "Content-Disposition"],
)

INTERNAL_SERVER_URL = "https://lt2srv-sscherrer.isl.iar.kit.edu"
TARGET_URL = f"{INTERNAL_SERVER_URL}/upload_lecture"
BASE_URL = INTERNAL_SERVER_URL
UPLOAD_FOLDER = os.path.join(os.path.dirname(__file__), "uploads")
SESSION_FOLDER = os.path.join(os.path.dirname(__file__), "sessions")
STATE_FILE = os.path.join(os.path.dirname(__file__), "server_state.pkl")
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(SESSION_FOLDER, exist_ok=True)

users = {}
videos = []
chunk_storage = {}
jobs = {}
sessions = {}
internal_session = requests.Session()
internal_session.verify = False
_state = {"token": None}


# ─── STATE PERSISTENCE ──────────────────────────────────────────────────


def save_state():
    """Save server state to disk."""
    try:
        state = {
            "users": users,
            "videos": videos,
            "jobs": jobs,
            "sessions": sessions,
            "timestamp": datetime.datetime.now().isoformat(),
        }
        with open(STATE_FILE, "wb") as f:
            pickle.dump(state, f)
        logging.info("State saved to %s", STATE_FILE)
    except (OSError, pickle.PickleError, TypeError, ValueError) as e:
        logging.error("Failed to save state: %s", e)


def load_state():
    """Load server state from disk."""
    if not os.path.exists(STATE_FILE):
        logging.info("No state file found. Starting with default state.")
        return False

    try:
        with open(STATE_FILE, "rb") as f:
            state = pickle.load(f)

        loaded_state = {
            "users": state.get("users", {}),
            "videos": state.get("videos", []),
            "jobs": state.get("jobs", {}),
            "sessions": state.get("sessions", {}),
        }
        globals().update(loaded_state)

        logging.info("State loaded from %s", STATE_FILE)
        logging.info("  - Users: %d", len(users))
        logging.info("  - Videos: %d", len(videos))
        logging.info("  - Jobs: %d", len(jobs))
        logging.info("  - Sessions: %d", len(sessions))

        # Verify video files still exist and update status
        for video in videos:
            file_name = video.get("file_name")
            if file_name:
                file_path = os.path.join(UPLOAD_FOLDER, file_name)
                if not os.path.exists(file_path):
                    logging.warning("Video file missing: %s", file_path)
                    video["file_missing"] = True
                else:
                    video["file_missing"] = False

        return True
    except (
        FileNotFoundError,
        OSError,
        pickle.PickleError,
        EOFError,
        AttributeError,
        TypeError,
        ValueError,
    ) as e:
        logging.error("Failed to load state: %s", e)
        return False


def clean_missing_videos():
    """Remove video entries whose files no longer exist on disk."""
    if not videos:
        return

    valid_videos = []
    removed_count = 0

    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            # Skip entries without a filename
            removed_count += 1
            logging.warning(
                "Removing video entry with no filename: %s",
                video.get("name", "Unknown"),
            )
            continue

        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if os.path.exists(file_path):
            valid_videos.append(video)
        else:
            removed_count += 1
            logging.warning(
                "Removing missing video: %s (key: %s)",
                file_name,
                video.get("key", "N/A"),
            )

            # Also remove any associated thumbnail
            thumb_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
            thumb_path = os.path.join(UPLOAD_FOLDER, thumb_filename)
            if os.path.exists(thumb_path):
                try:
                    os.remove(thumb_path)
                    logging.info("Removed orphaned thumbnail: %s", thumb_filename)
                except OSError as e:
                    logging.warning(
                        "Could not remove thumbnail %s: %s", thumb_filename, e
                    )

    if removed_count > 0:
        videos[:] = valid_videos
        save_state()
        logging.info(
            "🧹 Cleaned up %d missing video(s). %d video(s) remain.",
            removed_count,
            len(videos),
        )
    else:
        logging.info("✅ All %d video(s) are valid.", len(videos))


def cleanup_orphaned_data():
    """Remove orphaned sessions and jobs that reference non-existent videos."""
    # These dictionaries are mutated in place; rebinding their module-level
    # names is not necessary.
    session_store = sessions
    job_store = jobs

    # Get valid video keys
    valid_video_keys = {video.get("key") for video in videos if video.get("key")}

    # Clean up sessions
    orphaned_sessions = []
    for session_id, session in session_store.items():
        video_key = session.get("video_key")
        if video_key and video_key not in valid_video_keys:
            orphaned_sessions.append(session_id)
            logging.warning(
                "Removing orphaned session %s (video_key: %s)",
                session_id,
                video_key,
            )

            # Also remove session files if they exist
            session_dir = os.path.join(SESSION_FOLDER, session_id)
            if os.path.exists(session_dir):
                try:
                    shutil.rmtree(session_dir)
                    logging.info("Removed session directory: %s", session_dir)
                except OSError as e:
                    logging.warning(
                        "Could not remove session directory %s: %s", session_dir, e
                    )

    for session_id in orphaned_sessions:
        del session_store[session_id]

    # Clean up jobs
    orphaned_jobs = []
    for job_id, job in job_store.items():
        video_key = job.get("video_key")
        if video_key and video_key not in valid_video_keys:
            orphaned_jobs.append(job_id)
            logging.warning(
                "Removing orphaned job %s (video_key: %s)", job_id, video_key
            )

    for job_id in orphaned_jobs:
        del job_store[job_id]

    if orphaned_sessions or orphaned_jobs:
        save_state()
        logging.info(
            "🧹 Cleaned up %d orphaned session(s) and %d orphaned job(s)",
            len(orphaned_sessions),
            len(orphaned_jobs),
        )


def regenerate_missing_thumbnails():
    """Regenerate thumbnails for videos that don't have one."""
    if not videos:
        return

    regenerated = 0
    for video in videos:
        # Skip if already has a thumbnail
        if video.get("thumbnail_url") and video["thumbnail_url"] != "None":
            continue

        file_name = video.get("file_name")
        if not file_name:
            continue

        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if not os.path.exists(file_path):
            continue

        # Generate thumbnail
        thumbnail_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)

        if generate_video_thumbnail(file_path, thumbnail_path):
            video["thumbnail_url"] = f"/thumbnails/{thumbnail_filename}"
            regenerated += 1
            logging.info("Generated thumbnail for %s", file_name)
        else:
            video["thumbnail_url"] = None

    if regenerated > 0:
        save_state()
        logging.info("🖼️ Regenerated %d thumbnail(s)", regenerated)


def parse_html_with_bs4(html_content):
    """Parse HTML content using BeautifulSoup if available."""
    if has_bs4 and html_content:
        try:
            soup = BeautifulSoup(html_content, "html.parser")
            return soup
        except (TypeError, ValueError) as e:
            logging.warning("Failed to parse HTML with BeautifulSoup: %s", e)
    return None


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


def generate_mock_transcript():
    """Return a static sample transcript."""
    return (
        "This is a sample transcript generated by the mock server.\n"
        "It contains multiple sentences that demonstrate the output format.\n"
        "The lecture covers important topics in artificial intelligence "
        "and machine learning.\n"
        "Deep learning models have revolutionized the field of "
        "natural language processing.\n"
        "Transformers, in particular, have become the backbone of "
        "modern AI systems."
    )


def generate_mock_segments():
    """Return a list of mock transcript segments with timestamps."""
    return [
        {
            "text": "This is a sample transcript generated by the mock server.",
            "start": 0.0,
            "end": 5.2,
            "language": "en",
        },
        {
            "text": "It contains multiple sentences that demonstrate "
            "the output format.",
            "start": 5.2,
            "end": 10.8,
            "language": "en",
        },
        {
            "text": "The lecture covers important topics in artificial "
            "intelligence and machine learning.",
            "start": 10.8,
            "end": 16.5,
            "language": "en",
        },
        {
            "text": "Deep learning models have revolutionized the field of "
            "natural language processing.",
            "start": 16.5,
            "end": 22.3,
            "language": "en",
        },
        {
            "text": "Transformers, in particular, have become the backbone of "
            "modern AI systems.",
            "start": 22.3,
            "end": 28.0,
            "language": "en",
        },
    ]


def process_job(job_id):
    """Simulate background job processing with progress updates."""
    job = jobs.get(job_id)
    if not job:
        return

    # Get the video key and find the original video
    video_key = job.get("video_key")
    original_video = None
    if video_key:
        for video in videos:
            if video.get("key") == video_key:
                original_video = video
                break

    progress = 0.0
    while progress < 1.0:
        time.sleep(1)
        progress += 0.1
        if progress > 1.0:
            progress = 1.0
        job["progress"] = progress
        if progress >= 1.0:
            job["status"] = "completed"
            job["transcript"] = generate_mock_transcript()
            job["segments"] = generate_mock_segments()

            # Update the original video with processing results - DON'T create a new one
            if original_video:
                original_video["segmentation_done"] = True
                original_video["segmentation_progress"] = 100
                original_video["segment_count"] = len(job["segments"])
                original_video["languages"] = ["en"]
                logging.info(
                    "✅ Updated video %s with job results", original_video.get("name")
                )
            else:
                logging.warning("⚠️ No original video found for job %s", job_id)
        save_state()


def generate_video_thumbnail(video_path, thumbnail_path, time_offset=1.0):
    """
    Generate a thumbnail from a video file using ffmpeg.
    Returns True if successful, False otherwise.
    """
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        cmd = [
            "ffmpeg",
            "-i",
            video_path,
            "-ss",
            str(time_offset),
            "-vframes",
            "1",
            "-vf",
            "scale=320:-1",
            "-q:v",
            "2",
            "-y",
            thumbnail_path,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        )
        if result.returncode == 0 and os.path.exists(thumbnail_path):
            return True
        logging.warning("FFmpeg failed: %s", result.stderr)
        return False
    except subprocess.TimeoutExpired:
        logging.warning("FFmpeg timeout generating thumbnail")
        return False
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logging.warning("FFmpeg error: %s", e)
        return False


def get_video_metadata(video_path):
    """
    Extract video metadata using ffprobe.
    Returns (duration, fps) or (120.0, 30.0) if failed.
    """
    try:
        cmd = [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=duration,r_frame_rate",
            "-of",
            "json",
            video_path,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=10, check=False
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            streams = data.get("streams", [])
            if streams:
                stream = streams[0]
                duration = float(stream.get("duration", 120.0))
                fps_str = stream.get("r_frame_rate", "30/1")
                if "/" in fps_str:
                    num, den = fps_str.split("/")
                    fps = float(num) / float(den) if float(den) > 0 else 30.0
                else:
                    fps = float(fps_str)
                return duration, fps
    except (
        subprocess.SubprocessError,
        FileNotFoundError,
        json.JSONDecodeError,
        TypeError,
        ValueError,
        OSError,
    ) as e:
        logging.warning("Failed to get video metadata: %s", e)
    return 120.0, 30.0


def curl_download(url, output_path, token):
    """
    Download a file using curl with authentication.
    Returns True if successful, False otherwise.
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
            "User-Agent: Mozilla/5.0 (compatible; LT-Uploader/1.0)",
            "--cookie",
            f"_forward_auth={token}",
            "-o",
            output_path,
            url,
        ]
        subprocess.run(cmd, capture_output=True, text=True, timeout=300, check=False)
        if os.path.exists(output_path) and os.path.getsize(output_path) > 1000:
            return True
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
    """
    Download a file using curl with additional headers for authentication.
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
            "-o",
            output_path,
            url,
        ]
        subprocess.run(cmd, capture_output=True, text=True, timeout=300, check=False)
        if os.path.exists(output_path) and os.path.getsize(output_path) > 1000:
            return True
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


def get_actual_file_url(session_id, filename, html_content=None):
    """
    Determine the correct URL for a file based on its type.
    """
    if html_content:
        if filename == "video.mp4":
            match = re.search(r'<source src="([^"]+)"', html_content)
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{INTERNAL_SERVER_URL}{url}"
                return url
        if filename.startswith("subtitles_") and filename.endswith(".vtt"):
            label = filename.replace("subtitles_", "").replace(".vtt", "")
            match = re.search(
                rf'<track label="{label}" kind="subtitles" src="([^"]+)"', html_content
            )
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{INTERNAL_SERVER_URL}{url}"
                return url
        if filename.endswith(".wav"):
            match = re.search(r'<source src="([^"]+)"[^>]*type="audio/', html_content)
            if match:
                url = match.group(1)
                if url.startswith("/"):
                    url = f"{INTERNAL_SERVER_URL}{url}"
                return url
    if filename == "messages.json":
        return f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
    if filename.endswith(".vtt"):
        label = filename.replace(".vtt", "")
        return f"{INTERNAL_SERVER_URL}/archivemedia/{session_id}/vtt/{label}"
    if filename == "video.mp4":
        return f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/video.mp4"
    if filename.endswith(".wav"):
        encoded_name = filename.replace(" ", "%20")
        return f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/{encoded_name}"
    encoded_name = filename.replace(" ", "%20")
    return f"{INTERNAL_SERVER_URL}/archivesession/{session_id}/{encoded_name}"


def download_session_files(session_id, token):
    """
    Download all files from a session using curl with correct URLs.
    """
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    os.makedirs(session_dir, exist_ok=True)

    logging.info("=" * 60)
    logging.info("Downloading session %s", session_id)

    html_path = os.path.join(session_dir, "index.html")
    html_url = f"{INTERNAL_SERVER_URL}/archivesession/{session_id}"

    if curl_download(html_url, html_path, token):
        logging.info("Downloaded index.html")
    else:
        logging.warning("Failed to download index.html")
        return False

    html_content = ""
    try:
        with open(html_path, "r", encoding="utf-8") as f:
            html_content = f.read()
    except (OSError, UnicodeDecodeError):
        pass

    video_url = get_actual_file_url(session_id, "video.mp4", html_content)
    video_path = os.path.join(session_dir, "video.mp4")
    if curl_download(video_url, video_path, token):
        logging.info("Downloaded video.mp4")
    else:
        logging.warning("Failed to download video.mp4")

    try:
        track_matches = re.findall(
            r'<track label="([^"]+)" kind="subtitles" src="([^"]+)"', html_content
        )
        for label, src in track_matches:
            if src.startswith("/"):
                src = f"{INTERNAL_SERVER_URL}{src}"
            file_name = f"subtitles_{label}.vtt"
            file_path = os.path.join(session_dir, file_name)
            if curl_download(src, file_path, token):
                logging.info("Downloaded %s", file_name)
    except (OSError, re.error) as e:
        logging.warning("Could not download subtitles: %s", e)

    try:
        audio_match = re.search(r'<source src="([^"]+)"[^>]*type="audio/', html_content)
        if audio_match:
            audio_url = audio_match.group(1)
            if audio_url.startswith("/"):
                audio_url = f"{INTERNAL_SERVER_URL}{audio_url}"
            audio_path = os.path.join(session_dir, "audio.wav")
            if curl_download(audio_url, audio_path, token):
                logging.info("Downloaded audio.wav")
    except (OSError, re.error) as e:
        logging.warning("Could not download audio: %s", e)

    messages_url = f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
    messages_path = os.path.join(session_dir, "messages.json")
    if curl_download(messages_url, messages_path, token):
        logging.info(
            "Downloaded messages.json (%d bytes)", os.path.getsize(messages_path)
        )
    else:
        logging.warning("Failed to download messages.json")

    transcripts = extract_transcripts_from_messages(messages_path)
    if transcripts:
        save_transcripts_to_files(session_dir, transcripts)
        logging.info("Extracted %d transcripts from messages.json", len(transcripts))
    else:
        logging.warning("No transcripts extracted from messages.json")

    files = [
        f
        for f in os.listdir(session_dir)
        if os.path.isfile(os.path.join(session_dir, f))
        and os.path.getsize(os.path.join(session_dir, f)) > 1000
    ]

    logging.info("=" * 60)
    logging.info("Session %s: Downloaded %s files total", session_id, len(files))
    for f in files:
        size = os.path.getsize(os.path.join(session_dir, f))
        logging.info("  - %s (%d bytes)", f, size)
    logging.info("=" * 60)

    return len(files) > 0


def safe_float(value, default=0.0):
    """Safely convert a value to float, handling strings and None."""
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


def _format_vtt_timestamp(seconds):
    """Format seconds to VTT timestamp format: HH:MM:SS.mmm"""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds % 1) * 1000)

    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def extract_transcripts_from_messages(messages_path):
    """Extract transcripts from messages.json file with proper structure handling."""
    if not os.path.exists(messages_path) or os.path.getsize(messages_path) < 100:
        return []

    try:
        with open(messages_path, "r", encoding="utf-8") as f:
            messages_data = json.load(f)

        transcripts = []
        language_map = {}
        numeric_language_map = {}

        if isinstance(messages_data, list):
            for item in messages_data:
                if isinstance(item, list) and len(item) >= 2:
                    lang_id = item[0]
                    msg_str = item[1]
                    try:
                        if isinstance(msg_str, str):
                            msg_data = json.loads(msg_str)
                        elif isinstance(msg_str, dict):
                            msg_data = msg_str
                        else:
                            continue
                    except (json.JSONDecodeError, TypeError):
                        continue

                    if isinstance(msg_data, dict) and "sender" in msg_data:
                        sender = msg_data.get("sender", "")
                        lang_name = extract_language_from_sender(
                            sender, lang_id, numeric_language_map
                        )
                        if lang_id not in numeric_language_map:
                            numeric_language_map[lang_id] = lang_name
                        language_map[sender] = lang_name

        if isinstance(messages_data, list):
            for item in messages_data:
                if isinstance(item, list) and len(item) >= 2:
                    lang_id = item[0]
                    msg_str = item[1]

                    try:
                        if isinstance(msg_str, str):
                            msg_data = json.loads(msg_str)
                        elif isinstance(msg_str, dict):
                            msg_data = msg_str
                        else:
                            continue
                    except (json.JSONDecodeError, TypeError):
                        continue

                    if isinstance(msg_data, dict) and "seq" in msg_data:
                        sender = msg_data.get("sender", "")
                        text = msg_data.get("seq", "").strip()

                        if not text:
                            continue

                        if sender in language_map:
                            lang_name = language_map[sender]
                        elif lang_id in numeric_language_map:
                            lang_name = numeric_language_map[lang_id]
                        else:
                            lang_name = get_language_name_from_sender(sender, lang_id)

                        existing = next(
                            (t for t in transcripts if t.get("language") == lang_name),
                            None,
                        )

                        start_val = msg_data.get("start", 0)
                        end_val = msg_data.get("end", 0)
                        try:
                            start_float = (
                                float(start_val) if start_val is not None else 0.0
                            )
                        except (ValueError, TypeError):
                            start_float = 0.0
                        try:
                            end_float = float(end_val) if end_val is not None else 0.0
                        except (ValueError, TypeError):
                            end_float = 0.0

                        segment_data = {
                            "text": text,
                            "start": start_float,
                            "end": end_float,
                            "sender": sender,
                            "markup": msg_data.get("markup"),
                            "words": msg_data.get("words"),
                            "word_id": msg_data.get("word_id"),
                            "source_tokens": msg_data.get("sourceTokens"),
                            "speaker_name": msg_data.get("speakerName"),
                            "refined_sentence_cluster": msg_data.get(
                                "refined_sentence_cluster"
                            ),
                            "unstable": msg_data.get("unstable", False),
                            "message_id": msg_data.get("message_id"),
                        }

                        if existing:
                            existing["text"] += "\n" + text
                            if "segments" not in existing:
                                existing["segments"] = []
                            existing["segments"].append(segment_data)
                        else:
                            transcripts.append(
                                {
                                    "language": lang_name,
                                    "source_file": f"lang_{lang_id}",
                                    "text": text,
                                    "sender": sender,
                                    "segments": [segment_data],
                                }
                            )

        organized_transcripts = organize_transcripts(transcripts)
        return organized_transcripts

    except json.JSONDecodeError as e:
        logging.warning("Could not parse messages.json: %s", e)
    except (OSError, KeyError, TypeError, AttributeError) as e:
        logging.warning("Could not extract transcripts from messages.json: %s", e)

    return []


def extract_language_from_sender(sender, lang_id, numeric_language_map):
    """Extract language name from sender using dynamic mapping."""
    if lang_id in numeric_language_map:
        return numeric_language_map[lang_id]

    if sender.startswith("asr:"):
        num_id = sender.replace("asr:", "")
        if num_id in numeric_language_map:
            return numeric_language_map[num_id]
        return f"Transcript (Original ASR - Language {lang_id})"

    if sender.startswith("mt:"):
        num_id = sender.replace("mt:", "")
        if num_id in numeric_language_map:
            return f"{numeric_language_map[num_id]} Translation"
        return f"Translation (Language {lang_id})"

    if sender.startswith("textstructurer:0_"):
        lang_code = sender.replace("textstructurer:0_", "")
        language_names = {
            "en": "English",
            "de": "German",
            "fr": "French",
            "es": "Spanish",
            "it": "Italian",
            "pt": "Portuguese",
            "nl": "Dutch",
            "ru": "Russian",
            "ja": "Japanese",
            "ko": "Korean",
            "zh": "Chinese",
            "ar": "Arabic",
            "hi": "Hindi",
            "pl": "Polish",
            "tr": "Turkish",
            "uk": "Ukrainian",
            "vi": "Vietnamese",
            "th": "Thai",
            "id": "Indonesian",
            "ms": "Malay",
        }
        if lang_code in language_names:
            return f"Transcript (Structured - {language_names[lang_code]})"
        return f"Transcript (Structured - {lang_code})"

    if sender.startswith("saasr"):
        return f"Transcript (SAASR - Language {lang_id})"

    language_names = {
        "en": "English",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "it": "Italian",
        "pt": "Portuguese",
        "nl": "Dutch",
        "ru": "Russian",
        "ja": "Japanese",
        "ko": "Korean",
        "zh": "Chinese",
        "ar": "Arabic",
        "hi": "Hindi",
        "pl": "Polish",
        "tr": "Turkish",
        "uk": "Ukrainian",
        "vi": "Vietnamese",
        "th": "Thai",
        "id": "Indonesian",
        "ms": "Malay",
    }
    for code, name in language_names.items():
        if f"_{code}" in sender or f":{code}" in sender:
            return f"Transcript ({name})"

    return f"Transcript (Language {lang_id})"


def get_language_name_from_sender(sender, lang_id):
    """Get a human-readable language name from sender string (fallback)."""
    if not sender:
        return f"Language {lang_id}"

    language_names = {
        "en": "English",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "it": "Italian",
        "pt": "Portuguese",
        "nl": "Dutch",
        "ru": "Russian",
        "ja": "Japanese",
        "ko": "Korean",
        "zh": "Chinese",
        "ar": "Arabic",
        "hi": "Hindi",
        "pl": "Polish",
        "tr": "Turkish",
        "uk": "Ukrainian",
        "vi": "Vietnamese",
        "th": "Thai",
        "id": "Indonesian",
        "ms": "Malay",
    }

    if sender.startswith("asr:"):
        return f"Transcript (Original ASR - Language {lang_id})"
    if sender.startswith("mt:"):
        return f"Translation (Language {lang_id})"
    if sender.startswith("textstructurer:0_"):
        lang_code = sender.replace("textstructurer:0_", "")
        if lang_code in language_names:
            return f"Transcript (Structured - {language_names[lang_code]})"
        return f"Transcript (Structured - {lang_code})"
    if sender.startswith("saasr"):
        return f"Transcript (SAASR - Language {lang_id})"
    for code, name in language_names.items():
        if f"_{code}" in sender or f":{code}" in sender:
            return f"Transcript ({name})"
    return f"Transcript (Language {lang_id})"


def organize_transcripts(transcripts):
    """Organize transcripts by language, combining related messages."""
    organized = {}

    for t in transcripts:
        lang = t.get("language", "Unknown")
        if lang not in organized:
            organized[lang] = {
                "language": lang,
                "text": "",
                "source_file": t.get("source_file", ""),
                "sender": t.get("sender", ""),
                "segments": [],
                "chapters": [],
                "summaries": [],
                "post_edited": [],
                "notes": [],
                "global_summaries": [],
                "speakers": {},
                "paragraph_breaks": [],
            }
        if organized[lang]["text"]:
            organized[lang]["text"] += "\n"
        organized[lang]["text"] += t.get("text", "")

        if "segments" in t:
            organized[lang]["segments"].extend(t.get("segments", []))

    for lang, transcript in organized.items():
        if "segments" in transcript:
            transcript["segments"].sort(key=lambda x: safe_float(x.get("start", 0)))

    result = list(organized.values())

    def sort_key(item):
        lang = item.get("language", "")
        if "Original" in lang:
            return 0
        if "Structured" in lang:
            return 1
        if "Translation" in lang:
            return 2
        return 3

    result.sort(key=sort_key)
    return result


def save_transcripts_to_files(session_dir, transcripts):
    """Save transcripts to JSON and TXT files."""
    if not transcripts:
        return

    json_path = os.path.join(session_dir, "transcripts.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(transcripts, f, ensure_ascii=False, indent=2)
    logging.info("Saved transcripts to %s", json_path)

    txt_path = os.path.join(session_dir, "transcript.txt")
    with open(txt_path, "w", encoding="utf-8") as f:
        for t in transcripts:
            f.write(f"{'=' * 60}\n")
            f.write(f"Language: {t.get('language', 'Unknown')}\n")
            f.write(f"{'=' * 60}\n\n")
            segments = t.get("segments", [])
            segments.sort(key=lambda x: safe_float(x.get("start", 0)))
            for seg in segments:
                start = safe_float(seg.get("start", 0))
                end = safe_float(seg.get("end", 0))
                sender = seg.get("sender", "")
                text = seg.get("text", "")
                msg_markup = seg.get("markup", "")
                # Skip empty segments but don't skip based on <br> tags
                if not text or not text.strip():
                    continue
                if msg_markup:
                    f.write(
                        f"[{start:.1f}s - {end:.1f}s] [{sender}] [{msg_markup}] {text}\n"
                    )
                else:
                    f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
            f.write("\n")
    logging.info("Saved plain text to %s", txt_path)


def extract_structured_data_from_session(session_dir, language_filter=None):
    """
    Extract fully structured data from a session matching the window view.
    """
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return None

    with open(json_path, "r", encoding="utf-8") as f:
        all_transcripts = json.load(f)

    if language_filter:
        transcripts = [
            t for t in all_transcripts if t.get("language") == language_filter
        ]
    else:
        transcripts = all_transcripts

    messages_path = os.path.join(session_dir, "messages.json")
    structured_messages = []
    if os.path.exists(messages_path):
        try:
            with open(messages_path, "r", encoding="utf-8") as f:
                messages_data = json.load(f)
            if isinstance(messages_data, list):
                for item in messages_data:
                    if isinstance(item, list) and len(item) >= 2:
                        try:
                            msg_data = (
                                json.loads(item[1])
                                if isinstance(item[1], str)
                                else item[1]
                            )
                            if isinstance(msg_data, dict):
                                structured_messages.append(msg_data)
                        except (json.JSONDecodeError, TypeError):
                            pass
        except (json.JSONDecodeError, TypeError, OSError):
            pass

    structured_data = {
        "transcripts": [],
        "chapters": [],
        "summaries": [],
        "speakers": {},
        "post_edited": [],
        "notes": [],
        "global_summaries": [],
        "paragraph_breaks": [],
    }

    for t in transcripts:
        transcript_entry = {
            "language": t.get("language", "Unknown"),
            "text": t.get("text", ""),
            "segments": sorted(
                t.get("segments", []), key=lambda x: safe_float(x.get("start", 0))
            ),
            "sender": t.get("sender", ""),
        }
        structured_data["transcripts"].append(transcript_entry)

    chapter_stack = []
    for msg in sorted(structured_messages, key=lambda x: safe_float(x.get("start", 0))):
        markup = msg.get("markup")
        sender = msg.get("sender", "")
        seq = msg.get("seq", "")
        start = safe_float(msg.get("start", 0))
        end = safe_float(msg.get("end", 0))

        if markup == "chapterBreak":
            chapter = {
                "start": start,
                "end": end,
                "index": len(structured_data["chapters"]),
                "heading": "",
                "segments": [],
            }
            structured_data["chapters"].append(chapter)
            chapter_stack.append(chapter)

        elif markup == "heading" and chapter_stack:
            chapter_stack[-1]["heading"] = seq

        elif markup == "paragraphBreak":
            structured_data["paragraph_breaks"].append({"start": start, "end": end})

        elif markup == "summary":
            structured_data["summaries"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "sender": sender,
                }
            )

        elif markup == "postedited":
            compression_rate = "90"
            if ":" in sender:
                parts = sender.split(":")
                if len(parts) > 1 and "_" in parts[1]:
                    compression_rate = parts[1].split("_")[0]
            structured_data["post_edited"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "compression_rate": compression_rate,
                    "sender": sender,
                }
            )

        elif markup == "notes":
            structured_data["notes"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "nested_level": msg.get("nested_level", 0),
                    "chapter_index": msg.get("chapter_index", 0),
                }
            )

        elif markup == "global_summary":
            structured_data["global_summaries"].append(
                {
                    "text": seq,
                    "sender": sender,
                }
            )

        if "refined_sentence_cluster" in msg:
            speaker = msg.get("refined_sentence_cluster")
            if speaker:
                if speaker.startswith("unk-"):
                    speaker = f"Anonymous-{speaker.split('-')[1]}"
                structured_data["speakers"][speaker] = {
                    "name": speaker,
                    "last_seen": datetime.datetime.now().isoformat(),
                }

    for transcript in structured_data["transcripts"]:
        for seg in transcript.get("segments", []):
            seg_start = safe_float(seg.get("start", 0))
            for ch in structured_data["chapters"]:
                ch_start = safe_float(ch.get("start", 0))
                ch_end = safe_float(ch.get("end", 0))
                if ch_start <= seg_start < ch_end or (
                    ch == structured_data["chapters"][-1] and seg_start >= ch_start
                ):
                    if "segments" not in ch:
                        ch["segments"] = []
                    ch["segments"].append(seg)
                    break

    return structured_data


# ─── HELPER FUNCTIONS FOR EXPORT ──────────────────────────────────────


def clean_html_tags(text):
    """Remove HTML tags only, preserve everything else including music notes."""
    if not text:
        return ""
    # Remove HTML tags only (replace with space)
    clean = re.sub(r"<[^>]+>", " ", text)
    # Remove multiple spaces (but keep single spaces)
    clean = re.sub(r"\s+", " ", clean)
    # Trim leading/trailing spaces
    return clean.strip()


def escape_rtf(text):
    """Escape special characters for RTF format, preserving Unicode characters."""
    if not text:
        return ""
    # Escape backslashes and braces
    escaped = text.replace("\\", "\\\\")
    escaped = escaped.replace("{", "\\{")
    escaped = escaped.replace("}", "\\}")
    # Handle Unicode characters (preserve them)
    result = []
    for char in escaped:
        code = ord(char)
        if code > 127:
            result.append(f"\\u{code}?")
        else:
            result.append(char)
    return "".join(result)


def get_paragraph_number(sender):
    """
    Convert textstructurer: tags to sequential paragraph numbers.
    Only textstructurer: tags get numbers.
    """
    if not sender:
        return 0

    # Only textstructurer gets paragraph numbers
    if sender.startswith("textstructurer:"):
        if ":" in sender:
            parts = sender.split(":")
            if len(parts) >= 2:
                second_part = parts[1]
                match = re.search(r"^(\d+)", second_part)
                if match:
                    return int(match.group(1)) + 1
    return 0


def is_asr_or_mt(sender):
    """Check if sender is ASR or MT type."""
    if not sender:
        return False
    return (
        sender.startswith("asr:")
        or sender.startswith("mt:")
        or sender.startswith("translation:")
    )


def is_textstructurer(sender):
    """Check if sender is textstructurer type."""
    if not sender:
        return False
    return sender.startswith("textstructurer:")


def is_summarizer(sender):
    """Check if sender is summarizer type."""
    if not sender:
        return False
    return sender.startswith("summarizer:")


def format_sender_for_export(sender):
    """
    Format sender tag for export:
    - textstructurer: -> [1], [2], [3] (paragraph numbers)
    - asr: and mt: -> plain text (no marker)
    - Other senders -> [sender]
    """
    if not sender:
        return ""

    # textstructurer gets paragraph numbers
    if is_textstructurer(sender):
        num = get_paragraph_number(sender)
        if num > 0:
            return f"[{num}]"

    # asr and mt are plain text - return nothing (they're just markers)
    if is_asr_or_mt(sender):
        return ""

    # Other senders (summarizer, etc.) keep their name
    if is_summarizer(sender):
        return f"[{sender}]"

    return f"[{sender}]"


def format_text_for_export(text, sender):
    """
    Format text based on sender type:
    - textstructurer: -> keep as is (paragraph text)
    - summarizer: -> format with "Summary:" prefix
    - asr: / mt: -> plain text
    """
    clean_text = clean_html_tags(text)
    if not clean_text:
        return ""

    # Summarizer gets special formatting
    if is_summarizer(sender):
        return f"Summary: {clean_text}"

    # textstructurer is paragraph text
    if is_textstructurer(sender):
        return clean_text

    # asr and mt are plain text
    return clean_text


def extract_lang_code(language_name):
    """Extract language code from language name."""
    if not language_name:
        return None
    for code in [
        "en",
        "de",
        "fr",
        "es",
        "it",
        "pt",
        "nl",
        "ru",
        "ja",
        "ko",
        "zh",
        "ar",
        "hi",
        "pl",
        "tr",
        "uk",
        "vi",
        "th",
        "id",
        "ms",
    ]:
        if f"({code})" in language_name or f" - {code}" in language_name:
            return code
    return None


def filter_summaries_by_language(summaries, lang_code):
    """Filter summaries by language code."""
    if not lang_code:
        return summaries
    filtered = []
    for s in summaries:
        sender = s.get("sender", "")
        if f"_{lang_code}" in sender:
            filtered.append(s)
    return filtered if filtered else summaries


def format_structured_text(structured_data, language_filter=None):
    """Format structured data to match the website view, preserving music notes."""
    if not structured_data:
        return "No structured data available."

    lines = []

    # Get the language-specific data
    transcripts_data = structured_data.get("transcripts", [])

    # If we have a language filter, find the specific transcript
    selected_transcript = None
    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        # No filter - use first transcript
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code for filename
    lang_code = None
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents (only if chapters exist)
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        lines.append("TABLE OF CONTENTS")
        lines.append("-" * 40)
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                lines.append(f"  {idx}. {heading}")
            else:
                lines.append(f"  {idx}. Chapter {idx}")
        lines.append("")

    # Transcript with chapters
    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    # Track paragraph numbering for textstructurer
    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                lines.append(f"--- Chapter {idx}: {heading} ---")
            else:
                lines.append(f"--- Chapter {idx} ---")

            segments = ch.get("segments", [])
            current_sender = None
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                # Only clean HTML tags, preserve everything else
                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                # For textstructurer: show as paragraph with number
                if is_textstructurer(sender):
                    paragraph_counter += 1
                    lines.append(f"[{paragraph_counter}]")
                    lines.append(clean_text)
                    lines.append("")  # Single blank line between paragraphs
                # For asr and mt: show as plain text (no marker)
                elif is_asr_or_mt(sender):
                    if clean_text:
                        lines.append(clean_text)
                # For summarizer: show with "Summary:" prefix
                elif is_summarizer(sender):
                    lines.append(f"Summary: {clean_text}")
                # For other senders: show with sender name
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        lines.append(f"[{sender}]")
                    lines.append(clean_text)

            if not has_content:
                lines.append("(No content yet)")

            lines.append("")  # Single blank line between chapters
    else:
        # No chapters - show all transcripts
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            lines.append(f"--- {lang} ---")
            segments = selected_transcript.get("segments", [])
            current_sender = None

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    lines.append(f"[{paragraph_counter}]")
                    lines.append(clean_text)
                    lines.append("")
                elif is_asr_or_mt(sender):
                    if clean_text:
                        lines.append(clean_text)
                elif is_summarizer(sender):
                    lines.append(f"Summary: {clean_text}")
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        lines.append(f"[{sender}]")
                    lines.append(clean_text)

    # Summaries (filtered by language) - formatted differently
    if filtered_summaries:
        lines.append("=" * 60)
        lines.append("SUMMARIES")
        lines.append("-" * 40)
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            lines.append(f"  📋 {text}")
        lines.append("")

    # Global Summaries (filtered by language) - formatted differently
    if filtered_global_summaries:
        lines.append("=" * 60)
        lines.append("GLOBAL SUMMARIES")
        lines.append("-" * 40)
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            lines.append(f"  🌐 {text}")
        lines.append("")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        lines.append("=" * 60)
        lines.append("POST-EDITED CONTENT")
        lines.append("-" * 40)
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            lines.append(f"  [Compression: {rate}%] {text}")
        lines.append("")

    # Remove trailing empty lines and join with single newlines
    return "\n".join(lines).strip()


def export_structured_txt(session_id, session_dir, language_filter=None):
    """Export structured data as plain text matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        return io.BytesIO(b"No structured data available.")

    text = format_structured_text(structured_data, language_filter)

    header = "=" * 80 + "\n"
    header += f"SESSION: {session_id}\n"
    if language_filter:
        header += f"FILTER: {language_filter}\n"
    header += f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    header += "=" * 80 + "\n\n"

    return io.BytesIO((header + text).encode("utf-8"))


def export_structured_docx(session_id, session_dir, language_filter=None):
    """Export session data as DOCX matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        doc = Document()
        doc.add_heading("No structured data available", 1)
        return io.BytesIO()

    doc = Document()

    title = f"Session: {session_id}"
    if language_filter:
        title += f" - {language_filter}"
    doc.add_heading(title, 0)

    doc.add_paragraph(f"Session ID: {session_id}")
    doc.add_paragraph(
        f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    )
    doc.add_paragraph("")

    # Get language-specific data
    transcripts_data = structured_data.get("transcripts", [])
    selected_transcript = None
    lang_code = None

    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        doc.add_heading("Table of Contents", level=1)
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            p = doc.add_paragraph()
            p.add_run(f"{idx}. ").bold = True
            if heading:
                p.add_run(f"{heading}")
            else:
                p.add_run(f"Chapter {idx}")
        doc.add_paragraph("")

    # Transcripts with chapters
    doc.add_heading("Transcript", level=1)

    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                doc.add_heading(f"Chapter {idx}: {heading}", level=2)
            else:
                doc.add_heading(f"Chapter {idx}", level=2)

            segments = ch.get("segments", [])
            current_sender = None
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                if not text or not text.strip():
                    continue

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                # textstructurer: paragraph with number
                if is_textstructurer(sender):
                    paragraph_counter += 1
                    p = doc.add_paragraph()
                    run = p.add_run(f"[{paragraph_counter}]")
                    run.bold = True
                    run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)

                # asr and mt: plain text (no marker)
                elif is_asr_or_mt(sender):
                    p = doc.add_paragraph()
                    p.add_run(clean_text)

                # summarizer: with "Summary:" prefix
                elif is_summarizer(sender):
                    p = doc.add_paragraph()
                    run = p.add_run("Summary: ")
                    run.bold = True
                    run.font.color.rgb = RGBColor(255, 165, 0)  # Orange
                    p.add_run(clean_text)

                # other senders
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        p = doc.add_paragraph()
                        run = p.add_run(f"[{sender}]")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)

                    p = doc.add_paragraph()
                    p.add_run(clean_text)

            if not has_content:
                p = doc.add_paragraph()
                p.add_run("(No content yet)")
                p.italic = True
                p.font.size = Pt(10)

            doc.add_paragraph("")
    else:
        # No chapters - show selected transcript
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            doc.add_heading(lang, level=2)
            segments = selected_transcript.get("segments", [])
            current_sender = None
            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                if not text or not text.strip():
                    continue

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    p = doc.add_paragraph()
                    run = p.add_run(f"[{paragraph_counter}]")
                    run.bold = True
                    run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)
                elif is_asr_or_mt(sender):
                    p = doc.add_paragraph()
                    p.add_run(clean_text)
                elif is_summarizer(sender):
                    p = doc.add_paragraph()
                    run = p.add_run("Summary: ")
                    run.bold = True
                    run.font.color.rgb = RGBColor(255, 165, 0)
                    p.add_run(clean_text)
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        p = doc.add_paragraph()
                        run = p.add_run(f"[{sender}]")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)

                    p = doc.add_paragraph()
                    p.add_run(clean_text)
            doc.add_paragraph("")

    # Summaries (filtered by language) - formatted with special style
    if filtered_summaries:
        doc.add_heading("Summaries", level=1)
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            p = doc.add_paragraph()
            p.add_run("📋 ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    # Global Summaries (filtered by language)
    if filtered_global_summaries:
        doc.add_heading("Global Summaries", level=1)
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            p = doc.add_paragraph()
            p.add_run("🌐 ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        doc.add_heading("Post-Edited Content", level=1)
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            p = doc.add_paragraph()
            p.add_run(f"[Compression: {rate}%] ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    doc_buffer = io.BytesIO()
    doc.save(doc_buffer)
    doc_buffer.seek(0)
    return doc_buffer


def export_structured_rtf(session_id, session_dir, language_filter=None):
    """Export structured data as RTF matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        return io.BytesIO(b"{\\rtf1\\ansi No structured data available.}")

    rtf_parts = [
        r"{\rtf1\ansi\deff0",
        r"{\fonttbl{\f0\fnil\fcharset0 Arial;}}",
        r"\f0\fs24",
        r"\b\fs32 Session: " + session_id + r"\b0\par\par",
    ]

    if language_filter:
        rtf_parts.append(r"\b\fs28 Filter: " + language_filter + r"\b0\par\par")

    rtf_parts.append(
        r"\b\fs28 Export Date: "
        + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        + r"\b0\par\par"
    )

    # Get language-specific data
    transcripts_data = structured_data.get("transcripts", [])
    selected_transcript = None
    lang_code = None

    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        rtf_parts.append(r"\b\fs26 Table of Contents\b0\par")
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            text = f"{idx}. "
            if heading:
                text += f"{heading}"
            else:
                text += f"Chapter {idx}"
            rtf_parts.append(r"\bullet " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Transcripts with chapters
    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                rtf_parts.append(
                    r"\b\fs24 Chapter "
                    + str(idx)
                    + ": "
                    + escape_rtf(heading)
                    + r"\b0\par"
                )
            else:
                rtf_parts.append(r"\b\fs24 Chapter " + str(idx) + r"\b0\par")

            segments = ch.get("segments", [])
            current_sender = None
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    rtf_parts.append(
                        r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par"
                    )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_asr_or_mt(sender):
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_summarizer(sender):
                    rtf_parts.append(
                        r"\b "
                        + "Summary: "
                        + r"\b0 "
                        + escape_rtf(clean_text)
                        + r"\par"
                    )
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        rtf_parts.append(
                            r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par"
                        )

                    rtf_parts.append(escape_rtf(clean_text) + r"\par")

            if not has_content:
                rtf_parts.append(r"\i (No content yet)\i0\par")

            rtf_parts.append(r"\par")
    else:
        # No chapters - show selected transcript
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            rtf_parts.append(r"\b\fs24 " + escape_rtf(lang) + r"\b0\par")
            segments = selected_transcript.get("segments", [])
            current_sender = None
            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    rtf_parts.append(
                        r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par"
                    )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_asr_or_mt(sender):
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_summarizer(sender):
                    rtf_parts.append(
                        r"\b "
                        + "Summary: "
                        + r"\b0 "
                        + escape_rtf(clean_text)
                        + r"\par"
                    )
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        rtf_parts.append(
                            r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par"
                        )

                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
            rtf_parts.append(r"\par")

    # Summaries (filtered by language) - formatted with special style
    if filtered_summaries:
        rtf_parts.append(r"\b\fs26 Summaries\b0\par")
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            if text:
                rtf_parts.append(r"\b " + "📋 " + r"\b0 " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Global Summaries (filtered by language)
    if filtered_global_summaries:
        rtf_parts.append(r"\b\fs26 Global Summaries\b0\par")
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            if text:
                rtf_parts.append(r"\b " + "🌐 " + r"\b0 " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        rtf_parts.append(r"\b\fs26 Post-Edited Content\b0\par")
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            if text:
                rtf_parts.append(
                    r"\b [Compression: "
                    + str(rate)
                    + r"%]\b0 "
                    + escape_rtf(text)
                    + r"\par"
                )
        rtf_parts.append(r"\par")

    rtf_parts.append("}")
    return io.BytesIO("".join(rtf_parts).encode("utf-8"))


def _resolve_export_language_name(session_dir, language):
    """Return the transcript language label for export filenames."""
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return "transcript"

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
    except (OSError, ValueError, TypeError):
        return "transcript"

    if not transcripts:
        return "transcript"

    if language:
        for transcript in transcripts:
            lang = str(transcript.get("language", "")).strip()
            if not lang:
                continue
            if lang == language or language.lower() in lang.lower():
                return lang

    first_lang = transcripts[0].get("language", "transcript")
    return first_lang if first_lang else "transcript"


@app.route("/session_export_txt/<session_id>", methods=["GET"])
def session_export_txt(session_id):
    """Export all session data as structured plain text matching the window view."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.txt"

    txt_buffer = export_structured_txt(session_id, session_dir, language)

    return send_file(
        txt_buffer,
        mimetype="text/plain",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session_export_docx/<session_id>", methods=["GET"])
def session_export_docx(session_id):
    """Export session as a structured DOCX file matching the window view."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.docx"

    try:
        doc_buffer = export_structured_docx(session_id, session_dir, language)
    except ImportError:
        return (
            jsonify(
                {
                    "error": "python-docx not installed. "
                    "Please install: pip install python-docx"
                }
            ),
            500,
        )

    return send_file(
        doc_buffer,
        mimetype="application/vnd.openxmlformats-officedocument"
        ".wordprocessingml.document",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session_export_rtf/<session_id>", methods=["GET"])
def session_export_rtf(session_id):
    """Export all session data as a structured RTF document."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.rtf"

    rtf_buffer = export_structured_rtf(session_id, session_dir, language)

    return send_file(
        rtf_buffer,
        mimetype="text/rtf",
        as_attachment=True,
        download_name=filename,
    )


def get_available_languages(session_dir):
    """Get list of available languages from transcripts.json."""
    json_path = os.path.join(session_dir, "transcripts.json")
    languages = []

    if os.path.exists(json_path):
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
        languages = list(set(t.get("language", "Unknown") for t in transcripts))
        languages.sort()

    return languages


# ─── EXPORT ROUTES ─────────────────────────────────────────────────────


@app.route("/session_export/<session_id>", methods=["GET"])
def session_export(session_id):
    """Export all session data as a formatted DOCX document."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")

    try:
        doc_buffer = export_structured_docx(session_id, session_dir, language)
    except ImportError:
        return (
            jsonify(
                {
                    "error": "python-docx not installed. "
                    "Please install: pip install python-docx"
                }
            ),
            500,
        )

    filename = f"session_{session_id}"
    if language:
        clean_lang = language.replace(" ", "_").replace("(", "").replace(")", "")
        filename = f"session_{session_id}_{clean_lang}"

    return send_file(
        doc_buffer,
        mimetype="application/vnd.openxmlformats-officedocument"
        ".wordprocessingml.document",
        as_attachment=True,
        download_name=f"{filename}.docx",
    )


@app.route("/session_export_structured_json/<session_id>", methods=["GET"])
def session_export_structured_json(session_id):
    """Export session as structured JSON with all metadata."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")

    structured_data = extract_structured_data_from_session(session_dir, language)
    if not structured_data:
        return jsonify({"error": "No structured data available"}), 404

    json_str = json.dumps(structured_data, ensure_ascii=False, indent=2)

    # Get the actual language name from transcripts.json
    actual_lang_name = None
    json_path = os.path.join(session_dir, "transcripts.json")
    if os.path.exists(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)
            if transcripts:
                if language:
                    for t in transcripts:
                        lang = t.get("language", "")
                        if lang == language or language.lower() in lang.lower():
                            actual_lang_name = lang
                            break
                if not actual_lang_name:
                    actual_lang_name = transcripts[0].get("language", "transcript")
        except (OSError, TypeError, ValueError):
            actual_lang_name = "transcript"
    else:
        actual_lang_name = "transcript"

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.json"

    return send_file(
        io.BytesIO(json_str.encode("utf-8")),
        mimetype="application/json",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session_export_all_languages/<session_id>", methods=["GET"])
def session_export_all_languages(session_id):
    """Export all languages as separate files in a ZIP archive."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    export_format = request.args.get("format", "all").lower()

    languages = get_available_languages(session_dir)
    if not languages:
        return jsonify({"error": "No transcript data found"}), 404

    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zipf:
        for lang in languages:
            clean_lang = lang.replace(" ", "_").replace("(", "").replace(")", "")
            clean_lang = clean_lang.replace("/", "_").replace("\\", "_")
            if len(clean_lang) > 50:
                clean_lang = clean_lang[:50]

            formats_to_export = []
            if export_format == "all":
                formats_to_export = ["txt", "rtf", "docx", "json"]
            elif export_format in ["txt", "rtf", "docx", "json"]:
                formats_to_export = [export_format]
            else:
                formats_to_export = ["txt"]

            if "txt" in formats_to_export:
                txt_buffer = export_structured_txt(session_id, session_dir, lang)
                zipf.writestr(f"{clean_lang}.txt", txt_buffer.getvalue())

            if "rtf" in formats_to_export:
                rtf_buffer = export_structured_rtf(session_id, session_dir, lang)
                zipf.writestr(f"{clean_lang}.rtf", rtf_buffer.getvalue())

            if "docx" in formats_to_export:
                try:
                    doc_buffer = export_structured_docx(session_id, session_dir, lang)
                    zipf.writestr(f"{clean_lang}.docx", doc_buffer.getvalue())
                except ImportError:
                    logging.warning("python-docx not installed, skipping DOCX")

            if "json" in formats_to_export:
                structured_data = extract_structured_data_from_session(
                    session_dir, lang
                )
                if structured_data:
                    zipf.writestr(
                        f"{clean_lang}.json",
                        json.dumps(
                            structured_data, ensure_ascii=False, indent=2
                        ).encode("utf-8"),
                    )

    zip_buffer.seek(0)

    return send_file(
        zip_buffer,
        mimetype="application/zip",
        as_attachment=True,
        download_name="transcript_all_languages.zip",
    )


@app.route("/session_languages/<session_id>", methods=["GET"])
def session_languages(session_id):
    """Get list of available languages for a session."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    languages = get_available_languages(session_dir)
    return jsonify({"languages": languages}), 200


@app.route("/session_transcript_json/<session_id>", methods=["GET"])
def session_transcript_json(session_id):
    """Export session transcripts as JSON."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    json_path = os.path.join(session_dir, "transcripts.json")
    if os.path.exists(json_path):
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return jsonify(data), 200

    return jsonify({"error": "No transcript data found"}), 404


@app.route("/session_messages_json/<session_id>", methods=["GET"])
def session_messages_json(session_id):
    """Download the raw messages.json file from the session."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    if token:
        local_path = os.path.join(session_dir, "messages.json")
        if not os.path.exists(local_path) or os.path.getsize(local_path) < 1000:
            url = f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
            logging.info("Downloading messages.json from %s", url)
            if curl_download(url, local_path, token):
                logging.info("Successfully downloaded messages.json")

    json_path = os.path.join(session_dir, "messages.json")
    if os.path.exists(json_path) and os.path.getsize(json_path) > 1000:
        return send_file(
            json_path,
            as_attachment=True,
            download_name=f"messages_{session_id}.json",
            mimetype="application/json",
        )

    return jsonify({"error": "messages.json not found"}), 404


@app.route("/session_zip/<session_id>", methods=["GET"])
def download_session_zip(session_id):
    """Download all session files as a ZIP archive."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    if token:
        json_path = os.path.join(session_dir, "messages.json")
        if not os.path.exists(json_path) or os.path.getsize(json_path) < 1000:
            url = f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
            curl_download(url, json_path, token)

    zip_path = os.path.join(tempfile.gettempdir(), f"session_{session_id}.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, _, files in os.walk(session_dir):
            for file in files:
                file_path = os.path.join(root, file)
                if os.path.getsize(file_path) > 1000:
                    zipf.write(file_path, os.path.relpath(file_path, session_dir))

    return send_file(
        zip_path,
        as_attachment=True,
        download_name=f"session_{session_id}.zip",
        mimetype="application/zip",
    )


# In simple_flask_server.py - Update session_transcript_save_vtt


@app.route("/session_transcript_save_vtt/<session_id>", methods=["POST"])
def session_transcript_save_vtt(session_id):
    """
    Save transcript and update VTT file with proper naming.
    """
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Invalid JSON data"}), 400

        language = data.get("language")
        segments = data.get("segments", [])
        filename = data.get("filename")

        if not language:
            return jsonify({"error": "Language is required"}), 400

        if not segments:
            return jsonify({"error": "No segments provided"}), 400

        # Filter out summary/global_summary segments
        filtered_segments = []
        for seg in segments:
            if seg.get("start", 0) == 0 and seg.get("end", 0) == 0:
                continue
            markup = seg.get("markup")
            if markup in ["paragraphBreak", "chapterBreak", "heading"]:
                continue
            if not seg.get("text", "").strip():
                continue
            filtered_segments.append(seg)

        if not filtered_segments:
            return jsonify({"error": "No valid segments to save"}), 400

        # --- 1. Update transcripts.json ---
        json_path = os.path.join(session_dir, "transcripts.json")
        transcripts = []
        if os.path.exists(json_path):
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)

        updated = False
        for i, transcript in enumerate(transcripts):
            if transcript.get("language") == language:
                transcript["segments"] = filtered_segments
                transcript["text"] = " ".join(
                    [s.get("text", "") for s in filtered_segments]
                )
                transcripts[i] = transcript
                updated = True
                break

        if not updated:
            transcripts.append(
                {
                    "language": language,
                    "text": " ".join([s.get("text", "") for s in filtered_segments]),
                    "segments": filtered_segments,
                    "sender": (
                        filtered_segments[0].get("sender", "")
                        if filtered_segments
                        else ""
                    ),
                }
            )

        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(transcripts, f, ensure_ascii=False, indent=2)

        # --- 2. Determine the correct filename ---
        # If filename was provided and exists, use it
        if filename:
            vtt_filename = filename
        else:
            # Try to find an existing VTT file for this language
            existing_vtt = None

            # Extract simple language name
            simple_name = _extract_simple_language_name(language)

            # Look for existing VTT files
            for f in os.listdir(session_dir):
                if f.endswith(".vtt") and f != "subtitles.vtt":
                    # Check if this file matches our language
                    if (
                        simple_name in f
                        or language in f
                        or f.startswith(f"subtitles_{simple_name}")
                    ):
                        existing_vtt = f
                        break

            if existing_vtt:
                vtt_filename = existing_vtt
            else:
                # Create a new filename with simple name
                clean_lang = (
                    simple_name.replace(" ", "_").replace("(", "").replace(")", "")
                )
                vtt_filename = f"subtitles_{clean_lang}.vtt"

        # --- 3. Generate VTT content ---
        vtt_lines = ["WEBVTT", ""]
        cue_index = 0
        for seg in filtered_segments:
            start = safe_float(seg.get("start", 0))
            end = safe_float(seg.get("end", 0))
            text = seg.get("text", "")

            if not text or not text.strip():
                continue

            cue_index += 1
            start_time = _format_vtt_timestamp(start)
            end_time = _format_vtt_timestamp(end)

            vtt_lines.append(f"{cue_index}")
            vtt_lines.append(f"{start_time} --> {end_time}")

            speaker_name = seg.get("speakerName") or seg.get("speaker_name")
            if speaker_name and speaker_name.strip():
                vtt_lines.append(f"<v {speaker_name}>{text}</v>")
            else:
                vtt_lines.append(text)
            vtt_lines.append("")

        vtt_content = "\n".join(vtt_lines)

        # Save VTT file
        vtt_path = os.path.join(session_dir, vtt_filename)
        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write(vtt_content)

        # Also update subtitles.vtt for the main language
        if "Original ASR" in language or language.lower() in ["english", "en"]:
            generic_path = os.path.join(session_dir, "subtitles.vtt")
            with open(generic_path, "w", encoding="utf-8") as f:
                f.write(vtt_content)

        # --- 4. Update transcript.txt ---
        txt_path = os.path.join(session_dir, "transcript.txt")
        with open(txt_path, "w", encoding="utf-8") as f:
            for t in transcripts:
                f.write(f"{'=' * 60}\n")
                f.write(f"Language: {t.get('language', 'Unknown')}\n")
                f.write(f"{'=' * 60}\n\n")
                segs = t.get("segments", [])
                segs.sort(key=lambda x: safe_float(x.get("start", 0)))
                for seg in segs:
                    start = safe_float(seg.get("start", 0))
                    end = safe_float(seg.get("end", 0))
                    sender = seg.get("sender", "")
                    text = seg.get("text", "")
                    markup = seg.get("markup", "")
                    if not text or not text.strip():
                        continue
                    if markup:
                        f.write(
                            f"[{start:.1f}s - {end:.1f}s] [{sender}] [{markup}] {text}\n"
                        )
                    else:
                        f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
                f.write("\n")

        logging.info(
            "Saved transcript and updated VTT for language '%s' in session %s",
            language,
            session_id,
        )

        # Get the updated file list
        files = []
        for file in os.listdir(session_dir):
            file_path = os.path.join(session_dir, file)
            if os.path.isfile(file_path) and os.path.getsize(file_path) > 1000:
                mtime = os.path.getmtime(file_path)
                mod_time = datetime.datetime.fromtimestamp(mtime).isoformat()
                files.append(
                    {
                        "name": file,
                        "size": os.path.getsize(file_path),
                        "url": f"/session_file/{session_id}/{file}",
                        "modified": mod_time,
                    }
                )

        save_state()

        return (
            jsonify(
                {
                    "success": True,
                    "message": f"Transcript saved and VTT updated: {vtt_filename}",
                    "language": language,
                    "vtt_filename": vtt_filename,
                    "segments_count": len(filtered_segments),
                    "files": files,
                }
            ),
            200,
        )

    except json.JSONDecodeError as e:
        return jsonify({"error": f"Invalid JSON: {str(e)}"}), 400
    except (OSError, TypeError, KeyError) as e:
        logging.error("Error saving transcript: %s", e, exc_info=True)
        return jsonify({"error": f"Failed to save: {str(e)}"}), 500


def _extract_simple_language_name(language):
    """Extract a simple language name from the full language string."""
    # Try to extract from parentheses
    match = re.search(r"\(([^)]+)\)", language)
    if match:
        code = match.group(1)
        # Map language codes to simple names
        code_map = {
            "en": "English",
            "de": "German",
            "ja": "Japanese",
            "fa": "Persian",
            "ru": "Russian",
            "fr": "French",
            "es": "Spanish",
            "it": "Italian",
            "pt": "Portuguese",
            "nl": "Dutch",
            "zh": "Chinese",
            "ar": "Arabic",
            "hi": "Hindi",
            "ko": "Korean",
            "tr": "Turkish",
            "vi": "Vietnamese",
            "th": "Thai",
            "id": "Indonesian",
            "pl": "Polish",
            "uk": "Ukrainian",
        }
        return code_map.get(code, code)

    # Clean up the language name
    clean = language.replace("Translation (Language ", "").replace("Transcript (", "")
    clean = clean.replace("Original ASR - ", "").replace("Structured - ", "")
    clean = clean.replace(")", "").strip()

    return clean


@app.route("/update_video_subtitles/<session_id>", methods=["POST"])
def update_video_subtitles(session_id):
    """
    Update the embedded subtitles in video.mp4 with the edited VTT files.
    Also updates messages.json to reflect the changes.
    """
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    video_path = os.path.join(session_dir, "video.mp4")

    if not os.path.exists(video_path):
        return jsonify({"error": "video.mp4 not found"}), 404

    try:
        # --- 1. Get list of VTT files in the session ---
        vtt_files = []
        for f in os.listdir(session_dir):
            if f.endswith(".vtt") and f != "subtitles.vtt":
                file_path = os.path.join(session_dir, f)
                # Extract language from filename
                lang = f.replace("subtitles_", "").replace(".vtt", "")
                vtt_files.append(
                    {
                        "filename": f,
                        "path": file_path,
                        "language": lang,
                        "size": os.path.getsize(file_path),
                        "modified": os.path.getmtime(file_path),
                    }
                )

        if not vtt_files:
            return jsonify({"error": "No VTT files found to embed"}), 404

        # --- 2. Update messages.json with the edited content ---
        messages_path = os.path.join(session_dir, "messages.json")
        updated_count = 0
        if os.path.exists(messages_path):
            try:
                with open(messages_path, "r", encoding="utf-8") as f:
                    messages_data = json.load(f)

                json_path = os.path.join(session_dir, "transcripts.json")
                if os.path.exists(json_path):
                    with open(json_path, "r", encoding="utf-8") as f:
                        transcripts = json.load(f)

                    language_segments = {}
                    for transcript in transcripts:
                        lang = transcript.get("language", "")
                        if lang:
                            segments = transcript.get("segments", [])
                            language_segments[lang] = segments

                    if isinstance(messages_data, list):
                        for i, item in enumerate(messages_data):
                            if isinstance(item, list) and len(item) >= 2:
                                msg_lang = item[0]
                                matching_segments = None
                                for lang_key, segments in language_segments.items():
                                    if (
                                        msg_lang.lower() in lang_key.lower()
                                        or lang_key.lower() in msg_lang.lower()
                                    ):
                                        matching_segments = segments
                                        break

                                if matching_segments:
                                    try:
                                        msg_str = item[1]
                                        if isinstance(msg_str, str):
                                            msg_data = json.loads(msg_str)
                                        elif isinstance(msg_str, dict):
                                            msg_data = msg_str
                                        else:
                                            continue

                                        if (
                                            "seq" in msg_data
                                            and "start" in msg_data
                                            and "end" in msg_data
                                        ):
                                            start_time = msg_data.get("start", 0)
                                            if isinstance(start_time, str):
                                                try:
                                                    start_time = float(start_time)
                                                except ValueError:
                                                    start_time = 0

                                            matched_seg = None
                                            for seg in matching_segments:
                                                seg_start = seg.get("start", 0)
                                                if isinstance(seg_start, str):
                                                    try:
                                                        seg_start = float(seg_start)
                                                    except ValueError:
                                                        seg_start = 0
                                                if abs(seg_start - start_time) < 0.01:
                                                    matched_seg = seg
                                                    break

                                            if matched_seg:
                                                msg_data["seq"] = matched_seg.get(
                                                    "text", ""
                                                )
                                                if "markup" in matched_seg:
                                                    msg_data["markup"] = (
                                                        matched_seg.get("markup")
                                                    )
                                                if "speakerName" in matched_seg:
                                                    msg_data["speakerName"] = (
                                                        matched_seg.get("speakerName")
                                                    )
                                                if "words" in matched_seg:
                                                    msg_data["words"] = matched_seg.get(
                                                        "words"
                                                    )
                                                if "word_id" in matched_seg:
                                                    msg_data["word_id"] = (
                                                        matched_seg.get("word_id")
                                                    )

                                                if isinstance(msg_str, str):
                                                    messages_data[i][1] = json.dumps(
                                                        msg_data
                                                    )
                                                else:
                                                    messages_data[i][1] = msg_data
                                                updated_count += 1
                                    except (
                                        json.JSONDecodeError,
                                        TypeError,
                                        ValueError,
                                    ) as e:
                                        logging.warning(
                                            "Could not update message %d: %s", i, e
                                        )
                                        continue

                        if updated_count > 0:
                            with open(messages_path, "w", encoding="utf-8") as f:
                                json.dump(
                                    messages_data, f, ensure_ascii=False, indent=2
                                )
                            logging.info(
                                "Updated %d messages in messages.json", updated_count
                            )
            except (json.JSONDecodeError, TypeError, OSError) as e:
                logging.warning("Could not update messages.json: %s", e)

        # --- 3. Create a temporary file for the new video ---
        temp_output = os.path.join(
            tempfile.gettempdir(), f"video_updated_{session_id}.mp4"
        )

        # --- 4. Build ffmpeg command to embed subtitles ---
        # Start with basic command
        cmd = ["ffmpeg", "-y"]

        # Add input video
        cmd.extend(["-i", video_path])

        # Add validated subtitle files as inputs
        valid_vtt_files = []
        for vtt in vtt_files:
            # Validate VTT file first
            try:
                with open(vtt["path"], "r", encoding="utf-8") as f:
                    content = f.read()
                if not content.strip():
                    logging.warning("Skipping empty VTT: %s", vtt["filename"])
                    continue
                if "WEBVTT" not in content.upper():
                    logging.warning(
                        "Skipping invalid VTT (no WEBVTT header): %s", vtt["filename"]
                    )
                    continue
            except (OSError, UnicodeError) as e:
                logging.warning("Skipping VTT %s: %s", vtt["filename"], e)
                continue

            cmd.extend(["-i", vtt["path"]])
            valid_vtt_files.append(vtt)

        # Build subtitle stream mapping
        # Video stream: 0:v:0, Audio stream: 0:a:0
        cmd.extend(["-map", "0:v:0"])
        cmd.extend(["-map", "0:a:0"])

        # Map all subtitle streams from the additional inputs
        # They start at index 1 (since we have 1 input file)
        for i, vtt in enumerate(valid_vtt_files):
            cmd.extend(["-map", f"{i + 1}:s"])

            # Set language metadata
            lang_code = _get_language_code(vtt["language"])
            if lang_code:
                # For ffmpeg, metadata is applied to the output stream
                # The stream index for subtitle streams will be 2 + i (video=0, audio=1, subtitles=2+)
                stream_idx = 2 + i
                cmd.extend([f"-metadata:s:{stream_idx}", f"language={lang_code}"])
                cmd.extend([f"-metadata:s:{stream_idx}", f"title={vtt['language']}"])
            else:
                # Use a default title without language code
                stream_idx = 2 + i
                cmd.extend([f"-metadata:s:{stream_idx}", f"title={vtt['language']}"])

        # Remove any existing subtitle streams from the input
        # This prevents duplication issues
        cmd.extend(["-map", "-0:s?"])

        # Output options
        cmd.extend(["-c", "copy"])
        cmd.extend(["-c:s", "mov_text"])
        cmd.append(temp_output)

        # Log the command for debugging (sanitize to avoid huge logs)
        logging.info(
            "FFmpeg command: %s", " ".join(cmd[:5]) + " ... " + " ".join(cmd[-5:])
        )

        # --- 5. Run ffmpeg with error handling ---
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=300, check=False
            )

            if result.returncode != 0:
                error_msg = result.stderr if result.stderr else "Unknown ffmpeg error"
                logging.error("FFmpeg error: %s", error_msg)
                logging.error(
                    "FFmpeg stdout: %s",
                    result.stdout[:500] if result.stdout else "None",
                )
                return (
                    jsonify(
                        {
                            "error": "ffmpeg failed",
                            "stderr": error_msg[:500],
                            "stdout": result.stdout[:500] if result.stdout else None,
                        }
                    ),
                    500,
                )

        except subprocess.TimeoutExpired:
            logging.error("ffmpeg timed out for session %s", session_id)
            return jsonify({"error": "ffmpeg timed out"}), 500
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            logging.error("ffmpeg exception: %s", e, exc_info=True)
            return jsonify({"error": str(e)}), 500

        # --- 6. Replace the original video ---
        backup_path = os.path.join(session_dir, "video.mp4.backup")
        if os.path.exists(backup_path):
            os.remove(backup_path)
        os.rename(video_path, backup_path)
        os.rename(temp_output, video_path)

        # --- 7. Sync VTT files ---
        _sync_vtt_files(session_dir)

        # --- 8. Save state ---
        save_state()

        logging.info("Successfully updated video subtitles for session %s", session_id)

        return (
            jsonify(
                {
                    "success": True,
                    "message": "Video subtitles and messages.json updated successfully",
                    "embedded_subtitles": [
                        {
                            "language": vtt["language"],
                            "filename": vtt["filename"],
                        }
                        for vtt in valid_vtt_files
                    ],
                    "backup_path": backup_path,
                    "messages_updated": updated_count,
                }
            ),
            200,
        )

    # This is the endpoint boundary: unexpected failures must be converted to
    # an HTTP response instead of escaping Flask.
    # pylint: disable=broad-exception-caught
    except (
        AttributeError,
        KeyError,
        OSError,
        TypeError,
        ValueError,
        RuntimeError,
        yt_dlp.utils.DownloadError,
    ) as e:
        logging.error("Error updating video subtitles: %s", e, exc_info=True)
        return jsonify({"error": str(e)}), 500


def _get_language_code(language_name):
    """Map language name to ISO 639-1 code."""
    lang_map = {
        "English": "eng",
        "German": "deu",
        "Japanese": "jpn",
        "Persian": "fas",
        "Russian": "rus",
        "French": "fra",
        "Spanish": "spa",
        "Italian": "ita",
        "Portuguese": "por",
        "Dutch": "nld",
        "Chinese": "zho",
        "Arabic": "ara",
        "Hindi": "hin",
        "Korean": "kor",
        "Turkish": "tur",
        "Vietnamese": "vie",
        "Thai": "tha",
        "Indonesian": "ind",
        "Polish": "pol",
        "Ukrainian": "ukr",
        "Original ASR - Language English": "eng",
    }

    # Try exact match first
    if language_name in lang_map:
        return lang_map[language_name]

    # Try partial match
    for key, code in lang_map.items():
        if key in language_name or language_name in key:
            return code

    return None


def _sync_vtt_files(session_dir):
    """Sync subtitles.vtt with the English VTT file."""
    english_vtt = None
    for f in os.listdir(session_dir):
        if f.endswith(".vtt") and ("English" in f or "Original ASR" in f):
            english_vtt = f
            break

    if english_vtt:
        english_path = os.path.join(session_dir, english_vtt)
        generic_path = os.path.join(session_dir, "subtitles.vtt")

        with open(english_path, "r", encoding="utf-8") as f:
            content = f.read()

        with open(generic_path, "w", encoding="utf-8") as f:
            f.write(content)

        logging.info("Synced %s -> subtitles.vtt", english_vtt)


@app.route("/extract_video_subtitles/<session_id>", methods=["GET"])
def extract_video_subtitles(session_id):
    """Extract embedded subtitles from video.mp4 to VTT files."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    video_path = os.path.join(session_dir, "video.mp4")

    if not os.path.exists(video_path):
        return jsonify({"error": "video.mp4 not found"}), 404

    try:
        # First, get info about subtitle streams
        probe_cmd = [
            "ffprobe",
            "-i",
            video_path,
            "-show_entries",
            "stream=index,codec_type,codec_name,language,tags",
            "-select_streams",
            "s",
            "-of",
            "json",
        ]

        result = subprocess.run(
            probe_cmd, capture_output=True, text=True, timeout=30, check=False
        )
        if result.returncode != 0:
            return jsonify({"error": "ffprobe failed", "stderr": result.stderr}), 500

        probe_data = json.loads(result.stdout)
        streams = probe_data.get("streams", [])

        extracted = []
        for i, stream in enumerate(streams):
            stream_index = stream.get("index")
            language = stream.get("language", f"stream_{i}")

            # Extract subtitle to VTT
            output_file = os.path.join(
                session_dir, f"extracted_subtitle_{i}_{language}.vtt"
            )

            extract_cmd = [
                "ffmpeg",
                "-i",
                video_path,
                "-map",
                f"0:{stream_index}",
                "-c",
                "copy",
                "-y",
                output_file,
            ]

            subprocess.run(extract_cmd, capture_output=True, timeout=60, check=False)

            if os.path.exists(output_file):
                extracted.append(
                    {
                        "stream_index": stream_index,
                        "language": language,
                        "filename": os.path.basename(output_file),
                        "size": os.path.getsize(output_file),
                    }
                )

        return (
            jsonify({"success": True, "extracted": extracted, "total": len(extracted)}),
            200,
        )

    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, OSError) as e:
        return jsonify({"error": str(e)}), 500


# ─── AUTH ENDPOINTS ─────────────────────────────────────────────────────


@app.route("/register", methods=["POST"])
def register():
    """Register a new user with email and password."""
    email = request.form.get("email")
    password = request.form.get("password")
    name = request.form.get("name", "")
    if not email or not password:
        return jsonify({"message": "Email and password required"}), 400
    if email in users:
        return jsonify({"message": "User already exists"}), 400
    users[email] = {"name": name, "password": password}
    save_state()
    return (
        jsonify(
            {"token": str(uuid.uuid4()), "message": "User registered successfully"}
        ),
        201,
    )


@app.route("/login", methods=["POST"])
def login():
    """Log in an existing user and return an auth token."""
    email = request.form.get("email")
    password = request.form.get("password")
    if not email or not password:
        return jsonify({"message": "Email and password required"}), 400
    user = users.get(email)
    if not user or user["password"] != password:
        return jsonify({"message": "Invalid credentials"}), 401
    return jsonify({"token": str(uuid.uuid4()), "message": "Login successful"}), 200


# ─── VIDEO ENDPOINTS ────────────────────────────────────────────────────


@app.route("/videos", methods=["GET"])
def get_videos():
    """Return the list of uploaded videos with storage usage info."""
    # ============ DEDUPLICATION LOGIC ============
    # Group videos by filename (without UUID prefix)
    video_groups = {}

    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            continue

        # Check if this is a UUID-prefixed file
        uuid_match = re.match(
            r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_", file_name
        )

        # Determine the "clean" filename (without UUID prefix)
        if uuid_match:
            clean_name = file_name[
                36:
            ]  # Remove UUID prefix (8+1+4+1+4+1+4+1+12 = 36 chars)
            # If clean_name is empty or just extension, keep the original
            if not clean_name or clean_name.startswith("."):
                clean_name = file_name
        else:
            clean_name = file_name

        # Store in groups by clean_name
        if clean_name not in video_groups:
            video_groups[clean_name] = []
        video_groups[clean_name].append(video)

    # For each group, keep only the best video
    unique_videos = []
    for clean_name, group in video_groups.items():
        if len(group) == 1:
            # Only one video, keep it
            unique_videos.append(group[0])
        else:
            # Multiple videos with same name - keep the best one
            best_video = group[0]
            for video in group[1:]:
                # Prefer video with:
                # - segmentation_done == True
                # - thumbnail_url exists
                # - larger file_size
                # - no UUID prefix (prefer clean filename)
                current_score = 0
                best_score = 0

                # Check current video (best_video)
                if best_video.get("segmentation_done"):
                    best_score += 10
                if best_video.get("thumbnail_url"):
                    best_score += 5
                if best_video.get("file_size", 0) > 0:
                    best_score += min(
                        best_video.get("file_size", 0) / 1000000, 10
                    )  # Up to 10 points for size
                # Prefer clean filename (no UUID)
                if not re.match(
                    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
                    best_video.get("file_name", ""),
                ):
                    best_score += 3

                # Check candidate video (video)
                if video.get("segmentation_done"):
                    current_score += 10
                if video.get("thumbnail_url"):
                    current_score += 5
                if video.get("file_size", 0) > 0:
                    current_score += min(video.get("file_size", 0) / 1000000, 10)
                if not re.match(
                    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
                    video.get("file_name", ""),
                ):
                    current_score += 3

                if current_score > best_score:
                    best_video = video

            # Also log which ones were removed
            for video in group:
                if video != best_video:
                    logging.info(
                        "🗑️ Removing duplicate video: %s (keeping: %s)",
                        video.get("file_name"),
                        best_video.get("file_name"),
                    )

            unique_videos.append(best_video)
    # ========================================

    # Build absolute thumbnail URLs from the incoming request so they work
    # behind any host/proxy (localhost, Nginx, public domain, ...).
    # Do NOT mutate the stored dicts: their thumbnail_url stays relative.
    base = request.host_url.rstrip("/")
    unique_videos_serialized = []
    for video in unique_videos:
        v = dict(video)  # shallow copy
        thumb = v.get("thumbnail_url")
        if thumb and thumb.startswith("/thumbnails/"):
            v["thumbnail_url"] = f"{base}{thumb}"
        unique_videos_serialized.append(v)
    unique_videos = unique_videos_serialized

    storage_used_gb = sum(v.get("file_size", 0) for v in unique_videos) / (1024.0**3)
    return (
        jsonify(
            {
                "projects": unique_videos,
                "storage_used_gb": round(storage_used_gb, 2),
                "storage_limit_gb": 50.0,
            }
        ),
        200,
    )


@app.route("/video_detail/<video_key>", methods=["GET"])
def video_detail(video_key):
    """Return details for a specific video by its key."""
    for project in videos:
        if project["key"] == video_key:
            detail = project.copy()
            detail["segments"] = detail.get("segments", [])
            detail["video_url"] = None
            return jsonify(detail), 200
    return jsonify({"error": "Video not found"}), 404


@app.route("/media/<video_key>")
def serve_video(video_key):
    """Serve the video file for the given video key."""
    project = next((p for p in videos if p["key"] == video_key), None)
    if not project:
        return jsonify({"error": "Video not found"}), 404
    file_name = project.get("file_name")
    if not file_name:
        return jsonify({"error": "File name not available"}), 404
    file_path = os.path.join(UPLOAD_FOLDER, file_name)
    if not os.path.exists(file_path):
        return jsonify({"error": f'File "{file_name}" not found on disk'}), 404
    return send_file(file_path, as_attachment=False)


@app.route("/thumbnails/<filename>")
def serve_thumbnail(filename):
    """Serve thumbnail images."""
    if ".." in filename or "/" in filename or "\\" in filename:
        return jsonify({"error": "Invalid filename"}), 400

    thumbnail_path = os.path.join(UPLOAD_FOLDER, filename)
    if not os.path.exists(thumbnail_path):
        return jsonify({"error": "Thumbnail not found"}), 404

    return send_file(thumbnail_path, mimetype="image/jpeg")


@app.route("/upload-chunk", methods=["POST"])
def upload_chunk():
    """Receive a chunk of a file upload for chunked uploads."""
    file = request.files.get("file")
    filename = request.form.get("filename")
    chunk_index = int(request.form.get("chunk_index", 0))
    total_chunks = int(request.form.get("total_chunks", 1))
    if not file or not filename:
        return jsonify({"message": "Missing file or filename"}), 400
    if filename not in chunk_storage:
        chunk_storage[filename] = [None] * total_chunks
    chunk_storage[filename][chunk_index] = file.read()
    return jsonify({"message": "Chunk uploaded"}), 200


@app.route("/finish-upload", methods=["POST"])
def finish_upload():
    """Complete a chunked upload and persist the file to disk."""
    data = request.get_json()
    filename = data.get("filename")
    auto_segmentation = data.get("auto_segmentation", False)
    if not filename:
        return jsonify({"message": "Missing filename"}), 400
    chunks = chunk_storage.get(filename)
    if not chunks or any(chunk is None for chunk in chunks):
        return jsonify({"message": "Incomplete upload"}), 400
    combined = b"".join(chunks)

    # ============ FIX: Ensure .mp4 extension ============
    if not filename.lower().endswith(".mp4"):
        base_name = os.path.splitext(filename)[0]
        filename = f"{base_name}.mp4"
    # ====================================================

    file_path = os.path.join(UPLOAD_FOLDER, filename)
    with open(file_path, "wb") as f:
        f.write(combined)
    file_size = len(combined)

    thumbnail_filename = f"{os.path.splitext(filename)[0]}_thumb.jpg"
    thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
    thumbnail_url = None

    # Generate thumbnail with proper path
    if generate_video_thumbnail(file_path, thumbnail_path):
        thumbnail_url = f"/thumbnails/{thumbnail_filename}"
        logging.info("Generated thumbnail: %s", thumbnail_filename)
    else:
        logging.warning("Failed to generate thumbnail for %s", filename)

    duration, fps = get_video_metadata(file_path)

    project = {
        "key": str(uuid.uuid4()),
        "name": filename.rsplit(".", 1)[0] if "." in filename else filename,
        "file_name": filename,
        "uploaded": utc_now_iso(),
        "last_opened": None,
        "duration": duration,
        "fps": fps,
        "file_size": file_size,
        "segment_count": 0,
        "languages": ["en"],
        "thumbnail_url": thumbnail_url,
        "segmentation_done": auto_segmentation,
        "segmentation_progress": 100 if auto_segmentation else 0,
    }
    videos.append(project)
    del chunk_storage[filename]
    save_state()
    return jsonify({"message": "Upload finished", "project": project}), 200


# ─── JOB ENDPOINTS ──────────────────────────────────────────────────────


@app.route("/start_job/<video_key>", methods=["POST"])
def start_job(video_key):
    """Start a background transcription job for the given video."""
    data = request.get_json()
    job_id = str(uuid.uuid4())
    job = {
        "id": job_id,
        "video_key": video_key,
        "status": "processing",
        "progress": 0.0,
        "transcript": None,
        "segments": None,
        "created_at": utc_now_iso(),
        "config": data,
    }
    jobs[job_id] = job
    threading.Thread(target=process_job, args=(job_id,), daemon=True).start()
    save_state()
    return jsonify({"job_id": job_id, "status": "processing"}), 200


@app.route("/job_status/<job_id>", methods=["GET"])
def job_status(job_id):
    """Return the current status of a transcription job."""
    job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404
    return (
        jsonify(
            {
                "status": job["status"],
                "progress": job["progress"],
                "transcript": job.get("transcript"),
                "segments": job.get("segments"),
            }
        ),
        200,
    )


# ─── SESSION OUTPUT ENDPOINTS ──────────────────────────────────────────
# In simple_flask_server.py - Update get_session_output


@app.route("/session_output/<session_id>", methods=["GET"])
def get_session_output(session_id):
    """Get the session output as a JSON response with file URLs."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    # Only download if files don't exist or are very small
    if token:
        json_path = os.path.join(session_dir, "transcripts.json")
        messages_path = os.path.join(session_dir, "messages.json")

        # Check if we need to download
        need_download = False
        if not os.path.exists(json_path) or os.path.getsize(json_path) < 100:
            need_download = True
        if not os.path.exists(messages_path) or os.path.getsize(messages_path) < 100:
            need_download = True

        if need_download:
            logging.info("Downloading session %s from internal server", session_id)
            download_session_files(session_id, token)

    files = []
    if os.path.exists(session_dir):
        for file in os.listdir(session_dir):
            file_path = os.path.join(session_dir, file)
            if os.path.isfile(file_path) and os.path.getsize(file_path) > 1000:
                mtime = os.path.getmtime(file_path)
                mod_time = datetime.datetime.fromtimestamp(mtime).isoformat()

                # For VTT files, use the local file URL
                if file.endswith(".vtt"):
                    url = f"/session_file/{session_id}/{file}"
                else:
                    url = f"/session_file/{session_id}/{file}"

                files.append(
                    {
                        "name": file,
                        "size": os.path.getsize(file_path),
                        "url": url,
                        "modified": mod_time,
                    }
                )

    status = "ready" if files else "processing"
    return (
        jsonify(
            {
                "session_id": session_id,
                "files": files,
                "total_files": len(files),
                "session_url": f"{INTERNAL_SERVER_URL}/archivesession/{session_id}",
                "status": status,
            }
        ),
        200,
    )


@app.route("/session_file/<session_id>/<filename>", methods=["GET"])
def get_session_file(session_id, filename):
    """Download a specific file from the session."""
    session_dir = os.path.join(SESSION_FOLDER, session_id)
    file_path = os.path.join(session_dir, filename)

    # Check if file exists
    if not os.path.exists(file_path):
        return jsonify({"error": "File not found"}), 404

    # For VTT files, serve with correct MIME type and no cache
    if filename.endswith(".vtt"):
        response = send_file(
            file_path, as_attachment=False, mimetype="text/vtt", download_name=filename
        )
        # Add headers to prevent caching
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response

    return send_file(file_path, as_attachment=True)


# ─── YOUTUBE DOWNLOADER FUNCTIONS ──────────────────────────────────────


def extract_youtube_video_id(url):
    """Extract YouTube video ID from various URL formats."""
    patterns = [
        r"youtube\.com/watch\?v=([^&]+)",
        r"youtu\.be/([^?]+)",
        r"youtube\.com/shorts/([^?]+)",
        r"youtube\.com/embed/([^?]+)",
        r"youtube\.com/v/([^?]+)",
        r"youtube\.com/e/([^?]+)",
        r"m\.youtube\.com/watch\?v=([^&]+)",
    ]
    for pattern in patterns:
        match = re.search(pattern, url)
        if match:
            return match.group(1)
    return None


def is_youtube_url(url):
    """Check if a URL is a YouTube URL."""
    youtube_patterns = [
        "youtube.com/watch?v=",
        "youtu.be/",
        "youtube.com/shorts/",
        "youtube.com/embed/",
        "youtube.com/v/",
        "youtube.com/e/",
        "m.youtube.com/watch?v=",
    ]
    return any(pattern in url.lower() for pattern in youtube_patterns)


def get_youtube_video_info(youtube_url):
    """
    Get video info from YouTube using yt-dlp.
    Returns video info including URL, title, duration, etc.
    """
    try:
        # First check if it's a YouTube URL
        if not is_youtube_url(youtube_url):
            return {"success": False, "error": "Not a valid YouTube URL"}

        video_id = extract_youtube_video_id(youtube_url)
        if not video_id:
            return {"success": False, "error": "Could not extract video ID"}

        # Configure yt-dlp options
        ydl_opts = {
            "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            "quiet": True,
            "no_warnings": True,
            "extract_flat": False,
            "http_headers": {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-us,en;q=0.5",
                "Sec-Fetch-Mode": "navigate",
            },
        }

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            # Extract info without downloading
            info = ydl.extract_info(youtube_url, download=False)

            if not info:
                return {
                    "success": False,
                    "error": "Could not extract video information",
                }

            # Get the video URL
            video_url = info.get("url")
            if not video_url:
                # Try to get URL from formats
                formats = info.get("formats", [])
                for fmt in formats:
                    # Prefer MP4 with video and audio
                    if fmt.get("ext") == "mp4" and fmt.get("vcodec") != "none":
                        video_url = fmt.get("url")
                        break
                    elif fmt.get("ext") == "mp4" and fmt.get("acodec") != "none":
                        video_url = fmt.get("url")
                        break

                # If still no URL, try the first format
                if not video_url and formats:
                    video_url = formats[0].get("url")

            if not video_url:
                return {"success": False, "error": "Could not find video URL"}

            # Get title and other metadata
            title = info.get("title", "video")
            # Clean title for filename
            title = re.sub(r'[\\/*?:"<>|]', "_", title)

            # Get duration
            duration = info.get("duration", 0)

            # Get thumbnail
            thumbnail = info.get("thumbnail", "")

            return {
                "success": True,
                "url": video_url,
                "title": title,
                "duration": duration,
                "thumbnail": thumbnail,
                "video_id": video_id,
                "format": info.get("format", "mp4"),
                "ext": info.get("ext", "mp4"),
                "filesize": info.get("filesize", 0),
            }

    except yt_dlp.utils.DownloadError as e:
        logging.error("yt-dlp download error: %s", str(e))
        return {"success": False, "error": f"Download error: {str(e)}"}
    except yt_dlp.utils.ExtractorError as e:
        logging.error("yt-dlp extractor error: %s", str(e))
        return {"success": False, "error": f"Extractor error: {str(e)}"}
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as e:
        logging.error("YouTube error: %s", str(e), exc_info=True)
        return {"success": False, "error": f"Error: {str(e)}"}


def download_youtube_video_adaptive(youtube_url, output_dir, filename=None):
    """
    Adaptive YouTube downloader that first checks available formats.
    Works with all videos including Shorts and age-restricted content.
    """
    try:
        if not is_youtube_url(youtube_url):
            return {"success": False, "error": "Not a valid YouTube URL"}

        os.makedirs(output_dir, exist_ok=True)

        logging.info("🔍 Checking available formats for: %s", youtube_url)

        # Step 1: Get available formats
        with yt_dlp.YoutubeDL(
            {
                "quiet": True,
                "no_warnings": True,
                "http_headers": {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                },
            }
        ) as ydl:
            info = ydl.extract_info(youtube_url, download=False)

            if not info:
                return {"success": False, "error": "Could not get video info"}

            # Find the best format
            best_format = None
            best_score = -1
            available_formats = []

            for fmt in info.get("formats", []):
                # Skip formats without video
                if fmt.get("vcodec") == "none":
                    continue

                # Calculate score
                score = 0
                # Prefer MP4
                if fmt.get("ext") == "mp4":
                    score += 100
                # Prefer higher resolution
                height = fmt.get("height", 0)
                if height:
                    score += height
                # Prefer formats with audio
                if fmt.get("acodec") != "none":
                    score += 50

                available_formats.append(
                    {
                        "format_id": fmt.get("format_id"),
                        "ext": fmt.get("ext"),
                        "height": height,
                        "has_audio": fmt.get("acodec") != "none",
                        "score": score,
                    }
                )

                if score > best_score:
                    best_score = score
                    best_format = fmt

            if not best_format:
                return {"success": False, "error": "No suitable format found"}

            format_id = best_format.get("format_id")
            logging.info(
                "📹 Selected format: %s (score: %s)", format_id, best_score
            )
            logging.info(
                "📹 Available formats: %s...", available_formats[:5]
            )  # Log first 5

        # Step 2: Download with the selected format
        ydl_opts = {
            "format": format_id,
            "outtmpl": os.path.join(output_dir, "%(title)s.%(ext)s"),
            "quiet": True,
            "no_warnings": True,
            "ignoreerrors": True,
            "http_headers": {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            },
            "merge_output_format": "mp4",
            "prefer_insecure": True,
            "no_check_certificate": True,
        }

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            logging.info("📥 Downloading video...")
            info = ydl.extract_info(youtube_url, download=True)

            if not info:
                return {"success": False, "error": "Could not download video"}

            title = info.get("title", "video")
            # Clean title for filename
            title = re.sub(r'[\\/*?:"<>|]', "_", title)

            downloaded_file = None
            # Check for common extensions
            for ext in [".mp4", ".webm", ".mkv"]:
                possible = os.path.join(output_dir, f"{title}{ext}")
                if os.path.exists(possible):
                    downloaded_file = possible
                    break

            # If not found, look for any recent video file in the directory
            if not downloaded_file:
                for f in os.listdir(output_dir):
                    if f.endswith((".mp4", ".webm", ".mkv")):
                        file_path = os.path.join(output_dir, f)
                        # Check if file was created recently (last 2 minutes)
                        if os.path.getmtime(file_path) > time.time() - 120:
                            downloaded_file = file_path
                            break

            if not downloaded_file:
                return {"success": False, "error": "Downloaded file not found"}

            # Rename if needed
            if filename and os.path.exists(downloaded_file):
                _, ext = os.path.splitext(downloaded_file)
                new_filename = filename
                if not new_filename.endswith(ext):
                    new_filename = f"{new_filename}{ext}"
                new_path = os.path.join(output_dir, new_filename)
                os.rename(downloaded_file, new_path)
                downloaded_file = new_path

            file_size = (
                os.path.getsize(downloaded_file)
                if os.path.exists(downloaded_file)
                else 0
            )
            logging.info(
                "✅ Download complete: %s (%s bytes)",
                os.path.basename(downloaded_file),
                file_size,
            )

            return {
                "success": True,
                "file_path": downloaded_file,
                "title": title,
                "filename": os.path.basename(downloaded_file),
                "duration": info.get("duration", 0),
                "filesize": file_size,
            }

    except yt_dlp.utils.DownloadError as e:
        logging.error("yt-dlp download error: %s", str(e))
        return {"success": False, "error": f"Download error: {str(e)}"}
    except (OSError, RuntimeError, ValueError, TypeError, KeyError) as e:
        logging.error("YouTube download error: %s", str(e), exc_info=True)
        return {"success": False, "error": f"Error: {str(e)}"}


# ─── YOUTUBE API ROUTES ────────────────────────────────────────────────


@app.route("/api/youtube-info", methods=["POST", "OPTIONS"])
def youtube_info():
    """
    Get YouTube video information without downloading.
    """
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

    try:
        data = request.get_json()
        if not data or "url" not in data:
            return jsonify({"error": "URL is required"}), 400

        youtube_url = data["url"]
        result = get_youtube_video_info(youtube_url)

        if result.get("success"):
            return (
                jsonify(
                    {
                        "success": True,
                        "video_id": result.get("video_id"),
                        "title": result.get("title"),
                        "duration": result.get("duration"),
                        "thumbnail": result.get("thumbnail"),
                        "format": result.get("format"),
                        "url": result.get("url"),
                    }
                ),
                200,
            )
        else:
            return (
                jsonify(
                    {"success": False, "error": result.get("error", "Unknown error")}
                ),
                400,
            )

    except (ValueError, TypeError, KeyError) as e:
        logging.error("YouTube info error: %s", str(e), exc_info=True)
        return jsonify({"error": str(e)}), 500


@app.route("/api/youtube-download-and-upload", methods=["POST", "OPTIONS"])
def youtube_download_and_upload():
    """
    Download a YouTube video and upload it to the internal server.
    """
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

    try:
        data = request.get_json()
        if not data or "url" not in data:
            return jsonify({"error": "URL is required"}), 400

        youtube_url = data["url"]
        auto_segmentation = data.get("auto_segmentation", True)

        logging.info("📥 Downloading YouTube video: %s", youtube_url)

        # Get video info first
        try:
            ydl_opts = {
                "quiet": True,
                "no_warnings": True,
                "http_headers": {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                },
            }
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(youtube_url, download=False)
                title = info.get("title", "youtube_video")
                duration = info.get("duration", 0)

            clean_title = re.sub(r'[\\/*?:"<>|]', "_", title)
            filename = f"{clean_title}.mp4"

            if len(filename) > 200:
                name, ext = os.path.splitext(filename)
                filename = name[:195] + ext

            logging.info("📹 Video: %s", title)

        except (
            OSError,
            TypeError,
            ValueError,
            RuntimeError,
            yt_dlp.utils.DownloadError,
        ) as e:
            logging.error("❌ Error getting video info: %s", e)
            return jsonify({"success": False, "error": f"Info error: {str(e)}"}), 400

        # Download the video using adaptive method
        try:
            download_result = download_youtube_video_adaptive(
                youtube_url, UPLOAD_FOLDER, filename
            )
        except (
            OSError,
            TypeError,
            ValueError,
            RuntimeError,
            yt_dlp.utils.DownloadError,
        ) as e:
            logging.error("❌ Error downloading video: %s", e)
            return (
                jsonify({"success": False, "error": f"Download error: {str(e)}"}),
                400,
            )

        if not download_result.get("success"):
            error_msg = download_result.get("error", "Download failed")
            logging.error("❌ Download error: %s", error_msg)
            return jsonify({"success": False, "error": error_msg}), 400

        file_path = download_result.get("file_path")
        if not file_path or not os.path.exists(file_path):
            return jsonify({"error": "Downloaded file not found"}), 500

        file_size = download_result.get("filesize", 0)
        duration = download_result.get("duration", 0)
        actual_filename = download_result.get("filename", filename)

        logging.info("✅ Video downloaded: %s (%s bytes)", file_path, file_size)

        # Generate thumbnail
        thumbnail_filename = f"{os.path.splitext(actual_filename)[0]}_thumb.jpg"
        thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
        thumbnail_url = None

        if generate_video_thumbnail(file_path, thumbnail_path):
            thumbnail_url = f"/thumbnails/{thumbnail_filename}"
            logging.info("🖼️ Generated thumbnail")

        # Get video metadata
        if duration == 0:
            duration, fps = get_video_metadata(file_path)
        else:
            fps = 30.0

        # Create project entry
        video_key = str(uuid.uuid4())
        project = {
            "key": video_key,
            "name": clean_title,
            "file_name": actual_filename,
            "uploaded": utc_now_iso(),
            "last_opened": None,
            "duration": duration,
            "fps": fps,
            "file_size": file_size,
            "segment_count": 0,
            "languages": ["en"],
            "thumbnail_url": thumbnail_url,
            "segmentation_done": auto_segmentation,
            "segmentation_progress": 100 if auto_segmentation else 0,
        }

        # Add to videos list
        videos.append(project)
        save_state()

        logging.info("✅ YouTube video uploaded successfully: %s", clean_title)

        # Start segmentation job if enabled
        if auto_segmentation:
            job_id = str(uuid.uuid4())
            job = {
                "id": job_id,
                "video_key": video_key,
                "status": "processing",
                "progress": 0.0,
                "transcript": None,
                "segments": None,
                "created_at": utc_now_iso(),
                "config": {"auto_segmentation": True},
            }
            jobs[job_id] = job
            threading.Thread(target=process_job, args=(job_id,), daemon=True).start()
            save_state()

        return (
            jsonify(
                {
                    "success": True,
                    "video_info": {
                        "title": clean_title,
                        "duration": duration,
                        "file_size": file_size,
                    },
                    "project": project,
                    "message": f'Video "{clean_title}" imported successfully',
                    "filename": actual_filename,
                    "video_key": video_key,
                }
            ),
            200,
        )

    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as e:
        logging.error("YouTube download error: %s", str(e), exc_info=True)
        return jsonify({"success": False, "error": f"Server error: {str(e)}"}), 500


# ─── UPLOAD ENDPOINT ────────────────────────────────────────────────────


@app.route("/upload", methods=["POST", "OPTIONS"])
def upload_lecture():
    """Upload a video file to the internal server using streaming."""
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

    token = request.form.get("token", "")
    if not token:
        return jsonify({"error": "Missing token"}), 400
    if "videofile" not in request.files:
        return jsonify({"error": "No video file provided"}), 400

    file_storage = request.files["videofile"]
    if file_storage.filename == "":
        return jsonify({"error": "Empty filename"}), 400

    session_name = request.form.get("name", file_storage.filename)

    # ============ FIX: Use original filename with .mp4 extension ============
    original_filename = file_storage.filename

    # If filename doesn't have .mp4 extension, add it
    if not original_filename.lower().endswith(".mp4"):
        name_without_ext = os.path.splitext(original_filename)[0]
        original_filename = f"{name_without_ext}.mp4"
        logging.info("📹 Added .mp4 extension: %s", original_filename)
    # ====================================================

    # Check if this video already exists
    existing_video = None
    for video in videos:
        if video.get("file_name") == original_filename:
            existing_video = video
            break

    # ============ FIX: Initialize variables ============
    file_size = 0
    local_filename = original_filename
    local_path = os.path.join(UPLOAD_FOLDER, local_filename)
    project = None
    video_key = None
    # ====================================================

    if existing_video:
        # Use existing video
        video_key = existing_video["key"]
        project = existing_video  # Use the existing project
        logging.info(
            "📹 Using existing video: %s (key: %s)", original_filename, video_key
        )

        # Check if file exists on disk
        if not os.path.exists(local_path):
            # File was deleted, save it again
            file_storage.save(local_path)
            file_size = os.path.getsize(local_path)
            project["file_size"] = file_size
            logging.info("✅ Restored video file: %s", local_filename)
        else:
            # File exists, get its size
            file_size = os.path.getsize(local_path)
            project["file_size"] = file_size
            logging.info(
                "✅ Using existing file: %s (%d bytes)", local_filename, file_size
            )
    else:
        # New video - use original filename without UUID
        local_filename = original_filename
        # Ensure we don't overwrite
        base_name, ext = os.path.splitext(original_filename)
        if not ext:
            ext = ".mp4"
        counter = 1
        while os.path.exists(os.path.join(UPLOAD_FOLDER, local_filename)):
            local_filename = f"{base_name}_{counter}{ext}"
            counter += 1

        local_path = os.path.join(UPLOAD_FOLDER, local_filename)
        file_storage.save(local_path)
        file_size = os.path.getsize(local_path)
        logging.info("✅ New video saved: %s (%d bytes)", local_filename, file_size)

        video_key = str(uuid.uuid4())
        project = {
            "key": video_key,
            "name": session_name,
            "file_name": local_filename,
            "uploaded": utc_now_iso(),
            "last_opened": None,
            "duration": 120.0,
            "fps": 30.0,
            "file_size": file_size,
            "segment_count": 0,
            "languages": request.form.getlist("language") or ["en"],
            "thumbnail_url": None,
            "segmentation_done": False,
            "segmentation_progress": 0,
        }
        videos.append(project)

    # ============ FIX: Use the existing code below but with project defined ============
    # Now project is always defined, so the rest of the code works

    # Build data for the internal server
    data = {}
    for key in request.form.keys():
        if key == "token":
            continue
        values = request.form.getlist(key)
        data[key] = values[0] if len(values) == 1 else values
    if "path" not in data:
        data["path"] = "/home/admin@example.com"

    headers = {
        "X-Forward-Auth": token,
        "Authorization": f"Bearer {token}",
        "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
    }
    cookies = {"_forward_auth": token}

    try:
        logging.info("Uploading to internal server: %s", TARGET_URL)
        logging.info("Data keys: %s", list(data.keys()))
        logging.info("File size: %d bytes", file_size)

        with open(local_path, "rb") as f:
            boundary = f"----WebKitFormBoundary{uuid.uuid4().hex[:16]}"
            content_type = f"multipart/form-data; boundary={boundary}"

            def generate_multipart():
                for key, value in data.items():
                    if isinstance(value, list):
                        for v in value:
                            yield f"--{boundary}\r\n"
                            yield f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
                            yield f"{v}\r\n"
                    else:
                        yield f"--{boundary}\r\n"
                        yield f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
                        yield f"{value}\r\n"

                filename = file_storage.filename
                mimetype = mimetypes.guess_type(filename)[0] or "video/mp4"
                yield f"--{boundary}\r\n"
                yield f'Content-Disposition: form-data; name="videofile"; filename="{filename}"\r\n'
                yield f"Content-Type: {mimetype}\r\n\r\n"

                chunk_size = 16384
                while True:
                    chunk = f.read(chunk_size)
                    if not chunk:
                        break
                    yield chunk

                yield b"\r\n"
                yield f"--{boundary}--\r\n"

            class MultipartGenerator:
                """Generate multipart form data chunks for streaming upload."""

                def __init__(self, generator_func):
                    self.generator = generator_func()
                    self._iter = iter(self.generator)

                def __iter__(self):
                    return self

                def __next__(self):
                    value = next(self._iter)
                    if isinstance(value, str):
                        return value.encode("utf-8")
                    return value

            body_gen = MultipartGenerator(generate_multipart)

            resp = requests.post(
                TARGET_URL,
                data=body_gen,
                headers={**headers, "Content-Type": content_type},
                cookies=cookies,
                timeout=(60, 3600),
                verify=False,
                allow_redirects=True,
            )

        logging.info("Response status: %s", resp.status_code)
        logging.info("Response URL: %s", resp.url)

        final_url = resp.url
        session_id = None

        if "/archivesession/" in final_url:
            session_id = final_url.split("/archivesession/")[-1].split("/")[0]
            logging.info("Extracted session ID from URL: %s", session_id)
        elif "/session/" in final_url:
            session_id = final_url.split("/session/")[-1].split("/")[0]
            logging.info("Extracted session ID from URL: %s", session_id)

        if not session_id and session_name:
            user_email = data.get("path", "/home/admin@example.com")
            user_email = user_email.strip("/").split("/")[-1]
            path = f"/home/{user_email}/{session_name}"
            session_id = base64.b64encode(path.encode()).decode()
            logging.info("Generated session ID: %s", session_id)

        content = resp.text

        if session_id:
            project["session_id"] = session_id
            project["session_url"] = f"{BASE_URL}/archivesession/{session_id}"
            sessions[session_id] = {
                "id": session_id,
                "name": session_name,
                "video_key": video_key,
                "created_at": utc_now_iso(),
                "url": f"{BASE_URL}/archivesession/{session_id}",
            }
            logging.info("Session created: %s", session_id)

            job = {
                "id": session_id,
                "video_key": video_key,
                "status": "processing",
                "progress": 0.0,
                "transcript": None,
                "segments": None,
                "created_at": utc_now_iso(),
                "config": dict(request.form),
            }
            jobs[session_id] = job
            threading.Thread(
                target=process_job, args=(session_id,), daemon=True
            ).start()
            save_state()

        try:
            response_data = json.loads(content)
            if session_id:
                response_data.update(
                    {
                        "session_id": session_id,
                        "video_key": video_key,
                        "session_url": f"{BASE_URL}/archivesession/{session_id}",
                        "output_url": f"/session_output/{session_id}",
                        "download_url": f"/session_zip/{session_id}",
                    }
                )
            return jsonify(response_data), resp.status_code
        except json.JSONDecodeError:
            if session_id:
                return (
                    jsonify(
                        {
                            "status": "success",
                            "session_id": session_id,
                            "video_key": video_key,
                            "session_url": f"{BASE_URL}/archivesession/{session_id}",
                            "output_url": f"/session_output/{session_id}",
                            "download_url": f"/session_zip/{session_id}",
                            "message": "Upload successful!",
                            "response": content[:500],
                        }
                    ),
                    resp.status_code,
                )
            return (
                jsonify(
                    {
                        "status": "error",
                        "message": "No session ID received",
                        "response": content[:1000],
                        "status_code": resp.status_code,
                        "url": resp.url,
                    }
                ),
                500,
            )

    except requests.exceptions.Timeout:
        logging.error("Request timeout")
        return jsonify({"error": "Request timeout - file may be too large"}), 504
    except requests.exceptions.RequestException as e:
        logging.error("Request error: %s", str(e))
        return jsonify({"error": f"Request failed: {str(e)}"}), 500
    except OSError as e:
        logging.error("Upload error: %s", str(e), exc_info=True)
        return jsonify({"error": f"Upload failed: {str(e)}"}), 500


# ─── PROXY ENDPOINTS ────────────────────────────────────────────────────


@app.route("/check-session", methods=["GET"])
def check_session():
    """Forward a GET request to check if the session is authenticated."""
    headers = {}
    auth = request.headers.get("Authorization")
    if auth:
        headers["Authorization"] = auth
    forwarded_user = request.headers.get("X-Forwarded-User")
    if forwarded_user:
        headers["X-Forwarded-User"] = forwarded_user
    try:
        resp = requests.get(
            INTERNAL_SERVER_URL,
            headers=headers,
            allow_redirects=False,
            timeout=10,
            verify=False,
        )
        final_url = resp.url if hasattr(resp, "url") else INTERNAL_SERVER_URL
        is_login_page = resp.status_code == 200 and (
            "Log in to dex" in resp.text or "dex-container" in resp.text
        )
        authenticated = not (
            "dex" in final_url or resp.status_code == 302 or is_login_page
        )
        return jsonify({"authenticated": authenticated}), 200
    except requests.exceptions.RequestException:
        return jsonify({"authenticated": False, "error": "Request failed"}), 200


@app.route("/dex/token", methods=["POST"])
def dex_token():
    """Forward token exchange to the internal server's /dex/token endpoint."""
    try:
        headers = {k: v for k, v in request.headers if k.lower() != "host"}
        resp = requests.post(
            f"{INTERNAL_SERVER_URL}/dex/token",
            data=request.get_data(),
            headers=headers,
            allow_redirects=False,
            timeout=30,
            verify=False,
        )
        return (resp.content, resp.status_code, resp.headers.items())
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Proxy error: {str(e)}"}), 500


@app.route("/dex/userinfo", methods=["GET"])
def dex_userinfo():
    """Forward userinfo request to the internal server's /dex/userinfo endpoint."""
    try:
        headers = {k: v for k, v in request.headers if k.lower() != "host"}
        resp = requests.get(
            f"{INTERNAL_SERVER_URL}/dex/userinfo",
            headers=headers,
            allow_redirects=False,
            timeout=30,
            verify=False,
        )
        return (resp.content, resp.status_code, resp.headers.items())
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Proxy error: {str(e)}"}), 500


# ─── DEBUG ENDPOINTS ────────────────────────────────────────────────────

@app.route("/debug-videos", methods=["GET"])
def debug_videos():
    """Debug endpoint: return all video metadata (including duplicates)."""
    base = request.host_url.rstrip("/")
    serialized = []
    for video in videos:
        v = dict(video)
        thumb = v.get("thumbnail_url")
        if thumb and thumb.startswith("/thumbnails/"):
            v["thumbnail_url"] = f"{base}{thumb}"
        serialized.append(v)
    return jsonify({"count": len(videos), "projects": serialized}), 200


@app.route("/debug-jobs", methods=["GET"])
def debug_jobs():
    """Debug endpoint: return all jobs."""
    return jsonify({"count": len(jobs), "jobs": jobs}), 200


@app.route("/clear-videos", methods=["POST"])
def clear_videos():
    """Clear all uploaded videos (except the dummy one)."""
    for video in videos:
        if video.get("file_name") and video["file_name"] != "sample.mp4":
            file_path = os.path.join(UPLOAD_FOLDER, video["file_name"])
            if os.path.exists(file_path):
                os.remove(file_path)
            thumb_filename = f"{os.path.splitext(video['file_name'])[0]}_thumb.jpg"
            thumb_path = os.path.join(UPLOAD_FOLDER, thumb_filename)
            if os.path.exists(thumb_path):
                os.remove(thumb_path)
    videos.clear()
    dummy_with_thumb = dummy_project.copy()
    dummy_with_thumb["thumbnail_url"] = None
    videos.append(dummy_with_thumb)
    chunk_storage.clear()
    jobs.clear()
    save_state()
    return jsonify({"message": "Cleared"}), 200


# ─── DUMMY PROJECT ──────────────────────────────────────────────────────

dummy_project = {
    "key": "dummy-key-123",
    "name": "Sample Video",
    "file_name": "sample.mp4",
    "uploaded": utc_now_iso(),
    "last_opened": None,
    "duration": 60.0,
    "fps": 30.0,
    "file_size": 10485760,
    "segment_count": 5,
    "languages": ["en", "de"],
    "thumbnail_url": None,
    "segmentation_done": True,
    "segmentation_progress": 100,
}
videos.append(dummy_project)

users["testuser@example.com"] = {
    "name": "Test User",
    "password": "YourSecurePassword123",
}


if __name__ == "__main__":
    try:
        import urllib3

        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    except ImportError:
        pass

    # Load saved state
    load_state()

    # Clean up missing videos and orphaned data
    clean_missing_videos()
    cleanup_orphaned_data()

    # Regenerate missing thumbnails
    regenerate_missing_thumbnails()

    logging.info("Starting merged server on 0.0.0.0:5000")
    logging.info("State file: %s", STATE_FILE)
    app.run(host="0.0.0.0", port=5000, debug=True)
