import logging
import os
import re
import shutil
import threading
import uuid

from flask import Blueprint, jsonify, request, send_file

from ..config import UPLOAD_FOLDER, MAX_JOB_HISTORY_ENTRIES
from ..state import jobs, save_state, videos
from ..utils import (
    ensure_codec_field, ensure_greenscreen_fields, ensure_job_history,
    ensure_source_field, thumbnail_absolute_url, utc_now_iso,
)
from ..video import (
    build_greenscreen_for_project, generate_video_thumbnail,
    get_video_metadata,
)

bp = Blueprint("videos", __name__)


def _make_project_dict(filename, session_name, source, languages, auto_seg,
                       local_path):
    duration, fps, codec = get_video_metadata(local_path)
    return {
        "key": str(uuid.uuid4()),
        "name": session_name,
        "file_name": filename,
        "uploaded": utc_now_iso(),
        "last_opened": None,
        "duration": duration, "fps": fps, "codec": codec,
        "file_size": os.path.getsize(local_path),
        "segment_count": 0, "languages": languages,
        "thumbnail_url": None,
        "segmentation_done": auto_seg,
        "segmentation_progress": 100 if auto_seg else 0,
        "source": source,
    }


def _upload_chunk():
    file = request.files.get("file")
    filename = request.form.get("filename")
    chunk_index = int(request.form.get("chunk_index", 0))
    total_chunks = int(request.form.get("total_chunks", 1))
    if not file or not filename:
        return jsonify({"message": "Missing file or filename"}), 400
    from ..state import chunk_storage
    if filename not in chunk_storage:
        chunk_storage[filename] = [None] * total_chunks
    chunk_storage[filename][chunk_index] = file.read()
    return jsonify({"message": "Chunk uploaded"}), 200


bp.add_url_rule("/upload-chunk", "upload_chunk",
                _upload_chunk, methods=["POST"])


@bp.route("/finish-upload", methods=["POST"])
def finish_upload():
    data = request.get_json()
    original_filename = data.get("filename")
    auto_segmentation = data.get("auto_segmentation", False)
    if not original_filename:
        return jsonify({"message": "Missing filename"}), 400

    from ..state import chunk_storage
    chunks = chunk_storage.get(original_filename)
    if not chunks or any(c is None for c in chunks):
        return jsonify({"message": "Incomplete upload"}), 400
    combined = b"".join(chunks)

    filename = original_filename
    if not filename.lower().endswith(".mp4"):
        filename = f"{os.path.splitext(filename)[0]}.mp4"

    file_path = os.path.join(UPLOAD_FOLDER, filename)
    with open(file_path, "wb") as f:
        f.write(combined)
    file_size = len(combined)

    thumb_name = f"{os.path.splitext(filename)[0]}_thumb.jpg"
    thumb_path = os.path.join(UPLOAD_FOLDER, thumb_name)
    thumbnail_url = None
    if generate_video_thumbnail(file_path, thumb_path):
        thumbnail_url = f"/thumbnails/{thumb_name}"

    duration, fps, codec = get_video_metadata(file_path)
    source = (data.get("source") or "Desktop Upload").strip() or "Desktop Upload"

    project = {
        "key": str(uuid.uuid4()),
        "name": filename.rsplit(".", 1)[0] if "." in filename else filename,
        "file_name": filename,
        "uploaded": utc_now_iso(),
        "last_opened": None,
        "duration": duration, "fps": fps, "codec": codec,
        "file_size": file_size,
        "segment_count": 0, "languages": ["en"],
        "thumbnail_url": thumbnail_url,
        "segmentation_done": auto_segmentation,
        "segmentation_progress": 100 if auto_segmentation else 0,
        "source": source,
    }
    videos.append(project)
    chunk_storage.pop(original_filename, None)
    save_state()
    return jsonify({"message": "Upload finished", "project": project}), 200


@bp.route("/videos", methods=["GET"])
def get_videos():
    for v in videos:
        ensure_greenscreen_fields(v)
        ensure_source_field(v)
        ensure_codec_field(v)

    groups: dict = {}
    for video in videos:
        fn = video.get("file_name")
        if not fn:
            continue
        m = re.match(
            r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
            fn)
        clean = fn[36:] if m else fn
        if not clean or clean.startswith("."):
            clean = fn
        groups.setdefault(clean, []).append(video)

    unique: list = []
    for _, group in groups.items():
        if len(group) == 1:
            unique.append(group[0])
            continue
        best = group[0]
        for v in group[1:]:
            def score(x):
                s = 0
                if x.get("segmentation_done"): s += 10
                if x.get("thumbnail_url"): s += 5
                if x.get("file_size", 0) > 0: s += min(x["file_size"] / 1e6, 10)
                if not re.match(
                    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
                    x.get("file_name", "")):
                    s += 3
                return s
            if score(v) > score(best):
                best = v
        unique.append(best)

    serialized = []
    for video in unique:
        copy = dict(video)
        copy["thumbnail_url"] = thumbnail_absolute_url(video)
        serialized.append(copy)

    used = sum(v.get("file_size", 0) for v in serialized) / (1024.0 ** 3)
    return jsonify({
        "projects": serialized,
        "storage_used_gb": round(used, 2),
        "storage_limit_gb": 50.0,
    }), 200


