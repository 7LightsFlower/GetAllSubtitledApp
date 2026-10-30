"""YouTube info and download helpers, browser-compatible conversion.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import logging
import os
import re
import shutil
import subprocess
import time
import yt_dlp
from flask import jsonify, request

from .flask_app import _USER_AGENT, app
from .utils import _session_dir
from .downloads import download_session_files
from .media import _file_has_audio_stream


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
                "User-Agent": _USER_AGENT,
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
    Download a YouTube video with audio, using yt-dlp's format merging.
    Prefers mp4/m4a for direct container compatibility.
    """
    try:
        if not is_youtube_url(youtube_url):
            return {"success": False, "error": "Not a valid YouTube URL"}

        os.makedirs(output_dir, exist_ok=True)

        logging.info("🔍 Preparing download for: %s", youtube_url)

        # Prefer mp4 video + m4a audio; fall back to any best video+audio.
        # 'bv*' = best video-only, 'ba' = best audio-only.
        # The '/' chain tries each option left to right.
        format_selector = (
            # First choice: H.264 video + M4A audio. This is the one that
            # plays in every browser including iOS Safari and Chrome-on-iOS.
            "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/"
            "bv*[vcodec^=avc1]+ba/"
            # Fallbacks: any MP4 pair, then any pair, then progressive MP4.
            "bv*[ext=mp4]+ba[ext=m4a]/"
            "bv*[ext=mp4]+ba/"
            "bv*+ba/"
            "b[ext=mp4]/b"
        )

        ydl_opts = {
            "format": format_selector,
            "outtmpl": os.path.join(output_dir, "%(title)s.%(ext)s"),
            "quiet": True,
            "no_warnings": True,
            "ignoreerrors": True,
            "merge_output_format": "mp4",
            "http_headers": {
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36"
                ),
            },
            # Requires ffmpeg on PATH to mux video+audio into mp4
            "postprocessors": [
                {
                    "key": "FFmpegVideoConvertor",
                    "preferedformat": "mp4",
                }
            ],
        }

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            logging.info("📥 Downloading video + audio...")
            info = ydl.extract_info(youtube_url, download=True)

            if not info:
                return {"success": False, "error": "Could not download video"}

            title = info.get("title", "video")
            title = re.sub(r'[\\/*?:"<>|]', "_", title)

            # yt-dlp will produce <title>.mp4 after merging
            downloaded_file = None
            for ext in (".mp4", ".mkv", ".webm"):
                candidate = os.path.join(output_dir, f"{title}{ext}")
                if os.path.exists(candidate):
                    downloaded_file = candidate
                    break

            # Fallback: any recently created video file in the folder
            if not downloaded_file:
                newest = None
                newest_mtime = 0
                for f in os.listdir(output_dir):
                    if f.endswith((".mp4", ".mkv", ".webm")):
                        fp = os.path.join(output_dir, f)
                        m = os.path.getmtime(fp)
                        if m > time.time() - 600 and m > newest_mtime:
                            newest = fp
                            newest_mtime = m
                downloaded_file = newest

            if not downloaded_file:
                return {"success": False, "error": "Downloaded file not found"}

            # Rename if a specific filename was requested
            if filename and os.path.exists(downloaded_file):
                _, ext = os.path.splitext(downloaded_file)
                new_filename = filename
                if not new_filename.endswith(ext):
                    new_filename = f"{new_filename}{ext}"
                new_path = os.path.join(output_dir, new_filename)
                if os.path.abspath(new_path) != os.path.abspath(downloaded_file):
                    # Avoid overwriting an existing file of the same name
                    if os.path.exists(new_path):
                        os.remove(new_path)
                    os.rename(downloaded_file, new_path)
                downloaded_file = new_path

            file_size = os.path.getsize(downloaded_file)
            logging.info(
                "✅ Download complete: %s (%s bytes)",
                os.path.basename(downloaded_file),
                file_size,
            )

            # Verify audio actually exists
            has_audio = _file_has_audio_stream(downloaded_file)
            logging.info("🎵 Audio present: %s", has_audio)
            if not has_audio:
                logging.warning(
                    "⚠️ Downloaded file has NO audio stream: %s",
                    downloaded_file,
                )

            return {
                "success": True,
                "file_path": downloaded_file,
                "title": title,
                "filename": os.path.basename(downloaded_file),
                "duration": info.get("duration", 0),
                "filesize": file_size,
                "has_audio": has_audio,
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


def convert_video_to_browser_compatible(input_path, output_path):
    """
    Convert video to browser-compatible format (H.264/AAC in MP4 container).
    Returns True if successful, False otherwise.
    """
    try:
        # Check if ffmpeg is available
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)

        # Convert to H.264/AAC in MP4 container
        cmd = [
            "ffmpeg",
            "-i",
            input_path,
            "-c:v",
            "libx264",  # H.264 video codec
            "-c:a",
            "aac",  # AAC audio codec
            "-movflags",
            "+faststart",  # Optimize for web streaming
            "-profile:v",
            "main",  # Main profile for better compatibility
            "-level",
            "4.0",  # 4.0 covers 1080p; 3.1 is too tight for many sources
            "-pix_fmt",
            "yuv420p",  # YUV 4:2:0 for compatibility
            "-crf",
            "26",  # Quality level (18-28, 23 is good)
            "-preset",
            "veryfast",  # Encoding speed vs quality, was "medium" — 5–10× faster
            "-y",  # Overwrite output file
            output_path,
        ]

        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=300
        )

        if (
            result.returncode == 0
            and os.path.exists(output_path)
            and os.path.getsize(output_path) > 0
        ):
            logging.info(
                "✅ Video converted to browser-compatible format: %s", output_path
            )
            return True
        else:
            logging.error("❌ Video conversion failed: %s", result.stderr)
            return False

    except subprocess.TimeoutExpired:
        logging.error("❌ Video conversion timeout")
        return False
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logging.error("❌ Video conversion error: %s", e)
        return False


@app.route("/session-refresh/<path:session_id>", methods=["POST"])
def session_refresh(session_id):
    """Force a re-download of a session from the internal server."""
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")
    if not token:
        return jsonify({"error": "No token provided"}), 401

    session_dir = _session_dir(session_id)
    if os.path.exists(session_dir):
        shutil.rmtree(session_dir)
    os.makedirs(session_dir, exist_ok=True)

    download_session_files(session_id, token)
    return jsonify({"success": True, "session_id": session_id}), 200
