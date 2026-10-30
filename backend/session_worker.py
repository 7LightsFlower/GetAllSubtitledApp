"""Waiting for KIT to finish a session and downloading the result.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import json
import logging
import os
import subprocess
import time
import requests
from flask import jsonify

from .flask_app import app
from .servers import INTERNAL_SERVER_URL
from .config import jobs, sessions
from .state import save_state
from .utils import _effective_token, _session_dir, _short_sid
from .progress import (
    _JobCancelled,
    _clear_cancel,
    _consecutive_404s,
    _consecutive_404s_lock,
    _is_cancelled,
    _job_cancel,
    _job_finish,
    _job_log,
    _job_start,
    _log_target,
    _take_finish_now,
)
from .downloads import download_session_files
from .tts import _MIN_WAV_BYTES, _looks_like_wav, download_tts_files
from .kit_messages import (
    MIN_MESSAGES_BYTES,
    MIN_MESSAGES_COUNT,
    _MT_STALL_SECONDS,
    _PROGRESS_FETCH_INTERVAL,
    _PROGRESS_HEARTBEAT_SECONDS,
    _STABLE_GROWTH_BYTES,
    _STABLE_NEEDED,
    _STABLE_QUIET_SECONDS,
    _compute_translation_progress,
    _fetch_all_archive_messages,
    _fetch_archive_messages_page,
    _fetch_latest_archive_page,
    _last_reported_total,
    _last_reported_total_lock,
    _messages_look_done,
    _mt_summary,
    _mt_track_status,
    _session_video_duration,
)


def wait_for_session_ready(
    session_id, token, server_url=None, expected_langs=None, timeout=7200
):
    """Block until the internal server finishes producing messages.json.

    Emits panel progress only when the observed second value actually
    advances. An idle translation track — or a stall in ASR before any
    translation has started — will not repeatedly re-print the same
    line. A slow heartbeat is emitted every _PROGRESS_HEARTBEAT_SECONDS
    while waiting, so the user can tell the job is still alive.
    """
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")

    started = time.time()
    last_size = -1
    stable_count = 0
    unauthorized_count = 0

    # Quiet-period tracking for the readiness gate
    _quiet_baseline = 0
    _quiet_since = started

    # Progress-tick bookkeeping. The "reported" values are the ones the
    # panel has already seen; we only emit a new event when they move.
    last_progress_fetch = 0.0
    last_reported_mt_end = 0.0
    last_reported_asr_end = 0.0
    last_heartbeat = started

    # Fires the shape-diagnostic log line exactly once per call to this
    # function — i.e. once per session — instead of once per process.
    _logged_shape = False
    last_mt_summary = ""

    # Cooldown between two events of the same kind. Complements the
    # value-advance check below.
    while True:
        if _is_cancelled(session_id):
            raise _JobCancelled(f"Session {_short_sid(session_id)} cancelled by user")

        if _take_finish_now(session_id):
            logging.info(
                "Session %s: finish now requested — taking what is ready",
                _short_sid(session_id),
            )
            return True

        elapsed = time.time() - started
        if elapsed > timeout:
            if last_size >= MIN_MESSAGES_COUNT:
                # Plenty of output exists: keep it instead of failing.
                _job_log(
                    session_id,
                    f"⚠️ Still not finished after {timeout / 60:.0f} min — "
                    "downloading what is ready (some translations may be "
                    "incomplete).",
                    level="warning",
                    stage="translating",
                )
                return True
            raise TimeoutError(
                f"Session {_short_sid(session_id)} not ready after {timeout}s"
            )

        # Give the internal server a moment to accept the upload before
        # we start hammering it.
        if elapsed < 15:
            time.sleep(1)
            continue

        # KIT's live transcript endpoint: page 1 is the first page.
        # Fetching page 1 alone is cheap and gives us both `total` and
        # a fresh sample of the newest messages, which is enough for
        # the size / growth tracking that follows.
        page1 = _fetch_archive_messages_page(
            session_id,
            token,
            server_url,
            page=1,
            limit=1,
        )
        if page1 is None:
            # Treat a failed fetch as a transient 5xx: keep waiting
            # but make the 404/401 bookkeeping happy.
            status = 503
            size = 0
        else:
            status = 200
            try:
                total = int(page1.get("total", 0))
            except (TypeError, ValueError):
                total = 0
            # Use `total` as the "size" signal. It grows monotonically
            # as KIT produces more messages, so the quiet-period logic
            # below keeps working unchanged.
            size = total

        # ── One-time shape log ────────────────────────────────────
        if page1 is not None and not _logged_shape:
            _logged_shape = True
            shape_total = page1.get("total", 0)
            n = len(page1.get("data") or [])
            logging.info(
                "archive_messages: shape check — total=%s, page-1 items=%d",
                shape_total,
                n,
            )
            if n:
                logging.info(
                    "archive_messages: first item preview = %s",
                    str(page1["data"][0])[:200],
                )

        if status == 401:
            unauthorized_count += 1
            if unauthorized_count >= 5:
                raise PermissionError(
                    f"Token rejected by {server_url} (HTTP 401). "
                    f"The token is either expired or was issued by a "
                    f"different server."
                )
        else:
            unauthorized_count = 0

        size_changed = size != last_size

        # Track how long the file has been quiet. "Quiet" means it has
        # not grown by more than _STABLE_GROWTH_BYTES since the last
        # time we saw a meaningful jump. This is much more robust than
        # "size == last_size" for sessions with many translation
        # tracks, where the file grows on nearly every poll until the
        # very end.
        now = time.time()
        if size > _quiet_baseline + _STABLE_GROWTH_BYTES:
            _quiet_baseline = size
            _quiet_since = now

        quiet_for = now - _quiet_since
        plausible = size >= MIN_MESSAGES_COUNT
        if plausible and quiet_for >= _STABLE_QUIET_SECONDS:
            stable_count += 1
        else:
            stable_count = 0
        last_size = size

        # ── Console-only chatter ────────────────────────────────────
        # Only log when something meaningful changes. On a healthy
        # session that means the size moved, or we just entered or
        # finished a stability window. On a 404 the size never moves,
        # so the line is emitted once and never again.
        if status == 200:
            if size_changed or stable_count in (1, _STABLE_NEEDED):
                logging.info(
                    "Session %s: messages=%d (stable=%d/%d)",
                    _short_sid(session_id),
                    size,
                    stable_count,
                    _STABLE_NEEDED,
                )
        elif status != 200 and size_changed:
            logging.info(
                "Session %s: /archive_messages status=%d "
                "(waiting for the internal server to publish the session)",
                _short_sid(session_id),
                status,
            )

        # ── Persistent-failure early exit ────────────────────────
        # A run of consecutive failures from /archive_messages/ almost
        # always means the session id is wrong (the upload succeeded
        # but the response carried the wrong id, or the fallback path
        # was used). Fail loudly after 30 attempts instead of polling
        # until the 30-minute timeout.
        if page1 is None:
            with _consecutive_404s_lock:
                n = _consecutive_404s.get(session_id, 0) + 1
                _consecutive_404s[session_id] = n

            if n == 1:
                logging.warning(
                    "/archive_messages returned a failure for session %s "
                    "(attempt 1)",
                    _short_sid(session_id),
                )
            elif n == 5:
                logging.warning(
                    "/archive_messages still failing for session %s after "
                    "%d attempts; further failures for this session will "
                    "be silenced",
                    _short_sid(session_id),
                    n,
                )

            if n >= 30:
                raise RuntimeError(
                    f"Session {_short_sid(session_id)} could not be "
                    f"reached via /archive_messages/ for {n} consecutive "
                    f"attempts. The session id is almost certainly wrong — "
                    f"check the upload response in the backend log."
                )
        else:
            # Success — clear the counter so a later transient failure
            # starts a fresh count.
            with _consecutive_404s_lock:
                _consecutive_404s.pop(session_id, None)

        # ── Progress tick ────────────────────────────────────────────
        # Fetch the file and push a fraction of the video duration to
        # the panel, but only when the observed value has advanced.
        now = time.time()
        if now - last_progress_fetch >= _PROGRESS_FETCH_INTERVAL:
            last_progress_fetch = now
            # Fetch *all* pages for the progress calculation. This is
            # heavier than the page-1 probe above, but it runs only
            # every _PROGRESS_FETCH_INTERVAL seconds (default 30 s).
            # We only need the newest messages to compute progress.
            # Fetching just the last page is 10–20× cheaper than the
            # whole transcript, and the last page is the only one
            # whose contents change between polls.
            progress_messages = _fetch_latest_archive_page(
                session_id,
                token,
                server_url,
            )
            raw_for_progress = json.dumps(progress_messages).encode("utf-8")
            mt_end, asr_end = _compute_translation_progress(raw_for_progress)
            video_dur = _session_video_duration(session_id)

            if video_dur > 0:
                if mt_end > last_reported_mt_end:
                    last_reported_mt_end = mt_end
                    prog = min(mt_end / video_dur, 0.99)
                    _job_log(
                        session_id,
                        f"Translations cover {mt_end:.0f}s / "
                        f"{video_dur:.0f}s ({prog * 100:.0f}%)",
                        stage="translating",
                        progress=prog,
                    )
                elif mt_end <= 0 and asr_end > last_reported_asr_end:
                    last_reported_asr_end = asr_end
                    prog = min((asr_end / video_dur) * 0.05, 0.05)
                    _job_log(
                        session_id,
                        f"Transcribing… {asr_end:.0f}s / {video_dur:.0f}s",
                        stage="transcribing",
                        progress=prog,
                    )

        # ── Heartbeat ────────────────────────────────────────────────
        # If nothing has been reported for a while — neither the size
        # nor the ASR/MT values are moving — emit one short line so the
        # user knows we are still polling and not wedged.
        if now - last_heartbeat >= _PROGRESS_HEARTBEAT_SECONDS:
            last_heartbeat = now
            if last_mt_summary:
                _job_log(
                    session_id,
                    f"Waiting — {last_mt_summary}",
                    stage="translating",
                )
            elif last_reported_mt_end > 0:
                _job_log(
                    session_id,
                    f"Waiting — translation still at {last_reported_mt_end:.0f}s",
                    stage="translating",
                )
            elif last_reported_asr_end > 0:
                _job_log(
                    session_id,
                    f"Waiting — transcription still at {last_reported_asr_end:.0f}s",
                    stage="transcribing",
                )
            else:
                _job_log(
                    session_id,
                    "Waiting for the internal server…",
                    stage="starting",
                )

        # ── Readiness gate ───────────────────────────────────────────
        if stable_count >= _STABLE_NEEDED:
            ready_messages = _fetch_all_archive_messages(
                session_id,
                token,
                server_url,
            )
            raw = json.dumps(ready_messages).encode("utf-8")
            if _messages_look_done(raw, expected_langs):
                time.sleep(5)
                # Re-check `total` via a cheap probe before doing the
                # expensive re-fetch. If KIT added messages during the
                # 5-second window, don't bother fetching; go back to
                # waiting.
                probe = _fetch_archive_messages_page(
                    session_id,
                    token,
                    server_url,
                    page=1,
                    limit=1,
                )
                new_total = (probe or {}).get("total", 0) if probe else 0
                if new_total == total:  # total from this iteration's probe
                    ready_messages2 = _fetch_all_archive_messages(
                        session_id,
                        token,
                        server_url,
                    )
                    raw2 = json.dumps(ready_messages2).encode("utf-8")
                    if _messages_look_done(raw2, expected_langs):
                        logging.info(
                            "✅ Session %s appears complete (%d msgs)",
                            _short_sid(session_id),
                            len(ready_messages2),
                        )
                        return True
                    logging.info(
                        "Session %s: second readiness check failed, still growing",
                        _short_sid(session_id),
                    )
                else:
                    logging.info(
                        "Session %s: total grew from %d to %d during "
                        "the readiness check — continuing to wait",
                        _short_sid(session_id),
                        size,
                        new_total,
                    )
            else:
                logging.warning(
                    "Session %s: size stable but content invalid, "
                    "resetting stability counter",
                    _short_sid(session_id),
                )
                # Per-language status for the panel, instead of only the
                # fastest track (which sits at 99% while others lag).
                asr_end, tracks = _mt_track_status(raw)
                summary, avg, unfinished = _mt_summary(asr_end, tracks)
                if summary and summary != last_mt_summary:
                    last_mt_summary = summary
                    _job_log(session_id, summary, stage="translating")
                quiet = time.time() - _quiet_since
                if unfinished and asr_end > 0 and quiet >= _MT_STALL_SECONDS:
                    _job_log(
                        session_id,
                        f"⚠️ No new output from the server for "
                        f"{quiet / 60:.0f} min — finishing with what is "
                        f"ready. Incomplete: "
                        + ", ".join(
                            f"{t} ({tracks[t]:.0f}s of {asr_end:.0f}s)"
                            for t in unfinished
                        ),
                        level="warning",
                        stage="translating",
                    )
                    return True
            stable_count = 0
        # Adaptive backoff: 2s while the file is still growing, longer
        # once it has settled. KIT starts throttling if we hit it every
        # two seconds for a long session; this keeps the early polls
        # responsive and the late polls polite.
        if stable_count >= _STABLE_NEEDED - 1:
            time.sleep(8)
        elif last_size <= MIN_MESSAGES_BYTES:
            time.sleep(5)
        else:
            time.sleep(3)


def process_session_in_background(
    session_id, token, video_key, server_url=None, expected_mt=None
):
    """Wait for the internal server to finish, then download the session.

    Runs in a daemon thread, started right after a successful upload.
    Everything logged from this thread is auto-routed to this session's
    JobProgressPanel via the _log_target contextvar, so the Flutter UI
    sees the same stream as the terminal.

    `expected_mt` is the list of translation target languages the client
    asked for. The readiness gate will not fire until every one of them
    has at least one message in messages.json.
    """
    if not server_url:
        server_url = sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
    server_url = server_url.rstrip("/")

    effective_token = _effective_token(session_id, fallback=token)
    if effective_token != token:
        logging.info(
            "process_session_in_background: using stored token for %s "
            "(request-time token differs)",
            _short_sid(session_id),
        )

    # Fall back to what the upload endpoint recorded for this session.
    if not expected_mt:
        expected_mt = sessions.get(session_id, {}).get("expected_mt")
    if isinstance(expected_mt, str):
        expected_mt = [expected_mt]

    # Clear any stale cancel flag so a rerun of the same session id
    # doesn't get killed instantly.
    _clear_cancel(session_id)

    token_cv = _log_target.set(("job", session_id))
    try:
        logging.info(
            "🟢 [BG] Starting background processing for %s on %s "
            "(waiting for translations: %s)",
            _short_sid(session_id),
            server_url,
            expected_mt or "any",
        )
        session_name = sessions.get(session_id, {}).get("name", session_id)
        _job_start(session_id, video_key, session_name)
        _job_log(
            session_id,
            "Job registered — contacting internal server…",
            stage="starting",
            progress=0.02,
        )

        ready = wait_for_session_ready(
            session_id, effective_token, server_url, expected_langs=expected_mt
        )
        if not ready:
            logging.warning(
                "Session %s never stabilized; downloading what we have",
                _short_sid(session_id),
            )

        # download_session_files() already attempts TTS as part of its
        # normal flow (see _download_session_files_locked). If any TTS
        # WAV is missing after it returns, retry once here — that's the
        # case KIT's "TTS not generated yet" behaviour produces, and a
        # second pass is the only thing that recovers it. Otherwise a
        # second download_tts_files() call is pure duplicated work.
        ok = download_session_files(session_id, effective_token, server_url)

        if ok:
            tts_dir = _session_dir(session_id)
            have_tts = any(
                f.startswith("tts_")
                and f.endswith(".wav")
                and os.path.getsize(os.path.join(tts_dir, f)) > _MIN_WAV_BYTES
                and _looks_like_wav(os.path.join(tts_dir, f))
                for f in os.listdir(tts_dir)
            ) if os.path.isdir(tts_dir) else False

            if not have_tts:
                # Try one more time — the first pass may have run before
                # KIT finished synthesizing.
                logging.info(
                    "process_session_in_background: no valid TTS after "
                    "download_session_files, retrying for %s",
                    _short_sid(session_id),
                )
                tts = download_tts_files(session_id, effective_token, server_url)
                if not tts:
                    ok = False
                    _job_log(
                        session_id,
                        "Session files saved, but no TTS tracks could be "
                        "fetched. KIT may not have generated them yet, or "
                        "they may have expired.",
                        level="warning",
                    )

        job = jobs.get(session_id)
        if job:
            job["status"] = "completed" if ok else "partial"
            job["progress"] = 1.0
        save_state()

        _job_finish(session_id, error=None if ok else "Partial download")
        logging.info("✅ Background download finished for %s", _short_sid(session_id))

    except _JobCancelled as e:
        logging.warning(
            "🛑 Background processing cancelled for %s: %s",
            _short_sid(session_id),
            e,
        )
        job = jobs.get(session_id)
        if job:
            job["status"] = "cancelled"
            job["progress"] = 0.0
        _job_cancel(session_id)
        save_state()
    except (
        requests.exceptions.RequestException,
        OSError,
        subprocess.SubprocessError,
        TimeoutError,
        ValueError,
        TypeError,
        KeyError,
        RuntimeError,
    ) as e:
        logging.error(
            "Background session processing failed for %s: %s",
            _short_sid(session_id),
            e,
            exc_info=True,
        )
        _job_finish(session_id, error=f"{type(e).__name__}: {e}")
    finally:
        _log_target.reset(token_cv)
        with _consecutive_404s_lock:
            _consecutive_404s.pop(session_id, None)
        with _last_reported_total_lock:
            _last_reported_total.pop(session_id, None)


@app.route("/extract-video-subtitles/<path:session_id>", methods=["GET"])
def extract_video_subtitles(session_id):
    """Extract embedded subtitles from video.mp4 to VTT files."""
    session_dir = _session_dir(session_id)
    video_path = os.path.join(session_dir, "video.mp4")

    if not os.path.exists(video_path):
        return jsonify({"error": "video.mp4 not found"}), 404

    try:
        # First, get info about subtitle streams
        probe_cmd = [
            "ffprobe",
            "-i",
            video_path,
            "-show_entries",
            "stream=index,codec_type,codec_name,language,tags",
            "-select_streams",
            "s",
            "-of",
            "json",
        ]

        result = subprocess.run(
            probe_cmd, capture_output=True, text=True, timeout=30, check=False
        )
        if result.returncode != 0:
            return jsonify({"error": "ffprobe failed", "stderr": result.stderr}), 500

        probe_data = json.loads(result.stdout)
        streams = probe_data.get("streams", [])

        extracted = []
        for i, stream in enumerate(streams):
            stream_index = stream.get("index")
            language = stream.get("language", f"stream_{i}")

            # Extract subtitle to VTT
            output_file = os.path.join(
                session_dir, f"extracted_subtitle_{i}_{language}.vtt"
            )

            extract_cmd = [
                "ffmpeg",
                "-i",
                video_path,
                "-map",
                f"0:{stream_index}",
                "-c",
                "copy",
                "-y",
                output_file,
            ]

            subprocess.run(extract_cmd, capture_output=True, timeout=60, check=False)

            if os.path.exists(output_file):
                extracted.append(
                    {
                        "stream_index": stream_index,
                        "language": language,
                        "filename": os.path.basename(output_file),
                        "size": os.path.getsize(output_file),
                    }
                )

        return (
            jsonify({"success": True, "extracted": extracted, "total": len(extracted)}),
            200,
        )

    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, OSError) as e:
        return jsonify({"error": str(e)}), 500
