import importlib
import logging
import os
import re
import subprocess
import threading
import uuid

from flask import Blueprint, jsonify, request

from ..config import UPLOAD_FOLDER, USER_AGENT
from ..progress import (
    _progress_event, _progress_finish, _progress_init,
)
from ..state import jobs, save_state, videos
from ..utils import utc_now_iso
from ..video import (
    convert_video_to_browser_compatible, generate_video_thumbnail_simple,
    get_video_metadata,
)
from ..youtube import (
    download_youtube_video_adaptive, get_youtube_video_info,
)

bp = Blueprint("youtube", __name__)


@bp.route("/api/youtube-info", methods=["POST", "OPTIONS"])
def youtube_info():
    if request.method == "OPTIONS":
        return ("", 204)
    try:
        data = request.get_json()
        if not data or "url" not in data:
            return jsonify({"error": "URL is required"}), 400
        result = get_youtube_video_info(data["url"])
        if result.get("success"):
            return jsonify({
                "success": True,
                "video_id": result.get("video_id"),
                "title": result.get("title"),
                "duration": result.get("duration"),
                "thumbnail": result.get("thumbnail"),
                "format": result.get("format"),
                "url": result.get("url"),
            }), 200
        return jsonify({"success": False,
                        "error": result.get("error", "Unknown error")}), 400
    except (ValueError, TypeError, KeyError) as e:
        return jsonify({"error": str(e)}), 500


