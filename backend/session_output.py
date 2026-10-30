"""Session Output listing and file serving.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import os
from flask import jsonify, send_file

from .flask_app import app
from .utils import _session_dir
from .media import _get_session_original_video_path


@app.route("/session-file/<path:session_id>/<filename>", methods=["GET"])
def get_session_file(session_id, filename):
    """Download a specific file from the session."""
    session_dir = _session_dir(session_id)
    file_path = os.path.join(session_dir, filename)

    # Check if file exists
    if not os.path.exists(file_path):
        return jsonify({"error": "File not found"}), 404

    # For VTT files, serve with correct MIME type and no cache
    if filename.endswith(".vtt"):
        response = send_file(
            file_path, as_attachment=False, mimetype="text/vtt", download_name=filename
        )
        # Add headers to prevent caching
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response

    if filename.lower().endswith(".mp4"):
        # Preference order:
        #   1. video_subtitled.mp4 (user already embedded subtitles)
        #   2. the original full-quality video from UPLOAD_FOLDER
        #   3. the session-local file (green-screen placeholder)
        modified = os.path.join(session_dir, "video_subtitled.mp4")
        original = _get_session_original_video_path(session_id)

        if os.path.exists(modified):
            actual_path = modified
        elif original and filename == "video.mp4":
            actual_path = original
        else:
            actual_path = file_path

        return send_file(
            actual_path,
            as_attachment=False,
            mimetype="video/mp4",
            conditional=True,
        )

    return send_file(file_path, as_attachment=True, conditional=True)
