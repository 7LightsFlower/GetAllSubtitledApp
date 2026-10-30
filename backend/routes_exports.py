"""Export and transcript endpoints.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import io
import json
import logging
import os
import re
import zipfile
import requests
from flask import Response, jsonify, request, send_file, stream_with_context

from .flask_app import app
from .servers import INTERNAL_SERVER_URL
from .config import sessions
from .utils import _effective_token, _session_dir
from .downloads import curl_download
from .tts import _MIN_WAV_BYTES, _looks_like_wav
from .exports import (
    _resolve_export_language_name,
    export_structured_docx,
    export_structured_rtf,
    export_structured_txt,
    extract_structured_data_from_session,
)


@app.route("/session-export-docx/<path:session_id>", methods=["GET"])
def session_export_docx(session_id):
    """Export session as a structured DOCX file matching the window view."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.docx"

    try:
        doc_buffer = export_structured_docx(session_id, session_dir, language)
    except ImportError:
        return (
            jsonify(
                {
                    "error": "python-docx not installed",
                    "hint": "pip install python-docx",
                }
            ),
            500,
        )
    except (
        OSError,
        ValueError,
        TypeError,
        RuntimeError,
        KeyError,
        AttributeError,
    ) as e:
        logging.exception("DOCX export failed for %s: %s", session_id, e)
        return jsonify({"error": f"Export failed: {type(e).__name__}: {e}"}), 500

    return send_file(
        doc_buffer,
        mimetype="application/vnd.openxmlformats-officedocument"
        ".wordprocessingml.document",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session-export-rtf/<path:session_id>", methods=["GET"])
def session_export_rtf(session_id):
    """Export all session data as a structured RTF document."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")
    actual_lang_name = _resolve_export_language_name(session_dir, language)

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.rtf"

    rtf_buffer = export_structured_rtf(session_id, session_dir, language)

    return send_file(
        rtf_buffer,
        mimetype="text/rtf",
        as_attachment=True,
        download_name=filename,
    )


def get_available_languages(session_dir):
    """Get list of available languages from transcripts.json."""
    json_path = os.path.join(session_dir, "transcripts.json")
    languages = []

    if os.path.exists(json_path):
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
        languages = list(set(t.get("language", "Unknown") for t in transcripts))
        languages.sort()

    return languages


# ─── EXPORT ROUTES ─────────────────────────────────────────────────────


@app.route("/session-export/<path:session_id>", methods=["GET"])
def session_export(session_id):
    """Export all session data as a formatted DOCX document."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")

    try:
        doc_buffer = export_structured_docx(session_id, session_dir, language)
    except ImportError:
        return (
            jsonify(
                {
                    "error": "python-docx not installed. "
                    "Please install: pip install python-docx"
                }
            ),
            500,
        )

    filename = f"session_{session_id}"
    if language:
        clean_lang = language.replace(" ", "_").replace("(", "").replace(")", "")
        filename = f"session_{session_id}_{clean_lang}"

    return send_file(
        doc_buffer,
        mimetype="application/vnd.openxmlformats-officedocument"
        ".wordprocessingml.document",
        as_attachment=True,
        download_name=f"{filename}.docx",
    )


