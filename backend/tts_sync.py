"""Put KIT's TTS tracks of a video in time with the original.

KIT's archived "<Language> Audio.wav" is every TTS piece joined one after
another. Russian is shorter than English, so the track ends minutes early
and drifts away from the video. The archive keeps no timing of the TTS
pieces, but the translated transcript has a start time for every segment.

So, per TTS language:

  1. Find the pauses in KIT's WAV (ffmpeg silencedetect).
  2. Walk the translated segments in order: a segment's speech takes about
     (its characters × the track's speaking rate). Cut the WAV at the
     pause closest to where the next segment should begin. Where no pause
     is near, the segment stays joined to the one before.
  3. Put every piece at its segment's start time in the original; silence
     in between. A piece longer than its slot is sped up a little
     (≤ MAX_TEMPO); what is still too long pushes the next piece later.
  4. Pad to the length of the original.

KIT's file is kept in _kit_tts/ (re-syncing starts from it), so the step
is safe to repeat. Live sessions are skipped: their WAVs are built from
timestamped pieces already (live.py).
"""

import json
import logging
import os
import re
import shutil
import subprocess
import threading

from .transcripts import safe_float

RATE = 24000          # working sample rate (mono, 16 bit)
MAX_TEMPO = 1.25      # fastest speed-up that still sounds natural
MIN_GAP_S = 0.12      # shorter quiet parts are inside a sentence
NOISE_DB = -42        # quieter than this counts as silence
KIT_DIR = "_kit_tts"  # KIT's original files

_running: set = set()
_lock = threading.Lock()


# ── helpers ─────────────────────────────────────────────────────────────


def _decode(path: str) -> bytes:
    """Any WAV → raw s16le mono at RATE."""
    r = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", path,
         "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
        capture_output=True, check=True,
    )
    return r.stdout


def _silences(pcm: bytes) -> list[tuple[float, float]]:
    """(start, end) of every pause ≥ MIN_GAP_S, in seconds."""
    r = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "info", "-f", "s16le", "-ar", str(RATE),
         "-ac", "1", "-i", "-",
         "-af", f"silencedetect=noise={NOISE_DB}dB:d={MIN_GAP_S}",
         "-f", "null", "-"],
        input=pcm, capture_output=True,
    )
    out = r.stderr.decode("utf-8", "replace")
    starts = [float(x) for x in re.findall(r"silence_start: (-?[\d.]+)", out)]
    ends = [float(x) for x in re.findall(r"silence_end: (-?[\d.]+)", out)]
    total = len(pcm) / 2 / RATE
    gaps = []
    for i, s in enumerate(starts):
        e = ends[i] if i < len(ends) else total
        gaps.append((max(0.0, s), min(total, e)))
    return gaps


def _tempo(pcm: bytes, factor: float) -> bytes:
    if factor <= 1.01 or not pcm:
        return pcm
    r = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-f", "s16le", "-ar", str(RATE),
         "-ac", "1", "-i", "-", "-af", f"atempo={factor:.4f}",
         "-f", "s16le", "-"],
        input=pcm, capture_output=True,
    )
    return r.stdout if r.returncode == 0 and r.stdout else pcm


def _write_wav(path: str, pcm: bytes) -> None:
    import wave

    tmp = path + ".part"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
    os.replace(tmp, path)


def _speech_segments(transcript: dict) -> list[tuple[float, int]]:
    """(start, characters) of the spoken segments, in order."""
    out = []
    for s in transcript.get("segments") or []:
        if not isinstance(s, dict) or s.get("unstable") or s.get("markup"):
            continue
        text = re.sub(r"<[^>]+>", " ", str(s.get("text") or "")).strip()
        if not text:
            continue
        out.append((safe_float(s.get("start", 0)), len(text)))
    out.sort(key=lambda x: x[0])
    if out and out[0][0] > 1e8:  # absolute times → relative to the first
        t0 = out[0][0]
        out = [(t - t0, c) for t, c in out]
    return out


def _total_length(transcripts: list) -> float:
    end = 0.0
    for t in transcripts:
        for s in t.get("segments") or []:
            if isinstance(s, dict):
                end = max(end, safe_float(s.get("end", 0)))
    return end if end < 1e8 else 0.0


