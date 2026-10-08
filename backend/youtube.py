"""YouTube import: fetch info and download to UPLOAD_FOLDER."""

from __future__ import annotations

import os
import re
import time

import yt_dlp

from .config import USER_AGENT
from .video import file_has_audio_stream


def extract_youtube_video_id(url: str) -> str | None:
    """Extract a YouTube video ID from a supported YouTube URL."""
    patterns = [
        r"youtube\.com/watch\?v=([^&]+)",
        r"youtu\.be/([^?]+)",
        r"youtube\.com/shorts/([^?]+)",
        r"youtube\.com/embed/([^?]+)",
        r"youtube\.com/v/([^?]+)",
        r"youtube\.com/e/([^?]+)",
        r"m\.youtube\.com/watch\?v=([^&]+)",
    ]
    for p in patterns:
        m = re.search(p, url)
        if m:
            return m.group(1)
    return None


def is_youtube_url(url: str) -> bool:
    """Return whether a URL points to a supported YouTube page."""
    markers = (
        "youtube.com/watch?v=",
        "youtu.be/",
        "youtube.com/shorts/",
        "youtube.com/embed/",
        "youtube.com/v/",
        "youtube.com/e/",
        "m.youtube.com/watch?v=",
    )
    return any(m in url.lower() for m in markers)


def get_youtube_video_info(youtube_url):
    """Extract and return metadata for a supported YouTube video URL."""
    result = {"success": False, "error": "Unknown error"}

    try:
        if not is_youtube_url(youtube_url):
            result["error"] = "Not a valid YouTube URL"
        else:
            video_id = extract_youtube_video_id(youtube_url)
            if not video_id:
                result["error"] = "Could not extract video ID"
            else:
                opts = {
                    "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                    "quiet": True,
                    "no_warnings": True,
                    "extract_flat": False,
                    "http_headers": {"User-Agent": USER_AGENT},
                }
                with yt_dlp.YoutubeDL(opts) as ydl:
                    info = ydl.extract_info(youtube_url, download=False)

                if not info:
                    result["error"] = "Could not extract video information"
                else:
                    video_url = info.get("url")
                    if not video_url:
                        for fmt in info.get("formats", []):
                            if fmt.get("ext") == "mp4" and fmt.get("vcodec") != "none":
                                video_url = fmt.get("url")
                                break
                        if not video_url and info.get("formats"):
                            video_url = info["formats"][0].get("url")

                    if not video_url:
                        result["error"] = "Could not find video URL"
                    else:
                        title = re.sub(r'[\\/*?:"<>|]', "_", info.get("title", "video"))
                        result = {
                            "success": True,
                            "url": video_url,
                            "title": title,
                            "duration": info.get("duration", 0),
                            "thumbnail": info.get("thumbnail", ""),
                            "video_id": video_id,
                            "format": info.get("format", "mp4"),
                            "ext": info.get("ext", "mp4"),
                            "filesize": info.get("filesize", 0),
                        }
    except yt_dlp.utils.DownloadError as e:
        result["error"] = f"Download error: {e}"
    except yt_dlp.utils.ExtractorError as e:
        result["error"] = f"Extractor error: {e}"
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as e:
        result["error"] = f"Error: {e}"

    return result


def _find_downloaded_file(output_dir, title):
    """Return the expected downloaded file, or the newest recent video."""
    for ext in (".mp4", ".mkv", ".webm"):
        candidate = os.path.join(output_dir, f"{title}{ext}")
        if os.path.exists(candidate):
            return candidate

    newest = None
    newest_mtime = 0
    for filename in os.listdir(output_dir):
        if not filename.endswith((".mp4", ".mkv", ".webm")):
            continue
        candidate = os.path.join(output_dir, filename)
        modified = os.path.getmtime(candidate)
        if modified > time.time() - 600 and modified > newest_mtime:
            newest, newest_mtime = candidate, modified
    return newest


def _rename_downloaded_file(downloaded, output_dir, filename):
    """Rename a downloaded file while preserving its extension."""
    _, ext = os.path.splitext(downloaded)
    new_name = filename if filename.endswith(ext) else f"{filename}{ext}"
    new_path = os.path.join(output_dir, new_name)
    if os.path.abspath(new_path) != os.path.abspath(downloaded):
        if os.path.exists(new_path):
            os.remove(new_path)
        os.rename(downloaded, new_path)
    return new_path


def download_youtube_video_adaptive(youtube_url, output_dir, filename=None):
    """Download a YouTube video and return details about the resulting file."""
    try:
        if not is_youtube_url(youtube_url):
            return {"success": False, "error": "Not a valid YouTube URL"}
        os.makedirs(output_dir, exist_ok=True)

        format_selector = (
            "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/"
            "bv*[vcodec^=avc1]+ba/"
            "bv*[ext=mp4]+ba[ext=m4a]/"
            "bv*[ext=mp4]+ba/"
            "bv*+ba/"
            "b[ext=mp4]/b"
        )
        opts = {
            "format": format_selector,
            "outtmpl": os.path.join(output_dir, "%(title)s.%(ext)s"),
            "quiet": True,
            "no_warnings": True,
            "ignoreerrors": True,
            "merge_output_format": "mp4",
            "http_headers": {"User-Agent": USER_AGENT},
            "postprocessors": [
                {
                    "key": "FFmpegVideoConvertor",
                    "preferedformat": "mp4",
                }
            ],
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(youtube_url, download=True)
        if not info:
            return {"success": False, "error": "Could not download video"}

        title = re.sub(r'[\\/*?:"<>|]', "_", info.get("title", "video"))
        downloaded = _find_downloaded_file(output_dir, title)
        if not downloaded:
            return {"success": False, "error": "Downloaded file not found"}
        if filename:
            downloaded = _rename_downloaded_file(downloaded, output_dir, filename)

        return {
            "success": True,
            "file_path": downloaded,
            "title": title,
            "filename": os.path.basename(downloaded),
            "duration": info.get("duration", 0),
            "filesize": os.path.getsize(downloaded),
            "has_audio": file_has_audio_stream(downloaded),
        }
    except yt_dlp.utils.DownloadError as e:
        return {"success": False, "error": f"Download error: {e}"}
    except (OSError, RuntimeError, ValueError, TypeError, KeyError) as e:
        return {"success": False, "error": f"Error: {e}"}


def get_youtube_video_info_legacy(youtube_url):
    """Backwards-compatible name used by route handler."""
    return get_youtube_video_info(youtube_url)
