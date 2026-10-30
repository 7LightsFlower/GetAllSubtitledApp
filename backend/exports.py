"""Structured session data and TXT / DOCX / RTF exporters.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import datetime
import io
import json
import os
import re
from flask import jsonify, request, send_file
from docx import Document
from docx.shared import Pt, RGBColor

from .flask_app import app
from .utils import _session_dir
from .transcripts import _segment_speaker, safe_float


def extract_structured_data_from_session(session_dir, language_filter=None):
    """
    Extract fully structured data from a session matching the window view.
    """
    json_path = os.path.join(session_dir, "transcripts.json")
    if not os.path.exists(json_path):
        return None

    with open(json_path, "r", encoding="utf-8") as f:
        all_transcripts = json.load(f)

    if language_filter:
        transcripts = [
            t for t in all_transcripts if t.get("language") == language_filter
        ]
    else:
        transcripts = all_transcripts

    messages_path = os.path.join(session_dir, "messages.json")
    structured_messages = []
    if os.path.exists(messages_path):
        try:
            with open(messages_path, "r", encoding="utf-8") as f:
                messages_data = json.load(f)
            if isinstance(messages_data, list):
                for item in messages_data:
                    if isinstance(item, list) and len(item) >= 2:
                        try:
                            msg_data = (
                                json.loads(item[1])
                                if isinstance(item[1], str)
                                else item[1]
                            )
                            if isinstance(msg_data, dict):
                                structured_messages.append(msg_data)
                        except (json.JSONDecodeError, TypeError):
                            pass
        except (json.JSONDecodeError, TypeError, OSError):
            pass

    structured_data = {
        "transcripts": [],
        "chapters": [],
        "summaries": [],
        "speakers": {},
        "post_edited": [],
        "notes": [],
        "global_summaries": [],
        "paragraph_breaks": [],
    }

    for t in transcripts:
        transcript_entry = {
            "language": t.get("language", "Unknown"),
            "text": t.get("text", ""),
            "segments": sorted(
                t.get("segments", []), key=lambda x: safe_float(x.get("start", 0))
            ),
            "sender": t.get("sender", ""),
        }
        structured_data["transcripts"].append(transcript_entry)

    chapter_stack = []
    for msg in sorted(structured_messages, key=lambda x: safe_float(x.get("start", 0))):
        markup = msg.get("markup")
        sender = msg.get("sender", "")
        seq = msg.get("seq", "")
        start = safe_float(msg.get("start", 0))
        end = safe_float(msg.get("end", 0))

        if markup == "chapterBreak":
            chapter = {
                "start": start,
                "end": end,
                "index": len(structured_data["chapters"]),
                "heading": "",
                "segments": [],
            }
            structured_data["chapters"].append(chapter)
            chapter_stack.append(chapter)

        elif markup == "heading" and chapter_stack:
            chapter_stack[-1]["heading"] = seq

        elif markup == "paragraphBreak":
            structured_data["paragraph_breaks"].append({"start": start, "end": end})

        elif markup == "summary":
            structured_data["summaries"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "sender": sender,
                }
            )

        elif markup == "postedited":
            compression_rate = "90"
            if ":" in sender:
                parts = sender.split(":")
                if len(parts) > 1 and "_" in parts[1]:
                    compression_rate = parts[1].split("_")[0]
            structured_data["post_edited"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "compression_rate": compression_rate,
                    "sender": sender,
                }
            )

        elif markup == "notes":
            structured_data["notes"].append(
                {
                    "text": seq,
                    "start": start,
                    "end": end,
                    "nested_level": msg.get("nested_level", 0),
                    "chapter_index": msg.get("chapter_index", 0),
                }
            )

        elif markup == "global_summary":
            structured_data["global_summaries"].append(
                {
                    "text": seq,
                    "sender": sender,
                }
            )

        if "refined_sentence_cluster" in msg:
            speaker = msg.get("refined_sentence_cluster")
            if speaker:
                if speaker.startswith("unk-"):
                    speaker = f"Anonymous-{speaker.split('-')[1]}"
                structured_data["speakers"][speaker] = {
                    "name": speaker,
                    "last_seen": datetime.datetime.now().isoformat(),
                }

    for transcript in structured_data["transcripts"]:
        for seg in transcript.get("segments", []):
            seg_start = safe_float(seg.get("start", 0))
            for ch in structured_data["chapters"]:
                ch_start = safe_float(ch.get("start", 0))
                ch_end = safe_float(ch.get("end", 0))
                if ch_start <= seg_start < ch_end or (
                    ch == structured_data["chapters"][-1] and seg_start >= ch_start
                ):
                    if "segments" not in ch:
                        ch["segments"] = []
                    ch["segments"].append(seg)
                    break

    return structured_data


# ─── HELPER FUNCTIONS FOR EXPORT ──────────────────────────────────────


def clean_html_tags(text):
    """Remove HTML tags only, preserve everything else including music notes."""
    if not text:
        return ""
    # Remove HTML tags only (replace with space)
    clean = re.sub(r"<[^>]+>", " ", text)
    # Remove multiple spaces (but keep single spaces)
    clean = re.sub(r"\s+", " ", clean)
    # Trim leading/trailing spaces
    return clean.strip()


def escape_rtf(text):
    """Escape special characters for RTF format, preserving Unicode characters."""
    if not text:
        return ""
    # Escape backslashes and braces
    escaped = text.replace("\\", "\\\\")
    escaped = escaped.replace("{", "\\{")
    escaped = escaped.replace("}", "\\}")
    # Handle Unicode characters (preserve them)
    result = []
    for char in escaped:
        code = ord(char)
        if code > 127:
            result.append(f"\\u{code}?")
        else:
            result.append(char)
    return "".join(result)


def get_paragraph_number(sender):
    """
    Convert textstructurer: tags to sequential paragraph numbers.
    Only textstructurer: tags get numbers.
    """
    if not sender:
        return 0

    # Only textstructurer gets paragraph numbers
    if sender.startswith("textstructurer:"):
        if ":" in sender:
            parts = sender.split(":")
            if len(parts) >= 2:
                second_part = parts[1]
                match = re.search(r"^(\d+)", second_part)
                if match:
                    return int(match.group(1)) + 1
    return 0


def is_asr_or_mt(sender):
    """Check if sender is ASR or MT type."""
    if not sender:
        return False
    return (
        sender.startswith("asr:")
        or sender.startswith("mt:")
        or sender.startswith("translation:")
    )


def is_textstructurer(sender):
    """Check if sender is textstructurer type."""
    if not sender:
        return False
    return sender.startswith("textstructurer:")


def is_summarizer(sender):
    """Check if sender is summarizer type."""
    if not sender:
        return False
    return sender.startswith("summarizer:")


def format_sender_for_export(sender):
    """
    Format sender tag for export:
    - textstructurer: -> [1], [2], [3] (paragraph numbers)
    - asr: and mt: -> plain text (no marker)
    - Other senders -> [sender]
    """
    if not sender:
        return ""

    # textstructurer gets paragraph numbers
    if is_textstructurer(sender):
        num = get_paragraph_number(sender)
        if num > 0:
            return f"[{num}]"

    # asr and mt are plain text - return nothing (they're just markers)
    if is_asr_or_mt(sender):
        return ""

    # Other senders (summarizer, etc.) keep their name
    if is_summarizer(sender):
        return f"[{sender}]"

    return f"[{sender}]"


def format_text_for_export(text, sender):
    """
    Format text based on sender type:
    - textstructurer: -> keep as is (paragraph text)
    - summarizer: -> format with "Summary:" prefix
    - asr: / mt: -> plain text
    """
    clean_text = clean_html_tags(text)
    if not clean_text:
        return ""

    # Summarizer gets special formatting
    if is_summarizer(sender):
        return f"Summary: {clean_text}"

    # textstructurer is paragraph text
    if is_textstructurer(sender):
        return clean_text

    # asr and mt are plain text
    return clean_text


def extract_lang_code(language_name):
    """Extract language code from language name."""
    if not language_name:
        return None
    for code in [
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
    ]:
        if f"({code})" in language_name or f" - {code}" in language_name:
            return code
    return None


def filter_summaries_by_language(summaries, lang_code):
    """Filter summaries by language code."""
    if not lang_code:
        return summaries
    filtered = []
    for s in summaries:
        sender = s.get("sender", "")
        if f"_{lang_code}" in sender:
            filtered.append(s)
    return filtered if filtered else summaries


def format_structured_text(structured_data, language_filter=None):
    """Format structured data to match the website view, preserving music notes."""
    if not structured_data:
        return "No structured data available."

    lines = []

    # Get the language-specific data
    transcripts_data = structured_data.get("transcripts", [])

    # If we have a language filter, find the specific transcript
    selected_transcript = None
    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        # No filter - use first transcript
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code for filename
    lang_code = None
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents (only if chapters exist)
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        lines.append("TABLE OF CONTENTS")
        lines.append("-" * 40)
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                lines.append(f"  {idx}. {heading}")
            else:
                lines.append(f"  {idx}. Chapter {idx}")
        lines.append("")

    # Transcript with chapters
    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    # Track paragraph numbering for textstructurer
    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                lines.append(f"--- Chapter {idx}: {heading} ---")
            else:
                lines.append(f"--- Chapter {idx} ---")

            segments = ch.get("segments", [])
            current_sender = None
            current_speaker = ""
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                # Only clean HTML tags, preserve everything else
                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                # For textstructurer: show as paragraph with number
                if is_textstructurer(sender):
                    paragraph_counter += 1
                    lines.append(f"[{paragraph_counter}]")
                    lines.append(clean_text)
                    lines.append("")  # Single blank line between paragraphs
                # For asr and mt: show as plain text (no marker)
                elif is_asr_or_mt(sender):
                    speaker = _segment_speaker(seg)
                    if speaker and speaker != current_speaker:
                        current_speaker = speaker
                        if lines and lines[-1] != "":
                            lines.append("")
                        lines.append(f"{speaker}:")
                    if clean_text:
                        lines.append(clean_text)
                # For summarizer: show with "Summary:" prefix
                elif is_summarizer(sender):
                    lines.append(f"Summary: {clean_text}")
                # For other senders: show with sender name
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        lines.append(f"[{sender}]")
                    lines.append(clean_text)

            if not has_content:
                lines.append("(No content yet)")

            lines.append("")  # Single blank line between chapters
    else:
        # No chapters - show all transcripts
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            lines.append(f"--- {lang} ---")
            segments = selected_transcript.get("segments", [])
            current_sender = None
            current_speaker = ""

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    lines.append(f"[{paragraph_counter}]")
                    lines.append(clean_text)
                    lines.append("")
                elif is_asr_or_mt(sender):
                    speaker = _segment_speaker(seg)
                    if speaker and speaker != current_speaker:
                        current_speaker = speaker
                        if lines and lines[-1] != "":
                            lines.append("")
                        lines.append(f"{speaker}:")
                    if clean_text:
                        lines.append(clean_text)
                elif is_summarizer(sender):
                    lines.append(f"Summary: {clean_text}")
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        lines.append(f"[{sender}]")
                    lines.append(clean_text)

    # Summaries (filtered by language) - formatted differently
    if filtered_summaries:
        lines.append("=" * 60)
        lines.append("SUMMARIES")
        lines.append("-" * 40)
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            lines.append(f"  📋 {text}")
        lines.append("")

    # Global Summaries (filtered by language) - formatted differently
    if filtered_global_summaries:
        lines.append("=" * 60)
        lines.append("GLOBAL SUMMARIES")
        lines.append("-" * 40)
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            lines.append(f"  🌐 {text}")
        lines.append("")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        lines.append("=" * 60)
        lines.append("POST-EDITED CONTENT")
        lines.append("-" * 40)
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            lines.append(f"  [Compression: {rate}%] {text}")
        lines.append("")

    # Remove trailing empty lines and join with single newlines
    return "\n".join(lines).strip()


def export_structured_txt(session_id, session_dir, language_filter=None):
    """Export structured data as plain text matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        return io.BytesIO(b"No structured data available.")

    text = format_structured_text(structured_data, language_filter)

    header = "=" * 80 + "\n"
    header += f"SESSION: {session_id}\n"
    if language_filter:
        header += f"FILTER: {language_filter}\n"
    header += f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    header += "=" * 80 + "\n\n"

    return io.BytesIO((header + text).encode("utf-8"))