# ── alignment ───────────────────────────────────────────────────────────


def _cut_points(segs, gaps, total_s):
    """For each segment (speech begins, pause before it began) in seconds
    of KIT's WAV, or None when it stays joined to the segment before.

    Global alignment (dynamic programming): every cut goes into a pause
    near where the text predicts it, consecutive pieces must have about
    the length their text needs, and long pauses (sentence breaks) are
    preferred to short ones (breaths inside a sentence). Up to MAX_JOIN
    segments may stay joined where KIT left no pause between them.
    """
    n = len(segs)
    speech_start = gaps[0][1] if gaps and gaps[0][0] <= 0.05 else 0.0
    speech_end = gaps[-1][0] if gaps and gaps[-1][1] >= total_s - 0.05 else total_s
    inner = [g for g in gaps if g[0] > speech_start + 0.05 and g[1] < speech_end - 0.05]

    cum = [0]
    for _, c in segs:
        cum.append(cum[-1] + c)
    rate = max(speech_end - speech_start, 0.1) / max(cum[-1], 1)

    MAX_JOIN = 3

    def dev(d, chars):
        e = rate * chars
        return ((d - e) / (0.2 * e + 0.4)) ** 2

    def trap(g):
        return 1.5 * (1.0 - min((g[1] - g[0]) / 0.5, 1.0))

    # Candidate pauses per boundary j (between segment j-1 and j).
    mids = [(a + b) / 2 for a, b in inner]
    cands = [[(speech_start, None)]]          # j = 0: the start
    import bisect
    for j in range(1, n):
        est = speech_start + rate * cum[j]
        w = 10.0 + 0.05 * (est - speech_start)
        lo = bisect.bisect_left(mids, est - w)
        hi = bisect.bisect_right(mids, est + w)
        cands.append([(mids[k], inner[k]) for k in range(lo, hi)])

    INF = float("inf")
    best = [[INF] * len(c) for c in cands]
    back = [[None] * len(c) for c in cands]
    best[0][0] = 0.0
    for j in range(1, n + 1):
        here = cands[j] if j < n else [(speech_end, None)]
        row, brow = [INF] * len(here), [None] * len(here)
        for x, (m, g) in enumerate(here):
            extra = trap(g) if g else 0.0
            for jp in range(max(0, j - MAX_JOIN), j):
                chars = cum[j] - cum[jp]
                for y, (mp, _) in enumerate(cands[jp]):
                    if best[jp][y] == INF or m <= mp + 0.2:
                        continue
                    c = best[jp][y] + dev(m - mp, chars) + 4.0 * (j - jp - 1) + extra
                    if c < row[x]:
                        row[x], brow[x] = c, (jp, y)
        if j < n:
            best[j], back[j] = row, brow
        else:
            end_back = brow[0]

    cuts = [None] * n
    cuts[0] = (speech_start, speech_start)
    node = end_back
    if node is None:                          # no path: keep KIT's order
        return cuts
    while node and node[0] > 0:
        j, y = node
        g = cands[j][y][1]
        cuts[j] = (g[1], g[0])                # speech resumes, pause began
        node = back[j][y]
    return cuts


