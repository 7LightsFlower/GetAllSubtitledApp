"""Extract, organise, and rewrite transcripts from messages.json."""

from __future__ import annotations

import json
import logging
import os

from .config import LANGUAGE_NAMES, MIN_MESSAGES_BYTES
from .state import _warned_senders
from .utils import (
    extract_simple_language_name, format_vtt_timestamp, safe_float,
)

# Re-exported for callers
_extract_simple_language_name = extract_simple_language_name


def _lang_id_to_name(lang_id) -> str | None:
    if lang_id is None:
        return None
    if isinstance(lang_id, str):
        code = lang_id.strip().lower()
        if code in LANGUAGE_NAMES:
            return LANGUAGE_NAMES[code]
        if code in {n.lower() for n in LANGUAGE_NAMES.values()}:
            return lang_id.strip()
    return None


def extract_language_from_sender(sender, lang_id, numeric_language_map) -> str:
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
    for code, name in LANGUAGE_NAMES.items():
        if f"_{code}" in sender or f":{code}" in sender or f"-{code}" in sender:
            return f"Transcript ({name})"
    return f"Transcript (Language {lang_id})"


def get_language_name_from_sender(sender, lang_id) -> str:
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


def organize_transcripts(transcripts: list) -> list:
    organized: dict = {}
    for t in transcripts:
        lang = t.get("language", "Unknown")
        if lang not in organized:
            organized[lang] = {
                "language": lang, "text": "",
                "source_file": t.get("source_file", ""),
                "sender": t.get("sender", ""),
                "segments": [], "chapters": [], "summaries": [],
                "post_edited": [], "notes": [], "global_summaries": [],
                "speakers": {}, "paragraph_breaks": [],
            }
        if organized[lang]["text"]:
            organized[lang]["text"] += "\n"
        organized[lang]["text"] += t.get("text", "")
        if "segments" in t:
            organized[lang]["segments"].extend(t.get("segments", []))

    for transcript in organized.values():
        if "segments" in transcript:
            transcript["segments"].sort(
                key=lambda x: safe_float(x.get("start", 0)))

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


def extract_transcripts_from_messages(messages_path: str) -> list:
    if not os.path.exists(messages_path) or os.path.getsize(messages_path) < 100:
        return []
    try:
        with open(messages_path, "r", encoding="utf-8") as f:
            messages_data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        logging.warning("Could not parse messages.json: %s", e)
        return []

    transcripts: list = []
    language_map: dict = {}
    numeric_language_map: dict = {}

    # First pass: build language maps
    if isinstance(messages_data, list):
        for item in messages_data:
            if isinstance(item, list) and len(item) >= 2:
                lang_id, msg_str = item[0], item[1]
                try:
                    msg_data = json.loads(msg_str) if isinstance(msg_str, str) else msg_str
                except (json.JSONDecodeError, TypeError):
                    continue
                if isinstance(msg_data, dict) and "sender" in msg_data:
                    sender = msg_data.get("sender", "")
                    lang_name = extract_language_from_sender(
                        sender, lang_id, numeric_language_map)
                    if lang_id not in numeric_language_map:
                        numeric_language_map[lang_id] = lang_name
                    language_map[sender] = lang_name

    # Second pass: build transcripts
    if isinstance(messages_data, list):
        for item in messages_data:
            if not (isinstance(item, list) and len(item) >= 2):
                continue
            lang_id, msg_str = item[0], item[1]
            try:
                msg_data = json.loads(msg_str) if isinstance(msg_str, str) else msg_str
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(msg_data, dict):
                continue
            sender = msg_data.get("sender", "")
            if sender.startswith(("tts:", "tts_", "lip:", "lip_")):
                continue

            text = (msg_data.get("seq") or msg_data.get("text")
                    or msg_data.get("translation") or "")
            text = text.strip() if isinstance(text, str) else ""

            if not text:
                looks_like_control = (
                    "message_id" in msg_data and "session" in msg_data
                    and "tag" in msg_data
                )
                if (sender and sender not in _warned_senders
                        and not looks_like_control):
                    _warned_senders.add(sender)
                    logging.warning(
                        "extract: message with no text field "
                        "(sender=%r, keys=%s)", sender, sorted(msg_data.keys()))
                continue

            if sender in language_map:
                lang_name = language_map[sender]
            else:
                lang_name = (numeric_language_map.get(lang_id)
                             or get_language_name_from_sender(sender, lang_id))

            existing = next(
                (t for t in transcripts if t.get("language") == lang_name),
                None,
            )

            segment = {
                "text": text,
                "start": safe_float(msg_data.get("start", 0)),
                "end": safe_float(msg_data.get("end", 0)),
                "sender": sender,
                "markup": msg_data.get("markup"),
                "words": msg_data.get("words"),
                "word_id": msg_data.get("word_id"),
                "source_tokens": msg_data.get("sourceTokens"),
                "speaker_name": msg_data.get("speakerName"),
                "refined_sentence_cluster": msg_data.get("refined_sentence_cluster"),
                "unstable": msg_data.get("unstable", False),
                "message_id": msg_data.get("message_id"),
            }

            if existing:
                existing["text"] += "\n" + text
                existing.setdefault("segments", []).append(segment)
            else:
                transcripts.append({
                    "language": lang_name,
                    "source_file": f"lang_{lang_id}",
                    "text": text,
                    "sender": sender,
                    "segments": [segment],
                })

    return organize_transcripts(transcripts)


