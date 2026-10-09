"""Job-settings persistence: per-video, defaults, named presets."""

from __future__ import annotations

import json
import logging
import os
import re

from flask import Blueprint, jsonify, request

bp = Blueprint("settings", __name__)

# Settings are stored as plain JSON files under <backend>/settings/.
# They survive a restart and are visible to anyone who shells into
# the container. Three kinds:
#
#   video_<key>.json   — auto-saved settings for one video
#   defaults.json      — global fallback when a video has no file
#   presets.json       — user-named presets, shared across videos
_BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SETTINGS_DIR = os.path.join(_BACKEND_DIR, "settings")
os.makedirs(_SETTINGS_DIR, exist_ok=True)


def _settings_path(kind: str, key: str = "") -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", key)[:80] or "default"
    return os.path.join(_SETTINGS_DIR, f"{kind}_{safe}.json")


def _read_settings_file(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError) as e:
        logging.warning("settings: read failed for %s: %s", path, e)
        return {}


def _write_settings_file(path: str, data: dict) -> None:
    """Atomic write: temp file + os.replace. Readers never see a
    half-written file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


@bp.route(
    "/video-job-settings/<video_key>",
    methods=["GET", "PUT", "DELETE", "OPTIONS"],
)
def video_job_settings(video_key):
    """Per-video saved job settings.

    GET    → saved settings object (or {} when none)
    PUT    → replace it with the posted JSON object
    DELETE → remove the file (reset to whatever _defaults.json says)
    """
    if request.method == "OPTIONS":
        return ("", 204)

    path = _settings_path("video", video_key)

    if request.method == "GET":
        saved = _read_settings_file(path)
        if saved:
            return jsonify(saved), 200
        # No per-video file yet. Fall back to the global defaults
        # file if one exists, so a fresh video starts from a known
        # baseline instead of whatever the client happens to have
        # in SharedPreferences.
        defaults = _read_settings_file(_settings_path("defaults"))
        return jsonify(defaults), 200

    if request.method == "DELETE":
        try:
            if os.path.exists(path):
                os.remove(path)
            return jsonify({"success": True}), 200
        except OSError as e:
            return jsonify({"error": str(e)}), 500

    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "Expected a JSON object"}), 400

    try:
        _write_settings_file(path, payload)
        logging.info(
            "video-job-settings: saved %d keys for %s",
            len(payload),
            video_key,
        )
        return jsonify({"success": True, "keys": len(payload)}), 200
    except OSError as e:
        return jsonify({"error": f"Could not save settings: {e}"}), 500


@bp.route("/job-settings-defaults", methods=["GET", "PUT", "OPTIONS"])
def job_settings_defaults():
    """Global default job settings, consulted when a video has none."""
    if request.method == "OPTIONS":
        return ("", 204)

    path = _settings_path("defaults")

    if request.method == "GET":
        return jsonify(_read_settings_file(path)), 200

    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "Expected a JSON object"}), 400
    try:
        _write_settings_file(path, payload)
        return jsonify({"success": True}), 200
    except OSError as e:
        return jsonify({"error": str(e)}), 500


@bp.route(
    "/job-settings-presets",
    methods=["GET", "POST", "DELETE", "OPTIONS"],
)
def job_settings_presets():
    """Named settings presets, shared by every video.

    GET                  → {"presets": {name: {...}, …}}
    POST {name, settings}→ create or overwrite one preset
    DELETE ?name=…        → delete one preset
    """
    if request.method == "OPTIONS":
        return ("", 204)

    path = _settings_path("presets")
    store = _read_settings_file(path)
    presets = store.get("presets")
    if not isinstance(presets, dict):
        presets = {}

    if request.method == "GET":
        return jsonify({"presets": presets}), 200

    if request.method == "DELETE":
        name = (request.args.get("name") or "").strip()
        if not name:
            return jsonify({"error": "name is required"}), 400
        presets.pop(name, None)
        try:
            _write_settings_file(path, {"presets": presets})
        except OSError as e:
            return jsonify({"error": str(e)}), 500
        return jsonify({"success": True, "count": len(presets)}), 200

    payload = request.get_json(silent=True) or {}
    name = str(payload.get("name") or "").strip()
    settings = payload.get("settings")
    if not name or not isinstance(settings, dict):
        return jsonify({"error": "name and settings are required"}), 400
    if len(name) > 100:
        return jsonify({"error": "name is too long"}), 400
    presets[name] = settings
    try:
        _write_settings_file(path, {"presets": presets})
    except OSError as e:
        return jsonify({"error": str(e)}), 500
    logging.info("job-settings-presets: saved %r (%d keys)", name, len(settings))
    return jsonify({"success": True, "name": name}), 200
