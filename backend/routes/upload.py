import datetime
import json
import logging
import os
import uuid

from flask import Blueprint, jsonify, request

from ..config import UPLOAD_FOLDER, resolve_target_url
from ..state import save_state, videos
from ..uploader import upload_and_register
from ..utils import user_home_path, utc_now_iso
from ..video import get_video_metadata

bp = Blueprint("upload", __name__)


@bp.route("/upload", methods=["POST", "OPTIONS"])
def upload_to_internal():
    if request.method == "OPTIONS":
        return ("", 204)

    content_type = (request.content_type or "").lower()
    is_multipart = "multipart/form-data" in content_type

    if is_multipart:
        token = request.form.get("token", "").strip()
    else:
        data_in = request.get_json(silent=True) or {}
        token = ((data_in.get("token") or "").strip()
                 or request.headers.get("Authorization", "").replace("Bearer ", "").strip())
    if not token:
        return jsonify({"error": "Missing token"}), 400

    if is_multipart:
        if "videofile" not in request.files:
            return jsonify({"error": "No video file provided"}), 400
        file_storage = request.files["videofile"]
        if not file_storage.filename:
            return jsonify({"error": "Empty filename"}), 400

        session_name = request.form.get("name", file_storage.filename)
        original_filename = file_storage.filename
        if not original_filename.lower().endswith(".mp4"):
            original_filename = f"{os.path.splitext(original_filename)[0]}.mp4"

        existing = next((v for v in videos
                         if v.get("file_name") == original_filename), None)
        local_filename = original_filename
        local_path = os.path.join(UPLOAD_FOLDER, local_filename)

        if existing:
            video_key = existing["key"]
            project = existing
            if not os.path.exists(local_path):
                file_storage.save(local_path)
        else:
            base, ext = os.path.splitext(original_filename)
            ext = ext or ".mp4"
            counter = 1
            while os.path.exists(local_path):
                local_filename = f"{base}_{counter}{ext}"
                local_path = os.path.join(UPLOAD_FOLDER, local_filename)
                counter += 1
            file_storage.save(local_path)
            duration, fps, codec = get_video_metadata(local_path)
            video_key = str(uuid.uuid4())
            project = {
                "key": video_key, "name": session_name,
                "file_name": local_filename, "uploaded": utc_now_iso(),
                "last_opened": None, "duration": duration, "fps": fps,
                "codec": codec, "file_size": os.path.getsize(local_path),
                "segment_count": 0,
                "languages": request.form.getlist("language") or ["en"],
                "thumbnail_url": None, "segmentation_done": False,
                "segmentation_progress": 0,
                "source": request.form.get("source", "Desktop Upload"),
            }
            videos.append(project)

        file_size = os.path.getsize(local_path)
        form_data = {}
        for key in request.form.keys():
            if key == "token":
                continue
            values = request.form.getlist(key)
            form_data[key] = values[0] if len(values) == 1 else values
        form_data["path"] = user_home_path(token)
        expected_mt = request.form.getlist("mtLanguage") or ["de"]
        target_url = resolve_target_url(request.form.get("targetServer"))
        clear_stale = False
    else:
        video_key = (data_in.get("video_key") or "").strip()
        if not video_key:
            return jsonify({"error": "video_key is required"}), 400
        project = next((v for v in videos if v.get("key") == video_key), None)
        if project is None:
            return jsonify({"error": "Video not found", "video_key": video_key}), 404
        file_name = project.get("file_name")
        if not file_name:
            return jsonify({"error": "Video has no file_name"}), 400
        local_path = os.path.join(UPLOAD_FOLDER, file_name)
        if not os.path.exists(local_path):
            return jsonify({"error": f'File "{file_name}" not found on disk'}), 404
        file_size = os.path.getsize(local_path)
        if file_size < 1000:
            return jsonify({"error": "File is too small to upload"}), 400
        session_name = ((data_in.get("name") or "").strip()
                        or project.get("name")
                        or os.path.splitext(file_name)[0])

        def as_list(v):
            if v is None:
                return None
            if isinstance(v, list):
                return [str(x) for x in v]
            return [str(v)]

        form_data = {
            "path": user_home_path(token),
            "name": session_name,
            "topicname": data_in.get("topicname") or session_name,
            "date": data_in.get("date") or datetime.datetime.now().strftime("%Y-%m-%d"),
            "speakername": data_in.get("speakername") or "",
            "availability": data_in.get("availability") or "private",
            "format": data_in.get("format") or "mixed",
            "smartChaptering": data_in.get("smartChaptering") or "online_dynamic",
            "errorCorrection": data_in.get("errorCorrection") or "None",
            "ttsQualityMode": data_in.get("ttsQualityMode") or "low_latency",
            "language": as_list(data_in.get("language")) or ["en"],
            "mtLanguage": as_list(data_in.get("mtLanguage")) or ["de"],
            "audioLanguage": as_list(data_in.get("audioLanguage")) or ["de"],
            "profanity": str(data_in.get("profanity") or "1"),
            "filter_music": str(data_in.get("filter_music") or "1"),
            "summarization": str(data_in.get("summarization") or "1"),
            "logging": str(data_in.get("logging") or "1"),
            "legals": str(data_in.get("legals") or "1"),
            "profile": data_in.get("profile") or "profile_1",
            "profile_names": data_in.get("profile_names") or "",
            "shorten": data_in.get("shorten") or "",
            "mute": str(data_in.get("mute") or "120"),
            "pause": str(data_in.get("pause") or "2"),
            "save_profile": "1",
        }
        for opt in ("notes", "saasr", "aiassistant", "distinguish_unknown_speakers"):
            v = data_in.get(opt)
            if v:
                form_data[opt] = str(v)
        postprod = as_list(data_in.get("postproduction"))
        if postprod:
            form_data["postproduction"] = postprod
        expected_mt = (data_in.get("mtLanguage")
                       or data_in.get("mt_languages") or ["de"])
        if isinstance(expected_mt, str):
            expected_mt = [expected_mt]
        target_url = resolve_target_url(
            data_in.get("targetServer")
            or request.headers.get("X-Target-Server"))
        clear_stale = True

    base_url = target_url.rsplit("/upload_lecture", 1)[0]
    body, status = upload_and_register(
        local_path=local_path, file_size=file_size,
        session_name=session_name, form_data=form_data, token=token,
        target_url=target_url, base_url=base_url, video_key=video_key,
        project=project, expected_mt=expected_mt,
        clear_stale_session=clear_stale,
    )
    return jsonify(body), status