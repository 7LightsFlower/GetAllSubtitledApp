"""Export session transcripts to TXT / DOCX / RTF / JSON."""

from __future__ import annotations

import datetime
import io
import json
import os
import re

from docx import Document
from docx.shared import RGBColor

from .utils import safe_float


# ─── small helpers ─────────────────────────────────────────────────────
def clean_html_tags(text: str) -> str:
    """Remove HTML-like tags and normalize whitespace in text."""
    if not text:
        return ""
    clean = re.sub(r"<[^>]+>", " ", text)
    clean = re.sub(r"\s+", " ", clean)
    return clean.strip()


def escape_rtf(text: str) -> str:
    """Escape text so it can be safely embedded in an RTF document."""
    if not text:
        return ""
    escaped = text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
    result = []
    for char in escaped:
        code = ord(char)
        result.append(f"\\u{code}?" if code > 127 else char)
    return "".join(result)


def get_paragraph_number(sender: str) -> int:
    """Return the one-based paragraph number encoded in a textstructurer sender."""
    if not sender or not sender.startswith("textstructurer:"):
        return 0
    if ":" in sender:
        parts = sender.split(":")
        if len(parts) >= 2:
            m = re.search(r"^(\d+)", parts[1])
            if m:
                return int(m.group(1)) + 1
    return 0


def is_asr_or_mt(sender: str) -> bool:
    """Return whether a sender represents ASR, machine translation, or translation."""
    if not sender:
        return False
    return sender.startswith(("asr:", "mt:", "translation:"))


def is_textstructurer(sender: str) -> bool:
    """Return whether a sender represents a text structurer."""
    return bool(sender) and sender.startswith("textstructurer:")


def is_summarizer(sender: str) -> bool:
    """Return whether a sender represents a summarizer."""
    return bool(sender) and sender.startswith("summarizer:")


def extract_lang_code(language_name: str) -> str | None:
    """Extract a supported language code from a language name."""
    if not language_name:
        return None
    for code in (
        "en",
        "de",
        "fr",
        "es",
        "it",
        "pt",
        "nl",
        "ru",
        "ja",
        "ko",
        "zh",
        "ar",
        "hi",
        "pl",
        "tr",
        "uk",
        "vi",
        "th",
        "id",
        "ms",
    ):
        if f"({code})" in language_name or f" - {code}" in language_name:
            return code
    return None


def _filter_summaries_by_language(summaries, lang_code):
    if not lang_code:
        return summaries
    filtered = [s for s in summaries if f"_{lang_code}" in s.get("sender", "")]
    return filtered if filtered else summaries


# ─── structured data extraction ────────────────────────────────────────
def _load_structured_messages(messages_path):
    """Load dictionary messages from a session messages file."""
    try:
        with open(messages_path, "r", encoding="utf-8") as file:
            messages_data = json.load(file)
    except (json.JSONDecodeError, OSError, TypeError):
        return []

    if not isinstance(messages_data, list):
        return []

    messages = []
    for item in messages_data:
        if not isinstance(item, list) or len(item) < 2:
            continue
        try:
            message = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(message, dict):
            messages.append(message)
    return messages


def _append_chapter_segments(structured, transcripts):
    """Assign transcript segments to the chapter containing their start time."""
    for transcript in transcripts:
        for segment in transcript.get("segments", []):
            segment_start = safe_float(segment.get("start", 0))
            for chapter in structured["chapters"]:
                chapter_start = safe_float(chapter.get("start", 0))
                chapter_end = safe_float(chapter.get("end", 0))
                if chapter_start <= segment_start < chapter_end or (
                    chapter is structured["chapters"][-1]
                    and segment_start >= chapter_start
                ):
                    chapter.setdefault("segments", []).append(segment)
                    break


