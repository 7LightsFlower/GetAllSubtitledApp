"""Transcript exports (TXT / DOCX / RTF) that look like Session Output.

One language per file, built from the same transcripts.json the Session
Output screen shows:

    <Video or session name>
    Language · Date · Duration

    Global summary (once, at the top)

    Heading
    Speaker
    Running text, one paragraph per speaker / paragraph break …
        Summary: …            (chapter summaries where they occur)

Only the chosen language is included — its own summaries, headings and
notes come with it (KIT sends those per language). The file is named
"<name> - <Language>.<ext>".
"""

import datetime
import io
import json
import os
import re

from .config import sessions, videos
from .transcripts import _segment_speaker, safe_float

# ── data ────────────────────────────────────────────────────────────────


def export_title(session_id: str) -> str:
    """Video name (as renamed in the app), the live session's own name,
    or the session's name — never the raw session id."""
    sess = sessions.get(session_id) or {}
    key = sess.get("video_key")
    if key:
        for v in videos:
            if v.get("key") == key and (v.get("name") or "").strip():
                return v["name"].strip()
    if sess.get("source") == "live":
        try:
            from . import live_relay

            title = live_relay.saved_title_for_output(session_id)
            if title:
                return title
        except Exception:  # never let the name break an export
            pass
    name = (sess.get("name") or "").strip()
    return name or "Transcript"


def _load_transcripts(session_dir: str) -> list:
    path = os.path.join(session_dir, "transcripts.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def pick_transcript(session_dir: str, language: str | None) -> dict | None:
    transcripts = _load_transcripts(session_dir)
    if not transcripts:
        return None
    if language:
        lang = language.strip().lower()
        for t in transcripts:
            if str(t.get("language", "")).strip().lower() == lang:
                return t
        for t in transcripts:
            if lang in str(t.get("language", "")).lower():
                return t
    return transcripts[0]


_NO_SPACE = re.compile(r"[　-鿿豈-﫿＀-￯฀-๿]")


def _join(parts: list[str]) -> str:
    """Running text: a space between segments, none inside CJK/Thai."""
    out = ""
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if out and not (_NO_SPACE.match(out[-1]) and _NO_SPACE.match(p[0])):
            out += " "
        out += p
    return out


def _clean(text: str) -> str:
    text = re.sub(r"<br\s*/?>", " ", text or "", flags=re.I)
    return re.sub(r"<[^>]+>", "", text).strip()


def build_blocks(transcript: dict) -> tuple[list[str], list[tuple[str, str]]]:
    """(global summaries, body blocks) for one language.

    Block kinds: heading, speaker, para, summary, notes, postedited.
    """
    segs = [s for s in transcript.get("segments") or [] if isinstance(s, dict)]
    segs = [s for s in segs if not s.get("unstable")]
    segs.sort(key=lambda s: safe_float(s.get("start", 0)))

    global_summaries: list[str] = []
    blocks: list[tuple[str, str]] = []
    buf: list[str] = []
    speaker = ""
    last_box = {}

    def flush():
        if buf:
            blocks.append(("para", _join(buf)))
            buf.clear()

    for s in segs:
        raw = s.get("text") or ""
        markup = s.get("markup")
        if markup == "paragraphBreak" or (not markup and "<br" in raw.lower()
                                          and not _clean(raw)):
            flush()
            continue
        text = _clean(raw)
        if not text:
            continue
        if markup == "global_summary":
            if text not in global_summaries:
                global_summaries.append(text)
            continue
        if markup in ("summary", "notes", "postedited"):
            flush()
            if last_box.get(markup) != text:  # KIT repeats them
                blocks.append((markup, text))
                last_box[markup] = text
            continue
        if markup == "heading":
            flush()
            blocks.append(("heading", text))
            continue
        if markup:  # chapterBreak and other markers without text to show
            flush()
            continue
        name = _segment_speaker(s)
        if name and name != speaker:
            flush()
            speaker = name
            blocks.append(("speaker", name))
        buf.append(text)
    flush()
    return global_summaries, blocks


def _meta_line(transcript: dict, session_id: str) -> str:
    language = str(transcript.get("language") or "").strip()
    sess = sessions.get(session_id) or {}
    date = (sess.get("created_at") or "")[:10]
    segs = transcript.get("segments") or []
    end = max((safe_float(s.get("end", 0)) for s in segs if isinstance(s, dict)),
              default=0.0)
    parts = [p for p in (language, date) if p]
    if end > 0:
        m, sec = divmod(int(end), 60)
        h, m = divmod(m, 60)
        parts.append(f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}")
    parts.append("Exported " + datetime.datetime.now().strftime("%Y-%m-%d %H:%M"))
    return " · ".join(parts)


def file_name(title: str, transcript: dict | None, ext: str) -> str:
    lang = str((transcript or {}).get("language") or "").strip()
    base = f"{title} - {lang}" if lang else title
    base = re.sub(r'[\\/:*?"<>|\r\n\t]+', " ", base)
    base = re.sub(r"\s+", " ", base).strip()[:120] or "transcript"
    return f"{base}.{ext}"


_LABELS = {
    "summary": "Summary",
    "notes": "Notes",
    "postedited": "Post-edited",
}

# ── writers ─────────────────────────────────────────────────────────────


def to_txt(title: str, meta: str, gsum: list[str], blocks) -> bytes:
    out = [title, meta, "=" * min(max(len(title), 20), 80), ""]
    if gsum:
        out += ["GLOBAL SUMMARY", ""]
        for g in gsum:
            out += [g, ""]
        out += ["-" * 40, ""]
    for kind, text in blocks:
        if kind == "heading":
            out += ["", text.upper(), ""]
        elif kind == "speaker":
            out += [f"[{text}]"]
        elif kind == "para":
            out += [text, ""]
        else:
            out += [f"    {_LABELS[kind]}: {text}", ""]
    return ("\n".join(out).rstrip() + "\n").encode("utf-8")


def to_docx(title: str, meta: str, gsum: list[str], blocks) -> io.BytesIO:
    from docx import Document
    from docx.shared import Pt, RGBColor

    doc = Document()
    doc.add_heading(title, 0)
    p = doc.add_paragraph()
    r = p.add_run(meta)
    r.font.size = Pt(9)
    r.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

    if gsum:
        doc.add_heading("Global Summary", level=2)
        for g in gsum:
            p = doc.add_paragraph()
            r = p.add_run(g)
            r.italic = True
            r.font.color.rgb = RGBColor(0x5B, 0x2C, 0x83)  # purple, as on screen

    for kind, text in blocks:
        if kind == "heading":
            doc.add_heading(text, level=2)
        elif kind == "speaker":
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(10)
            p.paragraph_format.space_after = Pt(0)
            r = p.add_run(text)
            r.bold = True
            r.font.size = Pt(9)
            r.font.color.rgb = RGBColor(0x15, 0x65, 0xC0)  # speaker chip blue
        elif kind == "para":
            p = doc.add_paragraph(text)
            p.paragraph_format.space_after = Pt(8)
            p.paragraph_format.line_spacing = 1.2
        else:
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Pt(18)
            r = p.add_run(f"{_LABELS[kind]}: ")
            r.bold = True
            r.font.color.rgb = RGBColor(0x2E, 0x7D, 0x32)  # summary green
            r2 = p.add_run(text)
            r2.italic = True
    buf = io.BytesIO()
    doc.save(buf)
    buf.seek(0)
    return buf


def _rtf(text: str) -> str:
    out = []
    for ch in text:
        c = ord(ch)
        if ch in "\\{}":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\line ")
        elif c < 128:
            out.append(ch)
        elif c <= 0xFFFF:
            out.append(f"\\u{c - 65536 if c > 32767 else c}?")
        else:  # outside the BMP (emoji): UTF-16 surrogate pair
            c -= 0x10000
            for u in (0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF)):
                out.append(f"\\u{u - 65536}?")
    return "".join(out)


