import logging
import os

import requests
from flask import Blueprint, Response, jsonify, request, send_file, stream_with_context

from ..config import (
    INTERNAL_SERVER_URL, MIN_WAV_BYTES, media_cookie, media_cookie_is_dex,
)
from ..state import _state, save_state, sessions
from ..tts import download_tts_files
from ..utils import effective_token, looks_like_wav, session_dir, short_sid

bp = Blueprint("tts", __name__)


@bp.route("/session-tts/<path:session_id>/<path:label>",
          methods=["GET", "OPTIONS"])
def session_tts(session_id, label):
    if request.method == "OPTIONS":
        return ("", 204)

    sdir = session_dir(session_id)
    simple = label[:-len(" Audio")] if label.endswith(" Audio") else label
    for name in (f"tts_{simple}.wav", f"{label}.wav"):
        path = os.path.join(sdir, name)
        if not os.path.exists(path):
            continue
        if os.path.getsize(path) <= MIN_WAV_BYTES or not looks_like_wav(path):
            continue
        return send_file(path, mimetype="audio/wav",
                         conditional=True, as_attachment=False)

    server = (sessions.get(session_id, {}).get("server")
              or INTERNAL_SERVER_URL).rstrip("/")
    kit_url = f"{server}/archivemediafile/{session_id}/{label} Audio.wav"

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")
    if not token:
        token = effective_token(
            session_id,
            fallback=request.headers.get("Authorization", "").replace("Bearer ", ""),
        )

    headers = {"User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
        headers["X-Forward-Auth"] = token
    if request.headers.get("Range"):
        headers["Range"] = request.headers["Range"]

    try:
        r = requests.get(kit_url, headers=headers,
                         cookies={"_forward_auth": token},
                         verify=False, stream=True, timeout=60,
                         allow_redirects=True)
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Upstream fetch failed: {e}"}), 502

    if r.status_code >= 400:
        return jsonify({"error": f"Upstream returned {r.status_code}"}), r.status_code

    upstream_type = r.headers.get("Content-Type", "").lower()
    if "html" in upstream_type:
        return jsonify({"error": "upstream_html"}), 404

    passthrough = {}
    for h in ("Content-Type", "Content-Length", "Accept-Ranges", "Content-Range"):
        if h in r.headers:
            passthrough[h] = r.headers[h]
    if "Content-Type" not in passthrough:
        passthrough["Content-Type"] = "audio/wav"

    return Response(stream_with_context(r.iter_content(chunk_size=64 * 1024)),
                    status=r.status_code, headers=passthrough,
                    direct_passthrough=True)


@bp.route("/session-tts-sign/<path:session_id>/<path:label>",
          methods=["GET", "OPTIONS"])
def session_tts_sign(session_id, label):
    if request.method == "OPTIONS":
        return ("", 204)
    return jsonify({"error": "not_implemented",
                    "message": "Use /session-tts/<session_id>/<label>."}), 404


@bp.route("/session-tts-backfill/<path:session_id>", methods=["POST", "OPTIONS"])
def session_tts_backfill(session_id):
    if request.method == "OPTIONS":
        return ("", 204)
    sdir = session_dir(session_id)
    if not os.path.isdir(sdir):
        return jsonify({"error": "Session not found"}), 404
    token = _state.get("token") or ""
    if not token:
        return jsonify({"error": "no_token",
                        "message": "Open the session screen once first."}), 400
    server = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    try:
        written = download_tts_files(session_id, token, server)
    except (OSError, ValueError, TypeError) as e:
        return jsonify({"error": str(e)}), 500
    save_state()
    return jsonify({"success": True, "session_id": session_id,
                    "downloaded": written, "count": len(written)}), 200


@bp.route("/session-tts-backfill-all", methods=["POST", "OPTIONS"])
def session_tts_backfill_all():
    if request.method == "OPTIONS":
        return ("", 204)
    req_token = (request.headers.get("Authorization", "").replace("Bearer ", "")
                 or request.cookies.get("_forward_auth", ""))
    results = {}
    for sid in list(sessions.keys()):
        if not os.path.isdir(session_dir(sid)):
            continue
        token = effective_token(sid, fallback=req_token)
        if not token:
            results[sid] = {"error": "no_token_for_session"}
            continue
        server = sessions.get(sid, {}).get("server") or INTERNAL_SERVER_URL
        try:
            results[sid] = download_tts_files(sid, token, server)
        except (OSError, ValueError, TypeError,
                requests.exceptions.RequestException) as e:
            results[sid] = {"error": str(e)}
    save_state()
    return jsonify({"success": True, "results": results}), 200