def extract_structured_data_from_session(session_dir_path, language_filter=None):
    """Extract structured transcript, chapter, and message data from a session."""
    json_path = os.path.join(session_dir_path, "transcripts.json")
    if not os.path.exists(json_path):
        return None
    with open(json_path, "r", encoding="utf-8") as file:
        all_transcripts = json.load(file)

    transcripts = (
        [item for item in all_transcripts if item.get("language") == language_filter]
        if language_filter
        else all_transcripts
    )
    structured_messages = _load_structured_messages(
        os.path.join(session_dir_path, "messages.json")
    )
    structured = {
        "transcripts": [],
        "chapters": [],
        "summaries": [],
        "speakers": {},
        "post_edited": [],
        "notes": [],
        "global_summaries": [],
        "paragraph_breaks": [],
    }
    for transcript in transcripts:
        structured["transcripts"].append(
            {
                "language": transcript.get("language", "Unknown"),
                "text": transcript.get("text", ""),
                "segments": sorted(
                    transcript.get("segments", []),
                    key=lambda item: safe_float(item.get("start", 0)),
                ),
                "sender": transcript.get("sender", ""),
            }
        )

    chapter_stack = []
    for message in sorted(
        structured_messages, key=lambda item: safe_float(item.get("start", 0))
    ):
        markup = message.get("markup")
        sender = message.get("sender", "")
        sequence = message.get("seq", "")
        start = safe_float(message.get("start", 0))
        end = safe_float(message.get("end", 0))

        if markup == "chapterBreak":
            chapter = {
                "start": start,
                "end": end,
                "index": len(structured["chapters"]),
                "heading": "",
                "segments": [],
            }
            structured["chapters"].append(chapter)
            chapter_stack.append(chapter)
        elif markup == "heading" and chapter_stack:
            chapter_stack[-1]["heading"] = sequence
        elif markup == "paragraphBreak":
            structured["paragraph_breaks"].append({"start": start, "end": end})
        elif markup == "summary":
            structured["summaries"].append(
                {"text": sequence, "start": start, "end": end, "sender": sender}
            )
        elif markup == "postedited":
            rate = "90"
            sender_parts = sender.split(":")
            if len(sender_parts) > 1 and "_" in sender_parts[1]:
                rate = sender_parts[1].split("_")[0]
            structured["post_edited"].append(
                {
                    "text": sequence,
                    "start": start,
                    "end": end,
                    "compression_rate": rate,
                    "sender": sender,
                }
            )
        elif markup == "notes":
            structured["notes"].append(
                {
                    "text": sequence,
                    "start": start,
                    "end": end,
                    "nested_level": message.get("nested_level", 0),
                    "chapter_index": message.get("chapter_index", 0),
                }
            )
        elif markup == "global_summary":
            structured["global_summaries"].append({"text": sequence, "sender": sender})

        speaker = message.get("refined_sentence_cluster")
        if speaker:
            if speaker.startswith("unk-"):
                speaker = f"Anonymous-{speaker.split('-')[1]}"
            structured["speakers"][speaker] = {
                "name": speaker,
                "last_seen": datetime.datetime.now().isoformat(),
            }

    _append_chapter_segments(structured, structured["transcripts"])
    return structured


# ─── plain-text formatter ──────────────────────────────────────────────
def _select_transcript(structured_data, language_filter=None):
    """Return the selected transcript and the corresponding language code."""
    transcripts = structured_data.get("transcripts", [])
    if not transcripts:
        return None, None
    if language_filter:
        for transcript in transcripts:
            if transcript.get("language") == language_filter:
                return transcript, extract_lang_code(transcript.get("language", ""))
        return transcripts[0], extract_lang_code(transcripts[0].get("language", ""))
    return transcripts[0], extract_lang_code(transcripts[0].get("language", ""))


def _append_table_of_contents(lines, chapters):
    """Append a simple chapter table of contents."""
    if not chapters or len(chapters) <= 1:
        return
    lines.append("TABLE OF CONTENTS")
    lines.append("-" * 40)
    for chapter in chapters:
        idx = chapter.get("index", 0) + 1
        heading = chapter.get("heading", "")
        lines.append(f"  {idx}. {heading or f'Chapter {idx}'}")
    lines.append("")


def _append_entries(lines, heading, entries, prefix=""):
    """Append a generic text section from entries."""
    if not entries:
        return
    lines.append("=" * 60)
    lines.append(heading)
    lines.append("-" * 40)
    for entry in entries:
        text = clean_html_tags(entry.get("text", ""))
        if prefix:
            lines.append(f"  {prefix} {text}")
        else:
            lines.append(f"  {text}")
    lines.append("")


