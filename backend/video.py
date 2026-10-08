"""ffmpeg-based video work: metadata, thumbnails, green-screen stand-ins."""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import uuid

from .config import UPLOAD_FOLDER, USE_GREEN_SCREEN_UPLOAD
from .state import videos
from .utils import ensure_greenscreen_fields


def get_video_metadata(video_path: str) -> tuple[float, float, str]:
    try:
        cmd = [
            "ffprobe", "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=duration,r_frame_rate,codec_name,profile",
            "-of", "json", video_path,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True,
                                timeout=10, check=False)
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
                codec = f"{codec_name} ({profile})" if codec_name and profile else codec_name
                return duration, fps, codec
    except (subprocess.SubprocessError, FileNotFoundError, json.JSONDecodeError,
            TypeError, ValueError, OSError) as e:
        logging.warning("Failed to get video metadata: %s", e)
    return 120.0, 30.0, ""


def generate_video_thumbnail(video_path, thumbnail_path, time_offset=1.0) -> bool:
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        cmd = [
            "ffmpeg", "-i", video_path, "-ss", str(time_offset),
            "-vframes", "1", "-vf", "scale=320:-1", "-q:v", "2",
            "-y", thumbnail_path,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True,
                                check=False, timeout=30)
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


def generate_video_thumbnail_simple(video_path, thumbnail_path) -> bool:
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        duration = 0.0
        try:
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", video_path],
                capture_output=True, text=True, timeout=10, check=False,
            )
            if probe.returncode == 0 and probe.stdout.strip():
                duration = float(probe.stdout.strip())
        except (OSError, ValueError, subprocess.SubprocessError):
            pass

        positions = [1.0, 5.0, 10.0]
        if duration > 30:
            positions.append(duration * 0.5)
        if duration > 60:
            positions += [duration * 0.25, duration * 0.75]

        for pos in positions:
            if pos >= duration:
                continue
            cmd = [
                "ffmpeg", "-ss", str(pos), "-i", video_path,
                "-vframes", "1", "-vf", "scale=320:-1:flags=lanczos",
                "-q:v", "2", "-y", thumbnail_path,
            ]
            r = subprocess.run(cmd, capture_output=True, text=True,
                               check=False, timeout=30)
            if (r.returncode == 0 and os.path.exists(thumbnail_path)
                    and os.path.getsize(thumbnail_path) > 1000):
                return True

        cmd = [
            "ffmpeg", "-i", video_path, "-vframes", "1",
            "-vf", "scale=320:-1:flags=lanczos", "-q:v", "2", "-y",
            thumbnail_path,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True,
                           check=False, timeout=30)
        return (r.returncode == 0 and os.path.exists(thumbnail_path)
                and os.path.getsize(thumbnail_path) > 1000)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        logging.warning("Thumbnail generation error: %s", e)
        return False


def file_has_audio_stream(path: str) -> bool:
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a",
             "-show_entries", "stream=index", "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=15, check=False,
        )
        return bool(r.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        return False


def extract_audio_from_video(video_path: str, output_dir: str | None = None):
    if not os.path.exists(video_path) or not file_has_audio_stream(video_path):
        return None, 0.0

    duration = 0.0
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", video_path],
            capture_output=True, text=True, timeout=15, check=False,
        )
        if r.returncode == 0 and r.stdout.strip():
            duration = float(r.stdout.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        pass

    if output_dir is None:
        output_dir = tempfile.gettempdir()
    os.makedirs(output_dir, exist_ok=True)

    base = os.path.splitext(os.path.basename(video_path))[0]
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", base)[:60] or "audio"
    audio_path = os.path.join(output_dir, f"{safe}_{uuid.uuid4().hex[:8]}.webm")

    cmd = [
        "ffmpeg", "-y", "-i", video_path, "-vn", "-map", "0:a:0",
        "-ac", "1", "-ar", "16000", "-c:a", "libopus", "-b:a", "32k",
        audio_path,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=1800, check=False)
    except (subprocess.TimeoutExpired, OSError, subprocess.SubprocessError) as e:
        logging.error("extract_audio: %s", e)
        return None, 0.0

    if (r.returncode != 0 or not os.path.exists(audio_path)
            or os.path.getsize(audio_path) < 1000):
        logging.error("extract_audio: rc=%s stderr=%s",
                      r.returncode, (r.stderr or "")[-500:])
        if os.path.exists(audio_path):
            try:
                os.remove(audio_path)
            except OSError:
                pass
        return None, 0.0

    return audio_path, duration


def create_green_screen_video(audio_path, output_path, duration,
                              width=320, height=240, fps=5,
                              color="0x00FF00") -> bool:
    if not os.path.exists(audio_path):
        return False
    if duration <= 0:
        duration = 60.0
    cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi", "-i",
        f"color=c={color}:s={width}x{height}:r={fps}:d={duration}",
        "-i", audio_path, "-shortest",
        "-c:v", "libx264", "-tune", "stillimage", "-preset", "ultrafast",
        "-crf", "35", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "96k",
        "-movflags", "+faststart", output_path,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=1800, check=False)
    except (subprocess.TimeoutExpired, OSError, subprocess.SubprocessError) as e:
        logging.error("green_screen: %s", e)
        return False
    if (r.returncode != 0 or not os.path.exists(output_path)
            or os.path.getsize(output_path) < 1000):
        logging.error("green_screen: rc=%s stderr=%s",
                      r.returncode, (r.stderr or "")[-500:])
        return False
    return True