@app.route("/session-export-structured-json/<path:session_id>", methods=["GET"])
def session_export_structured_json(session_id):
    """Export session as structured JSON with all metadata."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    language = request.args.get("language")

    structured_data = extract_structured_data_from_session(session_dir, language)
    if not structured_data:
        return jsonify({"error": "No structured data available"}), 404

    json_str = json.dumps(structured_data, ensure_ascii=False, indent=2)

    # Get the actual language name from transcripts.json
    actual_lang_name = None
    json_path = os.path.join(session_dir, "transcripts.json")
    if os.path.exists(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)
            if transcripts:
                if language:
                    for t in transcripts:
                        lang = t.get("language", "")
                        if lang == language or language.lower() in lang.lower():
                            actual_lang_name = lang
                            break
                if not actual_lang_name:
                    actual_lang_name = transcripts[0].get("language", "transcript")
        except (OSError, TypeError, ValueError):
            actual_lang_name = "transcript"
    else:
        actual_lang_name = "transcript"

    # Clean the language name for filename
    clean_name = actual_lang_name.replace(" ", "_").replace("(", "").replace(")", "")
    clean_name = clean_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "", clean_name)
    if len(clean_name) > 50:
        clean_name = clean_name[:50]

    # Use the language name as filename (no session_id)
    filename = f"{clean_name}.json"

    return send_file(
        io.BytesIO(json_str.encode("utf-8")),
        mimetype="application/json",
        as_attachment=True,
        download_name=filename,
    )


@app.route("/session-export-all-languages/<path:session_id>", methods=["GET"])
def session_export_all_languages(session_id):
    """Export all languages as separate files in a ZIP archive."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    export_format = request.args.get("format", "all").lower()

    languages = get_available_languages(session_dir)
    if not languages:
        return jsonify({"error": "No transcript data found"}), 404

    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zipf:
        for lang in languages:
            clean_lang = lang.replace(" ", "_").replace("(", "").replace(")", "")
            clean_lang = clean_lang.replace("/", "_").replace("\\", "_")
            if len(clean_lang) > 50:
                clean_lang = clean_lang[:50]

            formats_to_export = []
            if export_format == "all":
                formats_to_export = ["txt", "rtf", "docx", "json"]
            elif export_format in ["txt", "rtf", "docx", "json"]:
                formats_to_export = [export_format]
            else:
                formats_to_export = ["txt"]

            if "txt" in formats_to_export:
                txt_buffer = export_structured_txt(session_id, session_dir, lang)
                zipf.writestr(f"{clean_lang}.txt", txt_buffer.getvalue())

            if "rtf" in formats_to_export:
                rtf_buffer = export_structured_rtf(session_id, session_dir, lang)
                zipf.writestr(f"{clean_lang}.rtf", rtf_buffer.getvalue())

            if "docx" in formats_to_export:
                try:
                    doc_buffer = export_structured_docx(session_id, session_dir, lang)
                    zipf.writestr(f"{clean_lang}.docx", doc_buffer.getvalue())
                except ImportError:
                    logging.warning("python-docx not installed, skipping DOCX")

            if "json" in formats_to_export:
                structured_data = extract_structured_data_from_session(
                    session_dir, lang
                )
                if structured_data:
                    zipf.writestr(
                        f"{clean_lang}.json",
                        json.dumps(
                            structured_data, ensure_ascii=False, indent=2
                        ).encode("utf-8"),
                    )

    zip_buffer.seek(0)

    return send_file(
        zip_buffer,
        mimetype="application/zip",
        as_attachment=True,
        download_name="transcript_all_languages.zip",
    )


@app.route("/session-languages/<path:session_id>", methods=["GET"])
def session_languages(session_id):
    """Get list of available languages for a session."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    languages = get_available_languages(session_dir)
    return jsonify({"languages": languages}), 200


@app.route("/session-transcript-json/<path:session_id>", methods=["GET"])
def session_transcript_json(session_id):
    """Export session transcripts as JSON."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    json_path = os.path.join(session_dir, "transcripts.json")
    if os.path.exists(json_path):
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return jsonify(data), 200

    return jsonify({"error": "No transcript data found"}), 404


@app.route("/session-messages-json/<path:session_id>", methods=["GET"])
def session_messages_json(session_id):
    """Download the raw messages.json file from the session."""
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = _effective_token(session_id, fallback=token)

    if token:
        local_path = os.path.join(session_dir, "messages.json")
        if not os.path.exists(local_path) or os.path.getsize(local_path) < 1000:
            url = f"{INTERNAL_SERVER_URL}/archivemediafile/{session_id}/messages.json"
            logging.info("Downloading messages.json from %s", url)
            if curl_download(url, local_path, token):
                logging.info("Successfully downloaded messages.json")

    json_path = os.path.join(session_dir, "messages.json")
    if os.path.exists(json_path) and os.path.getsize(json_path) > 1000:
        return send_file(
            json_path,
            as_attachment=True,
            download_name=f"messages_{session_id}.json",
            mimetype="application/json",
        )

    return jsonify({"error": "messages.json not found"}), 404