@bp.route("/video-detail/<video_key>", methods=["GET"])
def video_detail(video_key):
    for project in videos:
        if project["key"] == video_key:
            ensure_greenscreen_fields(project)
            ensure_source_field(project)
            ensure_codec_field(project)
            detail = project.copy()
            detail["thumbnail_url"] = thumbnail_absolute_url(project)
            detail["segments"] = detail.get("segments", [])
            detail["video_url"] = None

            gs_name = project.get("greenscreen_file_name")
            gs_size, gs_created = 0, None
            if gs_name:
                gs_path = os.path.join(UPLOAD_FOLDER, gs_name)
                if os.path.exists(gs_path):
                    try:
                        gs_size = os.path.getsize(gs_path)
                        from ..utils import file_mtime_iso
                        gs_created = file_mtime_iso(gs_path)
                    except OSError:
                        pass
            detail["greenscreen_file_size"] = gs_size
            detail["greenscreen_created_at"] = gs_created

            ensure_job_history(project)
            detail["job_history"] = list(project["job_history"])
            return jsonify(detail), 200
    return jsonify({"error": "Video not found"}), 404


@bp.route("/video-job-history/<video_key>",
          methods=["GET", "PUT", "DELETE", "OPTIONS"])
def video_job_history(video_key):
    if request.method == "OPTIONS":
        return ("", 204)
    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        return jsonify({"error": "Video not found"}), 404
    ensure_job_history(project)

    if request.method == "GET":
        return jsonify(list(project["job_history"])), 200
    if request.method == "DELETE":
        project["job_history"] = []
        save_state()
        return jsonify({"success": True, "count": 0}), 200

    payload = request.get_json(silent=True)
    if not isinstance(payload, list):
        return jsonify({"error": "Expected a JSON list"}), 400
    cleaned = [e for e in payload if isinstance(e, dict)][:MAX_JOB_HISTORY_ENTRIES]
    project["job_history"] = cleaned
    save_state()
    return jsonify({"success": True, "count": len(cleaned)}), 200


@bp.route("/video-job-remarks/<video_key>/<session_id>",
          methods=["POST", "OPTIONS"])
def update_job_remarks(video_key, session_id):
    if request.method == "OPTIONS":
        return ("", 204)
    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        return jsonify({"error": "Video not found"}), 404
    ensure_job_history(project)

    payload = request.get_json(silent=True) or {}
    if "remarks" not in payload:
        return jsonify({"error": "remarks is required"}), 400
    remarks = str(payload["remarks"])
    if len(remarks) > 4096:
        return jsonify({"error": "remarks is too long"}), 400

    entry = next((e for e in project["job_history"]
                  if e.get("session_id") == session_id), None)
    if entry is None:
        return jsonify({"error": "Job not found in history"}), 404
    entry["remarks"] = remarks
    save_state()
    return jsonify({"success": True, "job": entry}), 200


@bp.route("/media/<video_key>")
def serve_video(video_key):
    project = next((p for p in videos if p["key"] == video_key), None)
    if not project:
        return jsonify({"error": "Video not found"}), 404
    file_name = project.get("file_name")
    if not file_name:
        return jsonify({"error": "File name not available"}), 404
    file_path = os.path.join(UPLOAD_FOLDER, file_name)
    if not os.path.exists(file_path):
        return jsonify({"error": f'File "{file_name}" not found on disk'}), 404
    return send_file(file_path, as_attachment=False,
                     mimetype="video/mp4", conditional=True)


@bp.route("/thumbnails/<filename>")
def serve_thumbnail(filename):
    if ".." in filename or "/" in filename or "\\" in filename:
        return jsonify({"error": "Invalid filename"}), 400
    p = os.path.join(UPLOAD_FOLDER, filename)
    if not os.path.exists(p):
        return jsonify({"error": "Thumbnail not found"}), 404
    return send_file(p, mimetype="image/jpeg")


