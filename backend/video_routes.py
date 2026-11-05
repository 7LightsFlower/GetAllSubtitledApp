"""Video list, detail, uploads, deletion, folders.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import datetime
import glob
import json
import logging
import os
import re
import shutil
import threading
import urllib
import uuid
from flask import jsonify, request, send_file

from .flask_app import app
from .servers import INTERNAL_SERVER_URL, _SERVER_LABELS
from .live import _live_relay_mod
from .config import (
    STATE_FILE,
    UPLOAD_FOLDER,
    chunk_storage,
    jobs,
    sessions,
    videos,
)
from .state import save_state
from .utils import (
    MAX_JOB_HISTORY_ENTRIES,
    _effective_token,
    _ensure_codec_field,
    _ensure_greenscreen_fields,
    _ensure_job_history,
    _ensure_source_field,
    _session_dir,
    _short_sid,
    _thumbnail_absolute_url,
    file_mtime_iso,
    utc_now_iso,
)
from .progress import _JobCancelled, _job_progress_store, job_progress_lock
from .job_routes import process_job
from .video import generate_video_thumbnail, get_video_metadata
from .downloads import download_session_files
from .media import _get_session_original_video_path


@app.route("/videos", methods=["GET"])
def get_videos():
    """Return the list of uploaded videos with storage usage info."""

    for video in videos:
        _ensure_greenscreen_fields(video)
        _ensure_source_field(video)
        _ensure_codec_field(video)
    # ============ DEDUPLICATION LOGIC ============
    # Group videos by filename (without UUID prefix)
    video_groups = {}

    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            continue

        # Check if this is a UUID-prefixed file
        uuid_match = re.match(
            r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_", file_name
        )

        # Determine the "clean" filename (without UUID prefix)
        if uuid_match:
            clean_name = file_name[
                36:
            ]  # Remove UUID prefix (8+1+4+1+4+1+4+1+12 = 36 chars)
            # If clean_name is empty or just extension, keep the original
            if not clean_name or clean_name.startswith("."):
                clean_name = file_name
        else:
            clean_name = file_name

        # Store in groups by clean_name
        if clean_name not in video_groups:
            video_groups[clean_name] = []
        video_groups[clean_name].append(video)

    # For each group, keep only the best video
    unique_videos = []
    for clean_name, group in video_groups.items():
        if len(group) == 1:
            # Only one video, keep it
            unique_videos.append(group[0])
        else:
            # Multiple videos with same name - keep the best one
            best_video = group[0]
            for video in group[1:]:
                # Prefer video with:
                # - segmentation_done == True
                # - thumbnail_url exists
                # - larger file_size
                # - no UUID prefix (prefer clean filename)
                current_score = 0
                best_score = 0

                # Check current video (best_video)
                if best_video.get("segmentation_done"):
                    best_score += 10
                if best_video.get("thumbnail_url"):
                    best_score += 5
                if best_video.get("file_size", 0) > 0:
                    best_score += min(
                        best_video.get("file_size", 0) / 1000000, 10
                    )  # Up to 10 points for size
                # Prefer clean filename (no UUID)
                if not re.match(
                    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
                    best_video.get("file_name", ""),
                ):
                    best_score += 3

                # Check candidate video (video)
                if video.get("segmentation_done"):
                    current_score += 10
                if video.get("thumbnail_url"):
                    current_score += 5
                if video.get("file_size", 0) > 0:
                    current_score += min(video.get("file_size", 0) / 1000000, 10)
                if not re.match(
                    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}_",
                    video.get("file_name", ""),
                ):
                    current_score += 3

                if current_score > best_score:
                    best_video = video

            unique_videos.append(best_video)
    # ========================================

    # Build absolute thumbnail URLs from the incoming request so they work
    # behind any host/proxy (localhost, Nginx, public domain, ...).
    # Do NOT mutate the stored dicts: their thumbnail_url stays relative.
    unique_videos_serialized = []
    for video in unique_videos:
        v = dict(video)  # shallow copy
        v["thumbnail_url"] = _thumbnail_absolute_url(video)
        unique_videos_serialized.append(v)
    unique_videos = unique_videos_serialized

    storage_used_gb = sum(v.get("file_size", 0) for v in unique_videos) / (1024.0**3)
    return (
        jsonify(
            {
                "projects": unique_videos,
                "storage_used_gb": round(storage_used_gb, 2),
                "storage_limit_gb": 50.0,
            }
        ),
        200,
    )


@app.route("/video-detail/<video_key>", methods=["GET"])
def video_detail(video_key):
    """Return details for a specific video by its key."""
    for project in videos:
        if project["key"] == video_key:
            _ensure_greenscreen_fields(project)
            _ensure_source_field(project)
            _ensure_codec_field(project)
            detail = project.copy()
            detail["thumbnail_url"] = _thumbnail_absolute_url(project)
            detail["segments"] = detail.get("segments", [])
            detail["video_url"] = None

            # ── Green-screen metadata (size + creation time) ──
            # The green-screen is a tiny audio-bearing stand-in built
            # from the original video. It is what actually gets sent to
            # the internal processing server, so the client shows its
            # size and creation timestamp next to the original's.
            gs_name = project.get("greenscreen_file_name")
            gs_size = 0
            gs_created_at = None
            if gs_name:
                gs_path = os.path.join(UPLOAD_FOLDER, gs_name)
                if os.path.exists(gs_path):
                    try:
                        gs_size = os.path.getsize(gs_path)
                        gs_created_at = file_mtime_iso(gs_path)
                    except OSError:
                        pass
            detail["greenscreen_file_size"] = gs_size
            detail["greenscreen_created_at"] = gs_created_at

            _ensure_job_history(project)
            detail["job_history"] = list(project["job_history"])
            return jsonify(detail), 200
    return jsonify({"error": "Video not found"}), 404


@app.route(
    "/video-job-history/<video_key>",
    methods=["GET", "PUT", "DELETE", "OPTIONS"],
)
def video_job_history(video_key):
    """Server-side job history for one video.

    GET    → the whole list, newest first
    PUT    → replace the whole list (payload must be a JSON list)
    DELETE → clear the list

    The list is stored on the project dict and therefore persisted in
    `server_state.pkl` like everything else. It's shared between all
    browsers/clients that talk to this backend.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        return jsonify({"error": "Video not found"}), 404

    _ensure_job_history(project)

    if request.method == "GET":
        # Snapshot so a concurrent write can't mutate the list while
        # Flask is serialising it.
        return jsonify(list(project["job_history"])), 200

    if request.method == "DELETE":
        project["job_history"] = []
        save_state()
        logging.info("job-history: cleared for video %s", video_key)
        return jsonify({"success": True, "count": 0}), 200

    # PUT — replace the whole list
    payload = request.get_json(silent=True)
    if not isinstance(payload, list):
        return (
            jsonify({"error": "Expected a JSON list in the request body"}),
            400,
        )

    # Defensive: drop non-dict entries, cap length.
    cleaned = [e for e in payload if isinstance(e, dict)]
    if len(cleaned) > MAX_JOB_HISTORY_ENTRIES:
        cleaned = cleaned[:MAX_JOB_HISTORY_ENTRIES]

    project["job_history"] = cleaned
    save_state()
    logging.info(
        "job-history: saved %d entries for video %s",
        len(cleaned),
        video_key,
    )
    return jsonify({"success": True, "count": len(cleaned)}), 200


