"""Export session transcripts to TXT / DOCX / RTF / JSON."""

from __future__ import annotations

import datetime
import io
import json
import os
import re

from docx import Document
from docx.shared import Pt, RGBColor

from .utils import extract_simple_language_name, safe_float


# ─── small helpers ─────────────────────────────────────────────────────
def clean_html_tags(text: str) -> str:
    if not text:
        return ""
    clean = re.sub(r"<[^>]+>", " ", text)
    clean = re.sub(r"\s+", " ", clean)
    return clean.strip()


def escape_rtf(text: str) -> str:
    if not text:
        return ""
    escaped = text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
    result = []
    for char in escaped:
        code = ord(char)
        result.append(f"\\u{code}?" if code > 127 else char)
    return "".join(result)


def get_paragraph_number(sender: str) -> int:
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
    if not sender:
        return False
    return sender.startswith(("asr:", "mt:", "translation:"))


def is_textstructurer(sender: str) -> bool:
    return bool(sender) and sender.startswith("textstructurer:")


def is_summarizer(sender: str) -> bool:
    return bool(sender) and sender.startswith("summarizer:")


def extract_lang_code(language_name: str) -> str | None:
    if not language_name:
        return None
    for code in ("en", "de", "fr", "es", "it", "pt", "nl", "ru", "ja",
                 "ko", "zh", "ar", "hi", "pl", "tr", "uk", "vi", "th",
                 "id", "ms"):
        if f"({code})" in language_name or f" - {code}" in language_name:
            return code
    return None


def _filter_summaries_by_language(summaries, lang_code):
    if not lang_code:
        return summaries
    filtered = [s for s in summaries if f"_{lang_code}" in s.get("sender", "")]
    return filtered if filtered else summaries


# ─── structured data extraction ────────────────────────────────────────
def extract_structured_data_from_session(session_dir_path, language_filter=None):
    json_path = os.path.join(session_dir_path, "transcripts.json")
    if not os.path.exists(json_path):
        return None
    with open(json_path, "r", encoding="utf-8") as f:
        all_transcripts = json.load(f)

    transcripts = ([t for t in all_transcripts
                    if t.get("language") == language_filter]
                   if language_filter else all_transcripts)

    structured_messages: list = []
    messages_path = os.path.join(session_dir_path, "messages.json")
    if os.path.exists(messages_path):
        try:
            with open(messages_path, "r", encoding="utf-8") as f:
                messages_data = json.load(f)
            if isinstance(messages_data, list):
                for item in messages_data:
                    if isinstance(item, list) and len(item) >= 2:
                        try:
                            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
                            if isinstance(m, dict):
                                structured_messages.append(m)
                        except (json.JSONDecodeError, TypeError):
                            pass
        except (json.JSONDecodeError, TypeError, OSError):
            pass

    structured = {
        "transcripts": [], "chapters": [], "summaries": [],
        "speakers": {}, "post_edited": [], "notes": [],
        "global_summaries": [], "paragraph_breaks": [],
    }
    for t in transcripts:
        structured["transcripts"].append({
            "language": t.get("language", "Unknown"),
            "text": t.get("text", ""),
            "segments": sorted(t.get("segments", []),
                               key=lambda x: safe_float(x.get("start", 0))),
            "sender": t.get("sender", ""),
        })

    chapter_stack: list = []
    for msg in sorted(structured_messages,
                      key=lambda x: safe_float(x.get("start", 0))):
        markup = msg.get("markup")
        sender = msg.get("sender", "")
        seq = msg.get("seq", "")
        start = safe_float(msg.get("start", 0))
        end = safe_float(msg.get("end", 0))

        if markup == "chapterBreak":
            chapter = {"start": start, "end": end,
                       "index": len(structured["chapters"]),
                       "heading": "", "segments": []}
            structured["chapters"].append(chapter)
            chapter_stack.append(chapter)
        elif markup == "heading" and chapter_stack:
            chapter_stack[-1]["heading"] = seq
        elif markup == "paragraphBreak":
            structured["paragraph_breaks"].append({"start": start, "end": end})
        elif markup == "summary":
            structured["summaries"].append(
                {"text": seq, "start": start, "end": end, "sender": sender})
        elif markup == "postedited":
            rate = "90"
            if ":" in sender:
                parts = sender.split(":")
                if len(parts) > 1 and "_" in parts[1]:
                    rate = parts[1].split("_")[0]
            structured["post_edited"].append({
                "text": seq, "start": start, "end": end,
                "compression_rate": rate, "sender": sender,
            })
        elif markup == "notes":
            structured["notes"].append({
                "text": seq, "start": start, "end": end,
                "nested_level": msg.get("nested_level", 0),
                "chapter_index": msg.get("chapter_index", 0),
            })
        elif markup == "global_summary":
            structured["global_summaries"].append({"text": seq, "sender": sender})

        if "refined_sentence_cluster" in msg:
            speaker = msg.get("refined_sentence_cluster")
            if speaker:
                if speaker.startswith("unk-"):
                    speaker = f"Anonymous-{speaker.split('-')[1]}"
                structured["speakers"][speaker] = {
                    "name": speaker,
                    "last_seen": datetime.datetime.now().isoformat(),
                }

    for transcript in structured["transcripts"]:
        for seg in transcript.get("segments", []):
            seg_start = safe_float(seg.get("start", 0))
            for ch in structured["chapters"]:
                ch_start = safe_float(ch.get("start", 0))
                ch_end = safe_float(ch.get("end", 0))
                if ch_start <= seg_start < ch_end or (
                    ch == structured["chapters"][-1] and seg_start >= ch_start
                ):
                    ch.setdefault("segments", []).append(seg)
                    break
    return structured


