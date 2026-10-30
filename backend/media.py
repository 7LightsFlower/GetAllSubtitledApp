"""Subtitle extraction, audio extraction, green-screen videos.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import hashlib
import logging
import os
import re
import subprocess
import tempfile
import uuid

from .config import UPLOAD_FOLDER, USE_GREEN_SCREEN_UPLOAD, sessions, videos
from .state import save_state
from .utils import _ensure_greenscreen_fields


def _file_has_audio_stream(path):
    """Return True if the file has at least one audio stream."""
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "a",
                "-show_entries",
                "stream=index",
                "-of",
                "csv=p=0",
                path,
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        return bool(result.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        return False


def _get_session_original_video_path(session_id: str) -> str | None:
    """Path to the original full-quality video for a session.

    The session folder only ever contains a green-screen placeholder;
    the real video lives in UPLOAD_FOLDER and is found via
    sessions[session_id]['video_key'] -> videos[...]['file_name'].
    """
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


def extract_audio_from_video(video_path: str, output_dir: str | None = None):
    """Extract audio to a compressed .m4a. Returns (path, duration) or (None, 0)."""
    if not os.path.exists(video_path) or not _file_has_audio_stream(video_path):
        return None, 0.0

    duration = 0.0
    try:
        r = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                video_path,
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
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
    # 32 kbps mono Opus: ~8 MB for a 42-minute lecture. Perfectly fine
    # for speech recognition. Switch to AAC if the internal server
    # turns out to reject .webm — see `codec` below.
    codec = "libopus"  # or "aac" for .m4a
    ext = ".webm"  # or ".m4a" for AAC
    audio_path = os.path.join(output_dir, f"{safe}_{uuid.uuid4().hex[:8]}{ext}")

    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        video_path,
        "-vn",
        "-map",
        "0:a:0",
        "-ac",
        "1",  # mono
        "-ar",
        "16000",  # 16 kHz — enough for speech
        "-c:a",
        codec,
        "-b:a",
        "32k",
        audio_path,
    ]
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True, timeout=1800, check=False
        )
    except (subprocess.TimeoutExpired, OSError, subprocess.SubprocessError) as e:
        logging.error("extract_audio: %s", e)
        return None, 0.0

    if (
        r.returncode != 0
        or not os.path.exists(audio_path)
        or os.path.getsize(audio_path) < 1000
    ):
        logging.error(
            "extract_audio: rc=%s stderr=%s", r.returncode, (r.stderr or "")[-500:]
        )
        if os.path.exists(audio_path):
            try:
                os.remove(audio_path)
            except OSError:
                pass
        return None, 0.0

    logging.info(
        "🎵 Extracted audio: %s (%.1f MB, %.1fs)",
        os.path.basename(audio_path),
        os.path.getsize(audio_path) / (1024 * 1024),
        duration,
    )
    return audio_path, duration


def create_green_screen_video(
    audio_path, output_path, duration, width=320, height=240, fps=5, color="0x00FF00"
) -> bool:
    """Build a small solid-colour video with this audio."""
    if not os.path.exists(audio_path):
        return False
    if duration <= 0:
        duration = 60.0

    cmd = [
        "ffmpeg",
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"color=c={color}:s={width}x{height}:r={fps}:d={duration}",
        "-i",
        audio_path,
        "-shortest",
        "-c:v",
        "libx264",
        "-tune",
        "stillimage",
        "-preset",
        "ultrafast",
        "-crf",
        "35",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "96k",
        "-movflags",
        "+faststart",
        output_path,
    ]
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True, timeout=1800, check=False
        )
    except (subprocess.TimeoutExpired, OSError, subprocess.SubprocessError) as e:
        logging.error("green_screen: %s", e)
        return False

    if (
        r.returncode != 0
        or not os.path.exists(output_path)
        or os.path.getsize(output_path) < 1000
    ):
        logging.error(
            "green_screen: rc=%s stderr=%s", r.returncode, (r.stderr or "")[-500:]
        )
        return False

    logging.info(
        "🟩 Green-screen video: %s (%.1f MB)",
        os.path.basename(output_path),
        os.path.getsize(output_path) / (1024 * 1024),
    )
    return True


def prepare_upload_source(original_video_path: str) -> tuple[str, str, list[str]]:
    """Decide what to send to the internal server.

    Returns (source_path, upload_filename, cleanup_list).

    If USE_GREEN_SCREEN_UPLOAD is off, or green-screen generation fails,
    returns (original_video_path, basename, []) — the caller's existing
    multipart code then behaves exactly as it did before.
    """
    if not USE_GREEN_SCREEN_UPLOAD:
        return (original_video_path, os.path.basename(original_video_path), [])

    audio_path, duration = extract_audio_from_video(original_video_path)
    if audio_path is None:
        logging.warning(
            "prepare_upload_source: audio extraction failed; "
            "falling back to original upload"
        )
        return (original_video_path, os.path.basename(original_video_path), [])

    cleanup = [audio_path]
    gs_path = os.path.join(tempfile.gettempdir(), f"green_{uuid.uuid4().hex[:8]}.mp4")
    if not create_green_screen_video(audio_path, gs_path, duration):
        logging.warning(
            "prepare_upload_source: green-screen build failed; "
            "falling back to original upload"
        )
        return (original_video_path, os.path.basename(original_video_path), cleanup)

    cleanup.append(gs_path)
    return (gs_path, "green_screen.mp4", cleanup)


def prepare_upload_source_cached(
    original_video_path: str,
    video_key: str | None,
) -> tuple[str, str, list[str]]:
    """Like prepare_upload_source, but reuses a pre-built green-screen
    if one exists on disk for this project.

    Returns (source_path, upload_filename, cleanup_list). The cleanup
    list is empty when the cached file is used (we must not delete it),
    and contains the temp files when generation happened on the fly.
    """
    if video_key:
        project = next((v for v in videos if v.get("key") == video_key), None)
        if project is not None:
            _ensure_greenscreen_fields(project)
            gs_name = project.get("greenscreen_file_name")
            if gs_name:
                gs_path = os.path.join(UPLOAD_FOLDER, gs_name)
                if os.path.exists(gs_path) and os.path.getsize(gs_path) > 1000:
                    logging.info(
                        "internal_upload: using cached green-screen %s",
                        gs_name,
                    )
                    return gs_path, gs_name, []

    # No cached file — fall back to the existing on-the-fly path.
    return prepare_upload_source(original_video_path)

def _greenscreen_filename(original_name: str) -> str:
    """Build a deterministic, collision-resistant green-screen filename.

    The old scheme was ``<ascii_stem>__greenscreen.mp4`` where every
    non-ASCII character was flattened to ``_``. Two Cyrillic lectures
    with the same ASCII skeleton (e.g. both ending in ``(15.10.2026)``)
    collapsed to the same file and shared a green-screen. The hash of
    the *original* name — not the ASCII-folded one — makes each source
    produce a distinct file, while keeping the human-readable stem for
    anyone browsing the uploads/ folder.

    Stem is truncated to 50 chars so the full name stays well inside
    PATH_MAX on Windows even with a long UPLOAD_FOLDER prefix.
    """
    base = os.path.splitext(original_name)[0]
    stem = re.sub(r"[^A-Za-z0-9_.-]", "_", base)[:50].strip("_") or "video"
    digest = hashlib.sha1(original_name.encode("utf-8")).hexdigest()[:10]
    return f"{stem}__{digest}__greenscreen.mp4"


def _build_greenscreen_for_project(video_key: str) -> bool:
    """Build the audio+green-screen stand-in for one project.

    On success, writes the file into UPLOAD_FOLDER and updates the
    project dict with `greenscreen_file_name`, `greenscreen_status`
    and `greenscreen_progress`. Idempotent: if a usable file already
    exists, returns immediately.
    """
    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        logging.warning("greenscreen: project %s not found", video_key)
        return False

    _ensure_greenscreen_fields(project)

    # Already done? Bail.
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

    # Two steps: extract audio → mux into a small green-screen mp4.
    # Both intermediate and final files live in UPLOAD_FOLDER so they
    # survive a restart; the temp audio is deleted afterwards.
    gs_name = _greenscreen_filename(original_name)
    gs_path = os.path.join(UPLOAD_FOLDER, gs_name)

    # If a green-screen from the *old* naming scheme exists for this
    # project, and the project dict still points at it, migrate the
    # record rather than orphaning the file. Only the field changes;
    # the on-disk file keeps its old name so nothing needs moving.
    legacy_gs = project.get("greenscreen_file_name") or ""
    if legacy_gs and legacy_gs != gs_name:
        legacy_path = os.path.join(UPLOAD_FOLDER, legacy_gs)
        if os.path.exists(legacy_path) and os.path.getsize(legacy_path) > 1000:
            logging.info(
                "greenscreen: keeping legacy file %s for %s",
                legacy_gs, video_key,
            )
            return True

    audio_path = None
    try:
        audio_path, duration = extract_audio_from_video(original_path, UPLOAD_FOLDER)
        if audio_path is None:
            logging.warning("greenscreen: audio extraction failed for %s", video_key)
            project["greenscreen_status"] = "failed"
            save_state()
            return False

        project["greenscreen_progress"] = 50
        save_state()

        if not create_green_screen_video(audio_path, gs_path, duration):
            logging.warning("greenscreen: mux failed for %s", video_key)
            project["greenscreen_status"] = "failed"
            save_state()
            return False

        project["greenscreen_file_name"] = gs_name
        project["greenscreen_status"] = "ready"
        project["greenscreen_progress"] = 100
        save_state()

        logging.info(
            "✅ Greenscreen ready for %s → %s (%.1f MB)",
            video_key,
            gs_name,
            os.path.getsize(gs_path) / (1024 * 1024),
        )
        return True

    finally:
        if audio_path and os.path.exists(audio_path):
            try:
                os.remove(audio_path)
            except OSError:
                pass
