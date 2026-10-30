"""Dex token proxy, debug endpoints, clearing videos.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import logging
import os
import shutil
import requests
from flask import jsonify, request

from .flask_app import app
from .servers import INTERNAL_SERVER_URL, _is_allowed_server
from .config import (
    SESSION_FOLDER,
    UPLOAD_FOLDER,
    chunk_storage,
    jobs,
    sessions,
    videos,
)
from .state import rebuild_videos_from_disk, save_state
from .utils import _thumbnail_absolute_url
from .progress import (
    _cancelled_sessions,
    _cancelled_sessions_lock,
    _consecutive_404s,
    _consecutive_404s_lock,
    _job_progress_store,
    download_progress,
    download_progress_lock,
    job_progress_lock,
)


@app.route("/dex/token", methods=["POST"])
def dex_token():
    """Forward token exchange to the internal server's /dex/token endpoint."""
    requested = request.headers.get("X-Target-Server")
    server = (
        requested.rstrip("/") if _is_allowed_server(requested) else INTERNAL_SERVER_URL
    )
    resp = requests.post(
        f"{server}/dex/token",
        data=request.get_data(),
        headers={k: v for k, v in request.headers if k.lower() != "host"},
        allow_redirects=False,
        timeout=30,
        verify=False,
    )
    return (resp.content, resp.status_code, resp.headers.items())


@app.route("/dex/userinfo", methods=["GET"])
def dex_userinfo():
    """Forward userinfo request to the internal server's /dex/userinfo endpoint."""
    requested = request.headers.get("X-Target-Server")
    server = (
        requested.rstrip("/") if _is_allowed_server(requested) else INTERNAL_SERVER_URL
    )
    try:
        headers = {k: v for k, v in request.headers if k.lower() != "host"}
        resp = requests.get(
            f"{server}/dex/userinfo",
            headers=headers,
            allow_redirects=False,
            timeout=30,
            verify=False,
        )
        return (resp.content, resp.status_code, resp.headers.items())
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Proxy error: {str(e)}"}), 500


# ─── DEBUG ENDPOINTS ────────────────────────────────────────────────────


@app.route("/debug-videos", methods=["GET"])
def debug_videos():
    """Debug endpoint: return all video metadata (including duplicates)."""
    serialized = []
    for video in videos:
        v = dict(video)
        thumb = v.get("thumbnail_url")
        if thumb and thumb.startswith("/thumbnails/"):
            v["thumbnail_url"] = _thumbnail_absolute_url(video)
        serialized.append(v)
    return jsonify({"count": len(videos), "projects": serialized}), 200


@app.route("/debug-jobs", methods=["GET"])
def debug_jobs():
    """Debug endpoint: return all jobs."""
    return jsonify({"count": len(jobs), "jobs": jobs}), 200


@app.route("/clear-videos", methods=["POST", "OPTIONS"])
@app.route("/rebuild-videos-from-disk", methods=["POST", "OPTIONS"])
def rebuild_videos_from_disk_endpoint():
    """Reconcile the `videos` list with the MP4s present in
    UPLOAD_FOLDER. Idempotent. Does not delete anything.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    before = len(videos)
    rebuild_videos_from_disk()
    after = len(videos)

    return (
        jsonify(
            {
                "success": True,
                "before": before,
                "after": after,
                "added": after - before,
            }
        ),
        200,
    )


def clear_videos():
    """Wipe every project, file and piece of state.

    After this call the server is back to a pristine state: no
    uploaded files, no green-screens, no thumbnails, no sessions,
    no jobs, no chunk buffers. The user table and the language
    configuration are untouched.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    logging.info("🧹 clear-videos: wiping all project data")

    # ── 1. Files on disk ──────────────────────────────────────────
    # Rather than tracking each file through `videos`, scan the two
    # folders and delete everything. That also cleans up files that
    # leaked past a previous delete (orphaned green-screens, thumbs
    # for videos that were removed from the list by hand, ...).
    removed_files = 0

    for folder in (UPLOAD_FOLDER,):
        if not os.path.isdir(folder):
            continue
        for entry in os.listdir(folder):
            full = os.path.join(folder, entry)
            if not os.path.isfile(full):
                continue
            try:
                os.remove(full)
                removed_files += 1
            except OSError as e:
                logging.warning("clear-videos: could not remove %s: %s", full, e)

    # Session folders are directories, so handle them separately.
    removed_sessions = 0
    if os.path.isdir(SESSION_FOLDER):
        for entry in os.listdir(SESSION_FOLDER):
            full = os.path.join(SESSION_FOLDER, entry)
            if not os.path.isdir(full):
                continue
            try:
                shutil.rmtree(full)
                removed_sessions += 1
            except OSError as e:
                logging.warning(
                    "clear-videos: could not remove session dir %s: %s",
                    full,
                    e,
                )

    # ── 2. In-memory state ────────────────────────────────────────
    videos.clear()
    chunk_storage.clear()
    jobs.clear()
    sessions.clear()

    # ── 3. Progress stores ────────────────────────────────────────
    with job_progress_lock:
        _job_progress_store.clear()
    with download_progress_lock:
        download_progress.clear()
    with _cancelled_sessions_lock:
        _cancelled_sessions.clear()
    with _consecutive_404s_lock:
        _consecutive_404s.clear()

    # ── 4. Persist ────────────────────────────────────────────────
    save_state(force=True)

    logging.info(
        "🧹 clear-videos: removed %d files, %d session dirs",
        removed_files,
        removed_sessions,
    )

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