# ─── plain-text formatter ──────────────────────────────────────────────
def format_structured_text(structured_data, language_filter=None) -> str:
    if not structured_data:
        return "No structured data available."
    lines: list[str] = []

    transcripts_data = structured_data.get("transcripts", [])
    selected = None
    if language_filter:
        for t in transcripts_data:
            if t.get("language") == language_filter:
                selected = t
                break
        if not selected and transcripts_data:
            selected = transcripts_data[0]
    elif transcripts_data:
        selected = transcripts_data[0]

    lang_code = extract_lang_code(selected.get("language", "")) if selected else None
    filtered_summaries = _filter_summaries_by_language(
        structured_data.get("summaries", []), lang_code)
    filtered_global = _filter_summaries_by_language(
        structured_data.get("global_summaries", []), lang_code)
    filtered_pe = _filter_summaries_by_language(
        structured_data.get("post_edited", []), lang_code)

    if structured_data.get("chapters") and len(structured_data["chapters"]) > 1:
        lines.append("TABLE OF CONTENTS")
        lines.append("-" * 40)
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            lines.append(f"  {idx}. {heading or f'Chapter {idx}'}")
        lines.append("")

    paragraph_counter = 0
    has_chapters = bool(structured_data.get("chapters"))

    def emit_segment(seg):
        nonlocal paragraph_counter
        text = seg.get("text", "")
        sender = seg.get("sender", "")
        clean = clean_html_tags(text)
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
            lines.append(f"[{sender}]" if sender else "")
            lines.append(clean)

    if has_chapters:
        for ch in structured_data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            lines.append(f"--- Chapter {idx}: {heading} ---" if heading
                         else f"--- Chapter {idx} ---")
            for seg in ch.get("segments", []):
                emit_segment(seg)
            lines.append("")
    elif selected:
        lines.append(f"--- {selected.get('language', 'Unknown')} ---")
        for seg in selected.get("segments", []):
            emit_segment(seg)

    if filtered_summaries:
        lines.append("=" * 60); lines.append("SUMMARIES"); lines.append("-" * 40)
        for s in filtered_summaries:
            lines.append(f"  📋 {clean_html_tags(s.get('text', ''))}")
        lines.append("")
    if filtered_global:
        lines.append("=" * 60); lines.append("GLOBAL SUMMARIES"); lines.append("-" * 40)
        for gs in filtered_global:
            lines.append(f"  🌐 {clean_html_tags(gs.get('text', ''))}")
        lines.append("")
    if filtered_pe:
        lines.append("=" * 60); lines.append("POST-EDITED CONTENT"); lines.append("-" * 40)
        for pe in filtered_pe:
            rate = pe.get("compression_rate", "N/A")
            lines.append(f"  [Compression: {rate}%] {clean_html_tags(pe.get('text', ''))}")
        lines.append("")

    return "\n".join(lines).strip()


