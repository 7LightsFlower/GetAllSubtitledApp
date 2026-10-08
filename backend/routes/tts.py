"""Routes for serving and backfilling text-to-speech audio files."""

import html as _html_mod
import os
import re
import urllib.parse

import requests
from flask import Blueprint, Response, jsonify, request, send_file, stream_with_context

from ..config import INTERNAL_SERVER_URL, MIN_WAV_BYTES
from ..state import _state, save_state, sessions
from ..tts import download_tts_files
from ..utils import effective_token, looks_like_wav, session_dir

bp = Blueprint("tts", __name__)


def _tts_urls_from_html(
    _session_id: str, session_dir_path: str, server_url: str
) -> dict[str, str]:
    """Parse index.html for TTS <source> URLs.

    Returns {label: absolute_url}, where label is the dropdown label
    ("Korean Audio") and absolute_url is the fully-qualified KIT URL
    that the archive page itself would play.

    KIT's own archive page builds the audio-source <select> from these
    tags, so whatever it emits is — by definition — the correct URL.
    Scraping is strictly more reliable than guessing the path shape.

    Currently unused: `download_tts_files` constructs the URL from the
    language label instead. Kept here so anyone debugging a TTS path
    failure has the reference implementation handy.
    """
    index_path = os.path.join(session_dir_path, "index.html")
    if not os.path.exists(index_path):
        return {}

    try:
        with open(index_path, "r", encoding="utf-8", errors="ignore") as f:
            page = f.read()
    except OSError:
        return {}

    server_url = server_url.rstrip("/")
    urls: dict[str, str] = {}

    # Match <source src="…" type="audio/…">, in either attribute order.
    pattern = re.compile(
        r'<source\s+[^>]*?src=["\']([^"\']+)["\'][^>]*?'
        r'type=["\']audio/[^"\']*["\']'
        r'|<source\s+[^>]*?type=["\']audio/[^"\']*["\'][^>]*?'
        r'src=["\']([^"\']+)["\']',
        re.IGNORECASE,
    )

    for m in pattern.finditer(page):
        src = m.group(1) or m.group(2)
        if not src:
            continue
        src = _html_mod.unescape(src)

        if src.startswith("/"):
            absolute = f"{server_url}{src}"
        elif src.startswith("http"):
            absolute = src
        else:
            absolute = f"{server_url}/{src.lstrip('/')}"

        tail = src.rstrip("/").rsplit("/", 1)[-1]
        label = _html_mod.unescape(tail)
        label = urllib.parse.unquote(label)
        if label.lower().endswith(".wav"):
            label = label[:-4]
        if not label:
            continue

        urls[label] = absolute

    return urls


def _local_tts_path(session_id: str, label: str) -> str | None:
    """Return a valid cached WAV path for a TTS label, if one exists."""
    sdir = session_dir(session_id)
    simple = label[: -len(" Audio")] if label.endswith(" Audio") else label
    for name in (f"tts_{simple}.wav", f"{label}.wav"):
        path = os.path.join(sdir, name)
        if os.path.exists(path) and os.path.getsize(path) > MIN_WAV_BYTES:
            if looks_like_wav(path):
                return path
    return None


def _tts_upstream_response(session_id: str, label: str):
    """Fetch a TTS file from the configured KIT archive server."""
    server = (sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL).rstrip(
        "/"
    )
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

    return requests.get(
        kit_url,
        headers=headers,
        cookies={"_forward_auth": token},
        verify=False,
        stream=True,
        timeout=60,
        allow_redirects=True,
    )


@bp.route("/session-tts/<path:session_id>/<path:label>", methods=["GET", "OPTIONS"])
def session_tts(session_id, label):
    """Serve a cached TTS file or fetch it from the KIT archive server."""
    if request.method == "OPTIONS":
        return ("", 204)

    path = _local_tts_path(session_id, label)
    if path:
        return send_file(
            path, mimetype="audio/wav", conditional=True, as_attachment=False
        )

    try:
        response = _tts_upstream_response(session_id, label)
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Upstream fetch failed: {e}"}), 502

    if response.status_code >= 400:
        return jsonify({"error": f"Upstream returned {response.status_code}"}), response.status_code

    if "html" in response.headers.get("Content-Type", "").lower():
        return jsonify({"error": "upstream_html"}), 404

    passthrough = {
        header: response.headers[header]
        for header in ("Content-Type", "Content-Length", "Accept-Ranges", "Content-Range")
        if header in response.headers
    }
    passthrough.setdefault("Content-Type", "audio/wav")

    return Response(
        stream_with_context(response.iter_content(chunk_size=64 * 1024)),
        status=response.status_code,
        headers=passthrough,
        direct_passthrough=True,
    )


@bp.route(
    "/session-tts-sign/<path:session_id>/<path:label>", methods=["GET", "OPTIONS"]
)
def session_tts_sign(session_id, label):
    """Return a clear error for the deprecated signed TTS route."""
    if request.method == "OPTIONS":
        return ("", 204)
    return (
        jsonify(
            {
                "error": "not_implemented",
                "message": (
                    f"Use /session-tts/{session_id}/{label} instead."
                ),
            }
        ),
        404,
    )


@bp.route("/session-tts-backfill/<path:session_id>", methods=["POST", "OPTIONS"])
def session_tts_backfill(session_id):
    """Backfill TTS audio files for an existing session."""
    if request.method == "OPTIONS":
        return ("", 204)
    sdir = session_dir(session_id)
    if not os.path.isdir(sdir):
        return jsonify({"error": "Session not found"}), 404
    token = _state.get("token") or ""
    if not token:
        return (
            jsonify(
                {"error": "no_token", "message": "Open the session screen once first."}
            ),
            400,
        )
    server = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    try:
        written = download_tts_files(session_id, token, server)
    except (OSError, ValueError, TypeError) as e:
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


@bp.route("/session-tts-backfill-all", methods=["POST", "OPTIONS"])
def session_tts_backfill_all():
    """Backfill TTS files for all existing sessions that have a usable token."""
    if request.method == "OPTIONS":
        return ("", 204)
    req_token = request.headers.get("Authorization", "").replace(
        "Bearer ", ""
    ) or request.cookies.get("_forward_auth", "")
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
        except (
            OSError,
            ValueError,
            TypeError,
            requests.exceptions.RequestException,
        ) as e:
            results[sid] = {"error": str(e)}
    save_state()
    return jsonify({"success": True, "results": results}), 200
