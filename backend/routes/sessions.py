"""Session routes: progress, output, file serving, transcript editing."""

import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import threading
import zipfile

from flask import Blueprint, jsonify, request, send_file

from ..config import INTERNAL_SERVER_URL
from ..downloads import JobCancelled, download_session_files
from ..http import curl_download
from ..progress import (
    _job_cancel,
    _job_cleanup,
    _job_progress_store,
    _request_cancel,
    job_progress_lock,
)
from ..session_worker import process_session_in_background
from ..state import jobs, save_state, sessions
from ..transcripts import is_original_asr_language
from ..utils import (
    effective_token,
    extract_simple_language_name,
    file_mtime_iso,
    format_vtt_timestamp,
    is_meaningful_file,
    safe_float,
    session_dir,
)
from ..video import get_session_original_video_path

bp = Blueprint("sessions", __name__)


@bp.route("/job-progress/<path:session_id>", methods=["GET", "OPTIONS"])
def job_progress(session_id):
    """Progress endpoint polled by the client's JobProgressPanel."""
    if request.method == "OPTIONS":
        return ("", 204)

    _job_cleanup()

    sdir = session_dir(session_id)
    disk_files = []
    if os.path.exists(sdir):
        disk_files = [
            {"name": f, "size": os.path.getsize(os.path.join(sdir, f))}
            for f in os.listdir(sdir)
            if os.path.isfile(os.path.join(sdir, f))
            and is_meaningful_file(os.path.join(sdir, f))
        ]
    has_transcript = any(
        f["name"] in {"transcripts.json", "messages.json"} for f in disk_files
    )

    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        snapshot = dict(entry) if entry else None

    if snapshot is not None:
        merged = {f["name"]: f for f in snapshot.get("files", [])}
        for f in disk_files:
            merged[f["name"]] = f
        snapshot["files"] = list(merged.values())
        snapshot["total_files"] = len(snapshot["files"])
        if has_transcript and not snapshot.get("done"):
            snapshot["done"] = True
            snapshot["progress"] = 1.0
            snapshot["stage"] = "ready"
            snapshot["error"] = None
        return jsonify(snapshot), 200

    if has_transcript:
        return (
            jsonify(
                {
                    "session_id": session_id,
                    "stage": "ready",
                    "progress": 1.0,
                    "done": True,
                    "error": None,
                    "message": f"Ready — {len(disk_files)} files",
                    "files": disk_files,
                    "total_files": len(disk_files),
                    "events": [],
                }
            ),
            200,
        )

    persisted = jobs.get(session_id)
    if persisted is not None and persisted.get("status") == "processing":
        token = request.headers.get("Authorization", "").replace("Bearer ", "")
        if token:
            with job_progress_lock:
                claimed = not persisted.get("_recovery_started")
                if claimed:
                    persisted["_recovery_started"] = True
            if claimed:
                video_key = persisted.get("video_key")
                server_url = (
                    sessions.get(session_id, {}).get("server")
                    or INTERNAL_SERVER_URL
                )
                threading.Thread(
                    target=process_session_in_background,
                    args=(session_id, token, video_key, server_url),
                    daemon=True,
                ).start()
                return (
                    jsonify(
                        {
                            "session_id": session_id,
                            "stage": "starting",
                            "progress": 0.0,
                            "done": False,
                            "error": None,
                            "message": "Resuming after server restart…",
                            "files": disk_files,
                            "total_files": len(disk_files),
                            "events": [],
                        }
                    ),
                    200,
                )

    if persisted is None or persisted.get("status") != "processing":
        return (
            jsonify(
                {
                    "session_id": session_id,
                    "stage": "error",
                    "progress": 0.0,
                    "done": True,
                    "error": (
                        "Session tracking lost. The server was restarted "
                        "during processing. Click 'Check Status' to retry "
                        "the download."
                    ),
                    "message": "Session tracking lost",
                    "files": disk_files,
                    "total_files": len(disk_files),
                    "events": [],
                }
            ),
            200,
        )

    return (
        jsonify(
            {
                "session_id": session_id,
                "stage": "starting",
                "progress": 0.0,
                "done": False,
                "error": None,
                "message": "Resuming after server restart…",
                "files": disk_files,
                "total_files": len(disk_files),
                "events": [],
            }
        ),
        200,
    )


@bp.route("/cancel_session/<path:session_id>", methods=["POST", "OPTIONS"])
def cancel_session(session_id):
    """Cancel a queued or active processing session."""
    if request.method == "OPTIONS":
        return ("", 204)

    _request_cancel(session_id)

    job = jobs.get(session_id)
    had_job = job is not None and job.get("status") == "processing"
    if had_job:
        job["status"] = "cancelled"

    with job_progress_lock:
        had_progress = session_id in _job_progress_store

    _job_cancel(session_id)
    save_state()

    if not had_job and not had_progress:
        return (
            jsonify(
                {
                    "success": False,
                    "session_id": session_id,
                    "reason": "unknown_session",
                    "message": "No job is registered for this session id.",
                }
            ),
            404,
        )
    return jsonify({"success": True, "session_id": session_id}), 200