@bp.route("/delete-video/<video_key>", methods=["POST", "DELETE", "OPTIONS"])
def delete_video(video_key):
    if request.method == "OPTIONS":
        return ("", 204)
    target = next((v for v in videos if v.get("key") == video_key), None)
    if not target:
        return jsonify({"error": "Video not found"}), 404
    ensure_greenscreen_fields(target)

    def safe_unlink(path):
        if path and os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass

    file_name = target.get("file_name")
    gs_name = target.get("greenscreen_file_name")
    if file_name:
        safe_unlink(os.path.join(UPLOAD_FOLDER, file_name))
        safe_unlink(os.path.join(UPLOAD_FOLDER,
                                 f"{os.path.splitext(file_name)[0]}_thumb.jpg"))
    if gs_name:
        safe_unlink(os.path.join(UPLOAD_FOLDER, gs_name))

    from ..state import sessions
    from ..utils import session_dir
    session_ids = [sid for sid, s in sessions.items()
                   if s.get("video_key") == video_key]
    for sid in session_ids:
        sdir = session_dir(sid)
        if os.path.isdir(sdir):
            try:
                shutil.rmtree(sdir)
            except OSError:
                pass
        sessions.pop(sid, None)

    job_ids = [jid for jid, j in jobs.items() if j.get("video_key") == video_key]
    for jid in job_ids:
        jobs.pop(jid, None)

    videos.remove(target)
    save_state()
    return jsonify({"success": True, "deleted_key": video_key,
                    "deleted_sessions": len(session_ids),
                    "deleted_jobs": len(job_ids)}), 200


@bp.route("/update-project-name/<video_key>", methods=["POST", "OPTIONS"])
def update_project_name(video_key):
    if request.method == "OPTIONS":
        return ("", 204)
    data = request.get_json(silent=True) or {}
    new_name = (data.get("project_name") or "").strip()
    if not new_name:
        return jsonify({"error": "project_name is required"}), 400
    target = next((v for v in videos if v.get("key") == video_key), None)
    if not target:
        return jsonify({"error": "Video not found"}), 404
    target["name"] = new_name
    save_state()
    return jsonify({"success": True, "project": target}), 200


@bp.route("/update-project-source/<video_key>", methods=["POST", "OPTIONS"])
def update_project_source(video_key):
    if request.method == "OPTIONS":
        return ("", 204)
    data = request.get_json(silent=True) or {}
    new_source = (data.get("source") or "").strip()
    if not new_source:
        return jsonify({"error": "source is required"}), 400
    if len(new_source) > 2048:
        return jsonify({"error": "source is too long"}), 400
    target = next((v for v in videos if v.get("key") == video_key), None)
    if not target:
        return jsonify({"error": "Video not found"}), 404
    ensure_source_field(target)
    target["source"] = new_source
    save_state()
    return jsonify({"success": True, "video_key": video_key,
                    "source": new_source}), 200


@bp.route("/stop-segmentation/<video_key>", methods=["POST", "OPTIONS"])
def stop_segmentation(video_key):
    if request.method == "OPTIONS":
        return ("", 204)
    stopped = 0
    for job in jobs.values():
        if job.get("video_key") == video_key and job.get("status") == "processing":
            job["status"] = "stopped"
            stopped += 1
    if stopped:
        save_state()
    return jsonify({"success": True, "stopped_jobs": stopped}), 200


@bp.route("/prepare-greenscreen/<video_key>", methods=["POST", "OPTIONS"])
def prepare_greenscreen(video_key):
    if request.method == "OPTIONS":
        return ("", 204)
    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        return jsonify({"error": "Video not found"}), 404
    ensure_greenscreen_fields(project)
    if project.get("greenscreen_status") == "ready":
        return jsonify({"success": True, "status": "ready",
                        "greenscreen_file_name":
                            project.get("greenscreen_file_name")}), 200
    if project.get("greenscreen_status") == "building":
        return jsonify({"success": True, "status": "building"}), 200

    project["greenscreen_status"] = "building"
    project["greenscreen_progress"] = 0
    save_state()
    threading.Thread(target=build_greenscreen_for_project,
                     args=(video_key,), daemon=True).start()
    return jsonify({"success": True, "status": "building"}), 202


@bp.route("/start-job/<video_key>", methods=["POST"])
def start_job(video_key):
    data = request.get_json()
    job_id = str(uuid.uuid4())
    job = {
        "id": job_id, "video_key": video_key,
        "status": "processing", "progress": 0.0,
        "transcript": None, "segments": None,
        "created_at": utc_now_iso(), "config": data,
    }
    jobs[job_id] = job
    from ..video import _placeholder_job  # noqa: F401 — not used; real work is in worker
    save_state()
    return jsonify({"job_id": job_id, "status": "processing"}), 200


@bp.route("/job-status/<job_id>", methods=["GET"])
def job_status(job_id):
    job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404
    return jsonify({
        "status": job["status"], "progress": job["progress"],
        "transcript": job.get("transcript"),
        "segments": job.get("segments"),
    }), 200