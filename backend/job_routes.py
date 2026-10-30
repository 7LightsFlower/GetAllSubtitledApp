"""Job progress / finish-now / cancel endpoints and the mock job runner.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import logging
import time
from flask import jsonify, request

from .flask_app import app
from .config import jobs, videos
from .state import save_state
from .progress import (
    _job_cancel,
    _job_log,
    _job_progress_store,
    _request_cancel,
    _request_finish_now,
    generate_mock_segments,
    generate_mock_transcript,
    job_progress_lock,
)


@app.route("/finish_session/<path:session_id>", methods=["POST", "OPTIONS"])
def finish_session_now(session_id):
    """Stop waiting for unfinished translations: the worker downloads
    what is ready (complete languages fully, slow ones partially)."""
    if request.method == "OPTIONS":
        return ("", 204)
    with job_progress_lock:
        entry = _job_progress_store.get(session_id)
        active = entry is not None and not entry.get("done")
    if not active:
        return (
            jsonify(
                {
                    "success": False,
                    "reason": "not_running",
                    "message": "No running job for this session on this "
                    "backend (finished, cancelled, or the backend restarted).",
                }
            ),
            404,
        )
    _request_finish_now(session_id)
    _job_log(
        session_id,
        "Finish now requested — downloading the translations that are ready…",
        stage="translating",
    )
    return jsonify({"success": True, "session_id": session_id}), 200


@app.route("/cancel_session/<path:session_id>", methods=["POST", "OPTIONS"])
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
        # The session was never registered here — probably uploaded to a
        # different host, or the backend was restarted.
        return (
            jsonify(
                {
                    "success": False,
                    "session_id": session_id,
                    "reason": "unknown_session",
                    "message": (
                        "No job is registered for this session id. It was "
                        "either uploaded to a different server or the "
                        "backend has restarted since."
                    ),
                }
            ),
            404,
        )

    return jsonify({"success": True, "session_id": session_id}), 200


def process_job(job_id):
    """Simulate background job processing with progress updates."""
    job = jobs.get(job_id)
    if not job:
        return

    # Get the video key and find the original video
    video_key = job.get("video_key")
    original_video = None
    if video_key:
        for video in videos:
            if video.get("key") == video_key:
                original_video = video
                break

    # Persist the "processing" status once, so a restart during the job
    # can still see that this video was mid-flight.
    save_state()

    progress = 0.0
    while progress < 1.0:
        time.sleep(1)
        progress += 0.1
        if progress > 1.0:
            progress = 1.0
        job["progress"] = progress

    # Loop is done — finalise the job.
    job["status"] = "completed"
    job["transcript"] = generate_mock_transcript()
    job["segments"] = generate_mock_segments()

    # Update the original video with processing results — DON'T create a new one
    if original_video:
        original_video["segmentation_done"] = True
        original_video["segmentation_progress"] = 100
        original_video["segment_count"] = len(job["segments"])
        original_video["languages"] = ["en"]
        logging.info("✅ Updated video %s with job results", original_video.get("name"))
    else:
        logging.warning("⚠️ No original video found for job %s", job_id)

    # Single write at the end of the job.
    save_state()