@app.route(
    "/video-job-remarks/<video_key>/<session_id>",
    methods=["POST", "OPTIONS"],
)
def update_job_remarks(video_key, session_id):
    """Set or update the free-text remarks on one job-history entry.

    Body: ``{"remarks": "..."}``. Empty string clears the field.
    Returns the updated entry so the client can replace its copy
    without a full re-fetch.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        return jsonify({"error": "Video not found"}), 404

    _ensure_job_history(project)

    payload = request.get_json(silent=True) or {}
    if "remarks" not in payload:
        return jsonify({"error": "remarks is required"}), 400

    remarks = str(payload["remarks"])
    if len(remarks) > 4096:
        return jsonify({"error": "remarks is too long (max 4096)"}), 400

    # ── Locate the entry ────────────────────────────────────────────
    # Three lookups, most specific first:
    #   1. exact match on session_id
    #   2. match after stripping whitespace on both sides (a proxy
    #      can turn '+' into ' ' in a path segment)
    #   3. match after comparing the URL-decoded forms
    def _canon(s: str) -> str:
        return urllib.parse.unquote(str(s or "")).strip()

    want_exact = session_id
    want_canon = _canon(session_id)

    entry = None
    for e in project["job_history"]:
        if e.get("session_id") == want_exact:
            entry = e
            break
    if entry is None:
        for e in project["job_history"]:
            if _canon(e.get("session_id", "")) == want_canon:
                entry = e
                break

    # ── Fall back: create the entry ─────────────────────────────────
    # The client may be writing remarks on a job it knows about but
    # the server doesn't have yet (first-ever remarks on a job whose
    # PUT to /video-job-history raced with this call, or an older
    # client that stores history locally). Rather than 404, seed a
    # minimal entry so the note is not lost.
    if entry is None:
        logging.info(
            "job-remarks: no existing entry for %s on %s — creating one",
            _short_sid(session_id),
            video_key,
        )
        entry = {
            "session_id": session_id,
            "session_url": "",
            "session_name": session_id,
            "timestamp": utc_now_iso(),
            "date": datetime.datetime.now().strftime("%Y-%m-%d"),
            "status": "Unknown",
            "has_output": False,
            "output_files": 0,
            "pipeline": _SERVER_LABELS.get(INTERNAL_SERVER_URL, INTERNAL_SERVER_URL),
            "pipeline_url": INTERNAL_SERVER_URL,
            "email": "",
        }
        project["job_history"].insert(0, entry)

    entry["remarks"] = remarks
    save_state()

    logging.info(
        "job-remarks: updated for %s (len=%d)",
        _short_sid(session_id),
        len(remarks),
    )
    return jsonify({"success": True, "job": entry}), 200


@app.route("/media/<video_key>")
def serve_video(video_key):
    """Serve the original uploaded video file for a project."""
    project = next((p for p in videos if p["key"] == video_key), None)
    if not project:
        return jsonify({"error": "Video not found"}), 404
    file_name = project.get("file_name")
    if not file_name:
        return jsonify({"error": "File name not available"}), 404
    file_path = os.path.join(UPLOAD_FOLDER, file_name)
    if not os.path.exists(file_path):
        return jsonify({"error": f'File "{file_name}" not found on disk'}), 404

    return send_file(
        file_path,
        as_attachment=False,
        mimetype="video/mp4",
        conditional=True,
    )


@app.route("/thumbnails/<filename>")
def serve_thumbnail(filename):
    """Serve thumbnail images."""
    if ".." in filename or "/" in filename or "\\" in filename:
        return jsonify({"error": "Invalid filename"}), 400

    thumbnail_path = os.path.join(UPLOAD_FOLDER, filename)
    if not os.path.exists(thumbnail_path):
        return jsonify({"error": "Thumbnail not found"}), 404

    return send_file(thumbnail_path, mimetype="image/jpeg")


@app.route("/upload-chunk", methods=["POST"])
def upload_chunk():
    """Receive a chunk of a file upload for chunked uploads."""
    file = request.files.get("file")
    filename = request.form.get("filename")
    chunk_index = int(request.form.get("chunk_index", 0))
    total_chunks = int(request.form.get("total_chunks", 1))
    if not file or not filename:
        return jsonify({"message": "Missing file or filename"}), 400
    if filename not in chunk_storage:
        chunk_storage[filename] = [None] * total_chunks
    chunk_storage[filename][chunk_index] = file.read()
    return jsonify({"message": "Chunk uploaded"}), 200


@app.route("/finish-upload", methods=["POST"])
def finish_upload():
    """Complete a chunked upload and persist the file to disk."""
    data = request.get_json()
    original_filename = data.get("filename")
    auto_segmentation = data.get("auto_segmentation", False)
    if not original_filename:
        return jsonify({"message": "Missing filename"}), 400

    # chunk_storage is keyed by whatever name /upload-chunk was called
    # with — look it up under that name, not the normalised one.
    chunks = chunk_storage.get(original_filename)
    if not chunks or any(chunk is None for chunk in chunks):
        return jsonify({"message": "Incomplete upload"}), 400
    combined = b"".join(chunks)

    # ============ FIX: Ensure .mp4 extension ============
    # Only used for the on-disk filename; the storage key stays as-is.
    filename = original_filename
    if not filename.lower().endswith(".mp4"):
        base_name = os.path.splitext(filename)[0]
        filename = f"{base_name}.mp4"
    # ====================================================

    file_path = os.path.join(UPLOAD_FOLDER, filename)
    with open(file_path, "wb") as f:
        f.write(combined)
    file_size = len(combined)

    thumbnail_filename = f"{os.path.splitext(filename)[0]}_thumb.jpg"
    thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
    thumbnail_url = None

    # Generate thumbnail with proper path
    if generate_video_thumbnail(file_path, thumbnail_path):
        thumbnail_url = f"/thumbnails/{thumbnail_filename}"
        logging.info("Generated thumbnail: %s", thumbnail_filename)
    else:
        logging.warning("Failed to generate thumbnail for %s", filename)

    duration, fps, codec = get_video_metadata(file_path)

    # Source: whatever the client told us, or a sensible default.
    # The Flutter upload dialog sends "Desktop Upload" explicitly;
    # the URL-import dialog sends the original URL.
    source = (data.get("source") or "Desktop Upload").strip() or "Desktop Upload"

    project = {
        "key": str(uuid.uuid4()),
        "name": filename.rsplit(".", 1)[0] if "." in filename else filename,
        "file_name": filename,
        "uploaded": utc_now_iso(),
        "last_opened": None,
        "duration": duration,
        "fps": fps,
        "codec": codec,  # ── NEW ──
        "file_size": file_size,
        "segment_count": 0,
        "languages": ["en"],
        "thumbnail_url": thumbnail_url,
        "segmentation_done": auto_segmentation,
        "segmentation_progress": 100 if auto_segmentation else 0,
        "source": source,  # ── NEW ──
    }
    videos.append(project)

    # Remove the chunk buffer under the key the client actually used.
    # pop() instead of del so a duplicate /finish-upload call can't crash
    # the second time around.
    chunk_storage.pop(original_filename, None)

    save_state()
    return jsonify({"message": "Upload finished", "project": project}), 200


# ─── PROJECT MANAGEMENT (no auth) ──────────────────────────────────────


@app.route("/delete-video/<video_key>", methods=["POST", "DELETE", "OPTIONS"])
def delete_video(video_key):
    """Delete a project: original, green-screen, thumbnail, sessions, jobs.

    Every artefact associated with the project is removed from disk and
    from the in-memory state, in one call. Missing files are not an
    error — the endpoint is idempotent.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    target = next((v for v in videos if v.get("key") == video_key), None)
    if not target:
        return jsonify({"error": "Video not found"}), 404

    _ensure_greenscreen_fields(target)

    name = target.get("name", "<unnamed>")

    # ── 1. Files on disk ──────────────────────────────────────────
    # Everything a project owns lives in UPLOAD_FOLDER. We delete by
    # explicit filename rather than by pattern so we never touch a
    # different project's files.
    file_name = target.get("file_name")
    gs_name = target.get("greenscreen_file_name")

    def _safe_unlink(path: str, what: str):
        """Remove a file, logging but never raising on failure."""
        if not path:
            return
        if not os.path.exists(path):
            return
        try:
            os.remove(path)
            logging.info("🗑️ Deleted %s: %s", what, path)
        except OSError as e:
            logging.warning("Could not delete %s %s: %s", what, path, e)

    if file_name:
        _safe_unlink(os.path.join(UPLOAD_FOLDER, file_name), "original video")
        # The thumbnail is named after the original.
        thumb_name = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        _safe_unlink(os.path.join(UPLOAD_FOLDER, thumb_name), "thumbnail")

    if gs_name:
        _safe_unlink(os.path.join(UPLOAD_FOLDER, gs_name), "green-screen")

    # Belt-and-braces: sweep up any green-screen this project might
    # have left behind, whether it was named under the old scheme
    # (<stem>__greenscreen.mp4) or the new one (<stem>__<hash>__greenscreen.mp4).
    # Triggered when greenscreen_file_name was never populated, e.g.
    # because the build was interrupted. The stem prefix is the same
    # in both schemes for the first 50 chars, so one glob covers both.
    if file_name:
        base = os.path.splitext(file_name)[0]
        stem_prefix = re.sub(r"[^A-Za-z0-9_.-]", "_", base)[:50].strip("_") or "video"
        pattern = os.path.join(UPLOAD_FOLDER, f"{stem_prefix}*__greenscreen.mp4")
        for orphan_gs in glob.glob(pattern):
            _safe_unlink(orphan_gs, "orphaned green-screen")

    # ── 2. Sessions on disk ───────────────────────────────────────
    # A project can have any number of sessions (re-uploads of the
    # same file). Every one of them owns a directory.
    session_ids = [
        sid for sid, s in sessions.items() if s.get("video_key") == video_key
    ]
    for sid in session_ids:
        session_dir = _session_dir(sid)
        if os.path.isdir(session_dir):
            try:
                shutil.rmtree(session_dir)
                logging.info("🗑️ Deleted session dir: %s", session_dir)
            except OSError as e:
                logging.warning("Could not delete session dir %s: %s", session_dir, e)
        sessions.pop(sid, None)

    # ── 3. Jobs (in-memory and persisted) ─────────────────────────
    job_ids = [jid for jid, j in jobs.items() if j.get("video_key") == video_key]
    for jid in job_ids:
        jobs.pop(jid, None)

    # ── 4. In-memory progress entries ────────────────────────────
    # `_job_progress_store` is keyed by session id, so it's already
    # covered by the session removal above. `download_progress` is
    # keyed by download id and is unrelated to a project. Nothing to
    # do here for now, but leaving this comment so it's clear we
    # considered it.

    # ── 5. Chunk buffer (if the user re-uploaded this project) ────
    if file_name:
        # The exact key used by /upload-chunk is whatever the client
        # sent as `filename`, which is typically the original name.
        chunk_storage.pop(file_name, None)

        # Also sweep anything else that shares the cleaned base name.
        # Match on a real boundary: "cat" should match "cat.part1"
        # but not "certificate" or "bobcat_session_42".
        base = os.path.splitext(file_name)[0]
        prefix = base + "."
        for key in [k for k in chunk_storage if k == base or k.startswith(prefix)]:
            del chunk_storage[key]
    # ── 6. The project entry itself ───────────────────────────────
    videos.remove(target)
    save_state()

    logging.info("✅ Deleted project '%s' (key=%s)", name, video_key)

    return (
        jsonify(
            {
                "success": True,
                "deleted_key": video_key,
                "deleted_sessions": len(session_ids),
                "deleted_jobs": len(job_ids),
            }
        ),
        200,
    )