def format_structured_text(structured_data, language_filter=None) -> str:
    """Format structured session data as plain text for export."""
    if not structured_data:
        return "No structured data available."

    lines: list[str] = []
    selected, lang_code = _select_transcript(structured_data, language_filter)
    filtered_summaries = _filter_summaries_by_language(
        structured_data.get("summaries", []), lang_code
    )
    filtered_global = _filter_summaries_by_language(
        structured_data.get("global_summaries", []), lang_code
    )
    filtered_pe = _filter_summaries_by_language(
        structured_data.get("post_edited", []), lang_code
    )

    _append_table_of_contents(lines, structured_data.get("chapters", []))

    paragraph_counter = 0

    def emit_segment(seg):
        nonlocal paragraph_counter
        sender = seg.get("sender", "")
        clean = clean_html_tags(seg.get("text", ""))
        if not clean:
            return
        if is_textstructurer(sender):
            paragraph_counter += 1
            lines.append(f"[{paragraph_counter}]")
            lines.append(clean)
            lines.append("")
        elif is_asr_or_mt(sender):
            lines.append(clean)
        elif is_summarizer(sender):
            lines.append(f"Summary: {clean}")
        else:
            if sender:
                lines.append(f"[{sender}]")
            lines.append(clean)

    if structured_data.get("chapters"):
        for chapter in structured_data["chapters"]:
            idx = chapter.get("index", 0) + 1
            heading = chapter.get("heading", "")
            lines.append(
                f"--- Chapter {idx}: {heading} ---"
                if heading
                else f"--- Chapter {idx} ---"
            )
            for seg in chapter.get("segments", []):
                emit_segment(seg)
            lines.append("")
    elif selected:
        lines.append(f"--- {selected.get('language', 'Unknown')} ---")
        for seg in selected.get("segments", []):
            emit_segment(seg)

    _append_entries(lines, "SUMMARIES", filtered_summaries, "📋")
    _append_entries(lines, "GLOBAL SUMMARIES", filtered_global, "🌐")
    if filtered_pe:
        entries = []
        for entry in filtered_pe:
            rate = entry.get("compression_rate", "N/A")
            text = clean_html_tags(entry.get("text", ""))
            entries.append({"text": f"[Compression: {rate}%] {text}"})
        _append_entries(lines, "POST-EDITED CONTENT", entries)

    return "\n".join(lines).strip()


# ─── individual format writers ─────────────────────────────────────────
def export_structured_txt(session_id, session_dir_path, language_filter=None):
    """Export the session's structured data as a UTF-8 text file."""
    data = extract_structured_data_from_session(session_dir_path, language_filter)
    if not data:
        return io.BytesIO(b"No structured data available.")
    text = format_structured_text(data, language_filter)
    header = (
        "=" * 80 + "\n"
        f"SESSION: {session_id}\n"
        + (f"FILTER: {language_filter}\n" if language_filter else "")
        + f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
        + "=" * 80
        + "\n\n"
    )
    return io.BytesIO((header + text).encode("utf-8"))


def _add_docx_transcript(doc, data, selected):
    """Add transcript content and chapter headings to a document."""
    chapters = data.get("chapters", [])
    paragraph_counter = 0

    def emit_docx(segment):
        nonlocal paragraph_counter
        clean = clean_html_tags(segment.get("text", ""))
        sender = segment.get("sender", "")
        if not clean:
            return

        if is_textstructurer(sender):
            paragraph_counter += 1
            paragraph = doc.add_paragraph()
            run = paragraph.add_run(f"[{paragraph_counter}]")
            run.bold = True
            run.font.color.rgb = RGBColor(0, 102, 204)
            doc.add_paragraph(clean)
        elif is_asr_or_mt(sender):
            doc.add_paragraph(clean)
        elif is_summarizer(sender):
            paragraph = doc.add_paragraph()
            run = paragraph.add_run("Summary: ")
            run.bold = True
            run.font.color.rgb = RGBColor(255, 165, 0)
            paragraph.add_run(clean)
        else:
            if sender:
                paragraph = doc.add_paragraph()
                run = paragraph.add_run(f"[{sender}]")
                run.bold = True
                run.font.color.rgb = RGBColor(0, 102, 204)
            doc.add_paragraph(clean)

    if chapters:
        for chapter in chapters:
            index = chapter.get("index", 0) + 1
            heading = chapter.get("heading", "")
            doc.add_heading(
                f"Chapter {index}: {heading}" if heading else f"Chapter {index}",
                level=2,
            )
            for segment in chapter.get("segments", []):
                emit_docx(segment)
            doc.add_paragraph("")
    elif selected:
        doc.add_heading(selected.get("language", "Unknown"), level=2)
        for segment in selected.get("segments", []):
            emit_docx(segment)


