"""Routes for exporting session transcripts in TXT, DOCX, RTF, and JSON formats."""

import io
import json
import os
import zipfile

from flask import Blueprint, jsonify, request, send_file

from ..exports import (
    clean_filename_from_language,
    export_structured_docx,
    export_structured_rtf,
    export_structured_txt,
    extract_structured_data_from_session,
    get_available_languages,
    resolve_export_language_name,
)
from ..utils import session_dir

bp = Blueprint("exports", __name__)


def _lang_clean(name: str) -> str:
    return clean_filename_from_language(name)


@bp.route("/session-export-txt/<path:session_id>", methods=["GET"])
def session_export_txt(session_id):
    """Export a session transcript as a plain-text file."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    language = request.args.get("language")
    actual = resolve_export_language_name(sdir, language)
    buf = export_structured_txt(session_id, sdir, language)
    return send_file(
        buf,
        mimetype="text/plain",
        as_attachment=True,
        download_name=f"{_lang_clean(actual)}.txt",
    )


@bp.route("/session-export-docx/<path:session_id>", methods=["GET"])
def session_export_docx(session_id):
    """Export a session transcript as a DOCX file."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    language = request.args.get("language")
    actual = resolve_export_language_name(sdir, language)
    try:
        buf = export_structured_docx(session_id, sdir, language)
    except ImportError:
        return jsonify({"error": "python-docx not installed"}), 500
    except (
        OSError,
        ValueError,
        TypeError,
        RuntimeError,
        KeyError,
        AttributeError,
    ) as e:
        return jsonify({"error": f"Export failed: {type(e).__name__}: {e}"}), 500
    return send_file(
        buf,
        mimetype=(
            "application/vnd.openxmlformats-officedocument" ".wordprocessingml.document"
        ),
        as_attachment=True,
        download_name=f"{_lang_clean(actual)}.docx",
    )


@bp.route("/session-export-rtf/<path:session_id>", methods=["GET"])
def session_export_rtf(session_id):
    """Export a session transcript as an RTF file."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    language = request.args.get("language")
    actual = resolve_export_language_name(sdir, language)
    buf = export_structured_rtf(session_id, sdir, language)
    return send_file(
        buf,
        mimetype="text/rtf",
        as_attachment=True,
        download_name=f"{_lang_clean(actual)}.rtf",
    )


@bp.route("/session-export/<path:session_id>", methods=["GET"])
def session_export(session_id):
    """Export a session transcript as a DOCX file."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    language = request.args.get("language")
    try:
        buf = export_structured_docx(session_id, sdir, language)
    except ImportError:
        return jsonify({"error": "python-docx not installed"}), 500
    filename = f"session_{session_id}"
    if language:
        filename += "_" + _lang_clean(language)
    return send_file(
        buf,
        mimetype=(
            "application/vnd.openxmlformats-officedocument" ".wordprocessingml.document"
        ),
        as_attachment=True,
        download_name=f"{filename}.docx",
    )


@bp.route("/session-export-structured-json/<path:session_id>", methods=["GET"])
def session_export_structured_json(session_id):
    """Export a session's structured data as a JSON file."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    language = request.args.get("language")
    data = extract_structured_data_from_session(sdir, language)
    if not data:
        return jsonify({"error": "No structured data available"}), 404
    actual = resolve_export_language_name(sdir, language)
    js = json.dumps(data, ensure_ascii=False, indent=2)
    return send_file(
        io.BytesIO(js.encode("utf-8")),
        mimetype="application/json",
        as_attachment=True,
        download_name=f"{_lang_clean(actual)}.json",
    )


@bp.route("/session-export-all-languages/<path:session_id>", methods=["GET"])
def session_export_all_languages(session_id):
    """Export a session's transcript data in one or more supported formats."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    export_format = request.args.get("format", "all").lower()
    languages = get_available_languages(sdir)
    if not languages:
        return jsonify({"error": "No transcript data found"}), 404

    formats = (
        ["txt", "rtf", "docx", "json"]
        if export_format == "all"
        else (
            [export_format]
            if export_format in ("txt", "rtf", "docx", "json")
            else ["txt"]
        )
    )

    zip_buf = io.BytesIO()
    with zipfile.ZipFile(zip_buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for lang in languages:
            clean = _lang_clean(lang)
            if "txt" in formats:
                zf.writestr(
                    f"{clean}.txt",
                    export_structured_txt(session_id, sdir, lang).getvalue(),
                )
            if "rtf" in formats:
                zf.writestr(
                    f"{clean}.rtf",
                    export_structured_rtf(session_id, sdir, lang).getvalue(),
                )
            if "docx" in formats:
                try:
                    zf.writestr(
                        f"{clean}.docx",
                        export_structured_docx(session_id, sdir, lang).getvalue(),
                    )
                except ImportError:
                    pass
            if "json" in formats:
                data = extract_structured_data_from_session(sdir, lang)
                if data:
                    zf.writestr(
                        f"{clean}.json",
                        json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"),
                    )
    zip_buf.seek(0)
    return send_file(
        zip_buf,
        mimetype="application/zip",
        as_attachment=True,
        download_name="transcript_all_languages.zip",
    )


@bp.route("/session-languages/<path:session_id>", methods=["GET"])
def session_languages(session_id):
    """Return the languages available for a session."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    return jsonify({"languages": get_available_languages(sdir)}), 200


@bp.route("/session-transcript-json/<path:session_id>", methods=["GET"])
def session_transcript_json(session_id):
    """Return a session transcript as JSON."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    p = os.path.join(sdir, "transcripts.json")
    if os.path.exists(p):
        with open(p, "r", encoding="utf-8") as f:
            return jsonify(json.load(f)), 200
    return jsonify({"error": "No transcript data found"}), 404


@bp.route("/session-messages-json/<path:session_id>", methods=["GET"])
def session_messages_json(session_id):
    """Return a session's messages as a JSON attachment."""
    sdir = session_dir(session_id)
    if not os.path.exists(sdir):
        return jsonify({"error": "Session not found"}), 404
    p = os.path.join(sdir, "messages.json")
    if os.path.exists(p) and os.path.getsize(p) > 1000:
        return send_file(
            p,
            as_attachment=True,
            download_name=f"messages_{session_id}.json",
            mimetype="application/json",
        )
    return jsonify({"error": "messages.json not found"}), 404