@app.route("/update-project-name/<video_key>", methods=["POST", "OPTIONS"])
def update_project_name(video_key):
    """Rename a project in place (no auth)."""
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


# ─── Video folders (working screen) ─────────────────────────────────
# One level of folders. A video's folder is stored on the video entry
# itself ("folder": name or absent); the list of folder names — so empty
# folders survive too — lives in state/folders.json (persistent volume).
_FOLDERS_FILE = os.path.join(os.path.dirname(STATE_FILE), "folders.json")
_folders_lock = threading.Lock()


def _clean_folder_name(name) -> str:
    name = re.sub(r"\s+", " ", str(name or "")).strip()
    return name[:80]


def _read_folders() -> list:
    try:
        with open(_FOLDERS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        names = data.get("folders") if isinstance(data, dict) else data
        return [n for n in (names or []) if isinstance(n, str) and n.strip()]
    except (OSError, ValueError):
        return []


def _write_folders(names: list) -> None:
    os.makedirs(os.path.dirname(_FOLDERS_FILE), exist_ok=True)
    tmp = _FOLDERS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"folders": names}, f, ensure_ascii=False, indent=2)
    os.replace(tmp, _FOLDERS_FILE)


_SPLIT_MARKER = os.path.join(os.path.dirname(STATE_FILE), ".folders_split_done")


