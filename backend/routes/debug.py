"""Debug routes for inspecting and clearing tracked videos, jobs, and sessions."""

import importlib
import os
import shutil

from flask import Blueprint, jsonify, request

from ..config import SESSION_FOLDER, UPLOAD_FOLDER
from ..progress import (
    _cancelled_sessions,
    _cancelled_sessions_lock,
    _consecutive_404s,
    _consecutive_404s_lock,
    _job_progress_store,
    download_progress,
    download_progress_lock,
    job_progress_lock,
)
from ..state import (
    chunk_storage,
    jobs,
    save_state,
    sessions,
    videos,
)
from ..utils import thumbnail_absolute_url

bp = Blueprint("debug", __name__)


@bp.route("/debug-videos", methods=["GET"])
def debug_videos():
    """Return the currently tracked videos as JSON."""
    serialized = []
    for v in videos:
        copy = dict(v)
        if (copy.get("thumbnail_url") or "").startswith("/thumbnails/"):
            copy["thumbnail_url"] = thumbnail_absolute_url(v)
        serialized.append(copy)
    return jsonify({"count": len(videos), "projects": serialized}), 200


@bp.route("/debug-jobs", methods=["GET"])
def debug_jobs():
    """Return the currently tracked jobs as JSON."""
    return jsonify({"count": len(jobs), "jobs": jobs}), 200


@bp.route("/clear-videos", methods=["POST", "OPTIONS"])
@bp.route("/rebuild-videos-from-disk", methods=["POST", "OPTIONS"])
def clear_videos_endpoint():
    """Clear tracked data or rebuild it from files on disk."""
    if request.method == "OPTIONS":
        return ("", 204)
    if request.path.endswith("rebuild-videos-from-disk"):
        app_module = importlib.import_module(
            f"{__package__.rsplit('.', 1)[0]}.app"
        )
        before = len(videos)
        app_module.rebuild_videos_from_disk()
        return (
            jsonify(
                {
                    "success": True,
                    "before": before,
                    "after": len(videos),
                    "added": len(videos) - before,
                }
            ),
            200,
        )

    removed_files = 0
    for folder in (UPLOAD_FOLDER,):
        if not os.path.isdir(folder):
            continue
        for entry in os.listdir(folder):
            full = os.path.join(folder, entry)
            if os.path.isfile(full):
                try:
                    os.remove(full)
                    removed_files += 1
                except OSError:
                    pass

    removed_sessions = 0
    if os.path.isdir(SESSION_FOLDER):
        for entry in os.listdir(SESSION_FOLDER):
            full = os.path.join(SESSION_FOLDER, entry)
            if os.path.isdir(full):
                try:
                    shutil.rmtree(full)
                    removed_sessions += 1
                except OSError:
                    pass

    videos.clear()
    chunk_storage.clear()
    jobs.clear()
    sessions.clear()
    with job_progress_lock:
        _job_progress_store.clear()
    with download_progress_lock:
        download_progress.clear()
    with _cancelled_sessions_lock:
        _cancelled_sessions.clear()
    with _consecutive_404s_lock:
        _consecutive_404s.clear()
    save_state(force=True)
    return (
        jsonify(
            {
                "message": "Cleared",
                "removed_files": removed_files,
                "removed_sessions": removed_sessions,
            }
        ),
        200,
    )
