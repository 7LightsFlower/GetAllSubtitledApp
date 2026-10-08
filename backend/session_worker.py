"""Background worker that polls KIT and downloads the session."""

from __future__ import annotations

import json
import logging
import time

from .config import (
    INTERNAL_SERVER_URL,
    MIN_MESSAGES_BYTES,
    MIN_MESSAGES_COUNT,
    PROGRESS_FETCH_INTERVAL,
    PROGRESS_HEARTBEAT_SECONDS,
    STABLE_GROWTH_BYTES,
    STABLE_NEEDED,
    STABLE_QUIET_SECONDS,
)
from .downloads import (
    JobCancelled,
    _fetch_all_archive_messages,
    _fetch_archive_messages_page,
    _fetch_latest_archive_page,
    download_session_files,
)
from .progress import (
    _clear_cancel,
    _consecutive_404s,
    _consecutive_404s_lock,
    _is_cancelled,
    _job_cancel,
    _job_finish,
    _job_log,
    _job_start,
    _log_target,
)
from .state import jobs, save_state, sessions, videos
from .transcripts import messages_look_done
from .tts import download_tts_files
from .utils import effective_token, safe_float, short_sid


def _compute_translation_progress(raw: bytes) -> tuple[float, float]:
    """Return (mt_max_end_seconds, asr_max_end_seconds) from a messages blob."""
    mt_max_end = 0.0
    asr_max_end = 0.0
    if not raw:
        return mt_max_end, asr_max_end
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return mt_max_end, asr_max_end
    if not isinstance(data, list):
        return mt_max_end, asr_max_end
    for item in data:
        if not (isinstance(item, list) and len(item) >= 2):
            continue
        try:
            m = json.loads(item[1]) if isinstance(item[1], str) else item[1]
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(m, dict) or not m.get("seq", "").strip():
            continue
        end = safe_float(m.get("end", 0))
        sender = m.get("sender", "")
        if sender.startswith("asr:"):
            asr_max_end = max(asr_max_end, end)
        elif sender.startswith(("mt:", "translation:")):
            mt_max_end = max(mt_max_end, end)
    return mt_max_end, asr_max_end


def _session_video_duration(session_id: str) -> float:
    """Look up the source video duration for a session, in seconds."""
    sess = sessions.get(session_id) or {}
    video_key = sess.get("video_key")
    if not video_key:
        return 0.0
    for v in videos:
        if v.get("key") == video_key:
            try:
                return float(v.get("duration") or 0.0)
            except (TypeError, ValueError):
                return 0.0
    return 0.0


