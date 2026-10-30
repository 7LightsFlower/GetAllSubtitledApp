"""Session refresh / resync and completeness checks.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import importlib
import json
import logging
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
import requests
import yt_dlp
from flask import jsonify, request

from .flask_app import app
from .config import UPLOAD_FOLDER, USE_CHUNKED_UPLOAD, jobs, videos
from .state import save_state
from .utils import _session_dir, _short_sid, utc_now_iso
from .progress import _progress_event, _progress_finish, _progress_init
from .job_routes import process_job
from .video import get_video_metadata
from .downloads import download_session_files
from .tts import _MIN_WAV_BYTES, _looks_like_wav
from .kit_messages import MIN_MESSAGES_BYTES, _coverage_is_ok
from .youtube import (
    convert_video_to_browser_compatible,
    download_youtube_video_adaptive,
)


@app.route("/session_resync/<path:session_id>", methods=["POST"])
def session_resync(session_id):
    """Force a full re-download of a session from the internal server."""
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        return jsonify({"error": "No token"}), 401
    session_dir = _session_dir(session_id)
    if os.path.exists(session_dir):
        shutil.rmtree(session_dir)
    os.makedirs(session_dir, exist_ok=True)
    download_session_files(session_id, token)
    return jsonify({"success": True, "session_id": session_id}), 200


def _post_multipart_with_retries(
    target_url: str,
    body_file,
    headers: dict,
    cookies: dict,
    *,
    total_size: int,
    max_attempts: int = 3,
    base_delay: float = 5.0,
):
    """POST a multipart body, retrying on transient connection resets."""
    last_exc = None
    for attempt in range(1, max_attempts + 1):
        try:
            body_file.seek(0)
            resp = requests.post(
                target_url,
                data=body_file,
                headers=headers,
                cookies=cookies,
                timeout=(60, 3600),
                verify=False,
                allow_redirects=False,
            )

            # Follow a redirect manually so we can log where KIT sent us.
            # The final response's .url will then contain the session id,
            # which _extract_session_id() picks up in step 1.
            if resp.status_code in (301, 302, 303, 307, 308):
                location = resp.headers.get("Location", "")
                if location:
                    logging.info(
                        "internal_upload: redirect %s -> %s",
                        resp.status_code,
                        location,
                    )
                    resp = requests.get(
                        location,
                        cookies=cookies,
                        verify=False,
                        timeout=60,
                        allow_redirects=True,
                    )

            if attempt > 1:
                logging.info(
                    "internal_upload: succeeded on attempt %d/%d",
                    attempt,
                    max_attempts,
                )
            return resp

        except requests.exceptions.ConnectionError as e:
            logging.error(
                "internal_upload: connection reset after %d bytes "
                "(Content-Length: %s, chunked: %s)",
                total_size,
                headers.get("Content-Length", "<none>"),
                USE_CHUNKED_UPLOAD,
            )
            last_exc = e
            if attempt < max_attempts:
                delay = base_delay * (2 ** (attempt - 1))
                logging.info("internal_upload: retrying in %.1fs", delay)
                time.sleep(delay)

    raise last_exc


def _session_files_look_incomplete(session_dir):
    messages = os.path.join(session_dir, "messages.json")
    transcripts = os.path.join(session_dir, "transcripts.json")

    if not os.path.exists(transcripts):
        return True
    if not os.path.exists(messages) or os.path.getsize(messages) < 5000:
        return True

    try:
        with open(transcripts, "r", encoding="utf-8") as f:
            ts = json.load(f)
    except (json.JSONDecodeError, TypeError, ValueError):
        return True

    # How many languages did we actually extract text for?
    languages_with_text = [
        t
        for t in ts
        if any(seg.get("text", "").strip() for seg in t.get("segments", []))
    ]

    vtt_files = [
        f
        for f in os.listdir(session_dir)
        if f.startswith("subtitles_")
        and f.endswith(".vtt")
        and os.path.getsize(os.path.join(session_dir, f)) > 20
    ]

    # If we have more languages with text than VTTs, we're behind.
    if len(vtt_files) < len(languages_with_text):
        return True

    # If the local messages.json still shows short MT tracks, we're behind.
    if not _local_transcripts_cover_full_span(session_dir):
        logging.info(
            "_session_files_look_incomplete: %s — local MT coverage "
            "is short, will re-download",
            _short_sid(os.path.basename(session_dir)),
        )
        return True

    # Do we have a TTS WAV for every *translation* track that
    # has a VTT? The ASR track is intentionally excluded: KIT
    # does not synthesize TTS for the speaker's own language, so
    # there is no tts_Transcript.wav to expect.
    vtt_langs = {
        f[len("subtitles_") : -len(".vtt")]
        for f in vtt_files
        if f != "subtitles_Transcript.vtt"
    }
    tts_langs = {
        f[len("tts_") : -len(".wav")]
        for f in os.listdir(session_dir)
        if f.startswith("tts_")
        and f.endswith(".wav")
        and os.path.getsize(os.path.join(session_dir, f)) > _MIN_WAV_BYTES
        and _looks_like_wav(os.path.join(session_dir, f))
    }
    if vtt_langs - tts_langs:
        logging.info(
            "_session_files_look_incomplete: %s missing TTS for %s",
            _short_sid(os.path.basename(session_dir)),
            sorted(vtt_langs - tts_langs),
        )
        return True

    return False


def _local_transcripts_cover_full_span(session_dir) -> bool:
    """True if the local messages.json shows every MT track ending close
    to the ASR end. Used to decide whether a re-download is warranted.

    This is the local counterpart of _messages_look_done: same coverage
    rule, but reading from disk instead of from the internal server.
    """
    messages_path = os.path.join(session_dir, "messages.json")
    if not os.path.exists(messages_path):
        return False
    try:
        with open(messages_path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    if not raw or len(raw) < MIN_MESSAGES_BYTES:
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
        if not isinstance(m, dict):
            continue
        if not m.get("seq", "").strip():
            continue
        try:
            end = float(m.get("end", 0) or 0)
        except (ValueError, TypeError):
            end = 0.0
        sender = m.get("sender", "")
        if sender.startswith("asr:"):
            if end > asr_max_end:
                asr_max_end = end
        elif sender.startswith("mt:") or sender.startswith("translation:"):
            if end > mt_tracks.get(sender, 0.0):
                mt_tracks[sender] = end

    if not mt_tracks or asr_max_end <= 0:
        return False
    return all(_coverage_is_ok(mt_end, asr_max_end) for mt_end in mt_tracks.values())


@app.route("/api/youtube-download-and-upload", methods=["POST", "OPTIONS"])
def youtube_download_and_upload():
    """Download a YouTube video and register it as an uploadable project."""
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

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

        _progress_event(
            download_id, "Starting YouTube download", stage="info", progress=0.02
        )
        logging.info("=" * 60)
        logging.info("📥 Starting YouTube download: %s", youtube_url)
        logging.info("=" * 60)

        # ── 1. Get video info ────────────────────────────────────────
        _progress_event(download_id, "Getting video info…", stage="info", progress=0.05)
        try:
            logging.info("📋 Getting video info...")
            ydl_opts = {
                "quiet": True,
                "no_warnings": True,
                "http_headers": {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36",
                },
            }
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(youtube_url, download=False)
                title = info.get("title", "youtube_video")
                duration = info.get("duration", 0)

            # Human-readable project name: keep spaces, only strip characters
            # that are invalid in filenames.
            display_title = re.sub(r'[\\/*?:"<>|]+', "", title).strip()
            display_title = re.sub(r"\s+", " ", display_title)
            display_title = display_title or "youtube_video"

            # Safe on-disk filename: still uses underscores instead of spaces.
            safe_title = re.sub(r'[\\/*?:"<>|]+', "_", title).strip()
            safe_title = re.sub(r"\s+", "_", safe_title)
            safe_title = safe_title or "youtube_video"

            filename = f"{safe_title}.mp4"
            if len(filename) > 200:
                name, ext = os.path.splitext(filename)
                filename = f"{name[:195]}{ext}"

            logging.info("📹 Video: %s", display_title)
            logging.info("📹 Duration: %s seconds", duration)
            logging.info("📹 Filename: %s", filename)

            _progress_event(
                download_id,
                f"Video: {title}",
                stage="info",
                progress=0.08,
                details={
                    "title": display_title,
                    "duration": duration,
                    "filename": filename,
                },
            )
            _progress_event(
                download_id, f"Duration: {duration} s", stage="info", progress=0.08
            )
        except (
            yt_dlp.utils.DownloadError,
            OSError,
            ValueError,
            TypeError,
            KeyError,
        ) as e:
            msg = f"Info error: {e}"
            logging.error("❌ %s", msg, exc_info=True)
            _progress_finish(download_id, error=msg)
            return jsonify({"success": False, "error": msg}), 400

        # ── 2. Download ──────────────────────────────────────────────
        _progress_event(
            download_id,
            "Downloading video + audio…",
            stage="downloading",
            progress=0.15,
        )
        try:
            download_result = download_youtube_video_adaptive(
                youtube_url, UPLOAD_FOLDER, filename
            )
        except (
            yt_dlp.utils.DownloadError,
            OSError,
            ValueError,
            TypeError,
            KeyError,
        ) as e:
            msg = f"Download error: {e}"
            logging.error("❌ %s", msg, exc_info=True)
            _progress_finish(download_id, error=msg)
            return jsonify({"success": False, "error": msg}), 400

        if not download_result.get("success"):
            msg = download_result.get("error", "Download failed")
            logging.error("❌ Download error: %s", msg)
            _progress_finish(download_id, error=msg)
            return jsonify({"success": False, "error": msg}), 400

        file_path = download_result.get("file_path")
        if not file_path or not os.path.exists(file_path):
            msg = "Downloaded file not found"
            _progress_finish(download_id, error=msg)
            return jsonify({"error": msg}), 500

        file_size = download_result.get("filesize", 0)
        duration = download_result.get("duration", duration)
        actual_filename = download_result.get("filename", filename)
        has_audio = download_result.get("has_audio", False)

        logging.info("✅ Video downloaded: %s (%s bytes)", file_path, file_size)
        logging.info("🎵 Has audio: %s", has_audio)

        _progress_event(
            download_id,
            f"Download complete: {actual_filename} ({file_size} bytes)",
            stage="downloaded",
            progress=0.45,
            details={
                "filename": actual_filename,
                "filesize": file_size,
                "duration": duration,
                "has_audio": has_audio,
            },
        )
        _progress_event(
            download_id,
            f"Audio present: {has_audio}",
            stage="downloaded",
            progress=0.45,
        )

        if file_size < 1000:
            msg = "Downloaded file is too small (corrupted)"
            logging.error("❌ %s", msg)
            if os.path.exists(file_path):
                try:
                    os.remove(file_path)
                except OSError:
                    pass
            _progress_finish(download_id, error=msg)
            return jsonify({"error": msg}), 500

        # ── 3. Codec check + conversion ──────────────────────────────
        codec = ""
        try:
            probe_cmd = [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=codec_name",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                file_path,
            ]
            result = subprocess.run(
                probe_cmd, capture_output=True, text=True, timeout=10, check=False
            )
            codec = result.stdout.strip() if result.returncode == 0 else ""
            logging.info("📹 Video codec: %s", codec)
            _progress_event(
                download_id,
                f"Video codec: {codec or 'unknown'}",
                stage="probing",
                progress=0.50,
                details={"codec": codec},
            )
        except (OSError, subprocess.SubprocessError, ValueError, TypeError) as e:
            logging.warning("⚠️ Could not probe codec: %s", e)

        if codec and codec != "h264":
            _progress_event(
                download_id,
                "Converting video to browser-compatible format…",
                stage="converting",
                progress=0.55,
            )
            logging.info("🔄 Converting video to browser-compatible format...")
            try:
                base_name = os.path.splitext(actual_filename)[0]
                converted_filename = f"{base_name}_converted.mp4"
                converted_path = os.path.join(UPLOAD_FOLDER, converted_filename)

                if convert_video_to_browser_compatible(file_path, converted_path):
                    backup_path = file_path + ".backup"
                    os.rename(file_path, backup_path)
                    os.rename(converted_path, file_path)
                    file_size = os.path.getsize(file_path)
                    actual_filename = os.path.basename(file_path)

                    _progress_event(
                        download_id,
                        f"Conversion complete: {actual_filename}",
                        stage="converted",
                        progress=0.70,
                        details={
                            "filename": actual_filename,
                            "filesize": file_size,
                            "converted": True,
                        },
                    )
                    logging.info("✅ Video converted successfully: %s", actual_filename)

                    if os.path.exists(backup_path):
                        try:
                            os.remove(backup_path)
                        except OSError:
                            pass
                else:
                    _progress_event(
                        download_id,
                        "Conversion failed — using original file",
                        level="warning",
                        stage="converted",
                        progress=0.70,
                    )
                    logging.warning("⚠️ Video conversion failed, using original")
                    if os.path.exists(converted_path):
                        try:
                            os.remove(converted_path)
                        except OSError:
                            pass
            except (OSError, subprocess.SubprocessError, ValueError, TypeError) as e:
                logging.warning("⚠️ Could not convert video: %s", e)
                _progress_event(
                    download_id,
                    f"Conversion error: {e}",
                    level="warning",
                    stage="converted",
                    progress=0.70,
                )
        else:
            _progress_event(
                download_id,
                "Video already browser-compatible (H.264)",
                stage="converted",
                progress=0.70,
                details={"converted": False},
            )

        # ── 4. Thumbnail ─────────────────────────────────────────────
        _progress_event(
            download_id, "Generating thumbnail…", stage="thumbnail", progress=0.78
        )
        try:
            thumb_filename = f"{os.path.splitext(actual_filename)[0]}_thumb.jpg"
            thumb_path = os.path.join(UPLOAD_FOLDER, thumb_filename)
            thumbnail_url = None
            thumbnail_generated = False

            try:
                if generate_video_thumbnail_simple(file_path, thumb_path):
                    thumbnail_url = f"/thumbnails/{thumb_filename}"
                    thumbnail_generated = True
                    logging.info("✅ Thumbnail generated with ffmpeg")
                    _progress_event(
                        download_id,
                        "Thumbnail generated",
                        stage="thumbnail",
                        progress=0.82,
                    )
            except (OSError, RuntimeError, ValueError, TypeError) as e:
                logging.warning("⚠️ FFmpeg thumbnail failed: %s", e)

            if not thumbnail_generated:
                try:
                    cv2 = importlib.import_module("cv2")
                    cap = cv2.VideoCapture(file_path)
                    ret, frame = cap.read()
                    if ret:
                        cv2.imwrite(thumb_path, frame)
                        thumbnail_url = f"/thumbnails/{thumb_filename}"
                        thumbnail_generated = True
                        _progress_event(
                            download_id,
                            "Thumbnail generated (OpenCV)",
                            stage="thumbnail",
                            progress=0.82,
                        )
                    cap.release()
                except (ImportError, OSError, RuntimeError, ValueError, TypeError) as e:
                    logging.warning("⚠️ OpenCV thumbnail failed: %s", e)

            if not thumbnail_generated:
                _progress_event(
                    download_id,
                    "No thumbnail generated",
                    level="warning",
                    stage="thumbnail",
                    progress=0.82,
                )
        except (OSError, RuntimeError, ValueError, TypeError) as e:
            logging.warning("⚠️ Thumbnail generation error: %s", e)
            thumbnail_url = None

        # ── 5. Metadata ──────────────────────────────────────────────
        # We already probed the codec a few lines earlier (for the
        # h264 check). Reuse it here; only re-run ffprobe when the
        # duration is still unknown.
        try:
            if duration == 0:
                duration, fps, probed_codec = get_video_metadata(file_path)
                if probed_codec:
                    codec = probed_codec
            else:
                fps = 30.0
        except (OSError, RuntimeError, ValueError, TypeError):
            duration = duration or 120.0
            fps = 30.0

        # ── 6. Save project ──────────────────────────────────────────
        _progress_event(download_id, "Saving project…", stage="saving", progress=0.90)

        existing = next(
            (v for v in videos if v.get("file_name") == actual_filename),
            None,
        )

        if existing is not None:
            # Reuse the existing entry. Preserve key, uploaded, last_opened,
            # greenscreen_*, job_history, session_id — only refresh fields
            # that describe the file on disk. The source is refreshed to
            # the URL that produced this re-import.
            project = existing
            video_key = existing["key"]
            project.update(
                {
                    "name": display_title,
                    "file_size": file_size,
                    "duration": duration,
                    "fps": fps,
                    "codec": codec,
                    "thumbnail_url": thumbnail_url,
                    "source": youtube_url,
                }
            )

            logging.info(
                "♻️ Reusing existing project for %s (key=%s)",
                actual_filename,
                video_key,
            )
        else:
            video_key = str(uuid.uuid4())
            project = {
                "key": video_key,
                "name": display_title,
                "file_name": actual_filename,
                "uploaded": utc_now_iso(),
                "last_opened": None,
                "duration": duration,
                "fps": fps,
                "codec": codec,
                "file_size": file_size,
                "segment_count": 0,
                "languages": ["en"],
                "thumbnail_url": thumbnail_url,
                "segmentation_done": auto_segmentation,
                "segmentation_progress": 100 if auto_segmentation else 0,
                "source": youtube_url,
            }
            videos.append(project)

        save_state()

        # ── 7. Optional segmentation job ─────────────────────────────
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

        _progress_event(
            download_id, f'Imported "{display_title}"', stage="done", progress=1.0
        )
        _progress_finish(
            download_id,
            details={
                "title": display_title,
                "video_key": video_key,
            },
        )

        logging.info("=" * 60)
        logging.info("✅ YouTube video uploaded successfully: %s", display_title)
        logging.info("=" * 60)

        return (
            jsonify(
                {
                    "success": True,
                    "video_info": {
                        "title": display_title,
                        "duration": duration,
                        "file_size": file_size,
                        "thumbnail": thumbnail_url,
                        "has_audio": has_audio,
                    },
                    "project": project,
                    "message": f'Video "{display_title}" imported successfully',
                    "filename": actual_filename,
                    "video_key": video_key,
                }
            ),
            200,
        )

    except (
        OSError,
        RuntimeError,
        ValueError,
        TypeError,
        KeyError,
        yt_dlp.utils.DownloadError,
    ) as e:
        logging.error("❌ YouTube download error: %s", e, exc_info=True)
        _progress_finish(download_id, error=f"Server error: {e}")
        return jsonify({"success": False, "error": f"Server error: {e}"}), 500


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global generate_video_thumbnail_simple
    from .uploader import generate_video_thumbnail_simple