@bp.route("/session-output/<path:session_id>", methods=["GET"])
def get_session_output(session_id):
    """List the files available for a session, downloading if needed."""
    sdir = session_dir(session_id)
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        job_running = entry is not None and not entry.get("done")

    if (
        not job_running
        and token
        and (not os.path.isdir(sdir) or not os.listdir(sdir))
    ):
        server_url = (
            sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
        )
        try:
            download_session_files(
                session_id,
                effective_token(session_id, fallback=token),
                server_url,
            )
        except JobCancelled:
            pass

    files = []
    if os.path.exists(sdir):
        for f in os.listdir(sdir):
            fp = os.path.join(sdir, f)
            if not (os.path.isfile(fp) and is_meaningful_file(fp)):
                continue
            reported_size = os.path.getsize(fp)
            if f == "video.mp4":
                orig = get_session_original_video_path(session_id)
                if orig:
                    reported_size = os.path.getsize(orig)
            files.append(
                {
                    "name": f,
                    "size": reported_size,
                    "url": f"/session-file/{session_id}/{f}",
                    "modified": file_mtime_iso(fp),
                }
            )

    with job_progress_lock:
        job_snapshot = _job_progress_store.get(session_id)

    return (
        jsonify(
            {
                "session_id": session_id,
                "files": files,
                "total_files": len(files),
                "session_url": (
                    f"{INTERNAL_SERVER_URL}/archivesession/{session_id}"
                ),
                "status": "ready" if files else "processing",
                "job": job_snapshot,
                "embedded_languages": (sessions.get(session_id) or {}).get(
                    "embedded_languages"
                ),
            }
        ),
        200,
    )


@bp.route("/session-file/<path:session_id>/<filename>", methods=["GET"])
def get_session_file(session_id, filename):
    """Serve one file out of a session folder, with type-specific handling."""
    sdir = session_dir(session_id)
    fp = os.path.join(sdir, filename)
    if not os.path.exists(fp):
        return jsonify({"error": "File not found"}), 404

    if filename.endswith(".vtt"):
        resp = send_file(
            fp,
            as_attachment=False,
            mimetype="text/vtt",
            download_name=filename,
        )
        resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        return resp

    if filename.lower().endswith(".mp4"):
        modified = os.path.join(sdir, "video_subtitled.mp4")
        orig = get_session_original_video_path(session_id)
        if os.path.exists(modified):
            actual = modified
        elif orig and filename == "video.mp4":
            actual = orig
        else:
            actual = fp
        return send_file(
            actual,
            as_attachment=False,
            mimetype="video/mp4",
            conditional=True,
        )

    return send_file(fp, as_attachment=True, conditional=True)