def _add_docx_summaries(doc, summaries, heading):
    """Add a section of summaries to a document."""
    if not summaries:
        return
    doc.add_heading(heading, level=1)
    for summary in summaries:
        paragraph = doc.add_paragraph()
        paragraph.add_run("📋 ").bold = True
        paragraph.add_run(clean_html_tags(summary.get("text", "")))


def _add_docx_post_edited(doc, entries):
    """Add post-edited content to a document."""
    if not entries:
        return
    doc.add_heading("Post-Edited Content", level=1)
    for entry in entries:
        paragraph = doc.add_paragraph()
        paragraph.add_run(
            f"[Compression: {entry.get('compression_rate', 'N/A')}%] "
        ).bold = True
        paragraph.add_run(clean_html_tags(entry.get("text", "")))


def export_structured_docx(session_id, session_dir_path, language_filter=None):
    """Export structured session data to a UTF-8 DOCX document."""
    data = extract_structured_data_from_session(session_dir_path, language_filter)
    if not data:
        doc = Document()
        doc.add_heading("No structured data available", 1)
        buffer = io.BytesIO()
        doc.save(buffer)
        buffer.seek(0)
        return buffer

    doc = Document()
    title = f"Session: {session_id}"
    if language_filter:
        title += f" - {language_filter}"
    doc.add_heading(title, 0)
    doc.add_paragraph(f"Session ID: {session_id}")
    doc.add_paragraph(
        f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    )
    doc.add_paragraph("")

    transcripts = data.get("transcripts", [])
    selected = None
    if language_filter:
        selected = next(
            (
                transcript
                for transcript in transcripts
                if transcript.get("language") == language_filter
            ),
            None,
        )
        if not selected and transcripts:
            selected = transcripts[0]
    elif transcripts:
        selected = transcripts[0]

    language_code = (
        extract_lang_code(selected.get("language", "")) if selected else None
    )
    summaries = _filter_summaries_by_language(data.get("summaries", []), language_code)
    global_summaries = _filter_summaries_by_language(
        data.get("global_summaries", []), language_code
    )
    post_edited = _filter_summaries_by_language(
        data.get("post_edited", []), language_code
    )

    chapters = data.get("chapters", [])
    if len(chapters) > 1:
        doc.add_heading("Table of Contents", level=1)
        for chapter in chapters:
            index = chapter.get("index", 0) + 1
            paragraph = doc.add_paragraph()
            paragraph.add_run(f"{index}. ").bold = True
            paragraph.add_run(chapter.get("heading") or f"Chapter {index}")
        doc.add_paragraph("")

    doc.add_heading("Transcript", level=1)
    _add_docx_transcript(doc, data, selected)
    _add_docx_summaries(doc, summaries, "Summaries")
    _add_docx_summaries(doc, global_summaries, "Global Summaries")
    _add_docx_post_edited(doc, post_edited)

    buffer = io.BytesIO()
    doc.save(buffer)
    buffer.seek(0)
    return buffer


def _select_structured_transcript(data, language_filter=None):
    """Return the requested transcript, preferring the first transcript as fallback."""
    transcripts = data.get("transcripts", [])
    if language_filter:
        return next(
            (item for item in transcripts if item.get("language") == language_filter),
            transcripts[0] if transcripts else None,
        )
    return transcripts[0] if transcripts else None