# ─── individual format writers ─────────────────────────────────────────
def export_structured_txt(session_id, session_dir_path, language_filter=None):
    data = extract_structured_data_from_session(session_dir_path, language_filter)
    if not data:
        return io.BytesIO(b"No structured data available.")
    text = format_structured_text(data, language_filter)
    header = ("=" * 80 + "\n"
              f"SESSION: {session_id}\n"
              + (f"FILTER: {language_filter}\n" if language_filter else "")
              + f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
              + "=" * 80 + "\n\n")
    return io.BytesIO((header + text).encode("utf-8"))


def export_structured_docx(session_id, session_dir_path, language_filter=None):
    data = extract_structured_data_from_session(session_dir_path, language_filter)
    if not data:
        doc = Document()
        doc.add_heading("No structured data available", 1)
        buf = io.BytesIO(); doc.save(buf); buf.seek(0)
        return buf

    doc = Document()
    title = f"Session: {session_id}"
    if language_filter:
        title += f" - {language_filter}"
    doc.add_heading(title, 0)
    doc.add_paragraph(f"Session ID: {session_id}")
    doc.add_paragraph(
        f"Export Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    doc.add_paragraph("")

    transcripts_data = data.get("transcripts", [])
    selected = None
    if language_filter:
        selected = next((t for t in transcripts_data
                         if t.get("language") == language_filter), None)
        if not selected and transcripts_data:
            selected = transcripts_data[0]
    elif transcripts_data:
        selected = transcripts_data[0]

    lang_code = extract_lang_code(selected.get("language", "")) if selected else None
    filtered_summaries = _filter_summaries_by_language(data.get("summaries", []), lang_code)
    filtered_global = _filter_summaries_by_language(data.get("global_summaries", []), lang_code)
    filtered_pe = _filter_summaries_by_language(data.get("post_edited", []), lang_code)

    if data.get("chapters") and len(data["chapters"]) > 1:
        doc.add_heading("Table of Contents", level=1)
        for ch in data["chapters"]:
            idx = ch.get("index", 0) + 1
            p = doc.add_paragraph()
            p.add_run(f"{idx}. ").bold = True
            p.add_run(ch.get("heading") or f"Chapter {idx}")
        doc.add_paragraph("")

    doc.add_heading("Transcript", level=1)
    paragraph_counter = 0

    def emit_docx(seg):
        nonlocal paragraph_counter
        text = seg.get("text", "")
        sender = seg.get("sender", "")
        clean = clean_html_tags(text)
        if not clean:
            return
        if is_textstructurer(sender):
            paragraph_counter += 1
            p = doc.add_paragraph()
            run = p.add_run(f"[{paragraph_counter}]")
            run.bold = True
            run.font.color.rgb = RGBColor(0, 102, 204)
            doc.add_paragraph(clean)
        elif is_asr_or_mt(sender):
            doc.add_paragraph(clean)
        elif is_summarizer(sender):
            p = doc.add_paragraph()
            run = p.add_run("Summary: ")
            run.bold = True
            run.font.color.rgb = RGBColor(255, 165, 0)
            p.add_run(clean)
        else:
            if sender:
                p = doc.add_paragraph()
                run = p.add_run(f"[{sender}]")
                run.bold = True
                run.font.color.rgb = RGBColor(0, 102, 204)
            doc.add_paragraph(clean)

    if data.get("chapters"):
        for ch in data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            doc.add_heading(f"Chapter {idx}: {heading}" if heading
                            else f"Chapter {idx}", level=2)
            for seg in ch.get("segments", []):
                emit_docx(seg)
            doc.add_paragraph("")
    elif selected:
        doc.add_heading(selected.get("language", "Unknown"), level=2)
        for seg in selected.get("segments", []):
            emit_docx(seg)

    if filtered_summaries:
        doc.add_heading("Summaries", level=1)
        for s in filtered_summaries:
            p = doc.add_paragraph()
            p.add_run("📋 ").bold = True
            p.add_run(clean_html_tags(s.get("text", "")))
    if filtered_global:
        doc.add_heading("Global Summaries", level=1)
        for gs in filtered_global:
            p = doc.add_paragraph()
            p.add_run("🌐 ").bold = True
            p.add_run(clean_html_tags(gs.get("text", "")))
    if filtered_pe:
        doc.add_heading("Post-Edited Content", level=1)
        for pe in filtered_pe:
            p = doc.add_paragraph()
            p.add_run(f"[Compression: {pe.get('compression_rate', 'N/A')}%] ").bold = True
            p.add_run(clean_html_tags(pe.get("text", "")))

    buf = io.BytesIO(); doc.save(buf); buf.seek(0)
    return buf


def export_structured_rtf(session_id, session_dir_path, language_filter=None):
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
    parts.append(r"\b\fs28 Export Date: "
                 + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                 + r"\b0\par\par")

    transcripts_data = data.get("transcripts", [])
    selected = None
    if language_filter:
        selected = next((t for t in transcripts_data
                         if t.get("language") == language_filter), None)
        if not selected and transcripts_data:
            selected = transcripts_data[0]
    elif transcripts_data:
        selected = transcripts_data[0]

    lang_code = extract_lang_code(selected.get("language", "")) if selected else None
    fs = _filter_summaries_by_language(data.get("summaries", []), lang_code)
    fg = _filter_summaries_by_language(data.get("global_summaries", []), lang_code)
    fp = _filter_summaries_by_language(data.get("post_edited", []), lang_code)

    paragraph_counter = 0

    def emit_rtf(seg):
        nonlocal paragraph_counter
        text = seg.get("text", "")
        sender = seg.get("sender", "")
        clean = clean_html_tags(text)
        if not clean:
            return
        if is_textstructurer(sender):
            paragraph_counter += 1
            parts.append(r"\b " + escape_rtf(f"[{paragraph_counter}]") + r"\b0\par")
            parts.append(escape_rtf(clean) + r"\par")
        elif is_asr_or_mt(sender):
            parts.append(escape_rtf(clean) + r"\par")
        elif is_summarizer(sender):
            parts.append(r"\b Summary: \b0 " + escape_rtf(clean) + r"\par")
        else:
            if sender:
                parts.append(r"\b " + escape_rtf(f"[{sender}]") + r"\b0\par")
            parts.append(escape_rtf(clean) + r"\par")

    if data.get("chapters"):
        for ch in data["chapters"]:
            idx = ch.get("index", 0) + 1
            heading = ch.get("heading", "")
            parts.append(r"\b\fs24 Chapter " + str(idx)
                         + (": " + escape_rtf(heading) if heading else "")
                         + r"\b0\par")
            for seg in ch.get("segments", []):
                emit_rtf(seg)
            parts.append(r"\par")
    elif selected:
        parts.append(r"\b\fs24 " + escape_rtf(selected.get("language", "Unknown"))
                     + r"\b0\par")
        for seg in selected.get("segments", []):
            emit_rtf(seg)

    if fs:
        parts.append(r"\b\fs26 Summaries\b0\par")
        for s in fs:
            parts.append(r"\b 📋 \b0 " + escape_rtf(clean_html_tags(s.get("text", "")))
                         + r"\par")
    if fg:
        parts.append(r"\b\fs26 Global Summaries\b0\par")
        for gs in fg:
            parts.append(r"\b 🌐 \b0 " + escape_rtf(clean_html_tags(gs.get("text", "")))
                         + r"\par")
    if fp:
        parts.append(r"\b\fs26 Post-Edited Content\b0\par")
        for pe in fp:
            parts.append(
                r"\b [Compression: " + str(pe.get("compression_rate", "N/A"))
                + r"%]\b0 " + escape_rtf(clean_html_tags(pe.get("text", "")))
                + r"\par")

    parts.append("}")
    return io.BytesIO("".join(parts).encode("utf-8"))


def get_available_languages(session_dir_path) -> list[str]:
    json_path = os.path.join(session_dir_path, "transcripts.json")
    if not os.path.exists(json_path):
        return []
    with open(json_path, "r", encoding="utf-8") as f:
        transcripts = json.load(f)
    return sorted({t.get("language", "Unknown") for t in transcripts})


def resolve_export_language_name(session_dir_path, language) -> str:
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
    clean = name.replace(" ", "_").replace("(", "").replace(")", "")
    clean = clean.replace("/", "_").replace("\\", "_").replace(":", "_")
    clean = re.sub(r"[^a-zA-Z0-9_-]", "", clean)
    return clean[:50]