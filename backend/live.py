"""Live microphone sessions: relay blueprint + Session Output files.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import io
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import threading

from .paths import DATA_DIR
from .flask_app import app
from .servers import INTERNAL_SERVER_URL, _is_allowed_server


# ─── Live microphone ASR relay (/api/live/...) ───────────────────
# Imported both ways so it works under gunicorn (`lib.backend:app`)
# and when backend.py is run directly as a script.
from .live_relay import create_live_blueprint
from . import live_relay as _live_relay_mod


def _resolve_live_server(requested: str | None) -> str:
    """Allow-listed KIT base URL for a live session (no trailing slash)."""
    if requested and _is_allowed_server(requested):
        return requested.rstrip("/")
    if requested:
        logging.warning("Rejected unknown live target server: %r", requested)
    return INTERNAL_SERVER_URL.rstrip("/")


# Finished live sessions are kept on the persistent `state` volume —
# NOT under SESSION_FOLDER, which /clear-videos wipes wholesale.
LIVE_SESSIONS_DIR = os.path.join(DATA_DIR, "state", "live_sessions")

def _decode_tts_chunk(chunk: dict, rate: int) -> bytes | None:
    """One TTS chunk → mono 16-bit PCM at `rate`. Handles WAV chunks
    directly; raw PCM by its declared rate; anything else via ffmpeg."""
    import wave

    audio = chunk.get("audio") or b""
    key = (chunk.get("key") or "").lower()
    if audio[:4] == b"RIFF":
        try:
            with wave.open(io.BytesIO(audio), "rb") as w:
                if (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (rate, 1, 2):
                    return w.readframes(w.getnframes())
        except (wave.Error, EOFError):
            pass
        src = ["-f", "wav"]
    elif "pcm" in key or "s16" in key:
        if (chunk.get("rate") or 16000) == rate:
            return audio[: len(audio) - len(audio) % 2]  # already right
        src = ["-f", "s16le", "-ar", str(chunk.get("rate") or 16000), "-ac", "1"]
    else:
        src = []  # let ffmpeg detect (opus/ogg/mp3/webm…)
    try:
        r = subprocess.run(
            ["ffmpeg", "-loglevel", "error", *src, "-i", "pipe:0",
             "-f", "s16le", "-ac", "1", "-ar", str(rate), "pipe:1"],
            input=audio, capture_output=True, timeout=60, check=True,
        )
        return r.stdout or None
    except (OSError, subprocess.SubprocessError):
        return None


def _build_live_tts_wavs(session_dir: str, chunks: list, label_for) -> list:
    """Write tts_<Language>.wav per spoken-translation language, each chunk
    placed at its start time (silence in between), so the WAV lines up with
    live_audio.mp4 exactly like KIT's archived TTS tracks."""
    import wave

    by_lane: dict = {}
    for c in chunks:
        by_lane.setdefault(c.get("lane") or "tts", []).append(c)

    written = []
    for lane, items in by_lane.items():
        rate = items[0].get("rate") or 24000  # raw PCM: its own rate
        first = items[0].get("audio") or b""
        if first[:4] == b"RIFF":
            try:
                with wave.open(io.BytesIO(first), "rb") as w:
                    rate = w.getframerate()
            except (wave.Error, EOFError):
                pass
        pcm = bytearray()
        decoded = 0
        for c in sorted(items, key=lambda x: safe_float(x.get("start") or 0)):
            data = _decode_tts_chunk(c, rate)
            if not data:
                continue
            decoded += 1
            start = c.get("start")
            if start is not None:
                target = int(safe_float(start) * rate) * 2
                if target > len(pcm):
                    pcm.extend(b"\x00" * (target - len(pcm)))
            pcm.extend(data)
        if not pcm:
            logging.warning(
                "live: TTS %r — none of %d chunk(s) could be decoded (field %r)",
                lane, len(items), items[0].get("key"),
            )
            continue
        simple = _extract_simple_language_name(label_for(lane))
        name = "tts_{}.wav".format(re.sub(r"[^0-9A-Za-z_\-]", "_", simple))
        # Complete file first, under a name Session Output does not list,
        # so a half-written WAV is never offered for playback.
        partial = os.path.join(
            os.path.dirname(session_dir),
            f".{os.path.basename(session_dir)}.{name}.part",
        )
        with wave.open(partial, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(bytes(pcm))
        os.replace(partial, os.path.join(session_dir, name))
        written.append(name)
        logging.info(
            "live: wrote %s (%d/%d chunks, %.1f s)",
            name, decoded, len(items), len(pcm) / 2 / rate,
        )
    return written


def _finalize_live_session(info: dict) -> str | None:
    """Turn a finished live recording into a normal session folder, so the
    Session Output screen (transcripts, VTTs, editing, exports) works for
    live sessions exactly as for uploaded videos.

    Called by live_relay once per live session, after the last results.
    Writes messages.json (archive shape), transcripts.json/.txt, one VTT
    per language and — in the background — live_audio.mp4 from the
    microphone audio. Returns the session id (= KIT's live session id).
    """
    session_id = str(info.get("session_id") or "")
    messages = info.get("messages") or []
    if not session_id or not messages:
        logging.info("live: nothing recorded for %s — no output", session_id)
        return None

    def lang_name(code: str) -> str:
        return LANGUAGE_NAMES.get((code or "").lower(), code)

    inputs = info.get("input_languages") or []
    asr_label = "Transcript (Original ASR - {})".format(
        ", ".join(lang_name(c) for c in inputs) or "Speaker"
    )

    def label_for(lane: str) -> str:
        if lane == "asr":
            return asr_label
        if re.fullmatch(r"[a-z]{2,3}", lane or ""):
            return f"{lang_name(lane)} Translation ({lane})"
        return f"Translation ({lane})"  # KIT gave no language for it

    name = (info.get("name") or "").strip() or f"live_{session_id[:12]}"
    if session_id not in sessions:
        sessions[session_id] = {
            "id": session_id,
            "name": name,
            "local_name": _unique_local_name(name),
            "video_key": None,
            "source": "live",
            "created_at": utc_now_iso(),
            "url": f"{info.get('server', '')}/present/{session_id}",
            "server": info.get("server"),
            "expected_mt": info.get("output_languages") or [],
            "token": info.get("token"),
        }
    session_dir = _session_dir(session_id)
    os.makedirs(session_dir, exist_ok=True)

    # messages.json in the archive's [[lang_id, "<json>"], …] shape
    with open(os.path.join(session_dir, "messages.json"), "w", encoding="utf-8") as f:
        json.dump(
            [[m.get("_lane", ""), json.dumps(m, ensure_ascii=False)] for m in messages],
            f,
            ensure_ascii=False,
        )

    raw = []
    for m in messages:
        text = (m.get("seq") or m.get("text") or m.get("translation") or "").strip()
        if not text:
            continue
        lane = m.get("_lane", "")
        raw.append(
            {
                "language": label_for(lane),
                "source_file": f"lang_{lane}",
                "text": text,
                "sender": m.get("sender", ""),
                "segments": [
                    {
                        "text": text,
                        "start": safe_float(m.get("start", 0)),
                        "end": safe_float(m.get("end", 0)),
                        "sender": m.get("sender", ""),
                        "markup": m.get("markup"),
                        "words": m.get("words"),
                        "word_id": m.get("word_id"),
                        "source_tokens": m.get("sourceTokens"),
                        "speaker_name": m.get("speakerName"),
                        "refined_sentence_cluster": m.get("refined_sentence_cluster"),
                        "unstable": False,
                        "message_id": m.get("message_id"),
                    }
                ],
            }
        )
    transcripts = organize_transcripts(raw)
    # Original first, then translations A→Z, unidentified ones last.
    transcripts.sort(
        key=lambda t: (
            0 if t["language"] == asr_label
            else 2 if t["language"].startswith("Translation (")
            else 1,
            t["language"].lower(),
        )
    )
    save_transcripts_to_files(session_dir, transcripts)
    vtts = generate_vtt_files_from_transcripts(session_dir)
    save_state(force=True)
    logging.info(
        "live: session %s → %s (%d languages, %d VTT)",
        _short_sid(session_id), session_dir, len(transcripts), len(vtts),
    )

    # Spoken translations (TTS) → tts_<Language>.wav, off the request thread.
    tts_chunks = info.get("tts_chunks") or []
    if tts_chunks:
        threading.Thread(
            target=lambda: _build_live_tts_wavs(session_dir, tts_chunks, label_for),
            daemon=True,
        ).start()
    else:
        logging.info(
            "live: no spoken-translation audio in the stream for %s "
            "(audio languages: %s)",
            _short_sid(session_id), info.get("audio_languages") or "none",
        )

    # Microphone audio → live_audio.mp4 (AAC), off the request thread.
    pcm_path = info.get("pcm_path")
    if pcm_path and os.path.exists(pcm_path) and os.path.getsize(pcm_path) > 0:
        # Out of the session folder, so it never shows up as an output file.
        fd, kept = tempfile.mkstemp(prefix="live_keep_", suffix=".pcm")
        os.close(fd)
        try:
            shutil.move(pcm_path, kept)
        except OSError as e:
            logging.warning("live: could not keep audio for %s: %s", session_id, e)
            return session_id

        def _encode():
            out = os.path.join(session_dir, "live_audio.mp4")
            # Encode next to the session folder under a name Session Output
            # does not list, and rename only when complete: an MP4 is not
            # playable until ffmpeg has finished writing its index, and a
            # half-written file makes the browser fail with
            # MEDIA_ERR_SRC_NOT_SUPPORTED.
            partial = os.path.join(
                os.path.dirname(session_dir), f".{os.path.basename(session_dir)}.live_audio.part.mp4"
            )
            try:
                subprocess.run(
                    [
                        "ffmpeg", "-y", "-loglevel", "error",
                        "-f", "s16le", "-ar", str(info.get("sample_rate", 16000)),
                        "-ac", "1", "-i", kept,
                        "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart",
                        partial,
                    ],
                    check=True,
                    capture_output=True,
                    timeout=1800,
                )
                os.replace(partial, out)
                logging.info("live: audio saved for %s", _short_sid(session_id))
            except FileNotFoundError:
                logging.warning(
                    "live: audio encoding failed for %s: ffmpeg not found "
                    "(install ffmpeg and put it on PATH)", session_id,
                )
            except (OSError, subprocess.SubprocessError) as e:
                err = getattr(e, "stderr", b"") or b""
                logging.warning(
                    "live: audio encoding failed for %s: %s %s",
                    session_id, e, err.decode("utf-8", "replace")[-300:],
                )
            finally:
                for leftover in (kept, partial):
                    try:
                        os.remove(leftover)
                    except OSError:
                        pass

        threading.Thread(target=_encode, daemon=True).start()
    return session_id


app.register_blueprint(
    create_live_blueprint(
        _resolve_live_server, LIVE_SESSIONS_DIR, on_finished=_finalize_live_session
    )
)


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global LANGUAGE_NAMES, _extract_simple_language_name, _session_dir
    global _short_sid, _unique_local_name
    global generate_vtt_files_from_transcripts, organize_transcripts
    global safe_float, save_state, save_transcripts_to_files, sessions
    global utc_now_iso
    from .config import LANGUAGE_NAMES, sessions
    from .state import save_state
    from .utils import _session_dir, _short_sid, _unique_local_name, utc_now_iso
    from .transcripts import (
        generate_vtt_files_from_transcripts,
        organize_transcripts,
        safe_float,
        save_transcripts_to_files,
    )
    from .routes_sessions import _extract_simple_language_name
