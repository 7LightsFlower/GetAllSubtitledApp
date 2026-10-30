"""TTS endpoints (stream, sign, backfill, diagnose).

Split mechanically from the former lib/backend.py — code unchanged.
"""

import logging
import os
import re
import subprocess
import tempfile
import zipfile
from urllib.parse import quote
import requests
from flask import jsonify, request, send_file

from .flask_app import app
from .servers import INTERNAL_SERVER_URL
from .config import _state, sessions
from .state import save_state
from .utils import (
    _effective_token,
    _media_cookie,
    _media_cookie_is_dex,
    _session_dir,
    _short_sid,
)
from .downloads import curl_download
from .tts import download_tts_files


# pylint: disable=unused-argument
@app.route(
    "/session-tts-sign/<path:session_id>/<path:label>", methods=["GET", "OPTIONS"]
)
def session_tts_sign(session_id, label):
    """Signed-URL TTS endpoint — stub.

    The backend serves TTS through /session-tts directly, so there is
    nothing to sign. This route exists purely so the browser's CORS
    preflight gets a 2xx response.

    ``session_id`` and ``label`` are required by Flask's routing
    machinery (they match the ``<path:…>`` placeholders) but are not
    used in the body.
    """
    if request.method == "OPTIONS":
        return ("", 204)
    return (
        jsonify(
            {
                "error": "not_implemented",
                "message": (
                    "Signed TTS URLs are not supported on this server. "
                    "Use /session-tts/<session_id>/<label> instead."
                ),
            }
        ),
        404,
    )


@app.route("/session-tts-backfill/<path:session_id>", methods=["POST", "OPTIONS"])
def session_tts_backfill(session_id):
    """Download every TTS WAV for one session into its local folder.

    Idempotent — files already present are skipped.
    """
    if request.method == "OPTIONS":
        return ("", 204)

    session_dir = _session_dir(session_id)
    if not os.path.isdir(session_dir):
        return jsonify({"error": "Session not found"}), 404

    token = _state.get("token") or ""
    if not token:
        return (
            jsonify(
                {
                    "error": "no_token",
                    "message": (
                        "Open the session screen once in the browser "
                        "so the server caches a token, then retry."
                    ),
                }
            ),
            400,
        )

    server = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL

    try:
        written = download_tts_files(session_id, token, server)
    except (OSError, ValueError, TypeError) as e:
        logging.exception("TTS backfill failed for %s", _short_sid(session_id))
        return jsonify({"error": str(e)}), 500

    save_state()
    return (
        jsonify(
            {
                "success": True,
                "session_id": session_id,
                "downloaded": written,
                "count": len(written),
            }
        ),
        200,
    )


@app.route("/session-tts-backfill-all", methods=["POST", "OPTIONS"])
def session_tts_backfill_all():
    """Backfill TTS for every session the server currently knows about."""
    if request.method == "OPTIONS":
        return ("", 204)

    request_token = request.headers.get("Authorization", "").replace(
        "Bearer ", ""
    ) or request.cookies.get("_forward_auth", "")

    results = {}
    for sid in list(sessions.keys()):
        if not os.path.isdir(_session_dir(sid)):
            continue
        # Per-session token — this is what makes old sessions work.
        token = _effective_token(sid, fallback=request_token)
        if not token:
            results[sid] = {"error": "no_token_for_session"}
            continue
        server = sessions.get(sid, {}).get("server") or INTERNAL_SERVER_URL
        try:
            results[sid] = download_tts_files(sid, token, server)
        except (
            OSError,
            ValueError,
            TypeError,
            requests.exceptions.RequestException,
        ) as e:
            logging.warning("Backfill failed for %s: %s", _short_sid(sid), e)
            results[sid] = {"error": str(e)}

    save_state()
    return jsonify({"success": True, "results": results}), 200