def is_original_asr_language(language: str) -> bool:
    if not language:
        return False
    lower = language.lower()
    return "original" in lower or "asr" in lower


def save_transcripts_to_files(session_dir: str, transcripts: list) -> None:
    if not transcripts:
        return
    json_path = os.path.join(session_dir, "transcripts.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(transcripts, f, ensure_ascii=False, indent=2)

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
                markup = seg.get("markup", "")
                if not text or not text.strip():
                    continue
                if markup:
                    f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] "
                            f"[{markup}] {text}\n")
                else:
                    f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
            f.write("\n")


def generate_vtt_files_from_transcripts(session_dir: str) -> list[str]:
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
    for transcript in transcripts:
        language = transcript.get("language", "")
        segments = transcript.get("segments", [])
        if not segments:
            continue

        if is_original_asr_language(language):
            vtt_filename = "subtitles_Transcript.vtt"
        else:
            simple = extract_simple_language_name(language)
            clean = simple.replace(" ", "_").replace("(", "").replace(")", "")
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
            lines.append(f"{format_vtt_timestamp(start)} --> "
                         f"{format_vtt_timestamp(end)}")
            speaker = seg.get("speakerName") or seg.get("speaker_name")
            if speaker and speaker.strip():
                lines.append(f"<v {speaker}>{text}</v>")
            else:
                lines.append(text)
            lines.append("")

        if cue_index == 0:
            continue
        with open(vtt_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        written.append(vtt_filename)

    return written


# ─── readiness / coverage helpers ──────────────────────────────────────
def messages_look_done(raw: bytes, expected_langs=None, log: bool = True) -> bool:
    if not raw or len(raw) < MIN_MESSAGES_BYTES:
        return False
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return False
    if not isinstance(data, list) or not data:
        return False

    asr_count = 0
    asr_max_end = 0.0
    mt_tracks: dict[str, float] = {}

    for item in data:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict) or not m.get("seq", "").strip():
            continue
        try:
            end = float(m.get("end", 0) or 0)
        except (ValueError, TypeError):
            end = 0.0
        sender = m.get("sender", "")
        if sender.startswith("asr:"):
            asr_count += 1
            asr_max_end = max(asr_max_end, end)
        elif sender.startswith(("mt:", "translation:")):
            mt_tracks[sender] = max(mt_tracks.get(sender, 0.0), end)

    if asr_count < 5 or asr_max_end <= 0:
        return False
    if expected_langs and not mt_tracks:
        if log:
            logging.info("messages.json has ASR but no MT tracks yet")
        return False

    from .config import MT_COVERAGE_MIN_FRACTION, MT_COVERAGE_SLACK_SECONDS

    def coverage_ok(mt_end: float, asr_end: float) -> bool:
        if asr_end <= 0:
            return True
        if mt_end >= asr_end - MT_COVERAGE_SLACK_SECONDS:
            return True
        return (mt_end / asr_end) >= MT_COVERAGE_MIN_FRACTION

    incomplete = [f"{s} covers {e:.0f}s of {asr_max_end:.0f}s"
                  for s, e in mt_tracks.items() if not coverage_ok(e, asr_max_end)]
    if incomplete:
        if log:
            logging.info("messages.json stable but MT tracks still short: %s",
                         "; ".join(incomplete))
        return False
    return True