def to_rtf(title: str, meta: str, gsum: list[str], blocks) -> bytes:
    rtf = [
        r"{\rtf1\ansi\ansicpg1252\deff0\uc1",
        r"{\fonttbl{\f0\fswiss Arial;}}",
        r"{\colortbl;\red102\green102\blue102;\red91\green44\blue131;"
        r"\red21\green101\blue192;\red46\green125\blue50;}",
        r"\f0\fs22",
        r"{\pard\sa120\b\fs36 " + _rtf(title) + r"\par}",
        r"{\pard\sa240\cf1\fs18 " + _rtf(meta) + r"\par}",
    ]
    if gsum:
        rtf.append(r"{\pard\sa80\b\fs26 Global Summary\par}")
        for g in gsum:
            rtf.append(r"{\pard\sa160\i\cf2 " + _rtf(g) + r"\par}")
    for kind, text in blocks:
        if kind == "heading":
            rtf.append(r"{\pard\sb240\sa120\b\fs26 " + _rtf(text) + r"\par}")
        elif kind == "speaker":
            rtf.append(r"{\pard\sb160\b\fs18\cf3 " + _rtf(text) + r"\par}")
        elif kind == "para":
            rtf.append(r"{\pard\sa160\sl276\slmult1 " + _rtf(text) + r"\par}")
        else:
            rtf.append(r"{\pard\li360\sa160{\b\cf4 " + _rtf(_LABELS[kind] + ": ")
                       + r"}{\i " + _rtf(text) + r"}\par}")
    rtf.append("}")
    return "\n".join(rtf).encode("ascii")


def build_export(session_id: str, session_dir: str, language: str | None,
                 fmt: str):
    """(bytes or BytesIO, file name, mimetype) for txt / docx / rtf."""
    transcript = pick_transcript(session_dir, language) or {"segments": []}
    title = export_title(session_id)
    gsum, blocks = build_blocks(transcript)
    meta = _meta_line(transcript, session_id)
    name = file_name(title, transcript, fmt)
    if fmt == "docx":
        return (to_docx(title, meta, gsum, blocks), name,
                "application/vnd.openxmlformats-officedocument"
                ".wordprocessingml.document")
    if fmt == "rtf":
        return io.BytesIO(to_rtf(title, meta, gsum, blocks)), name, "application/rtf"
    return io.BytesIO(to_txt(title, meta, gsum, blocks)), name, "text/plain; charset=utf-8"