@app.route("/session-tts/<path:session_id>/<path:label>", methods=["GET", "OPTIONS"])
def session_tts(session_id, label):
    """Stream a per-language TTS track.

    Preference order:
      1. locally-downloaded WAV (offline, no token)
      2. live proxy to KIT (legacy, requires cached token)
    """
    # CORS preflight — must return 2xx or the browser blocks the call.
    if request.method == "OPTIONS":
        return ("", 204)

    session_dir = _session_dir(session_id)

    # ── 1. Local file ─────────────────────────────────────────────
    simple = label[: -len(" Audio")] if label.endswith(" Audio") else label
    for name in (f"tts_{simple}.wav", f"{label}.wav"):
        path = os.path.join(session_dir, name)
        if not os.path.exists(path):
            continue
        if os.path.getsize(path) <= _MIN_WAV_BYTES:
            logging.warning(
                "session_tts: %s is only %d bytes — not a real WAV, "
                "treating as missing",
                name,
                os.path.getsize(path),
            )
            continue
        if not _looks_like_wav(path):
            logging.warning(
                "session_tts: %s exists but has no RIFF/WAVE header "
                "— not a real WAV, treating as missing",
                name,
            )
            continue
        logging.info("session_tts: serving local %s", name)
        return send_file(
            path,
            mimetype="audio/wav",
            conditional=True,
            as_attachment=False,
        )

    # ── 2. Live proxy (unchanged) ─────────────────────────────────
    server = (sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL).rstrip(
        "/"
    )
    simple = label[: -len(" Audio")] if label.endswith(" Audio") else label
    kit_url = f"{server}/archivemediafile/{session_id}/{simple} Audio.wav"

    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        token = request.cookies.get("_forward_auth", "")
    if not token:
        # The browser's native <audio> element cannot send custom
        # headers, so the TTS request arrives bare. Fall back to the
        # most recent token we saw on any other request from this
        # session — _capture_auth_token() stores it in _state["token"].
        token = _effective_token(
            session_id,
            fallback=request.headers.get("Authorization", "").replace("Bearer ", ""),
        )

    upstream_headers = {
        "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
    }
    if token:
        upstream_headers["Authorization"] = f"Bearer {token}"
        upstream_headers["X-Forward-Auth"] = token

    # Forward the browser's Range header so <audio> seeking works.
    if request.headers.get("Range"):
        upstream_headers["Range"] = request.headers["Range"]

    try:
        r = requests.get(
            kit_url,
            headers=upstream_headers,
            cookies={"_forward_auth": token},
            verify=False,
            stream=True,
            timeout=60,
            allow_redirects=True,
        )
    except requests.exceptions.RequestException as e:
        logging.warning("session_tts: upstream fetch failed: %s", e)
        return jsonify({"error": f"Upstream fetch failed: {e}"}), 502

    if r.status_code >= 400:
        logging.info(
            "session_tts: upstream %s for %s (label=%r)",
            r.status_code,
            kit_url,
            label,
        )
        return (
            jsonify({"error": f"Upstream returned {r.status_code}"}),
            r.status_code,
        )

    # KIT returns 200 with an HTML error page when a TTS file is
    # missing. Forwarding that as audio/wav causes the browser's
    # <audio> element to fail with DEMUXER_ERROR_COULD_NOT_OPEN.
    # Return a clean 404 instead.
    upstream_type = r.headers.get("Content-Type", "").lower()
    if "html" in upstream_type:
        logging.info(
            "session_tts: upstream returned HTML for %s (label=%r)",
            kit_url,
            label,
        )
        return jsonify({"error": "upstream_html"}), 404

    # Pass through the headers the <audio> element cares about.
    passthrough = {}
    for h in (
        "Content-Type",
        "Content-Length",
        "Accept-Ranges",
        "Content-Range",
    ):
        if h in r.headers:
            passthrough[h] = r.headers[h]

    # KIT serves WAVs without an explicit type; fill it in so the
    # browser doesn't fall back to sniffing (which fails on web).
    if "Content-Type" not in passthrough:
        passthrough["Content-Type"] = "audio/wav"

    return Response(
        stream_with_context(r.iter_content(chunk_size=64 * 1024)),
        status=r.status_code,
        headers=passthrough,
        direct_passthrough=True,
    )