def export_structured_docx(session_id, session_dir, language_filter=None):
    """Export session data as DOCX matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        doc = Document()
        doc.add_heading("No structured data available", 1)
        return io.BytesIO()

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

    # Get language-specific data
    transcripts_data = structured_data.get("transcripts", [])
    selected_transcript = None
    lang_code = None

    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        doc.add_heading("Table of Contents", level=1)
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            p = doc.add_paragraph()
            p.add_run(f"{idx}. ").bold = True
            if heading:
                p.add_run(f"{heading}")
            else:
                p.add_run(f"Chapter {idx}")
        doc.add_paragraph("")

    # Transcripts with chapters
    doc.add_heading("Transcript", level=1)

    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                doc.add_heading(f"Chapter {idx}: {heading}", level=2)
            else:
                doc.add_heading(f"Chapter {idx}", level=2)

            segments = ch.get("segments", [])
            current_sender = None
            current_speaker = ""
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                if not text or not text.strip():
                    continue

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                # textstructurer: paragraph with number
                if is_textstructurer(sender):
                    paragraph_counter += 1
                    p = doc.add_paragraph()
                    run = p.add_run(f"[{paragraph_counter}]")
                    run.bold = True
                    run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)

                # asr and mt: plain text (no marker)
                elif is_asr_or_mt(sender):
                    speaker = _segment_speaker(seg)
                    if speaker and speaker != current_speaker:
                        current_speaker = speaker
                        p = doc.add_paragraph()
                        run = p.add_run(f"{speaker}:")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)

                # summarizer: with "Summary:" prefix
                elif is_summarizer(sender):
                    p = doc.add_paragraph()
                    run = p.add_run("Summary: ")
                    run.bold = True
                    run.font.color.rgb = RGBColor(255, 165, 0)  # Orange
                    p.add_run(clean_text)

                # other senders
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        p = doc.add_paragraph()
                        run = p.add_run(f"[{sender}]")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)

                    p = doc.add_paragraph()
                    p.add_run(clean_text)

            if not has_content:
                p = doc.add_paragraph()
                run = p.add_run("(No content yet)")
                run.italic = True
                run.font.size = Pt(10)

            doc.add_paragraph("")
    else:
        # No chapters - show selected transcript
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            doc.add_heading(lang, level=2)
            segments = selected_transcript.get("segments", [])
            current_sender = None
            current_speaker = ""
            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                if not text or not text.strip():
                    continue

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    p = doc.add_paragraph()
                    run = p.add_run(f"[{paragraph_counter}]")
                    run.bold = True
                    run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)
                elif is_asr_or_mt(sender):
                    speaker = _segment_speaker(seg)
                    if speaker and speaker != current_speaker:
                        current_speaker = speaker
                        p = doc.add_paragraph()
                        run = p.add_run(f"{speaker}:")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)
                    p = doc.add_paragraph()
                    p.add_run(clean_text)
                elif is_summarizer(sender):
                    p = doc.add_paragraph()
                    run = p.add_run("Summary: ")
                    run.bold = True
                    run.font.color.rgb = RGBColor(255, 165, 0)
                    p.add_run(clean_text)
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        p = doc.add_paragraph()
                        run = p.add_run(f"[{sender}]")
                        run.bold = True
                        run.font.color.rgb = RGBColor(0, 102, 204)

                    p = doc.add_paragraph()
                    p.add_run(clean_text)
            doc.add_paragraph("")

    # Summaries (filtered by language) - formatted with special style
    if filtered_summaries:
        doc.add_heading("Summaries", level=1)
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            p = doc.add_paragraph()
            p.add_run("📋 ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    # Global Summaries (filtered by language)
    if filtered_global_summaries:
        doc.add_heading("Global Summaries", level=1)
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            p = doc.add_paragraph()
            p.add_run("🌐 ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        doc.add_heading("Post-Edited Content", level=1)
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            p = doc.add_paragraph()
            p.add_run(f"[Compression: {rate}%] ").bold = True
            p.add_run(text)
        doc.add_paragraph("")

    doc_buffer = io.BytesIO()
    doc.save(doc_buffer)
    doc_buffer.seek(0)
    return doc_buffer


def export_structured_rtf(session_id, session_dir, language_filter=None):
    """Export structured data as RTF matching the window view."""
    structured_data = extract_structured_data_from_session(session_dir, language_filter)
    if not structured_data:
        return io.BytesIO(b"{\\rtf1\\ansi No structured data available.}")

    rtf_parts = [
        r"{\rtf1\ansi\deff0",
        r"{\fonttbl{\f0\fnil\fcharset0 Arial;}}",
        r"\f0\fs24",
        r"\b\fs32 Session: " + session_id + r"\b0\par\par",
    ]

    if language_filter:
        rtf_parts.append(r"\b\fs28 Filter: " + language_filter + r"\b0\par\par")

    rtf_parts.append(
        r"\b\fs28 Export Date: "
        + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        + r"\b0\par\par"
    )

    # Get language-specific data
    transcripts_data = structured_data.get("transcripts", [])
    selected_transcript = None
    lang_code = None

    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected_transcript = t
                break
        if not selected_transcript and transcripts_data:
            selected_transcript = transcripts_data[0]
    else:
        if transcripts_data:
            selected_transcript = transcripts_data[0]

    # Extract language code
    if selected_transcript:
        lang = selected_transcript.get("language", "")
        lang_code = extract_lang_code(lang)

    # Filter summaries by language
    all_summaries = structured_data.get("summaries", [])
    filtered_summaries = filter_summaries_by_language(all_summaries, lang_code)

    # Filter global summaries
    all_global_summaries = structured_data.get("global_summaries", [])
    filtered_global_summaries = filter_summaries_by_language(
        all_global_summaries, lang_code
    )

    # Filter post-edited
    all_post_edited = structured_data.get("post_edited", [])
    filtered_post_edited = filter_summaries_by_language(all_post_edited, lang_code)

    # Table of Contents
    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        rtf_parts.append(r"\b\fs26 Table of Contents\b0\par")
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            text = f"{idx}. "
            if heading:
                text += f"{heading}"
            else:
                text += f"Chapter {idx}"
            rtf_parts.append(r"\bullet " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Transcripts with chapters
    has_chapters = (
        structured_data.get("chapters") and len(structured_data["chapters"]) > 0
    )

    paragraph_counter = 0

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            if heading:
                rtf_parts.append(
                    r"\b\fs24 Chapter "
                    + str(idx)
                    + ": "
                    + escape_rtf(heading)
                    + r"\b0\par"
                )
            else:
                rtf_parts.append(r"\b\fs24 Chapter " + str(idx) + r"\b0\par")

            segments = ch.get("segments", [])
            current_sender = None
            current_speaker = ""
            has_content = False

            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                has_content = True

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    rtf_parts.append(
                        r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par"
                    )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_asr_or_mt(sender):
                    speaker = _segment_speaker(seg)
                    if speaker and speaker != current_speaker:
                        current_speaker = speaker
                        rtf_parts.append(
                            r"\par\b " + escape_rtf(f"{speaker}:") + r"\b0\par"
                        )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_summarizer(sender):
                    rtf_parts.append(
                        r"\b "
                        + "Summary: "
                        + r"\b0 "
                        + escape_rtf(clean_text)
                        + r"\par"
                    )
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        rtf_parts.append(
                            r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par"
                        )

                    rtf_parts.append(escape_rtf(clean_text) + r"\par")

            if not has_content:
                rtf_parts.append(r"\i (No content yet)\i0\par")

            rtf_parts.append(r"\par")
    else:
        # No chapters - show selected transcript
        if selected_transcript:
            lang = selected_transcript.get("language", "Unknown")
            rtf_parts.append(r"\b\fs24 " + escape_rtf(lang) + r"\b0\par")
            segments = selected_transcript.get("segments", [])
            current_sender = None
            current_speaker = ""
            for seg in segments:
                text = seg.get("text", "")
                sender = seg.get("sender", "")

                clean_text = clean_html_tags(text)
                if not clean_text:
                    continue

                if is_textstructurer(sender):
                    paragraph_counter += 1
                    rtf_parts.append(
                        r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par"
                    )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_asr_or_mt(sender):
                    speaker = _segment_speaker(seg)
                    if speaker and speaker != current_speaker:
                        current_speaker = speaker
                        rtf_parts.append(
                            r"\par\b " + escape_rtf(f"{speaker}:") + r"\b0\par"
                        )
                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
                elif is_summarizer(sender):
                    rtf_parts.append(
                        r"\b "
                        + "Summary: "
                        + r"\b0 "
                        + escape_rtf(clean_text)
                        + r"\par"
                    )
                else:
                    if sender != current_sender and sender:
                        current_sender = sender
                        rtf_parts.append(
                            r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par"
                        )

                    rtf_parts.append(escape_rtf(clean_text) + r"\par")
            rtf_parts.append(r"\par")

    # Summaries (filtered by language) - formatted with special style
    if filtered_summaries:
        rtf_parts.append(r"\b\fs26 Summaries\b0\par")
        for s in filtered_summaries:
            text = clean_html_tags(s.get("text", ""))
            if text:
                rtf_parts.append(r"\b " + "📋 " + r"\b0 " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Global Summaries (filtered by language)
    if filtered_global_summaries:
        rtf_parts.append(r"\b\fs26 Global Summaries\b0\par")
        for gs in filtered_global_summaries:
            text = clean_html_tags(gs.get("text", ""))
            if text:
                rtf_parts.append(r"\b " + "🌐 " + r"\b0 " + escape_rtf(text) + r"\par")
        rtf_parts.append(r"\par")

    # Post-edited content (filtered by language)
    if filtered_post_edited:
        rtf_parts.append(r"\b\fs26 Post-Edited Content\b0\par")
        for pe in filtered_post_edited:
            rate = pe.get("compression_rate", "N/A")
            text = clean_html_tags(pe.get("text", ""))
            if text:
                rtf_parts.append(
                    r"\b [Compression: "
                    + str(rate)
                    + r"%]\b0 "
                    + escape_rtf(text)
                    + r"\par"
                )
        rtf_parts.append(r"\par")

    rtf_parts.append("}")
    return io.BytesIO("".join(rtf_parts).encode("utf-8"))


def _resolve_export_language_name(session_dir, language):
    """Return the transcript language label for export filenames."""
    json_path = os.path.join(session_dir, "transcripts.json")
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
        for transcript in transcripts:
            lang = str(transcript.get("language", "")).strip()
            if not lang:
                continue
            if lang == language or language.lower() in lang.lower():
                return lang

    first_lang = transcripts[0].get("language", "transcript")
    return first_lang if first_lang else "transcript"


@app.route("/session-export-txt/<path:session_id>", methods=["GET"])
def session_export_txt(session_id):
    """Export all session data as structured plain text matching the window view."""
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
    filename = f"{clean_name}.txt"

    txt_buffer = export_structured_txt(session_id, session_dir, language)

    return send_file(
        txt_buffer,
        mimetype="text/plain",
        as_attachment=True,
        download_name=filename,
    )