@bp.route("/api/youtube-download-and-upload", methods=["POST", "OPTIONS"])
def youtube_download_and_upload():
    if request.method == "OPTIONS":
        return ("", 204)
    download_id = None
    try:
        data = request.get_json()
        if not data or "url" not in data:
            return jsonify({"error": "URL is required"}), 400
        youtube_url = data["url"]
        auto_segmentation = data.get("auto_segmentation", True)
        download_id = data.get("download_id")

        if download_id:
            _progress_init(download_id, youtube_url)
        _progress_event(download_id, "Starting YouTube download",
                        stage="info", progress=0.02)

        try:
            import yt_dlp
            opts = {"quiet": True, "no_warnings": True,
                    "http_headers": {"User-Agent": USER_AGENT}}
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(youtube_url, download=False)
            title = info.get("title", "youtube_video")
            duration = info.get("duration", 0)
            display_title = re.sub(r'[\\/*?:"<>|]+', "", title).strip()
            display_title = re.sub(r"\s+", " ", display_title) or "youtube_video"
            safe_title = re.sub(r'[\\/*?:"<>|]+', "_", title).strip()
            safe_title = re.sub(r"\s+", "_", safe_title) or "youtube_video"
            filename = f"{safe_title}.mp4"
            if len(filename) > 200:
                base, ext = os.path.splitext(filename)
                filename = f"{base[:195]}{ext}"
            _progress_event(download_id, f"Video: {title}",
                            stage="info", progress=0.08,
                            details={"title": display_title, "duration": duration,
                                     "filename": filename})
        except Exception as e:  # noqa: BLE001
            _progress_finish(download_id, error=f"Info error: {e}")
            return jsonify({"success": False, "error": f"Info error: {e}"}), 400

        _progress_event(download_id, "Downloading video + audio…",
                        stage="downloading", progress=0.15)
        dl = download_youtube_video_adaptive(youtube_url, UPLOAD_FOLDER, filename)
        if not dl.get("success"):
            msg = dl.get("error", "Download failed")
            _progress_finish(download_id, error=msg)
            return jsonify({"success": False, "error": msg}), 400

        file_path = dl["file_path"]
        file_size = dl.get("filesize", 0)
        duration = dl.get("duration", duration)
        actual_filename = dl.get("filename", filename)
        has_audio = dl.get("has_audio", False)

        _progress_event(download_id,
                        f"Download complete: {actual_filename} ({file_size} bytes)",
                        stage="downloaded", progress=0.45,
                        details={"filename": actual_filename,
                                 "filesize": file_size, "duration": duration,
                                 "has_audio": has_audio})

        if file_size < 1000:
            if os.path.exists(file_path):
                try:
                    os.remove(file_path)
                except OSError:
                    pass
            _progress_finish(download_id, error="Downloaded file is too small")
            return jsonify({"error": "Downloaded file is too small"}), 500

        # codec check + conversion
        codec = ""
        try:
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=codec_name",
                 "-of", "default=noprint_wrappers=1:nokey=1", file_path],
                capture_output=True, text=True, timeout=10, check=False)
            codec = probe.stdout.strip() if probe.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            pass

        if codec and codec != "h264":
            _progress_event(download_id,
                            "Converting video to browser-compatible format…",
                            stage="converting", progress=0.55)
            try:
                base_name = os.path.splitext(actual_filename)[0]
                converted = os.path.join(UPLOAD_FOLDER, f"{base_name}_converted.mp4")
                if convert_video_to_browser_compatible(file_path, converted):
                    backup = file_path + ".backup"
                    os.rename(file_path, backup)
                    os.rename(converted, file_path)
                    file_size = os.path.getsize(file_path)
                    actual_filename = os.path.basename(file_path)
                    _progress_event(download_id,
                                    f"Conversion complete: {actual_filename}",
                                    stage="converted", progress=0.70)
                    if os.path.exists(backup):
                        os.remove(backup)
                else:
                    if os.path.exists(converted):
                        os.remove(converted)
            except (OSError, subprocess.SubprocessError):
                pass

        # thumbnail
        try:
            thumb_name = f"{os.path.splitext(actual_filename)[0]}_thumb.jpg"
            thumb_path = os.path.join(UPLOAD_FOLDER, thumb_name)
            thumbnail_url = None
            if generate_video_thumbnail_simple(file_path, thumb_path):
                thumbnail_url = f"/thumbnails/{thumb_name}"
            else:
                try:
                    cv2 = importlib.import_module("cv2")
                    cap = cv2.VideoCapture(file_path)
                    ret, frame = cap.read()
                    if ret:
                        cv2.imwrite(thumb_path, frame)
                        thumbnail_url = f"/thumbnails/{thumb_name}"
                    cap.release()
                except (ImportError, OSError, RuntimeError, ValueError, TypeError):
                    pass
        except (OSError, RuntimeError, ValueError, TypeError):
            thumbnail_url = None

        if duration == 0:
            duration, fps, probed = get_video_metadata(file_path)
            if probed:
                codec = probed
        else:
            fps = 30.0

        existing = next((v for v in videos if v.get("file_name") == actual_filename),
                        None)
        if existing is not None:
            project = existing
            video_key = existing["key"]
            project.update({
                "name": display_title, "file_size": file_size,
                "duration": duration, "fps": fps, "codec": codec,
                "thumbnail_url": thumbnail_url, "source": youtube_url,
            })
        else:
            video_key = str(uuid.uuid4())
            project = {
                "key": video_key, "name": display_title,
                "file_name": actual_filename, "uploaded": utc_now_iso(),
                "last_opened": None, "duration": duration, "fps": fps,
                "codec": codec, "file_size": file_size,
                "segment_count": 0, "languages": ["en"],
                "thumbnail_url": thumbnail_url,
                "segmentation_done": auto_segmentation,
                "segmentation_progress": 100 if auto_segmentation else 0,
                "source": youtube_url,
            }
            videos.append(project)
        save_state()

        if auto_segmentation:
            job_id = str(uuid.uuid4())
            jobs[job_id] = {
                "id": job_id, "video_key": video_key, "status": "processing",
                "progress": 0.0, "transcript": None, "segments": None,
                "created_at": utc_now_iso(),
                "config": {"auto_segmentation": True},
            }
            save_state()

        _progress_event(download_id, f'Imported "{display_title}"',
                        stage="done", progress=1.0)
        _progress_finish(download_id,
                         details={"title": display_title, "video_key": video_key})
        return jsonify({
            "success": True,
            "video_info": {
                "title": display_title, "duration": duration,
                "file_size": file_size, "thumbnail": thumbnail_url,
                "has_audio": has_audio,
            },
            "project": project,
            "message": f'Video "{display_title}" imported successfully',
            "filename": actual_filename,
            "video_key": video_key,
        }), 200

    except (OSError, RuntimeError, ValueError, TypeError, KeyError) as e:
        logging.error("YouTube download error: %s", e, exc_info=True)
        _progress_finish(download_id, error=f"Server error: {e}")
        return jsonify({"success": False, "error": f"Server error: {e}"}), 500


@bp.route("/api/download-progress/<download_id>", methods=["GET", "OPTIONS"])
def download_progress_status(download_id):
    if request.method == "OPTIONS":
        return ("", 204)
    from ..progress import (
        _progress_cleanup_old, download_progress, download_progress_lock,
    )
    _progress_cleanup_old()
    with download_progress_lock:
        entry = download_progress.get(download_id)
    if entry is None:
        return jsonify({"error": "not_found", "download_id": download_id}), 404
    return jsonify(entry), 200