@app.route(
    "/session-tts-diagnose/<path:session_id>/<path:label>",
    methods=["GET"],
)
def session_tts_diagnose(session_id, label):
    """Probe every known TTS URL with both credential sets and
    report status / content-type / content-length for each.

    Read-only. Never writes a file. Use this once to discover which
    URL KIT actually serves TTS from on a given host, then trim
    `download_tts_files`'s candidate list accordingly.
    """
    server = (sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL).rstrip(
        "/"
    )

    token = _effective_token(session_id, fallback="")
    if not token:
        return (
            jsonify(
                {
                    "error": "no_token",
                    "message": (
                        "Open the session screen once so the backend caches a "
                        "token, then retry."
                    ),
                }
            ),
            400,
        )

    enc = quote(f"{label}.wav")
    enc_label = quote(label)

    candidates = [
        f"{server}/archivemediafile/{session_id}/{enc}",
        f"{server}/archivemedia/{session_id}/{enc}",
        f"{server}/archivemedia/{session_id}/tts/{enc_label}",
        f"{server}/archivemedia/{session_id}/{enc_label}",
        f"{server}/archivesession/{session_id}/{enc}",
    ]

    results = []
    for url in candidates:
        for mode in ("dex_cookie", "bearer"):
            if mode == "dex_cookie" and not _media_cookie_is_dex():
                continue

            headers = [
                "-H",
                "User-Agent: Mozilla/5.0 (diagnostic)",
            ]
            if mode == "bearer":
                headers += [
                    "-H",
                    f"X-Forward-Auth: {token}",
                    "-H",
                    f"Authorization: Bearer {token}",
                ]
            cookie_value = _media_cookie(token) if mode == "dex_cookie" else token
            headers += ["--cookie", f"_forward_auth={cookie_value}"]

            try:
                proc = subprocess.run(
                    [
                        "curl",
                        "-s",
                        "-L",
                        "--insecure",
                        "-o",
                        "/dev/null",
                        "-D",
                        "-",
                        *headers,
                        url,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
            except (subprocess.TimeoutExpired, OSError) as e:
                results.append(
                    {
                        "url": url,
                        "mode": mode,
                        "error": str(e),
                    }
                )
                continue

            head = proc.stdout or ""
            first_line = head.split("\n", 1)[0].strip()
            ctype = ""
            clen = ""
            for line in head.splitlines():
                if line.lower().startswith("content-type:"):
                    ctype = line.split(":", 1)[1].strip()
                elif line.lower().startswith("content-length:"):
                    clen = line.split(":", 1)[1].strip()

            verdict = "unknown"
            if "audio" in ctype.lower():
                verdict = "real_audio"
            elif "html" in ctype.lower():
                verdict = "kit_error_page"
            elif first_line.startswith("HTTP") and " 404" in first_line:
                verdict = "not_found"
            elif first_line.startswith("HTTP") and " 401" in first_line:
                verdict = "unauthorized"
            elif first_line.startswith("HTTP") and " 200" in first_line:
                verdict = "html_or_other"

            results.append(
                {
                    "url": url,
                    "mode": mode,
                    "status_line": first_line,
                    "content_type": ctype,
                    "content_length": clen,
                    "verdict": verdict,
                }
            )

    return (
        jsonify(
            {
                "session_id": session_id,
                "label": label,
                "has_dex_cookie": _media_cookie_is_dex(),
                "results": results,
            }
        ),
        200,
    )


@app.route("/session-zip/<path:session_id>", methods=["GET"])
def download_session_zip(session_id):
    """Download all files from a session as a ZIP archive."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")

    if token:
        json_path = os.path.join(session_dir, "messages.json")
        if not os.path.exists(json_path) or os.path.getsize(json_path) < 1000:
            url = f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
            curl_download(url, json_path, token)

    # Sanitize session_id before using it in a filename
    safe_id = re.sub(r"[^A-Za-z0-9_.-]", "_", session_id)[:80]
    zip_path = os.path.join(tempfile.gettempdir(), f"session_{safe_id}.zip")

    try:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for root, _, files in os.walk(session_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    try:
                        if os.path.getsize(file_path) > 1000:
                            zipf.write(
                                file_path,
                                os.path.relpath(file_path, session_dir),
                            )
                    except OSError:
                        continue

        return send_file(
            zip_path,
            as_attachment=True,
            download_name=f"session_{safe_id}.zip",
            mimetype="application/zip",
        )
    finally:
        # Clean up after Flask has actually sent the file
        try:
            if os.path.exists(zip_path):
                os.remove(zip_path)
        except OSError:
            pass