def _append_rtf_segment(parts, segment, paragraph_counter):
    """Append one segment to an RTF document and return its paragraph counter."""
    clean = clean_html_tags(segment.get("text", ""))
    if not clean:
        return paragraph_counter

    sender = segment.get("sender", "")
    if is_textstructurer(sender):
        paragraph_counter += 1
        parts.append(r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par")
    elif is_summarizer(sender):
        parts.append(r"\b Summary: \b0 ")
    elif sender:
        parts.append(r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par")

    parts.append(escape_rtf(clean) + r"\par")
    return paragraph_counter


def export_structured_rtf(session_id, session_dir_path, language_filter=None):
    """Export structured session data as an RTF document."""
    data = extract_structured_data_from_session(session_dir_path, language_filter)
    if not data:
        return io.BytesIO(b"{\\rtf1\\ansi No structured data available.}")

    parts = [
        r"{\rtf1\ansi\deff0",
        r"{\fonttbl{\f0\fnil\fcharset0 Arial;}}",
        r"\f0\fs24",
        r"\b\fs32 Session: " + session_id + r"\b0\par\par",
    ]
    if language_filter:
        parts.append(r"\b\fs28 Filter: " + language_filter + r"\b0\par\par")
    parts.append(
        r"\b\fs28 Export Date: "
        + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        + r"\b0\par\par"
    )

    selected = _select_structured_transcript(data, language_filter)
    lang_code = extract_lang_code(selected.get("language", "")) if selected else None
    filtered_summaries = _filter_summaries_by_language(
        data.get("summaries", []), lang_code
    )
    filtered_global = _filter_summaries_by_language(
        data.get("global_summaries", []), lang_code
    )
    filtered_post_edited = _filter_summaries_by_language(
        data.get("post_edited", []), lang_code
    )

    paragraph_counter = 0
    chapters = data.get("chapters")
    if chapters:
        for chapter in chapters:
            index = chapter.get("index", 0) + 1
            heading = chapter.get("heading", "")
            parts.append(
                r"\b\fs24 Chapter "
                + str(index)
                + (": " + escape_rtf(heading) if heading else "")
                + r"\b0\par"
            )
            for segment in chapter.get("segments", []):
                paragraph_counter = _append_rtf_segment(
                    parts, segment, paragraph_counter
                )
            parts.append(r"\par")
    elif selected:
        parts.append(
            r"\b\fs24 " + escape_rtf(selected.get("language", "Unknown")) + r"\b0\par"
        )
        for segment in selected.get("segments", []):
            paragraph_counter = _append_rtf_segment(parts, segment, paragraph_counter)

    for heading, summaries, icon in (
        ("Summaries", filtered_summaries, "📋"),
        ("Global Summaries", filtered_global, "🌐"),
        ("Post-Edited Content", filtered_post_edited, ""),
    ):
        if not summaries:
            continue
        parts.append(r"\b\fs26 " + heading + r"\b0\par")
        for summary in summaries:
            text = escape_rtf(clean_html_tags(summary.get("text", "")))
            prefix = r"\b " + icon + r" \b0 " if icon else r"\b "
            if heading == "Post-Edited Content":
                compression = summary.get("compression_rate", "N/A")
                prefix += r"[Compression: " + str(compression) + r"%]\b0 "
            parts.append(prefix + text + r"\par")

    parts.append("}")
    return io.BytesIO("".join(parts).encode("utf-8"))


def get_available_languages(session_dir_path) -> list[str]:
    """Return the unique languages available in a session's transcript file."""
    json_path = os.path.join(session_dir_path, "transcripts.json")
    if not os.path.exists(json_path):
        return []
    with open(json_path, "r", encoding="utf-8") as f:
        transcripts = json.load(f)
    return sorted({t.get("language", "Unknown") for t in transcripts})


def resolve_export_language_name(session_dir_path, language) -> str:
    """Return the canonical language name for an export language."""
    json_path = os.path.join(session_dir_path, "transcripts.json")
    if not os.path.exists(json_path):
        return "transcript"
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            transcripts = json.load(f)
    except (OSError, ValueError, TypeError):
        return "transcript"
    if not transcripts:
        return "transcript"
    if language:
        for t in transcripts:
            lang = str(t.get("language", "")).strip()
            if lang and (lang == language or language.lower() in lang.lower()):
                return lang
    return transcripts[0].get("language", "transcript") or "transcript"


def clean_filename_from_language(name: str) -> str:
    """Clean a language name into a safe, filename-friendly string."""
    clean = name.replace(" ", "_").replace("(", "").replace(")", "")
    clean = clean.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean = re.sub(r"[^a-zA-Z0-9_-]", "", clean)
    return clean[:50]
