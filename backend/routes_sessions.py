"""Session ZIP, VTT saving and subtitle updates.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import json
import logging
import os
import re
import subprocess
import time
import yt_dlp
from flask import jsonify, request

from .flask_app import app
from .config import LANGUAGE_NAMES, _LANG_CODE_RE, sessions
from .state import save_state
from .utils import _session_dir, _short_sid, file_mtime_iso
from .transcripts import (
    _display_speaker,
    _format_vtt_timestamp,
    _is_original_asr_language,
    safe_float,
)


@app.route("/session-transcript-save-vtt/<path:session_id>", methods=["POST"])
def session_transcript_save_vtt(session_id):
    """Save edited transcript segments and rewrite the corresponding VTT file.

    Naming rules:
      - Original ASR track   -> subtitles_Transcript.vtt  (and mirrored to
                                subtitles.vtt, the generic default)
      - Any other language   -> subtitles_<SimpleName>.vtt
      - Explicit `filename` in the payload always wins.
    """
    session_dir = _session_dir(session_id)
    if not os.path.exists(session_dir):
        return jsonify({"error": "Session not found"}), 404

    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Invalid JSON data"}), 400

        language = data.get("language")
        segments = data.get("segments", [])
        filename = data.get("filename")

        if not language:
            return jsonify({"error": "Language is required"}), 400
        if not segments:
            return jsonify({"error": "No segments provided"}), 400

        # Filter out structural / empty segments
        filtered_segments = []
        for seg in segments:
            if seg.get("start", 0) == 0 and seg.get("end", 0) == 0:
                continue
            if seg.get("markup") in ["paragraphBreak", "chapterBreak", "heading"]:
                continue
            if not seg.get("text", "").strip():
                continue
            filtered_segments.append(seg)

        if not filtered_segments:
            return jsonify({"error": "No valid segments to save"}), 400

        # --- 1. Update transcripts.json -----------------------------------
        json_path = os.path.join(session_dir, "transcripts.json")
        transcripts = []
        if os.path.exists(json_path):
            with open(json_path, "r", encoding="utf-8") as f:
                transcripts = json.load(f)

        updated = False
        for i, transcript in enumerate(transcripts):
            if transcript.get("language") == language:
                transcript["segments"] = filtered_segments
                transcript["text"] = " ".join(
                    s.get("text", "") for s in filtered_segments
                )
                transcripts[i] = transcript
                updated = True
                break

        if not updated:
            transcripts.append(
                {
                    "language": language,
                    "text": " ".join(s.get("text", "") for s in filtered_segments),
                    "segments": filtered_segments,
                    "sender": (
                        filtered_segments[0].get("sender", "")
                        if filtered_segments
                        else ""
                    ),
                }
            )

        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(transcripts, f, ensure_ascii=False, indent=2)

        # --- 2. Decide which VTT file to write ----------------------------
        if filename:
            # Caller was explicit — trust them.
            vtt_filename = filename

        elif _is_original_asr_language(language):
            # Speaker's own language always goes to the same predictable
            # filename, so generator / save / sync all agree.
            vtt_filename = "subtitles_Transcript.vtt"

        else:
            # Non-ASR track: reuse an existing VTT for this language if
            # one exists, otherwise create a new one from the simple name.
            existing_vtt = None
            simple_name = _extract_simple_language_name(language)

            for f in os.listdir(session_dir):
                if not f.endswith(".vtt"):
                    continue
                if (
                    simple_name in f
                    or language in f
                    or f.startswith(f"subtitles_{simple_name}")
                ):
                    existing_vtt = f
                    break

            if existing_vtt:
                vtt_filename = existing_vtt
            else:
                clean_lang = (
                    simple_name.replace(" ", "_").replace("(", "").replace(")", "")
                )
                vtt_filename = f"subtitles_{clean_lang}.vtt"

        # --- 3. Build the VTT content -------------------------------------
        vtt_lines = ["WEBVTT", ""]
        cue_index = 0
        for seg in filtered_segments:
            start = safe_float(seg.get("start", 0))
            end = safe_float(seg.get("end", 0))
            text = seg.get("text", "")

            if not text or not text.strip():
                continue

            cue_index += 1
            vtt_lines.append(str(cue_index))
            vtt_lines.append(
                f"{_format_vtt_timestamp(start)} --> " f"{_format_vtt_timestamp(end)}"
            )

            speaker_name = _display_speaker(
                seg.get("speakerName") or seg.get("speaker_name")
            )
            if speaker_name:
                vtt_lines.append(f"<v {speaker_name}>{text}</v>")
            else:
                vtt_lines.append(text)
            vtt_lines.append("")

        vtt_content = "\n".join(vtt_lines)

        # Write the per-language file
        vtt_path = os.path.join(session_dir, vtt_filename)
        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write(vtt_content)

        # --- 4. Update transcript.txt -------------------------------------
        txt_path = os.path.join(session_dir, "transcript.txt")
        with open(txt_path, "w", encoding="utf-8") as f:
            for t in transcripts:
                f.write(f"{'=' * 60}\n")
                f.write(f"Language: {t.get('language', 'Unknown')}\n")
                f.write(f"{'=' * 60}\n\n")
                segs = t.get("segments", [])
                segs.sort(key=lambda x: safe_float(x.get("start", 0)))
                for seg in segs:
                    start = safe_float(seg.get("start", 0))
                    end = safe_float(seg.get("end", 0))
                    sender = seg.get("sender", "")
                    text = seg.get("text", "")
                    markup = seg.get("markup", "")
                    if not text or not text.strip():
                        continue
                    if markup:
                        f.write(
                            f"[{start:.1f}s - {end:.1f}s] [{sender}] "
                            f"[{markup}] {text}\n"
                        )
                    else:
                        f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
                f.write("\n")

        logging.info(
            "Saved transcript and updated VTT for language '%s' in session %s",
            language,
            _short_sid(session_id),
        )

        # --- 5. Return the refreshed file list ----------------------------
        files = []
        for file in os.listdir(session_dir):
            file_path = os.path.join(session_dir, file)
            if os.path.isfile(file_path) and _is_meaningful_file(file_path):
                mod_time = file_mtime_iso(file_path)
                files.append(
                    {
                        "name": file,
                        "size": os.path.getsize(file_path),
                        "url": f"/session-file/{session_id}/{file}",
                        "modified": mod_time,
                    }
                )

        save_state()

        return (
            jsonify(
                {
                    "success": True,
                    "message": f"Transcript saved and VTT updated: {vtt_filename}",
                    "language": language,
                    "vtt_filename": vtt_filename,
                    "segments_count": len(filtered_segments),
                    "files": files,
                }
            ),
            200,
        )

    except json.JSONDecodeError as e:
        return jsonify({"error": f"Invalid JSON: {str(e)}"}), 400
    except (OSError, TypeError, KeyError) as e:
        logging.error("Error saving transcript: %s", e, exc_info=True)
        return jsonify({"error": f"Failed to save: {str(e)}"}), 500


def _extract_simple_language_name(language):
    """Extract a full, human-readable language name.

    Handles strings like:
      "Translation (Language de)"        -> "German"
      "Transcript (Structured - en)"     -> "English"
      "Original ASR - Language English"  -> "English"
      "de"                               -> "German"
      "English"                          -> "English"
    """
    if not language:
        return "Unknown"

    # 1. Code inside parentheses, e.g. "(de)"
    match = re.search(r"\(([^)]+)\)", language)
    if match:
        candidate = match.group(1).strip()
        # "(Language de)" -> "de"
        if candidate.lower().startswith("language "):
            candidate = candidate.split(" ", 1)[1].strip()
        name = LANGUAGE_NAMES.get(candidate.lower())
        if name:
            return name

    # 2. Strip the wrapper phrases
    clean = language
    stripped = False
    for prefix in (
        "Translation (Language ",
        "Transcript (Original ASR - ",
        "Transcript (Structured - ",
        "Transcript (",
    ):
        if prefix in clean:
            clean = clean.replace(prefix, "")
            stripped = True

    if stripped:
        clean = clean.rstrip(")").strip()
    else:
        clean = clean.strip()

    # 3. A bare code, e.g. "de"
    if _LANG_CODE_RE.match(clean):
        return LANGUAGE_NAMES.get(clean.lower(), clean)

    # 4. "Language English" -> "English"
    if clean.lower().startswith("language "):
        clean = clean.split(" ", 1)[1].strip()
        if _LANG_CODE_RE.match(clean):
            return LANGUAGE_NAMES.get(clean.lower(), clean)

    return clean or "Unknown"


@app.route("/update-video-subtitles/<path:session_id>", methods=["POST"])
def update_video_subtitles(session_id):
    """
    Update the embedded subtitles in video.mp4 with the edited VTT files.
    Also updates messages.json to reflect the changes.
    """
    session_dir = _session_dir(session_id)
    if not os.path.isdir(session_dir):
        return jsonify({"error": "Session not found"}), 404

    # NEW: which tracks the user ticked in the dialog. `None` means the
    # caller didn't send a selection (older clients) — in that case we
    # keep the previous behaviour and embed everything.
    payload = request.get_json(silent=True) or {}
    include = payload.get("include")
    if include is not None:
        if not isinstance(include, list):
            return (
                jsonify(
                    {
                        "error": "bad_include",
                        "message": "'include' must be a list of VTT filenames.",
                    }
                ),
                400,
            )
        include = {str(x) for x in include}

    # Same preference order as get_session_file():
    #   1. already-subtitled video (incremental re-edits)
    #   2. original full-quality video
    #   3. session-local placeholder
    modified_candidate = os.path.join(session_dir, "video_subtitled.mp4")
    original = _get_session_original_video_path(session_id)
    placeholder = os.path.join(session_dir, "video.mp4")

    if os.path.exists(modified_candidate):
        video_path = modified_candidate
    elif original:
        video_path = original
    elif os.path.exists(placeholder):
        video_path = placeholder
    else:
        return jsonify({"error": "No video source found for this session"}), 404

    logging.info(
        "update_video_subtitles: session=%r using source=%s "
        "(dir_exists=%s, original=%s)",
        _short_sid(session_id),
        os.path.basename(video_path),
        os.path.isdir(session_dir),
        bool(original),
    )

    try:
        # --- 1. Get list of VTT files in the session ---
        vtt_files = []
        for f in os.listdir(session_dir):
            if f.endswith(".vtt"):
                file_path = os.path.join(session_dir, f)
                # Extract language from filename
                lang = f.replace("subtitles_", "").replace(".vtt", "")
                vtt_files.append(
                    {
                        "filename": f,
                        "path": file_path,
                        "language": lang,
                        "size": os.path.getsize(file_path),
                        "modified": os.path.getmtime(file_path),
                    }
                )

        # ── NEW: honour the caller's selection ────────────────────
        # `include` is the set of VTT filenames the user ticked in the
        # dialog. `None` means an older client that didn't send a
        # selection — keep the previous behaviour and embed everything.
        if include is not None:
            before = len(vtt_files)
            vtt_files = [v for v in vtt_files if v["filename"] in include]
            logging.info(
                "update_video_subtitles: filtered %d VTT(s) down to %d "
                "based on client selection: %s",
                before,
                len(vtt_files),
                [v["filename"] for v in vtt_files],
            )
            if not vtt_files:
                return (
                    jsonify(
                        {
                            "error": "no_matching_tracks",
                            "message": (
                                "None of the selected subtitle tracks "
                                "exist for this session."
                            ),
                        }
                    ),
                    400,
                )

        if not vtt_files:
            return jsonify({"error": "No VTT files found to embed"}), 404

        # --- 2. Update messages.json with the edited content ---
        messages_path = os.path.join(session_dir, "messages.json")
        updated_count = 0
        if os.path.exists(messages_path):
            try:
                with open(messages_path, "r", encoding="utf-8") as f:
                    messages_data = json.load(f)

                json_path = os.path.join(session_dir, "transcripts.json")
                if os.path.exists(json_path):
                    with open(json_path, "r", encoding="utf-8") as f:
                        transcripts = json.load(f)

                    language_segments = {}
                    for transcript in transcripts:
                        lang = transcript.get("language", "")
                        if lang:
                            segments = transcript.get("segments", [])
                            language_segments[lang] = segments

                    if isinstance(messages_data, list):
                        for i, item in enumerate(messages_data):
                            if isinstance(item, list) and len(item) >= 2:
                                msg_lang = item[0]
                                matching_segments = None
                                for lang_key, segments in language_segments.items():
                                    if (
                                        msg_lang.lower() in lang_key.lower()
                                        or lang_key.lower() in msg_lang.lower()
                                    ):
                                        matching_segments = segments
                                        break

                                if matching_segments:
                                    try:
                                        msg_str = item[1]
                                        if isinstance(msg_str, str):
                                            msg_data = json.loads(msg_str)
                                        elif isinstance(msg_str, dict):
                                            msg_data = msg_str
                                        else:
                                            continue

                                        if (
                                            "seq" in msg_data
                                            and "start" in msg_data
                                            and "end" in msg_data
                                        ):
                                            start_time = msg_data.get("start", 0)
                                            if isinstance(start_time, str):
                                                try:
                                                    start_time = float(start_time)
                                                except ValueError:
                                                    start_time = 0

                                            matched_seg = None
                                            for seg in matching_segments:
                                                seg_start = seg.get("start", 0)
                                                if isinstance(seg_start, str):
                                                    try:
                                                        seg_start = float(seg_start)
                                                    except ValueError:
                                                        seg_start = 0
                                                if abs(seg_start - start_time) < 0.01:
                                                    matched_seg = seg
                                                    break

                                            if matched_seg:
                                                msg_data["seq"] = matched_seg.get(
                                                    "text", ""
                                                )
                                                if "markup" in matched_seg:
                                                    msg_data["markup"] = (
                                                        matched_seg.get("markup")
                                                    )
                                                if "speakerName" in matched_seg:
                                                    msg_data["speakerName"] = (
                                                        matched_seg.get("speakerName")
                                                    )
                                                if "words" in matched_seg:
                                                    msg_data["words"] = matched_seg.get(
                                                        "words"
                                                    )
                                                if "word_id" in matched_seg:
                                                    msg_data["word_id"] = (
                                                        matched_seg.get("word_id")
                                                    )

                                                if isinstance(msg_str, str):
                                                    messages_data[i][1] = json.dumps(
                                                        msg_data
                                                    )
                                                else:
                                                    messages_data[i][1] = msg_data
                                                updated_count += 1
                                    except (
                                        json.JSONDecodeError,
                                        TypeError,
                                        ValueError,
                                    ) as e:
                                        logging.warning(
                                            "Could not update message %d: %s", i, e
                                        )
                                        continue

                        if updated_count > 0:
                            with open(messages_path, "w", encoding="utf-8") as f:
                                json.dump(
                                    messages_data, f, ensure_ascii=False, indent=2
                                )
                            logging.info(
                                "Updated %d messages in messages.json", updated_count
                            )
            except (json.JSONDecodeError, TypeError, OSError) as e:
                logging.warning("Could not update messages.json: %s", e)

        # --- 3. Write the new video to a fixed temp name ---
        temp_output = os.path.join(session_dir, "video_subtitled_tmp.mp4")
        # Clean up any leftover from a previous interrupted run
        if os.path.exists(temp_output):
            try:
                os.remove(temp_output)
            except OSError:
                pass

        # Always start from the *original* upload, not the session-local
        # green-screen placeholder and not a previous video_subtitled.mp4.
        # Re-encoding a re-encoded file compounds quality loss; feeding
        # the green-screen back in would embed subtitles into the
        # placeholder instead of the real footage.
        original_path = _get_session_original_video_path(session_id)
        if original_path:
            video_path = original_path
            source_label = "original upload"
        elif os.path.exists(placeholder):
            video_path = placeholder
            source_label = "session placeholder (no original found)"
        else:
            return (
                jsonify(
                    {
                        "error": (
                            "No original video found for this session. "
                            "The uploaded file may have been deleted."
                        )
                    }
                ),
                404,
            )

        logging.info(
            "update_video_subtitles: ffmpeg input = %s (%s)",
            video_path,
            source_label,
        )

        # --- 4. Build ffmpeg command to embed subtitles ---
        #
        # Stream layout in the output (in this order):
        #   0 : video  (copied from input 0)
        #   1 : audio  (copied from input 0)
        #   2+: one subtitle track per valid VTT (re-encoded as mov_text)
        #
        # We map streams explicitly rather than using `-map 0` because
        # we want to control exactly which subtitles end up in the file.

        cmd = ["ffmpeg", "-y"]

        # Input 0: the video
        cmd.extend(["-i", video_path])

        # Inputs 1..N: one VTT per subtitle track
        valid_vtt_files = []
        for vtt in vtt_files:
            try:
                with open(vtt["path"], "r", encoding="utf-8") as f:
                    content = f.read()
                if not content.strip():
                    logging.warning("Skipping empty VTT: %s", vtt["filename"])
                    continue
                if "WEBVTT" not in content.upper():
                    logging.warning(
                        "Skipping invalid VTT (no WEBVTT header): %s",
                        vtt["filename"],
                    )
                    continue
            except (OSError, UnicodeError) as e:
                logging.warning("Skipping VTT %s: %s", vtt["filename"], e)
                continue

            cmd.extend(["-i", vtt["path"]])
            valid_vtt_files.append(vtt)

        # ── Stream mapping ─────────────────────────────────────────
        # Video and audio from input 0. The `?` makes each map optional
        # so a streamless video (audio-less lecture, say) doesn't abort
        # the whole command.
        cmd.extend(["-map", "0:v:0?"])
        cmd.extend(["-map", "0:a:0?"])

        # Exclude any subtitle streams already present in the original
        # video. This must come BEFORE the positive subtitle maps so it
        # only strips streams from input 0, not the freshly added ones.
        cmd.extend(["-map", "-0:s?"])

        # Subtitles from inputs 1..N -> output stream 2..N+1
        for i, vtt in enumerate(valid_vtt_files):
            cmd.extend(["-map", f"{i + 1}:s"])
            stream_idx = 2 + i

            display_name = _extract_simple_language_name(vtt["language"])
            if not display_name or display_name == "Unknown":
                display_name = vtt["language"]
            cmd.extend([f"-metadata:s:{stream_idx}", f"title={display_name}"])

        # ── Codecs ─────────────────────────────────────────────────
        # Copy the video and audio bitstreams verbatim (fast, lossless),
        # but re-encode the subtitles as mov_text so MP4 can hold them.
        cmd.extend(["-c:v", "copy"])
        cmd.extend(["-c:a", "copy"])
        cmd.extend(["-c:s", "mov_text"])

        # ── Container ──────────────────────────────────────────────
        # Move the moov atom to the front of the file. Without this,
        # browsers streaming the file over HTTP read the first frames
        # before they've seen the index, and often render them as
        # solid green. This is the single most important flag for web
        # playback of an MP4.
        cmd.extend(["-movflags", "+faststart"])

        cmd.append(temp_output)

        # Log the command for debugging (sanitize to avoid huge logs)
        logging.info(
            "FFmpeg command: %s", " ".join(cmd[:5]) + " ... " + " ".join(cmd[-5:])
        )

        # --- 5. Run ffmpeg with error handling ---
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=300, check=False
            )

            if result.returncode != 0:
                error_msg = result.stderr if result.stderr else "Unknown ffmpeg error"
                logging.error("FFmpeg error: %s", error_msg)
                logging.error(
                    "FFmpeg stdout: %s",
                    result.stdout[:500] if result.stdout else "None",
                )
                return (
                    jsonify(
                        {
                            "error": "ffmpeg failed",
                            "stderr": error_msg[:500],
                            "stdout": result.stdout[:500] if result.stdout else None,
                        }
                    ),
                    500,
                )

        except subprocess.TimeoutExpired:
            logging.error("ffmpeg timed out for session %s", session_id)
            return jsonify({"error": "ffmpeg timed out"}), 500
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            logging.error("ffmpeg exception: %s", e, exc_info=True)
            return jsonify({"error": str(e)}), 500

        # --- 6. Atomically replace video_subtitled.mp4 with the new file ---
        target = os.path.join(session_dir, "video_subtitled.mp4")
        max_attempts = 5
        attempt_delay = 3  # seconds

        replaced = False
        for attempt in range(1, max_attempts + 1):
            try:
                os.replace(temp_output, target)
                replaced = True
                logging.info(
                    "update_video_subtitles: replaced %s (attempt %d/%d)",
                    target,
                    attempt,
                    max_attempts,
                )
                break
            except PermissionError:
                logging.warning(
                    "update_video_subtitles: %s is locked (attempt %d/%d)",
                    target,
                    attempt,
                    max_attempts,
                )
                if attempt < max_attempts:
                    time.sleep(attempt_delay)
            except OSError as e:
                logging.error("update_video_subtitles: os.replace failed: %s", e)
                return jsonify({"error": f"Could not replace video: {e}"}), 500

        if not replaced:
            logging.error(
                "update_video_subtitles: giving up after %d attempts; "
                "new video kept at %s",
                max_attempts,
                temp_output,
            )
            return (
                jsonify(
                    {
                        "error": "video_locked",
                        "message": (
                            "The current video is being played in another tab. "
                            "Close it and try saving again. Your new version is "
                            "saved as video_subtitled_tmp.mp4 and will be "
                            "applied automatically on the next successful save."
                        ),
                        "pending_file": "video_subtitled_tmp.mp4",
                    }
                ),
                423,  # HTTP 423 Locked
            )

        # --- 7. Save state ---
        # Remember the choice so a retry after a 423 lock doesn't make
        # the user re-pick the same tracks.
        if include is not None:
            sessions.setdefault(session_id, {})["embedded_languages"] = sorted(include)
        save_state()

        logging.info("Successfully updated video subtitles for session %s", session_id)

        return (
            jsonify(
                {
                    "success": True,
                    "message": "Video subtitles and messages.json updated successfully",
                    "embedded_subtitles": [
                        {
                            "language": vtt["language"],
                            "filename": vtt["filename"],
                        }
                        for vtt in valid_vtt_files
                    ],
                    "video": "video_subtitled.mp4",
                    "messages_updated": updated_count,
                }
            ),
            200,
        )

    # This is the endpoint boundary: unexpected failures must be converted to
    # an HTTP response instead of escaping Flask.
    # pylint: disable=broad-exception-caught
    except (
        AttributeError,
        KeyError,
        OSError,
        TypeError,
        ValueError,
        RuntimeError,
        yt_dlp.utils.DownloadError,
    ) as e:
        logging.error("Error updating video subtitles: %s", e, exc_info=True)
        return jsonify({"error": str(e)}), 500


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global _get_session_original_video_path, _is_meaningful_file
    from .media import _get_session_original_video_path
    from .video_routes import _is_meaningful_file
