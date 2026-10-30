"""Video thumbnails and metadata (ffprobe/ffmpeg).

Split mechanically from the former lib/backend.py — code unchanged.
"""

import json
import logging
import os
import subprocess


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
    """Extract video metadata using ffprobe.

    Returns (duration, fps, codec) where codec is a short label such
    as "h264 (High)", "hevc (Main)", "vp9", "av1", or "" on failure.

    The previous 2-tuple signature was extended to include the codec
    so the project card can flag browser-incompatible formats. Every
    caller must unpack all three values.
    """
    try:
        cmd = [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=duration,r_frame_rate,codec_name,profile",
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

                codec_name = (stream.get("codec_name") or "").strip()
                profile = (stream.get("profile") or "").strip()
                if codec_name and profile:
                    codec = f"{codec_name} ({profile})"
                else:
                    codec = codec_name

                return duration, fps, codec
    except (
        subprocess.SubprocessError,
        FileNotFoundError,
        json.JSONDecodeError,
        TypeError,
        ValueError,
        OSError,
    ) as e:
        logging.warning("Failed to get video metadata: %s", e)
    return 120.0, 30.0, ""