def prepare_upload_source(original_path: str) -> tuple[str, str, list[str]]:
    if not USE_GREEN_SCREEN_UPLOAD:
        return original_path, os.path.basename(original_path), []
    audio_path, duration = extract_audio_from_video(original_path)
    if audio_path is None:
        logging.warning("prepare_upload_source: audio extraction failed; "
                        "falling back to original upload")
        return original_path, os.path.basename(original_path), []
    cleanup = [audio_path]
    gs_path = os.path.join(tempfile.gettempdir(),
                           f"green_{uuid.uuid4().hex[:8]}.mp4")
    if not create_green_screen_video(audio_path, gs_path, duration):
        return original_path, os.path.basename(original_path), cleanup
    cleanup.append(gs_path)
    return gs_path, "green_screen.mp4", cleanup


def prepare_upload_source_cached(original_path: str, video_key: str | None):
    if video_key:
        project = next((v for v in videos if v.get("key") == video_key), None)
        if project is not None:
            ensure_greenscreen_fields(project)
            gs_name = project.get("greenscreen_file_name")
            if gs_name:
                gs_path = os.path.join(UPLOAD_FOLDER, gs_name)
                if os.path.exists(gs_path) and os.path.getsize(gs_path) > 1000:
                    logging.info("internal_upload: using cached green-screen %s",
                                 gs_name)
                    return gs_path, gs_name, []
    return prepare_upload_source(original_path)


def build_greenscreen_for_project(video_key: str) -> bool:
    from .state import save_state
    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        logging.warning("greenscreen: project %s not found", video_key)
        return False
    ensure_greenscreen_fields(project)

    existing = project.get("greenscreen_file_name")
    if existing:
        p = os.path.join(UPLOAD_FOLDER, existing)
        if os.path.exists(p) and os.path.getsize(p) > 1000:
            project["greenscreen_status"] = "ready"
            project["greenscreen_progress"] = 100
            return True

    original_name = project.get("file_name")
    if not original_name:
        project["greenscreen_status"] = "failed"
        return False
    original_path = os.path.join(UPLOAD_FOLDER, original_name)
    if not os.path.exists(original_path):
        project["greenscreen_status"] = "failed"
        save_state()
        return False

    project["greenscreen_status"] = "building"
    project["greenscreen_progress"] = 5
    save_state()

    base = os.path.splitext(original_name)[0]
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", base)[:60] or "video"
    gs_name = f"{safe}__greenscreen.mp4"
    gs_path = os.path.join(UPLOAD_FOLDER, gs_name)

    audio_path = None
    try:
        audio_path, duration = extract_audio_from_video(original_path, UPLOAD_FOLDER)
        if audio_path is None:
            project["greenscreen_status"] = "failed"
            save_state()
            return False
        project["greenscreen_progress"] = 50
        save_state()
        if not create_green_screen_video(audio_path, gs_path, duration):
            project["greenscreen_status"] = "failed"
            save_state()
            return False
        project["greenscreen_file_name"] = gs_name
        project["greenscreen_status"] = "ready"
        project["greenscreen_progress"] = 100
        save_state()
        return True
    finally:
        if audio_path and os.path.exists(audio_path):
            try:
                os.remove(audio_path)
            except OSError:
                pass


def convert_video_to_browser_compatible(input_path, output_path) -> bool:
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        cmd = [
            "ffmpeg", "-i", input_path,
            "-c:v", "libx264", "-c:a", "aac",
            "-movflags", "+faststart",
            "-profile:v", "main", "-level", "4.0",
            "-pix_fmt", "yuv420p", "-crf", "26", "-preset", "veryfast",
            "-y", output_path,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True,
                           check=False, timeout=300)
        return (r.returncode == 0 and os.path.exists(output_path)
                and os.path.getsize(output_path) > 0)
    except subprocess.TimeoutExpired:
        logging.error("Video conversion timeout")
        return False
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logging.error("Video conversion error: %s", e)
        return False


def get_session_original_video_path(session_id: str) -> str | None:
    from .state import sessions
    sess = sessions.get(session_id) or {}
    video_key = sess.get("video_key")
    if not video_key:
        return None
    for v in videos:
        if v.get("key") == video_key:
            fn = v.get("file_name")
            if fn:
                p = os.path.join(UPLOAD_FOLDER, fn)
                if os.path.exists(p):
                    return p
    return None