def sync_wav(wav_path: str, transcript: dict, total_s: float) -> dict:
    """Re-time one TTS WAV in place (KIT's original kept in _kit_tts/)."""
    session_dir = os.path.dirname(wav_path)
    name = os.path.basename(wav_path)
    keep_dir = os.path.join(session_dir, KIT_DIR)
    original = os.path.join(keep_dir, name)
    if not os.path.exists(original):
        os.makedirs(keep_dir, exist_ok=True)
        shutil.copy2(wav_path, original)

    segs = _speech_segments(transcript)
    if len(segs) < 2:
        return {"file": name, "status": "skipped", "reason": "no segments"}

    pcm = _decode(original)
    wav_s = len(pcm) / 2 / RATE
    gaps = _silences(pcm)
    cuts = _cut_points(segs, gaps, wav_s)
    speech_end_s = (gaps[-1][0] if gaps and gaps[-1][1] >= wav_s - 0.05
                    else wav_s)

    # pieces: (target start, audio)
    starts = [i for i, c in enumerate(cuts) if c is not None]
    pieces = []
    for n, i in enumerate(starts):
        a = cuts[i][0]                      # speech begins
        b = cuts[starts[n + 1]][1] if n + 1 < len(starts) else speech_end_s
        b = max(b, a)
        audio = pcm[int(a * RATE) * 2:int(b * RATE) * 2]
        pieces.append((segs[i][0], audio))

    total = max(total_s, segs[-1][0] + 1.0)
    out = bytearray()
    sped = 0
    for n, (target, audio) in enumerate(pieces):
        at = max(target, len(out) / 2 / RATE)
        nxt = pieces[n + 1][0] if n + 1 < len(pieces) else total
        slot = nxt - at
        dur = len(audio) / 2 / RATE
        if slot > 0.2 and dur > slot * 1.02:
            audio = _tempo(audio, min(dur / slot, MAX_TEMPO))
            sped += 1
        pad = int(at * RATE) * 2 - len(out)
        if pad > 0:
            out.extend(b"\x00" * pad)
        out.extend(audio)
    pad = int(total * RATE) * 2 - len(out)
    if pad > 0:
        out.extend(b"\x00" * pad)

    _write_wav(wav_path, bytes(out))
    info = {
        "file": name,
        "status": "synced",
        "segments": len(segs),
        "pieces": len(pieces),
        "sped_up": sped,
        "kit_length_s": round(wav_s, 1),
        "length_s": round(len(out) / 2 / RATE, 1),
    }
    logging.info("tts_sync: %s", info)
    return info


# ── per session ─────────────────────────────────────────────────────────


def _simple(language: str) -> str:
    from .routes_sessions import _extract_simple_language_name

    return _extract_simple_language_name(language)


def is_live(session_dir: str) -> bool:
    return os.path.exists(os.path.join(session_dir, "live_audio.mp4"))


def needs_sync(session_dir: str) -> bool:
    if is_live(session_dir) or not os.path.isdir(session_dir):
        return False
    keep = os.path.join(session_dir, KIT_DIR)
    return any(
        f.startswith("tts_") and f.endswith(".wav")
        and not os.path.exists(os.path.join(keep, f))
        for f in os.listdir(session_dir)
    )


def sync_session(session_dir: str, force: bool = False) -> list[dict]:
    """Sync every tts_<Language>.wav of a video session."""
    if is_live(session_dir):
        return []
    try:
        with open(os.path.join(session_dir, "transcripts.json"), encoding="utf-8") as f:
            transcripts = json.load(f)
    except (OSError, ValueError):
        return []
    if not isinstance(transcripts, list):
        return []
    by_lang = {}
    for t in transcripts:
        lang = str(t.get("language") or "")
        if not lang or lang == "Transcript" or "Original ASR" in lang:
            continue
        by_lang.setdefault(_simple(lang), t)
    total_s = _total_length(transcripts)

    results = []
    keep = os.path.join(session_dir, KIT_DIR)
    for f in sorted(os.listdir(session_dir)):
        if not (f.startswith("tts_") and f.endswith(".wav")):
            continue
        if not force and os.path.exists(os.path.join(keep, f)):
            continue
        lang = f[len("tts_"):-len(".wav")]
        t = by_lang.get(lang)
        if t is None:
            results.append({"file": f, "status": "skipped", "reason": "no transcript"})
            continue
        try:
            results.append(sync_wav(os.path.join(session_dir, f), t, total_s))
        except Exception as e:  # keep KIT's file on any failure
            logging.warning("tts_sync: %s failed: %s", f, e)
            original = os.path.join(keep, f)
            if os.path.exists(original):
                shutil.copy2(original, os.path.join(session_dir, f))
            results.append({"file": f, "status": "failed", "reason": str(e)})
    return results


def sync_session_in_background(session_dir: str) -> bool:
    """Start a sync unless one runs already. True if started."""
    with _lock:
        if session_dir in _running:
            return False
        _running.add(session_dir)

    def run():
        try:
            sync_session(session_dir)
        finally:
            with _lock:
                _running.discard(session_dir)

    threading.Thread(target=run, daemon=True, name="tts-sync").start()
    return True
