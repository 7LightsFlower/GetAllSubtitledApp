"""Login / register / whoami.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import threading
import uuid
from flask import jsonify, request

from .flask_app import app
from .config import users, videos
from .state import save_state
from .utils import _email_from_token, _ensure_greenscreen_fields
from .media import _build_greenscreen_for_project


@app.route("/login", methods=["POST"])
def login():
    """Log in an existing user and return an auth token."""
    email = request.form.get("email")
    password = request.form.get("password")
    if not email or not password:
        return jsonify({"message": "Email and password required"}), 400
    user = users.get(email)
    if not user or user["password"] != password:
        return jsonify({"message": "Invalid credentials"}), 401
    return jsonify({"token": str(uuid.uuid4()), "message": "Login successful"}), 200


@app.route("/whoami", methods=["GET", "OPTIONS"])
def whoami():
    """Return the login identity the current request is carrying.

    Accepts the token as a bearer header or as the `_forward_auth`
    cookie, same as every other endpoint. Reads the email verbatim out
    of `<opaque>|<expiry>|<email>` — no normalisation, because the
    client uses this value only to build a URL, and the same spelling
    appears in the URL that the user pastes back into a browser.

    Anonymous (no token) is not an error: return `{"email": ""}` so
    the client can fall back to a generic path without special-casing
    a 401.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    token = ""
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        token = auth[7:].strip()
    if not token:
        token = request.cookies.get("_forward_auth", "")
    if not token:
        token = (request.args.get("token") or "").strip()

    email = _email_from_token(token) if token else ""
    return jsonify({
        "email": email,
        "authenticated": bool(token),
    }), 200

# ─── VIDEO ENDPOINTS ────────────────────────────────────────────────────


@app.route("/prepare-greenscreen/<video_key>", methods=["POST", "OPTIONS"])
def prepare_greenscreen(video_key):
    """Build the audio+green-screen stand-in for a project, in the
    background. Returns immediately; the client polls /video-detail
    (or /videos) to observe `greenscreen_status`.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    project = next((v for v in videos if v.get("key") == video_key), None)
    if project is None:
        return jsonify({"error": "Video not found"}), 404

    _ensure_greenscreen_fields(project)

    # Already done or in progress? Nothing to do.
    if project.get("greenscreen_status") == "ready":
        return (
            jsonify(
                {
                    "success": True,
                    "status": "ready",
                    "greenscreen_file_name": project.get("greenscreen_file_name"),
                }
            ),
            200,
        )
    if project.get("greenscreen_status") == "building":
        return (
            jsonify({"success": True, "status": "building"}),
            200,
        )

    # Mark it as building *before* spawning the thread so a rapid
    # double-click doesn't queue two workers.
    project["greenscreen_status"] = "building"
    project["greenscreen_progress"] = 0
    save_state()

    threading.Thread(
        target=_build_greenscreen_for_project,
        args=(video_key,),
        daemon=True,
    ).start()

    return jsonify({"success": True, "status": "building"}), 202