@bp.route("/session-zip/<path:session_id>", methods=["GET"])
def download_session_zip(session_id):
    """Download the whole session folder as a ZIP archive."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")
    if token:
        json_path = os.path.join(sdir, "messages.json")
        if not os.path.exists(json_path) or os.path.getsize(json_path) < 1000:
            curl_download(
                f"{INTERNAL_SERVER_URL}/archivemediafile/"
                f"{session_id}/messages.json",
                json_path,
                token,
            )

    safe_id = re.sub(r"[^A-Za-z0-9_.-]", "_", session_id)[:80]
    zip_path = os.path.join(tempfile.gettempdir(), f"session_{safe_id}.zip")
    try:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for root, _, files in os.walk(sdir):
                for file in files:
                    fp = os.path.join(root, file)
                    try:
                        if os.path.getsize(fp) > 1000:
                            zipf.write(fp, os.path.relpath(fp, sdir))
                    except OSError:
                        continue
        return send_file(
            zip_path,
            as_attachment=True,
            download_name=f"session_{safe_id}.zip",
            mimetype="application/zip",
        )
    finally:
        try:
            if os.path.exists(zip_path):
                os.remove(zip_path)
        except OSError:
            pass


@bp.route("/session-refresh/<path:session_id>", methods=["POST"])
def session_refresh(session_id):
    """Wipe the local session folder and re-download it from KIT."""
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")
    if not token:
        return jsonify({"error": "No token provided"}), 401

    sdir = session_dir(session_id)
    if os.path.exists(sdir):
        shutil.rmtree(sdir)
    os.makedirs(sdir, exist_ok=True)
    download_session_files(session_id, token)
    return jsonify({"success": True, "session_id": session_id}), 200


@bp.route("/session_resync/<path:session_id>", methods=["POST"])
def session_resync(session_id):
    """Like /session-refresh, kept for the older client endpoint name."""
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        return jsonify({"error": "No token"}), 401

    sdir = session_dir(session_id)
    if os.path.exists(sdir):
        shutil.rmtree(sdir)
    os.makedirs(sdir, exist_ok=True)
    download_session_files(session_id, token)
    return jsonify({"success": True, "session_id": session_id}), 200


@bp.route("/session-transcript-save-vtt/<path:session_id>", methods=["POST"])
def session_transcript_save_vtt(session_id):
    """Persist edited transcript segments and rewrite the matching VTT."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
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

        filtered = [
            s
            for s in segments
            if not (s.get("start", 0) == 0 and s.get("end", 0) == 0)
            and s.get("markup")
            not in ("paragraphBreak", "chapterBreak", "heading")
            and s.get("text", "").strip()
        ]
        if not filtered:
            return jsonify({"error": "No valid segments to save"}), 400

        json_path = os.path.join(sdir, "transcripts.json")
        transcripts = []
        if os.path.exists(json_path):
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)

        updated = False
        for i, t in enumerate(transcripts):
            if t.get("language") == language:
                t["segments"] = filtered
                t["text"] = " ".join(s.get("text", "") for s in filtered)
                transcripts[i] = t
                updated = True
                break
        if not updated:
            transcripts.append(
                {
                    "language": language,
                    "text": " ".join(s.get("text", "") for s in filtered),
                    "segments": filtered,
                    "sender": (
                        filtered[0].get("sender", "") if filtered else ""
                    ),
                }
            )

        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(transcripts, f, ensure_ascii=False, indent=2)

        # Pick the VTT filename.
        if filename:
            vtt_filename = filename
        elif is_original_asr_language(language):
            vtt_filename = "subtitles_Transcript.vtt"
        else:
            simple = extract_simple_language_name(language)
            existing = None
            for f in os.listdir(sdir):
                if f.endswith(".vtt") and (
                    simple in f
                    or language in f
                    or f.startswith(f"subtitles_{simple}")
                ):
                    existing = f
                    break
            if existing:
                vtt_filename = existing
            else:
                clean = (
                    simple.replace(" ", "_").replace("(", "").replace(")", "")
                )
                vtt_filename = f"subtitles_{clean}.vtt"

        lines = ["WEBVTT", ""]
        cue_index = 0
        for seg in filtered:
            start = safe_float(seg.get("start", 0))
            end = safe_float(seg.get("end", 0))
            text = seg.get("text", "")
            if not text or not text.strip():
                continue
            cue_index += 1
            lines.append(str(cue_index))
            lines.append(
                f"{format_vtt_timestamp(start)} --> "
                f"{format_vtt_timestamp(end)}"
            )
            speaker = seg.get("speakerName") or seg.get("speaker_name")
            lines.append(
                f"<v {speaker}>{text}</v>"
                if speaker and speaker.strip()
                else text
            )
            lines.append("")

        with open(
            os.path.join(sdir, vtt_filename), "w", encoding="utf-8"
        ) as f:
            f.write("\n".join(lines))

        save_state()
        return (
            jsonify(
                {
                    "success": True,
                    "message": (
                        f"Transcript saved and VTT updated: {vtt_filename}"
                    ),
                    "language": language,
                    "vtt_filename": vtt_filename,
                    "segments_count": len(filtered),
                }
            ),
            200,
        )
    except json.JSONDecodeError as e:
        return jsonify({"error": f"Invalid JSON: {e}"}), 400
    except (OSError, TypeError, KeyError) as e:
        logging.error("Error saving transcript: %s", e, exc_info=True)
        return jsonify({"error": f"Failed to save: {e}"}), 500


@bp.route("/extract-video-subtitles/<path:session_id>", methods=["GET"])
def extract_video_subtitles(session_id):
    """Extract every embedded subtitle stream from video.mp4 to VTT files."""
    sdir = session_dir(session_id)
    video_path = os.path.join(sdir, "video.mp4")
    if not os.path.exists(video_path):
        return jsonify({"error": "video.mp4 not found"}), 404

    try:
        probe = subprocess.run(
            [
                "ffprobe",
                "-i",
                video_path,
                "-show_entries",
                "stream=index,codec_type,codec_name,language,tags",
                "-select_streams",
                "s",
                "-of",
                "json",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if probe.returncode != 0:
            return (
                jsonify({"error": "ffprobe failed", "stderr": probe.stderr}),
                500,
            )

        streams = json.loads(probe.stdout).get("streams", [])
        extracted = []
        for i, s in enumerate(streams):
            idx = s.get("index")
            lang = s.get("language", f"stream_{i}")
            output = os.path.join(sdir, f"extracted_subtitle_{i}_{lang}.vtt")
            subprocess.run(
                [
                    "ffmpeg",
                    "-i",
                    video_path,
                    "-map",
                    f"0:{idx}",
                    "-c",
                    "copy",
                    "-y",
                    output,
                ],
                capture_output=True,
                timeout=60,
                check=False,
            )
            if os.path.exists(output):
                extracted.append(
                    {
                        "stream_index": idx,
                        "language": lang,
                        "filename": os.path.basename(output),
                        "size": os.path.getsize(output),
                    }
                )
        return (
            jsonify(
                {
                    "success": True,
                    "extracted": extracted,
                    "total": len(extracted),
                }
            ),
            200,
        )
    except (
        subprocess.TimeoutExpired,
        json.JSONDecodeError,
        OSError,
        TypeError,
        ValueError,
    ) as e:
        logging.error("Error extracting video subtitles: %s", e, exc_info=True)
        return jsonify({"error": str(e)}), 500