def _split_off_live_folders() -> None:
    """Once: video and live folders used to be shared. Folders that only
    live sessions use move to the live list (they keep their sessions);
    they leave the video list. Empty folders stay video folders."""
    if os.path.exists(_SPLIT_MARKER):
        return
    try:
        live_names = {n.lower() for n in _live_relay_mod.live_folder_names_in_use()}
        video_used = {(v.get("folder") or "").lower() for v in videos}
        keep = [n for n in _read_folders()
                if n.lower() not in live_names or n.lower() in video_used]
        _write_folders(keep)
        _live_relay_mod._read_live_folders()  # creates the live folder file
        with open(_SPLIT_MARKER, "w", encoding="utf-8") as f:
            f.write("done\n")
    except Exception as e:  # never block the video list over this
        logging.warning("splitting live folders off failed: %s", e)


def _all_folders() -> list:
    """Saved folder names plus any a video still points to, A→Z."""
    names = {n.lower(): n for n in _read_folders()}
    for v in videos:
        f = v.get("folder")
        if f and f.lower() not in names:
            names[f.lower()] = f
    return sorted(names.values(), key=str.lower)


def _find_folder(name: str):
    low = name.lower()
    return next((n for n in _all_folders() if n.lower() == low), None)


@app.route("/api/folders", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
def video_folders():
    """GET → {"folders": [...]}
    POST {"name"}                → create
    PUT {"old", "new"}            → rename (moves its videos along)
    DELETE ?name=…                → delete (its videos become unsorted)"""
    if request.method == "OPTIONS":
        return ("", 204)
    with _folders_lock:
        if request.method == "GET":
            _split_off_live_folders()
            return jsonify({"folders": _all_folders()}), 200

        if request.method == "DELETE":
            name = _find_folder(_clean_folder_name(request.args.get("name")))
            if not name:
                return jsonify({"error": "Folder not found"}), 404
            moved = 0
            for v in videos:
                if (v.get("folder") or "").lower() == name.lower():
                    v.pop("folder", None)
                    moved += 1
            _write_folders([n for n in _all_folders() if n.lower() != name.lower()])
            save_state(force=True)
            return jsonify({"success": True, "unsorted": moved}), 200

        data = request.get_json(silent=True) or {}
        if request.method == "POST":
            name = _clean_folder_name(data.get("name"))
            if not name:
                return jsonify({"error": "name is required"}), 400
            if _find_folder(name):
                return jsonify({"error": f'A folder "{name}" already exists'}), 409
            _write_folders(_all_folders() + [name])
            return jsonify({"success": True, "folders": _all_folders()}), 201

        # PUT = rename
        old = _find_folder(_clean_folder_name(data.get("old")))
        new = _clean_folder_name(data.get("new"))
        if not old:
            return jsonify({"error": "Folder not found"}), 404
        if not new:
            return jsonify({"error": "new name is required"}), 400
        clash = _find_folder(new)
        if clash and clash.lower() != old.lower():
            return jsonify({"error": f'A folder "{new}" already exists'}), 409
        for v in videos:
            if (v.get("folder") or "").lower() == old.lower():
                v["folder"] = new
        _write_folders(
            [new if n.lower() == old.lower() else n for n in _all_folders()]
        )
        save_state(force=True)
        return jsonify({"success": True, "folders": _all_folders()}), 200


@app.route("/api/videos/<video_key>/folder", methods=["POST", "OPTIONS"])
def set_video_folder(video_key):
    """Move a video into a folder: {"folder": "Name"} or {"folder": null}."""
    if request.method == "OPTIONS":
        return ("", 204)
    target = next((v for v in videos if v.get("key") == video_key), None)
    if not target:
        return jsonify({"error": "Video not found"}), 404
    raw = (request.get_json(silent=True) or {}).get("folder")
    with _folders_lock:
        if raw in (None, ""):
            target.pop("folder", None)
        else:
            name = _clean_folder_name(raw)
            existing = _find_folder(name)
            if not existing:  # moving into a new name creates the folder
                _write_folders(_all_folders() + [name])
                existing = name
            target["folder"] = existing
        save_state(force=True)
    return jsonify({"success": True, "folder": target.get("folder")}), 200


@app.route("/stop-segmentation/<video_key>", methods=["POST", "OPTIONS"])
def stop_segmentation(video_key):
    """Mark any running segmentation jobs for this video as stopped."""
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


@app.route("/update-project-source/<video_key>", methods=["POST", "OPTIONS"])
def update_project_source(video_key):
    """Update the `source` field of a project (no auth).

    Body:  {"source": "<url or free-text label>"}

    Empty or whitespace-only values are rejected so the field never
    becomes useless. The full value is echoed back so the client can
    use the server's canonical form.
    """
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

    _ensure_source_field(target)
    target["source"] = new_source
    save_state()

    logging.info("update_project_source: %s -> %r", video_key, new_source)
    return (
        jsonify(
            {
                "success": True,
                "video_key": video_key,
                "source": new_source,
            }
        ),
        200,
    )


# ─── JOB ENDPOINTS ──────────────────────────────────────────────────────


@app.route("/start-job/<video_key>", methods=["POST"])
def start_job(video_key):
    """Start a background transcription job for the given video."""
    data = request.get_json()
    job_id = str(uuid.uuid4())
    job = {
        "id": job_id,
        "video_key": video_key,
        "status": "processing",
        "progress": 0.0,
        "transcript": None,
        "segments": None,
        "created_at": utc_now_iso(),
        "config": data,
    }
    jobs[job_id] = job
    threading.Thread(target=process_job, args=(job_id,), daemon=True).start()
    save_state()
    return jsonify({"job_id": job_id, "status": "processing"}), 200


@app.route("/job-status/<job_id>", methods=["GET"])
def job_status(job_id):
    """Return the current status of a transcription job."""
    job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404
    return (
        jsonify(
            {
                "status": job["status"],
                "progress": job["progress"],
                "transcript": job.get("transcript"),
                "segments": job.get("segments"),
            }
        ),
        200,
    )


# ─── SESSION OUTPUT ENDPOINTS ──────────────────────────────────────────
def _is_meaningful_file(path: str) -> bool:
    """Files worth showing in the UI. VTTs can be tiny for short videos."""
    name = os.path.basename(path).lower()
    try:
        size = os.path.getsize(path)
    except OSError:
        return False

    if name.endswith(".vtt") or name.endswith(".txt") or name.endswith(".json"):
        return size > 20
    return size > 1000


@app.route("/session-output/<path:session_id>", methods=["GET"])
def get_session_output(session_id):
    """Return the available output files for a transcription session."""
    session_dir = _session_dir(session_id)

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    # Don't race the background worker. It's already going to fetch
    # everything as soon as the KIT server says the session is ready.
    with job_progress_lock:
        job_running = session_id in _job_progress_store and not _job_progress_store[
            session_id
        ].get("done")

    if (
        not job_running
        and token
        and (not os.path.isdir(session_dir) or not os.listdir(session_dir))
    ):
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
        logging.info(
            "Session %s has no local files — triggering download from %s",
            _short_sid(session_id),
            server_url,
        )
        try:
            download_session_files(
                session_id,
                _effective_token(session_id, fallback=token),
                server_url,
            )
        except _JobCancelled:
            pass

    files = []
    if os.path.exists(session_dir):
        for file in os.listdir(session_dir):
            file_path = os.path.join(session_dir, file)
            if os.path.isfile(file_path) and _is_meaningful_file(file_path):
                mod_time = file_mtime_iso(file_path)

                # For VTT files, use the local file URL
                url = f"/session-file/{session_id}/{file}"

                # If this is the placeholder video.mp4, report the
                # size of the ORIGINAL video instead. The session
                # folder only ever holds a tiny green-screen copy,
                # but get_session_file() serves the original, so the
                # size shown in the UI must match what is served.
                reported_size = os.path.getsize(file_path)
                if file == "video.mp4":
                    _orig = _get_session_original_video_path(session_id)
                    if _orig:
                        reported_size = os.path.getsize(_orig)

                files.append(
                    {
                        "name": file,
                        "size": reported_size,
                        "url": url,
                        "modified": mod_time,
                    }
                )

    with job_progress_lock:
        job_snapshot = _job_progress_store.get(session_id)

    status = "ready" if files else "processing"
    return (
        jsonify(
            {
                "session_id": session_id,
                "files": files,
                "total_files": len(files),
                "session_url": f"{INTERNAL_SERVER_URL}/archivesession/{session_id}",
                "status": status,
                "job": job_snapshot,
                "embedded_languages": (sessions.get(session_id) or {}).get(
                    "embedded_languages"
                ),
            }
        ),
        200,
    )