def wait_for_session_ready(
    session_id,
    token,
    server_url=None,
    expected_langs=None,
    timeout=7200,
) -> bool:
    """Block until KIT finishes producing messages.json.

    Emits panel progress only when the observed second value actually
    advances, plus a slow heartbeat so the user can tell the job is
    still alive.
    """
    if not server_url:
        server_url = (
            sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
        )
    server_url = server_url.rstrip("/")

    started = time.time()
    last_size = -1
    stable_count = 0
    unauthorized_count = 0
    quiet_baseline = 0
    quiet_since = started
    last_progress_fetch = 0.0
    last_reported_mt_end = 0.0
    last_reported_asr_end = 0.0
    last_heartbeat = started
    logged_shape = False

    while True:
        if _is_cancelled(session_id):
            raise JobCancelled(
                f"Session {short_sid(session_id)} cancelled by user"
            )

        elapsed = time.time() - started
        if elapsed > timeout:
            raise TimeoutError(
                f"Session {short_sid(session_id)} not ready after {timeout}s"
            )

        if elapsed < 15:
            time.sleep(1)
            continue

        page1 = _fetch_archive_messages_page(
            session_id, token, server_url, page=1, limit=1
        )
        if page1 is None:
            status = 503
            size = 0
        else:
            status = 200
            try:
                size = int(page1.get("total", 0))
            except (TypeError, ValueError):
                size = 0

        if page1 is not None and not logged_shape:
            logged_shape = True
            logging.info(
                "archive_messages: shape check — total=%s, page-1 items=%d",
                page1.get("total", 0),
                len(page1.get("data") or []),
            )

        if status == 401:
            unauthorized_count += 1
            if unauthorized_count >= 5:
                raise PermissionError(
                    f"Token rejected by {server_url} (HTTP 401)."
                )
        else:
            unauthorized_count = 0

        size_changed = size != last_size
        now = time.time()
        if size > quiet_baseline + STABLE_GROWTH_BYTES:
            quiet_baseline = size
            quiet_since = now
        quiet_for = now - quiet_since
        plausible = size >= MIN_MESSAGES_COUNT
        if plausible and quiet_for >= STABLE_QUIET_SECONDS:
            stable_count += 1
        else:
            stable_count = 0
        last_size = size

        if status == 200:
            if size_changed or stable_count in (1, STABLE_NEEDED):
                logging.info(
                    "Session %s: messages=%d (stable=%d/%d)",
                    short_sid(session_id),
                    size,
                    stable_count,
                    STABLE_NEEDED,
                )
        elif size_changed:
            logging.info(
                "Session %s: /archive_messages status=%d",
                short_sid(session_id),
                status,
            )

        if page1 is None:
            with _consecutive_404s_lock:
                n = _consecutive_404s.get(session_id, 0) + 1
                _consecutive_404s[session_id] = n
            if n >= 30:
                raise RuntimeError(
                    f"Session {short_sid(session_id)} could not be reached "
                    f"via /archive_messages/ for {n} consecutive attempts."
                )
        else:
            with _consecutive_404s_lock:
                _consecutive_404s.pop(session_id, None)

        now = time.time()
        if now - last_progress_fetch >= PROGRESS_FETCH_INTERVAL:
            last_progress_fetch = now
            msgs = _fetch_latest_archive_page(session_id, token, server_url)
            raw = json.dumps(msgs).encode("utf-8")
            mt_end, asr_end = _compute_translation_progress(raw)
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

        if now - last_heartbeat >= PROGRESS_HEARTBEAT_SECONDS:
            last_heartbeat = now
            if last_reported_mt_end > 0:
                _job_log(
                    session_id,
                    f"Waiting — translation still at "
                    f"{last_reported_mt_end:.0f}s",
                    stage="translating",
                )
            elif last_reported_asr_end > 0:
                _job_log(
                    session_id,
                    f"Waiting — transcription still at "
                    f"{last_reported_asr_end:.0f}s",
                    stage="transcribing",
                )
            else:
                _job_log(
                    session_id,
                    "Waiting for the internal server…",
                    stage="starting",
                )

        if stable_count >= STABLE_NEEDED:
            ready = _fetch_all_archive_messages(
                session_id, token, server_url
            )
            raw = json.dumps(ready).encode("utf-8")
            if messages_look_done(raw, expected_langs):
                time.sleep(5)
                probe = _fetch_archive_messages_page(
                    session_id, token, server_url, page=1, limit=1
                )
                new_total = (probe or {}).get("total", 0) if probe else 0
                if new_total == size:
                    ready2 = _fetch_all_archive_messages(
                        session_id, token, server_url
                    )
                    raw2 = json.dumps(ready2).encode("utf-8")
                    if messages_look_done(raw2, expected_langs):
                        return True
            stable_count = 0

        if stable_count >= STABLE_NEEDED - 1:
            time.sleep(8)
        elif last_size <= MIN_MESSAGES_BYTES:
            time.sleep(5)
        else:
            time.sleep(3)


def process_session_in_background(
    session_id,
    token,
    video_key,
    server_url=None,
    expected_mt=None,
) -> None:
    """Wait for KIT, download the session, then run a final TTS pass.

    Runs in a daemon thread started by the upload handler. Every log
    line emitted from here is auto-routed to the session's panel via
    the `_log_target` contextvar.
    """
    if not server_url:
        server_url = (
            sessions.get(session_id, {}).get("server") or INTERNAL_SERVER_URL
        )
    server_url = server_url.rstrip("/")

    effective = effective_token(session_id, fallback=token)
    if not expected_mt:
        expected_mt = sessions.get(session_id, {}).get("expected_mt")
    if isinstance(expected_mt, str):
        expected_mt = [expected_mt]

    _clear_cancel(session_id)
    token_cv = _log_target.set(("job", session_id))
    try:
        session_name = sessions.get(session_id, {}).get("name", session_id)
        _job_start(session_id, video_key, session_name)
        _job_log(
            session_id,
            "Job registered — contacting internal server…",
            stage="starting",
            progress=0.02,
        )

        wait_for_session_ready(
            session_id,
            effective,
            server_url,
            expected_langs=expected_mt,
        )
        ok = download_session_files(session_id, effective, server_url)

        job = jobs.get(session_id)
        if job:
            job["status"] = "completed" if ok else "partial"
            job["progress"] = 1.0
        save_state()

        # Final TTS pass — some tracks appear only after ASR settles.
        tts = download_tts_files(session_id, token, server_url)
        if not tts:
            ok = False

        _job_finish(session_id, error=None if ok else "Partial download")
    except JobCancelled as e:
        logging.warning(
            "Background processing cancelled for %s: %s",
            short_sid(session_id),
            e,
        )
        job = jobs.get(session_id)
        if job:
            job["status"] = "cancelled"
            job["progress"] = 0.0
        _job_cancel(session_id)
        save_state()
    except (
        OSError,
        RuntimeError,
        TimeoutError,
        ValueError,
        TypeError,
        KeyError,
    ) as e:
        logging.error(
            "Background session processing failed for %s: %s",
            short_sid(session_id),
            e,
            exc_info=True,
        )
        _job_finish(session_id, error=f"{type(e).__name__}: {e}")
    finally:
        _log_target.reset(token_cv)
        with _consecutive_404s_lock:
            _consecutive_404s.pop(session_id, None)
