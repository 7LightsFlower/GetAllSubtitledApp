"""Transcripts from messages.json, VTT generation, speaker names.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import json
import logging
import os
import re

from .config import LANGUAGE_NAMES, _warned_senders


def safe_float(value, default=0.0):
    """Safely convert a value to float, handling strings and None."""
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except (ValueError, TypeError):
            return default
    return default


def _format_vtt_timestamp(seconds):
    """Format seconds to VTT timestamp format: HH:MM:SS.mmm"""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds % 1) * 1000)

    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def extract_transcripts_from_messages(messages_path):
    """Extract transcripts from messages.json file with proper structure handling."""
    if not os.path.exists(messages_path) or os.path.getsize(messages_path) < 100:
        return []

    try:
        with open(messages_path, "r", encoding="utf-8") as f:
            messages_data = json.load(f)

        transcripts = []
        language_map = {}
        numeric_language_map = {}

        if isinstance(messages_data, list):
            for item in messages_data:
                if isinstance(item, list) and len(item) >= 2:
                    lang_id = item[0]
                    msg_str = item[1]
                    try:
                        if isinstance(msg_str, str):
                            msg_data = json.loads(msg_str)
                        elif isinstance(msg_str, dict):
                            msg_data = msg_str
                        else:
                            continue
                    except (json.JSONDecodeError, TypeError):
                        continue

                    if isinstance(msg_data, dict) and "sender" in msg_data:
                        sender = msg_data.get("sender", "")
                        lang_name = extract_language_from_sender(
                            sender, lang_id, numeric_language_map
                        )
                        if lang_id not in numeric_language_map:
                            numeric_language_map[lang_id] = lang_name
                        language_map[sender] = lang_name

        if isinstance(messages_data, list):
            for item in messages_data:
                if isinstance(item, list) and len(item) >= 2:
                    lang_id = item[0]
                    msg_str = item[1]

                    try:
                        if isinstance(msg_str, str):
                            msg_data = json.loads(msg_str)
                        elif isinstance(msg_str, dict):
                            msg_data = msg_str
                        else:
                            continue
                    except (json.JSONDecodeError, TypeError):
                        continue

                    # ── accept any of several text fields, not just "seq" ──
                    if isinstance(msg_data, dict):
                        sender = msg_data.get("sender", "")

                        # Skip TTS and lip-sync senders. These are synthesized audio
                        # messages that carry no text; the KIT front-end ignores them too
                        # (see the `startsWith("lip") / startsWith("tts")` branch in the
                        # archive page JS). Left in, they resolve to useless labels like
                        # "Transcript (Language 4)" and clutter the language dropdown.
                        if sender.startswith(("tts:", "tts_", "lip:", "lip_")):
                            continue

                        text = (
                            msg_data.get("seq")
                            or msg_data.get("text")
                            or msg_data.get("translation")
                            or ""
                        )
                        text = text.strip() if isinstance(text, str) else ""

                        if not text:
                            # Messages that carry no `seq` / `text` /
                            # `translation` field fall into two buckets:
                            #
                            #  1. Mediator control/transport messages. They
                            #     have a fixed shape: 'message_id', 'session',
                            #     'tag', 'access', 'controll', 'directory',
                            #     'host', 'meta', 'time_arrive_mediator'.
                            #     No text is expected — this is normal.
                            #
                            #  2. Actual transcript messages whose field was
                            #     renamed. These are the ones we want to hear
                            #     about, so we log them once per sender.
                            looks_like_control = (
                                "message_id" in msg_data
                                and "session" in msg_data
                                and "tag" in msg_data
                            )
                            if (
                                sender
                                and sender not in _warned_senders
                                and not looks_like_control
                            ):
                                _warned_senders.add(sender)
                                logging.warning(
                                    "extract: message with no text field "
                                    "(sender=%r, keys=%s)",
                                    sender,
                                    sorted(msg_data.keys()),
                                )
                            continue

                        if sender in language_map:
                            lang_name = language_map[sender]
                        else:
                            lang_name = numeric_language_map.get(
                                lang_id
                            ) or get_language_name_from_sender(sender, lang_id)

                        existing = next(
                            (t for t in transcripts if t.get("language") == lang_name),
                            None,
                        )

                        start_val = msg_data.get("start", 0)
                        end_val = msg_data.get("end", 0)
                        try:
                            start_float = (
                                float(start_val) if start_val is not None else 0.0
                            )
                        except (ValueError, TypeError):
                            start_float = 0.0
                        try:
                            end_float = float(end_val) if end_val is not None else 0.0
                        except (ValueError, TypeError):
                            end_float = 0.0

                        segment_data = {
                            "text": text,
                            "start": start_float,
                            "end": end_float,
                            "sender": sender,
                            "markup": msg_data.get("markup"),
                            "words": msg_data.get("words"),
                            "word_id": msg_data.get("word_id"),
                            "source_tokens": msg_data.get("sourceTokens"),
                            "speaker_name": msg_data.get("speakerName"),
                            "refined_sentence_cluster": msg_data.get(
                                "refined_sentence_cluster"
                            ),
                            "unstable": msg_data.get("unstable", False),
                            "message_id": msg_data.get("message_id"),
                        }

                        if existing:
                            existing["text"] += "\n" + text
                            if "segments" not in existing:
                                existing["segments"] = []
                            existing["segments"].append(segment_data)
                        else:
                            transcripts.append(
                                {
                                    "language": lang_name,
                                    "source_file": f"lang_{lang_id}",
                                    "text": text,
                                    "sender": sender,
                                    "segments": [segment_data],
                                }
                            )

        organized_transcripts = organize_transcripts(transcripts)
        return organized_transcripts

    except json.JSONDecodeError as e:
        logging.warning("Could not parse messages.json: %s", e)
    except (OSError, KeyError, TypeError, AttributeError) as e:
        logging.warning("Could not extract transcripts from messages.json: %s", e)

    return []


def extract_language_from_sender(sender, lang_id, numeric_language_map):
    """Extract a full language name from a sender string."""
    if lang_id in numeric_language_map:
        return numeric_language_map[lang_id]

    if sender.startswith("asr:"):
        num_id = sender.replace("asr:", "")
        if num_id in numeric_language_map:
            return numeric_language_map[num_id]
        return f"Transcript (Original ASR - Language {lang_id})"

    if sender.startswith("mt:"):
        num_id = sender.replace("mt:", "")
        if num_id in numeric_language_map:
            return f"{numeric_language_map[num_id]} Translation"
        return f"{lang_id}"

    if sender.startswith("textstructurer:0_"):
        lang_code = sender.replace("textstructurer:0_", "").lower()
        full = LANGUAGE_NAMES.get(lang_code)
        if full:
            return f"Transcript (Structured - {full})"
        return f"Transcript (Structured - {lang_code})"

    if sender.startswith("saasr"):
        return f"Transcript (SAASR - Language {lang_id})"

    # Look for a 2-letter code anywhere in the sender
    for code, name in LANGUAGE_NAMES.items():
        if f"_{code}" in sender or f":{code}" in sender or f"-{code}" in sender:
            return f"Transcript ({name})"

    return f"Transcript (Language {lang_id})"


def get_language_name_from_sender(sender, lang_id):
    """Get a human-readable language name from a sender string (fallback)."""
    if not sender:
        lang_name = _lang_id_to_name(lang_id)
        return f"Language {lang_name}" if lang_name else f"Language {lang_id}"

    lang_name = _lang_id_to_name(lang_id)

    if sender.startswith("asr:"):
        return f"Original ASR ({lang_name})" if lang_name else "Original ASR"
    if sender.startswith("mt:"):
        return f"Translation ({lang_name})" if lang_name else "Translation"
    if sender.startswith("textstructurer:0_"):
        lang_code = sender.replace("textstructurer:0_", "").lower()
        full = LANGUAGE_NAMES.get(lang_code, lang_code)
        return f"Structured ({full})"
    if sender.startswith("saasr"):
        return f"SAASR ({lang_name})" if lang_name else "SAASR"

    for code, name in LANGUAGE_NAMES.items():
        if f"_{code}" in sender or f":{code}" in sender or f"-{code}" in sender:
            return f"Transcript ({name})"

    if lang_name:
        return f"Transcript ({lang_name})"
    return f"Transcript (Language {lang_id})"


def _lang_id_to_name(lang_id):
    """Resolve a lang_id ('en', 'English', ...) to a full language name."""
    if lang_id is None:
        return None
    if isinstance(lang_id, str):
        code = lang_id.strip().lower()
        if code in LANGUAGE_NAMES:
            return LANGUAGE_NAMES[code]
        if code in {n.lower() for n in LANGUAGE_NAMES.values()}:
            return lang_id.strip()
    return None


def organize_transcripts(transcripts):
    """Organize transcripts by language, combining related messages."""
    organized = {}

    for t in transcripts:
        lang = t.get("language", "Unknown")
        if lang not in organized:
            organized[lang] = {
                "language": lang,
                "text": "",
                "source_file": t.get("source_file", ""),
                "sender": t.get("sender", ""),
                "segments": [],
                "chapters": [],
                "summaries": [],
                "post_edited": [],
                "notes": [],
                "global_summaries": [],
                "speakers": {},
                "paragraph_breaks": [],
            }
        if organized[lang]["text"]:
            organized[lang]["text"] += "\n"
        organized[lang]["text"] += t.get("text", "")

        if "segments" in t:
            organized[lang]["segments"].extend(t.get("segments", []))

    for lang, transcript in organized.items():
        if "segments" in transcript:
            transcript["segments"].sort(key=lambda x: safe_float(x.get("start", 0)))

    result = list(organized.values())

    def sort_key(item):
        lang = item.get("language", "")
        if "Original" in lang:
            return 0
        if "Structured" in lang:
            return 1
        if "Translation" in lang:
            return 2
        return 3

    result.sort(key=sort_key)
    return result


def _is_original_asr_language(language: str) -> bool:
    """True for the ASR track that reflects what the speaker actually said."""
    if not language:
        return False
    lower = language.lower()
    return "original" in lower or "asr" in lower


def _display_speaker(raw) -> str:
    """KIT speaker id `<sid>:asr:speakerdiarization:<name>` → `<name>`."""
    if not raw or not isinstance(raw, str):
        return ""
    name = re.sub(r"<[^>]+>", "", raw).strip()
    name = name.rsplit(":", 1)[-1].strip()
    return re.sub(r"^Anonymous-?\s*", "Unknown ", name).strip()


def _segment_speaker(seg: dict) -> str:
    """Clean speaker name of a transcript segment ('' when none)."""
    return _display_speaker(seg.get("speaker_name") or seg.get("speakerName"))


def generate_vtt_files_from_transcripts(session_dir):
    """Materialise per-language .vtt files from transcripts.json."""
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return []

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
    except (OSError, ValueError, TypeError):
        return []

    if not transcripts:
        return []

    written = []
    default_path = None  # was: english_path

    for transcript in transcripts:
        language = transcript.get("language", "")
        segments = transcript.get("segments", [])
        if not segments:
            continue

        is_original = _is_original_asr_language(language)

        if is_original:
            # Stable, predictable name for the speaker's own language
            vtt_filename = "subtitles_Transcript.vtt"
        else:
            simple_name = _extract_simple_language_name(language)
            clean = simple_name.replace(" ", "_").replace("(", "").replace(")", "")
            vtt_filename = f"subtitles_{clean}.vtt"

        vtt_path = os.path.join(session_dir, vtt_filename)

        lines = ["WEBVTT", ""]
        cue_index = 0
        for seg in sorted(segments, key=lambda x: safe_float(x.get("start", 0))):
            text = seg.get("text", "")
            if not text or not text.strip():
                continue
            if seg.get("markup") in ("chapterBreak", "paragraphBreak", "heading"):
                continue
            start = safe_float(seg.get("start", 0))
            end = safe_float(seg.get("end", 0))
            cue_index += 1
            lines.append(str(cue_index))
            lines.append(
                f"{_format_vtt_timestamp(start)} --> {_format_vtt_timestamp(end)}"
            )
            speaker = _display_speaker(
                seg.get("speakerName") or seg.get("speaker_name")
            )
            if speaker:
                lines.append(f"<v {speaker}>{text}</v>")
            else:
                lines.append(text)
            lines.append("")

        if cue_index == 0:
            # Don't write a header-only VTT
            logging.info("generate_vtt: no cues for language %r, skipping", language)
            continue

        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        written.append(vtt_filename)

        # Original ASR wins; anything else is only used if no original exists.
        if default_path is None or is_original:
            default_path = vtt_path

    if written:
        logging.info("Generated %d VTT file(s)", len(written))
    return written


def save_transcripts_to_files(session_dir, transcripts):
    """Save transcripts to JSON and TXT files."""
    if not transcripts:
        return

    json_path = os.path.join(session_dir, "transcripts.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(transcripts, f, ensure_ascii=False, indent=2)
    logging.info("Saved transcripts to %s", json_path)

    txt_path = os.path.join(session_dir, "transcript.txt")
    with open(txt_path, "w", encoding="utf-8") as f:
        for t in transcripts:
            f.write(f"{'=' * 60}\n")
            f.write(f"Language: {t.get('language', 'Unknown')}\n")
            f.write(f"{'=' * 60}\n\n")
            segments = t.get("segments", [])
            segments.sort(key=lambda x: safe_float(x.get("start", 0)))
            for seg in segments:
                start = safe_float(seg.get("start", 0))
                end = safe_float(seg.get("end", 0))
                sender = seg.get("sender", "")
                text = seg.get("text", "")
                msg_markup = seg.get("markup", "")
                # Skip empty segments but don't skip based on <br> tags
                if not text or not text.strip():
                    continue
                if msg_markup:
                    f.write(
                        f"[{start:.1f}s - {end:.1f}s] [{sender}] [{msg_markup}] {text}\n"
                    )
                else:
                    f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
            f.write("\n")
    logging.info("Saved plain text to %s", txt_path)


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global _extract_simple_language_name
    from .routes_sessions import _extract_simple_language_name
