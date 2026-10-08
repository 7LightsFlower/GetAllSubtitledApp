"""Extract, organise, and rewrite transcripts from messages.json."""

from __future__ import annotations

import json
import logging
import os

from .config import (
    LANGUAGE_NAMES,
    MIN_MESSAGES_BYTES,
    MT_COVERAGE_MIN_FRACTION,
    MT_COVERAGE_SLACK_SECONDS,
)
from .state import _warned_senders
from .utils import (
    extract_simple_language_name,
    format_vtt_timestamp,
    safe_float,
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
    """Extract a human-readable language label from a sender identifier."""
    if lang_id in numeric_language_map:
        return numeric_language_map[lang_id]

    if sender.startswith("asr:"):
        num_id = sender.removeprefix("asr:")
        label = (
            numeric_language_map[num_id]
            if num_id in numeric_language_map
            else f"Transcript (Original ASR - Language {lang_id})"
        )
    elif sender.startswith("mt:"):
        num_id = sender.removeprefix("mt:")
        label = (
            f"{numeric_language_map[num_id]} Translation"
            if num_id in numeric_language_map
            else str(lang_id)
        )
    elif sender.startswith("textstructurer:0_"):
        lang_code = sender.removeprefix("textstructurer:0_").lower()
        full = LANGUAGE_NAMES.get(lang_code)
        label = (
            f"Transcript (Structured - {full})"
            if full
            else f"Transcript (Structured - {lang_code})"
        )
    elif sender.startswith("saasr"):
        label = f"Transcript (SAASR - Language {lang_id})"
    else:
        label = next(
            (
                f"Transcript ({name})"
                for code, name in LANGUAGE_NAMES.items()
                if f"_{code}" in sender
                or f":{code}" in sender
                or f"-{code}" in sender
            ),
            f"Transcript (Language {lang_id})",
        )

    return label


def get_language_name_from_sender(sender, lang_id) -> str:
    """Build a display label for a transcript based on its sender and language."""
    lang_name = _lang_id_to_name(lang_id)
    if not sender:
        return f"Language {lang_name}" if lang_name else f"Language {lang_id}"

    if sender.startswith("asr:"):
        label = f"Original ASR ({lang_name})" if lang_name else "Original ASR"
    elif sender.startswith("mt:"):
        label = f"Translation ({lang_name})" if lang_name else "Translation"
    elif sender.startswith("textstructurer:0_"):
        lang_code = sender.removeprefix("textstructurer:0_").lower()
        full = LANGUAGE_NAMES.get(lang_code, lang_code)
        label = f"Structured ({full})"
    elif sender.startswith("saasr"):
        label = f"SAASR ({lang_name})" if lang_name else "SAASR"
    else:
        label = next(
            (
                f"Transcript ({name})"
                for code, name in LANGUAGE_NAMES.items()
                if f"_{code}" in sender
                or f":{code}" in sender
                or f"-{code}" in sender
            ),
            f"Transcript ({lang_name})" if lang_name else f"Transcript (Language {lang_id})",
        )

    return label


def organize_transcripts(transcripts: list) -> list:
    """Group transcript records by language and return them in a stable order."""
    organized: dict = {}
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

    for transcript in organized.values():
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


def _parse_message(item: object) -> dict | None:
    """Parse a messages entry and return its dictionary payload."""
    if not isinstance(item, list) or len(item) < 2:
        return None
    msg_str = item[1]
    try:
        msg_data = json.loads(msg_str) if isinstance(msg_str, str) else msg_str
    except (json.JSONDecodeError, TypeError):
        return None
    return msg_data if isinstance(msg_data, dict) else None


def _build_segment(msg_data: dict, text: str, sender: str) -> dict:
    """Build a transcript segment from a parsed message."""
    return {
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


def extract_transcripts_from_messages(messages_path: str) -> list:
    """Extract and organize transcript data from a messages JSON file."""
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

    if isinstance(messages_data, list):
        for item in messages_data:
            msg_data = _parse_message(item)
            if not msg_data or "sender" not in msg_data:
                continue
            sender = msg_data["sender"]
            lang_id = item[0]
            lang_name = extract_language_from_sender(
                sender, lang_id, numeric_language_map
            )
            if lang_id not in numeric_language_map:
                numeric_language_map[lang_id] = lang_name
            language_map[sender] = lang_name

    if isinstance(messages_data, list):
        for item in messages_data:
            msg_data = _parse_message(item)
            if not msg_data:
                continue
            sender = msg_data.get("sender", "")
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
                looks_like_control = (
                    "message_id" in msg_data
                    and "session" in msg_data
                    and "tag" in msg_data
                )
                if sender and sender not in _warned_senders and not looks_like_control:
                    _warned_senders.add(sender)
                    logging.warning(
                        "extract: message with no text field (sender=%r, keys=%s)",
                        sender,
                        sorted(msg_data.keys()),
                    )
                continue

            lang_id = item[0]
            lang_name = language_map.get(sender) or numeric_language_map.get(
                lang_id
            ) or get_language_name_from_sender(sender, lang_id)
            existing = next(
                (t for t in transcripts if t.get("language") == lang_name),
                None,
            )
            segment = _build_segment(msg_data, text, sender)
            if existing:
                existing["text"] += "\n" + text
                existing.setdefault("segments", []).append(segment)
            else:
                transcripts.append(
                    {
                        "language": lang_name,
                        "source_file": f"lang_{lang_id}",
                        "text": text,
                        "sender": sender,
                        "segments": [segment],
                    }
                )

    return organize_transcripts(transcripts)


def is_original_asr_language(language: str) -> bool:
    """Return whether a language is identified as original or ASR."""
    if not language:
        return False
    lower = language.lower()
    return "original" in lower or "asr" in lower


def save_transcripts_to_files(session_dir: str, transcripts: list) -> None:
    """Save transcript data as JSON and a human-readable text file."""
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
                    f.write(
                        f"[{start:.1f}s - {end:.1f}s] [{sender}] "
                        f"[{markup}] {text}\n"
                    )
                else:
                    f.write(f"[{start:.1f}s - {end:.1f}s] [{sender}] {text}\n")
            f.write("\n")


def _vtt_filename(language: str) -> str:
    if is_original_asr_language(language):
        return "subtitles_Transcript.vtt"

    simple = extract_simple_language_name(language)
    clean = simple.replace(" ", "_").replace("(", "").replace(")", "")
    return f"subtitles_{clean}.vtt"


def _vtt_cue_lines(segments: list[dict]) -> list[str]:
    lines = ["WEBVTT", ""]
    cue_index = 0
    for segment in sorted(segments, key=lambda item: safe_float(item.get("start", 0))):
        text = segment.get("text", "")
        if not text or not text.strip():
            continue
        if segment.get("markup") in ("chapterBreak", "paragraphBreak", "heading"):
            continue

        cue_index += 1
        start = safe_float(segment.get("start", 0))
        end = safe_float(segment.get("end", 0))
        lines.extend(
            [
                str(cue_index),
                f"{format_vtt_timestamp(start)} --> {format_vtt_timestamp(end)}",
            ]
        )
        speaker = segment.get("speakerName") or segment.get("speaker_name")
        lines.append(f"<v {speaker}>{text}</v>" if speaker and speaker.strip() else text)
        lines.append("")

    return lines if cue_index else []


def generate_vtt_files_from_transcripts(session_dir: str) -> list[str]:
    """Generate WebVTT subtitle files from a session's transcript JSON."""
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return []
    try:
        with open(json_path, "r", encoding="utf-8") as file:
            transcripts = json.load(file)
    except (OSError, ValueError, TypeError):
        return []
    if not transcripts:
        return []

    written = []
    for transcript in transcripts:
        segments = transcript.get("segments", [])
        if not segments:
            continue

        filename = _vtt_filename(transcript.get("language", ""))
        lines = _vtt_cue_lines(segments)
        if not lines:
            continue

        with open(os.path.join(session_dir, filename), "w", encoding="utf-8") as file:
            file.write("\n".join(lines))
        written.append(filename)

    return written


# ─── readiness / coverage helpers ──────────────────────────────────────
def messages_look_done(raw: bytes, expected_langs=None, log: bool = True) -> bool:
    """Return whether the message stream has enough stable ASR and MT coverage."""
    if not raw or len(raw) < MIN_MESSAGES_BYTES:
        return False
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return False
    if not isinstance(data, list) or not data:
        return False

    def message_end(item: object) -> float | None:
        if not (isinstance(item, list) and len(item) >= 2):
            return None
        try:
            message = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            return None
        if not isinstance(message, dict) or not message.get("seq", "").strip():
            return None
        try:
            return float(message.get("end", 0) or 0)
        except (TypeError, ValueError):
            return None

    def coverage_ok(mt_end: float, asr_end: float) -> bool:
        if asr_end <= 0 or mt_end >= asr_end - MT_COVERAGE_SLACK_SECONDS:
            return True
        return mt_end / asr_end >= MT_COVERAGE_MIN_FRACTION

    asr_count = 0
    asr_max_end = 0.0
    mt_tracks: dict[str, float] = {}

    for item in data:
        end = message_end(item)
        if end is None:
            continue
        sender = item[1] if isinstance(item[1], str) else item[1]
        if isinstance(sender, dict):
            sender = sender.get("sender", "")
        else:
            sender = sender.get("sender", "") if isinstance(sender, dict) else ""
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

    incomplete = [
        f"{sender} covers {end:.0f}s of {asr_max_end:.0f}s"
        for sender, end in mt_tracks.items()
        if not coverage_ok(end, asr_max_end)
    ]
    if incomplete and log:
        logging.info(
            "messages.json stable but MT tracks still short: %s",
            "; ".join(incomplete),
        )
    return not incomplete
