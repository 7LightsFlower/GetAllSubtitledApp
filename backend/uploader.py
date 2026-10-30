"""Uploading videos to KIT and registering the session.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import base64
import datetime
import json
import logging
import mimetypes
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib
import uuid
import requests
from flask import jsonify, request

from .flask_app import app
from .servers import INTERNAL_SERVER_URL, _SERVER_LABELS, _resolve_target_url
from .config import UPLOAD_FOLDER, USE_CHUNKED_UPLOAD, jobs, sessions, videos
from .state import save_state
from .utils import (
    _email_from_token,
    _ensure_job_history,
    _extract_session_id,
    _log_token_email,
    _session_dir,
    _short_sid,
    _unique_local_name,
    _user_home_path,
    utc_now_iso,
)
from .progress import (
    _clear_cancel,
    _job_progress_store,
    _job_start,
    _request_cancel,
    job_progress_lock,
)
from .video import get_video_metadata
from .session_worker import process_session_in_background
from .media import prepare_upload_source_cached
from .session_sync import _post_multipart_with_retries


def generate_video_thumbnail_simple(video_path, thumbnail_path):
    """
    Generate a thumbnail using ffmpeg with multiple attempts.
    """
    try:
        # Check if ffmpeg is available
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)

        # Get video duration
        duration = 0
        try:
            probe_cmd = [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                video_path,
            ]
            result = subprocess.run(
                probe_cmd, capture_output=True, text=True, timeout=10, check=False
            )
            if result.returncode == 0 and result.stdout.strip():
                duration = float(result.stdout.strip())
        except (OSError, ValueError, subprocess.SubprocessError):
            pass

        # Try different positions
        positions = [1.0, 5.0, 10.0]
        if duration > 30:
            positions.append(duration * 0.5)
        if duration > 60:
            positions.append(duration * 0.25)
            positions.append(duration * 0.75)

        for pos in positions:
            if pos >= duration:
                continue

            cmd = [
                "ffmpeg",
                "-ss",
                str(pos),
                "-i",
                video_path,
                "-vframes",
                "1",
                "-vf",
                "scale=320:-1:flags=lanczos",
                "-q:v",
                "2",
                "-y",
                thumbnail_path,
            ]

            result = subprocess.run(
                cmd, capture_output=True, text=True, check=False, timeout=30
            )

            if (
                result.returncode == 0
                and os.path.exists(thumbnail_path)
                and os.path.getsize(thumbnail_path) > 1000
            ):
                logging.info("✅ Thumbnail generated at %ss", pos)
                return True

        # Fallback: first frame
        cmd = [
            "ffmpeg",
            "-i",
            video_path,
            "-vframes",
            "1",
            "-vf",
            "scale=320:-1:flags=lanczos",
            "-q:v",
            "2",
            "-y",
            thumbnail_path,
        ]

        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        )

        if (
            result.returncode == 0
            and os.path.exists(thumbnail_path)
            and os.path.getsize(thumbnail_path) > 1000
        ):
            logging.info("✅ Thumbnail generated from first frame")
            return True

        return False

    except (OSError, ValueError, subprocess.SubprocessError) as e:
        logging.warning("⚠️ Thumbnail generation error: %s", str(e))
        return False


def _sanitize_session_name_for_kit(name: str) -> str:
    """Match what KIT stores as the session path segment."""
    if not name:
        return name
    for src, dst in {
        "\u2022": "-",
        "\u2013": "-",
        "\u2014": "-",
        "\u2018": "'",
        "\u2019": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u00a0": " ",
    }.items():
        name = name.replace(src, dst)
    return re.sub(r"\s+", " ", name).strip()


import unicodedata  # add to the imports block at the top of the file

def _norm_session_name(s: str) -> str:
    """Fold punctuation AND Unicode canonical form.

    NFC is the load-bearing change: it makes composed vs decomposed
    Cyrillic (e.g. 'й' = U+0439 vs 'и' + U+0306) compare equal, which
    is what lets Cyrillic session names match against the tail KIT
    stores in its base64 ids.
    """
    for src, dst in {
        "\u2018": "'", "\u2019": "'",
        "\u201c": '"', "\u201d": '"',
        "\u2013": "-", "\u2014": "-",
        "\u2022": "-", "\u00a0": " ",
    }.items():
        s = s.replace(src, dst)
    s = unicodedata.normalize("NFC", s)
    return re.sub(r"\s+", " ", s).strip().casefold()


def _names_match(a: str, b: str, min_prefix: int = 15) -> bool:
    """Compare two session names, allowing either to be a prefix of the other.

    Guards against two ways the id we decode can differ from the name
    we sent:

      * the archive page truncated the id (rare, but possible on very
        long names), leaving us with a prefix of the real tail;
      * KIT normalised something we did not anticipate, so our name
        happens to be a prefix of theirs.

    The floor of `min_prefix` characters stops `Tibbiyotda` from
    matching `Tibbiyotda 2` — a real false positive that would
    otherwise let the scrape claim the wrong session.
    """
    na, nb = _norm_session_name(a), _norm_session_name(b)
    if na == nb:
        return True
    short, long_ = (na, nb) if len(na) <= len(nb) else (nb, na)
    return len(short) >= min_prefix and long_.startswith(short)


# ─── UPLOAD ENDPOINT ────────────────────────────────────────────────────
def _upload_to_internal_server_and_register(
    *,
    local_path: str,
    file_size: int,
    session_name: str,
    form_data: dict,
    token: str,
    target_url: str,
    base_url: str,
    video_key: str,
    project: dict,
    expected_mt: list,
    clear_stale_session: bool = False,
) -> tuple[dict, int]:
    """Upload the prepared media to the KIT server and register the session.

    Returns ``(response_body, http_status)``; both are suitable for
    ``jsonify(body), status``.

    Every upload-side concern lives here:
      * green-screen substitution (via ``prepare_upload_source``),
      * multipart body assembly + a POST with explicit Content-Length,
      * session-id extraction with the KIT base64 fallback,
      * optional clearing of any stale local session directory,
      * registering the session/job and spawning the background worker,
      * temp-file cleanup in ``finally``.

    The two callers only differ in what they send in and whether they
    want the stale-session cleanup (``forward_to_internal`` does).

    Session/job records now also carry:
      * ``pipeline_label`` — a friendly name for the internal server
        the upload was forwarded to (e.g. "LT2SRV (primary)").
      * ``pipeline_url``   — the raw base URL of that server.
      * ``email_used``     — the login email pulled out of the bearer
        token (``<opaque>|<expiry>|<email>``). Empty string when the
        token is missing or does not match that shape.
      * ``remarks``        — free-text note the user can edit later
        via ``/video-job-remarks/<video_key>/<session_id>``.
    """

    session_name = _sanitize_session_name_for_kit(session_name)

    _log_token_email(token, "internal_upload")

    # ── Identity + pipeline bookkeeping ─────────────────────────
    # Captured once, up front, so the same values land on the session
    # record, the job record, and any log line we emit along the way.
    email_used = _email_from_token(token)
    pipeline_url = base_url
    pipeline_label = _SERVER_LABELS.get(base_url, base_url)

    logging.info(
        "internal_upload: pipeline=%s url=%s email=%s",
        pipeline_label,
        pipeline_url,
        email_used or "<none>",
    )

    upload_source_path = local_path
    upload_filename_used = os.path.basename(local_path)
    gs_cleanup: list = []
    temp_multipart_path = None

    logging.info(
        "internal_upload: uploading %s (%d bytes) to KIT",
        os.path.basename(upload_source_path),
        os.path.getsize(upload_source_path),
    )

    try:
        # ── 1. Decide what to send ────────────────────────────────
        upload_source_path, upload_filename_used, gs_cleanup = (
            prepare_upload_source_cached(local_path, video_key)
        )

        if upload_source_path != local_path:
            logging.info(
                "internal_upload: sending green-screen (%.1f MB) instead "
                "of original (%.1f MB)",
                os.path.getsize(upload_source_path) / (1024 * 1024),
                file_size / (1024 * 1024),
            )

        logging.info("internal_upload: posting to %s", target_url)
        logging.info("internal_upload: form keys = %s", sorted(form_data.keys()))

        # ── 2. Build the multipart body in a temp file ────────────
        # We build it explicitly so we can send an explicit
        # Content-Length. Many proxies and the internal server reject
        # chunked uploads.
        #
        # Windows note: NamedTemporaryFile holds an exclusive lock on
        # the file until its handle is closed. Using `with` guarantees
        # the handle is released before we re-open for reading.
        boundary = f"----WebKitFormBoundary{uuid.uuid4().hex[:16]}"
        content_type = f"multipart/form-data; boundary={boundary}"
        total_size = 0

        with tempfile.NamedTemporaryFile(delete=False) as temp_multipart:
            temp_multipart_path = temp_multipart.name

            for key, value in form_data.items():
                if isinstance(value, list):
                    for v in value:
                        part = (
                            f"--{boundary}\r\n"
                            f"Content-Disposition: form-data; "
                            f'name="{key}"\r\n\r\n'
                            f"{v}\r\n"
                        ).encode("utf-8")
                        temp_multipart.write(part)
                        total_size += len(part)
                else:
                    part = (
                        f"--{boundary}\r\n"
                        f"Content-Disposition: form-data; "
                        f'name="{key}"\r\n\r\n'
                        f"{value}\r\n"
                    ).encode("utf-8")
                    temp_multipart.write(part)
                    total_size += len(part)

            upload_filename = upload_filename_used
            if not upload_filename.lower().endswith(".mp4"):
                upload_filename = f"{upload_filename}.mp4"
            mimetype = mimetypes.guess_type(upload_filename)[0] or "video/mp4"
            file_header = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="videofile"; '
                f'filename="{upload_filename}"\r\n'
                f"Content-Type: {mimetype}\r\n\r\n"
            ).encode("utf-8")
            temp_multipart.write(file_header)
            total_size += len(file_header)

            with open(upload_source_path, "rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    temp_multipart.write(chunk)
                    total_size += len(chunk)

            trailer = f"\r\n--{boundary}--\r\n".encode("utf-8")
            temp_multipart.write(trailer)
            total_size += len(trailer)

        logging.info("internal_upload: multipart body prepared (%d bytes)", total_size)

        # ── 3. POST to the KIT server ─────────────────────────────
        headers = {
            "X-Forward-Auth": token,
            "Authorization": f"Bearer {token}",
            "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
            "Content-Type": content_type,
        }
        if not USE_CHUNKED_UPLOAD:
            headers["Content-Length"] = str(total_size)
        # else: let requests pick Transfer-Encoding: chunked
        cookies = {"_forward_auth": token}

        with open(temp_multipart_path, "rb") as body_file:
            resp = _post_multipart_with_retries(
                target_url=target_url,
                body_file=body_file,
                headers=headers,
                cookies=cookies,
                total_size=total_size,
            )

        logging.info(
            "internal_upload: response status=%s url=%s",
            resp.status_code,
            resp.url,
        )

        if resp.status_code >= 400:
            logging.error(
                "internal_upload: internal server rejected %s:\n%s",
                resp.status_code,
                resp.text[:2000],
            )
            return (
                {
                    "error": f"Internal server returned {resp.status_code}",
                    "response": resp.text[:1000],
                    "pipeline": pipeline_label,
                    "pipeline_url": pipeline_url,
                    "email": email_used,
                },
                502,
            )

        # ── 4. Extract the session id ─────────────────────────────
        session_id = _extract_session_id(resp)
        if session_id:
            logging.info("internal_upload: session id from response: %s", session_id)
        else:
            logging.error(
                "internal_upload: NO session id in upload response. "
                "status=%s url=%s\n"
                "----- RAW RESPONSE BODY (first 5000 chars) -----\n%s\n"
                "----- END RAW RESPONSE BODY -----",
                resp.status_code,
                resp.url,
                resp.text[:5000],
            )

            # ── Ask KIT's archive browser for the real id ───────────
            # /archive/<home_b64> lists every session for this user.
            # The list is NOT ordered by recency — it is grouped by
            # session name alphabetically. So we can't just take the
            # first entry; we have to decode each candidate id and
            # match its last path segment against the session name
            # we sent to KIT.
            #
            # Matching is two-pass: exact-string first, prefix
            # fallback second. A plain-key candidate like
            # `122f9e34-…` is a strict prefix of a timestamped name
            # like `122f9e34-…_20261016-…`, so without the two-pass
            # rule a re-upload would always bind to the older
            # session. The exact match wins unconditionally; the
            # prefix match is used only if no exact match is found,
            # and only if the candidate is not already in the
            # project's job history.
            home_path = _user_home_path(token)
            home_b64 = base64.b64encode(home_path.encode("utf-8")).decode("ascii")
            wanted_norm = _norm_session_name(session_name)

            _ensure_job_history(project)
            already_known = {
                (e.get("session_id") or "").strip()
                for e in project.get("job_history", [])
                if isinstance(e, dict)
            }

            last_name_match = None

            for attempt in range(1, 7):
                try:
                    archive_resp = requests.get(
                        f"{base_url}/archive/{home_b64}",
                        headers={
                            "Authorization": f"Bearer {token}",
                            "X-Forward-Auth": token,
                        },
                        cookies={"_forward_auth": token},
                        verify=False,
                        timeout=20,
                        allow_redirects=True,
                    )
                    if archive_resp.status_code == 200:
                        # Base64 uses `+` and `/` for indices 62 and 63.
                        # KIT emits standard base64, not the URL-safe
                        # variant, so both characters appear in
                        # Cyrillic ids. Including `%` guards against
                        # a percent-encoded id if the archive page
                        # ever sends one.
                        candidates = re.findall(
                            r"/archivesession/([A-Za-z0-9_\-+/=%]+)",
                            archive_resp.text,
                        )

                        # If the page percent-encoded the id, decode it
                        # back to the raw base64 before comparing.
                        # `unquote` is a no-op when there is nothing
                        # to decode, so this is safe either way.
                        candidates = [urllib.parse.unquote(c) for c in candidates]

                        logging.info(
                            "archive scrape attempt %d: %d candidate(s), wanted=%r",
                            attempt,
                            len(candidates),
                            wanted_norm,
                        )

                        exact_match = None
                        prefix_match = None

                        for cand in candidates:
                            padded = cand + "=" * (-len(cand) % 4)
                            try:
                                decoded = base64.b64decode(padded).decode(
                                    "utf-8", errors="ignore"
                                )
                            except (ValueError, UnicodeDecodeError):
                                continue
                            tail_raw = decoded.rsplit("/", 1)[-1]
                            tail_norm = _norm_session_name(tail_raw)

                            if tail_norm == wanted_norm:
                                exact_match = cand
                                break

                            if prefix_match is None and _names_match(
                                tail_raw, session_name
                            ):
                                if cand in already_known:
                                    logging.info(
                                        "archive scrape: skipping %s "
                                        "(already in job history)",
                                        cand[:40] + "…",
                                    )
                                    continue
                                prefix_match = cand

                        candidate = exact_match or prefix_match
                        if candidate:
                            # Name matched — verify KIT actually
                            # serves this id before trusting it. A
                            # one-byte ranged GET turns a silently-
                            # dead sid into a loud skip.
                            probe_url = f"{base_url}/archivesession/{candidate}"
                            try:
                                probe = requests.get(
                                    probe_url,
                                    headers={
                                        "Authorization": f"Bearer {token}",
                                        "X-Forward-Auth": token,
                                    },
                                    cookies={"_forward_auth": token},
                                    verify=False,
                                    timeout=15,
                                    allow_redirects=True,
                                )
                            except requests.exceptions.RequestException as e:
                                logging.warning(
                                    "archive scrape: probe for %s failed: %s",
                                    candidate[:40] + "…",
                                    e,
                                )
                                probe = None

                            if probe is not None and probe.status_code == 200:
                                session_id = candidate
                                logging.info(
                                    "archive scrape: %s match and verified "
                                    "on attempt %d",
                                    "exact" if exact_match else "prefix",
                                    attempt,
                                )
                                break
                            elif probe is not None:
                                logging.warning(
                                    "archive scrape: name matched but KIT "
                                    "returned %s for id=%s… — skipping",
                                    probe.status_code,
                                    candidate[:40],
                                )

                        # Remember the most recent name-matched
                        # candidate so a slow publish can still be
                        # handed to the background worker below.
                        if prefix_match and not exact_match:
                            last_name_match = prefix_match
                        elif exact_match:
                            last_name_match = exact_match

                        # Dump the tails so the next failure is
                        # debuggable.
                        if not session_id:
                            for cand in candidates[:8]:
                                try:
                                    dec = base64.b64decode(
                                        cand + "=" * (-len(cand) % 4)
                                    ).decode("utf-8", errors="ignore")
                                except (ValueError, UnicodeDecodeError):
                                    continue
                                logging.info(
                                    "  candidate id=%r (len=%d) tail=%r",
                                    cand[:60] + ("…" if len(cand) > 60 else ""),
                                    len(cand),
                                    dec.rsplit("/", 1)[-1],
                                )

                except requests.exceptions.RequestException as e:
                    logging.warning(
                        "archive scrape attempt %d failed: %s", attempt, e
                    )

                if session_id:
                    break
                if attempt < 6:
                    time.sleep(30)

            # ── Fallback: register the most recent name-match even if
            #    no candidate returned 200 ───────────────────────────
            # Freshly-uploaded sessions often take 1–3 minutes to
            # become reachable on KIT. Rather than 502 the upload we
            # hand the most recent name-match to the background
            # worker. Its own 404 counter will abandon a truly dead
            # id after 30 consecutive failures.
            if not session_id and last_name_match:
                session_id = last_name_match
                logging.warning(
                    "internal_upload: no candidate verified 200 after "
                    "%d attempt(s); registering last name-match %s "
                    "(len=%d) for the background worker to resolve",
                    attempt,
                    last_name_match[:40] + "…",
                    len(last_name_match),
                )

            # If the scrape produced nothing at all, we are done.
            if not session_id:
                logging.error(
                    "internal_upload: KIT did not return a session id. "
                    "Refusing to fabricate one — a locally-built id would "
                    "almost certainly 404 on every poll. Raw response:\n%s",
                    resp.text[:3000],
                )
                return (
                    {
                        "error": (
                            "KIT accepted the upload but did not return a "
                            "session id. See the backend log for the raw "
                            "response body."
                        ),
                        "status_code": resp.status_code,
                        "pipeline": pipeline_label,
                        "pipeline_url": pipeline_url,
                        "email": email_used,
                    },
                    502,
                )

        # ── 5. Optionally clear stale local state ─────────────────
        if clear_stale_session:
            stale_dir = _session_dir(session_id)
            if os.path.exists(stale_dir):
                try:
                    shutil.rmtree(stale_dir)
                    logging.info(
                        "internal_upload: cleared stale session dir %s",
                        stale_dir,
                    )
                except OSError as e:
                    logging.warning("Could not clear %s: %s", stale_dir, e)
            with job_progress_lock:
                _job_progress_store.pop(session_id, None)

        # ── 6. Register session + spawn background worker ─────────
        _clear_cancel(session_id)

        project["session_id"] = session_id
        project["session_url"] = f"{base_url}/archivesession/{session_id}"

        sessions[session_id] = {
            "id": session_id,
            "name": session_name,
            # Human-readable folder name under sessions/ — this is
            # what the user sees on disk instead of the encoded id.
            "local_name": _unique_local_name(session_name),
            "video_key": video_key,
            "created_at": utc_now_iso(),
            "url": f"{base_url}/archivesession/{session_id}",
            "server": base_url,
            "expected_mt": expected_mt,
            "token": token,  # the token that created this session
            # ── pipeline + identity, for display and audit ──
            "pipeline_label": pipeline_label,
            "pipeline_url": pipeline_url,
            "email_used": email_used,
        }
        jobs[session_id] = {
            "id": session_id,
            "video_key": video_key,
            "status": "processing",
            "progress": 0.0,
            "transcript": None,
            "segments": None,
            "created_at": utc_now_iso(),
            "config": {"source": "internal_upload"},
            "expected_mt": expected_mt,
            # ── pipeline + identity, plus a scratch notes field ──
            "pipeline_label": pipeline_label,
            "pipeline_url": pipeline_url,
            "email_used": email_used,
            "remarks": "",
        }

        _job_start(session_id, video_key, session_name)

        # If a worker is already running for this video_key, cancel
        # it before starting the new one. Without this, every retry
        # leaves an orphan thread polling a stale session id.
        for other_sid, other_job in list(jobs.items()):
            if (
                other_job.get("video_key") == video_key
                and other_job.get("status") == "processing"
                and other_sid != session_id
            ):
                logging.info(
                    "internal_upload: cancelling stale worker for %s",
                    _short_sid(other_sid),
                )
                _request_cancel(other_sid)
                other_job["status"] = "cancelled"
                with job_progress_lock:
                    _job_progress_store.pop(other_sid, None)

        threading.Thread(
            target=process_session_in_background,
            args=(session_id, token, video_key, base_url, expected_mt),
            daemon=True,
        ).start()
        save_state()

        logging.info(
            "internal_upload: session %s registered, worker started "
            "(pipeline=%s, email=%s)",
            _short_sid(session_id),
            pipeline_label,
            email_used or "<none>",
        )

        # ── 7. Build the client response ──────────────────────────
        try:
            response_data = json.loads(resp.text)
            if not isinstance(response_data, dict):
                response_data = {}
        except json.JSONDecodeError:
            response_data = {
                "status": "success",
                "message": "Upload successful!",
                "response": resp.text[:500],
            }

        response_data.update(
            {
                "success": True,
                "session_id": session_id,
                "video_key": video_key,
                "session_url": f"{base_url}/archivesession/{session_id}",
                "output_url": f"/session-output/{session_id}",
                "download_url": f"/session-zip/{session_id}",
                # ── echo the pipeline + identity back to the client ──
                "pipeline_label": pipeline_label,
                "pipeline_url": pipeline_url,
                "email": email_used,
            }
        )
        return response_data, resp.status_code

    except requests.exceptions.Timeout:
        logging.error("internal_upload: request timed out", exc_info=True)
        return (
            {
                "error": "Request timeout - file may be too large",
                "pipeline": pipeline_label,
                "pipeline_url": pipeline_url,
                "email": email_used,
            },
            504,
        )
    except requests.exceptions.RequestException as e:
        logging.error(
            "internal_upload: request error (%s): %s",
            type(e).__name__,
            e,
            exc_info=True,
        )
        return (
            {
                "error": f"Request failed: {type(e).__name__}: {e}",
                "pipeline": pipeline_label,
                "pipeline_url": pipeline_url,
                "email": email_used,
            },
            500,
        )
    except OSError as e:
        logging.error(
            "internal_upload: OS error (%s): %s",
            type(e).__name__,
            e,
            exc_info=True,
        )
        return (
            {
                "error": f"Upload failed: {type(e).__name__}: {e}",
                "pipeline": pipeline_label,
                "pipeline_url": pipeline_url,
                "email": email_used,
            },
            500,
        )
    finally:
        if temp_multipart_path and os.path.exists(temp_multipart_path):
            try:
                os.unlink(temp_multipart_path)
            except OSError:
                pass
        for p in gs_cleanup:
            try:
                if os.path.exists(p):
                    os.unlink(p)
                    logging.info("🧹 Cleaned up temp file: %s", p)
            except OSError:
                pass
            

@app.route("/upload", methods=["POST", "OPTIONS"])
def upload_to_internal():
    """Send a video to the internal KIT server and register the session.

    Accepts two request shapes, detected from Content-Type:

      * multipart/form-data with a `videofile` field
            → the file is saved locally, then uploaded.
      * application/json with a `video_key`
            → the file already lives in UPLOAD_FOLDER; it is used
              directly.

    All the heavy lifting — green-screen substitution, multipart
    assembly, POST, session-id extraction, session/job registration,
    background worker spawn, temp-file cleanup — lives in
    ``_upload_to_internal_server_and_register``.
    """
    if request.method == "OPTIONS":
        response = jsonify({"message": "OK"})
        response.headers.add("Access-Control-Allow-Origin", "*")
        response.headers.add(
            "Access-Control-Allow-Headers", "Content-Type,Authorization"
        )
        response.headers.add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        return response, 200

    content_type = (request.content_type or "").lower()
    is_multipart = "multipart/form-data" in content_type

    # ── Extract the token, whichever mode we're in ───────────────
    if is_multipart:
        token = request.form.get("token", "").strip()
    else:
        data_in = request.get_json(silent=True) or {}
        token = (data_in.get("token") or "").strip()
        if not token:
            token = (
                request.headers.get("Authorization", "").replace("Bearer ", "").strip()
            )
    if not token:
        return jsonify({"error": "Missing token"}), 400

    # ── Locate the local file + build mode-specific form fields ──
    if is_multipart:
        # ---------- Mode A: direct multipart upload ----------
        if "videofile" not in request.files:
            return jsonify({"error": "No video file provided"}), 400
        file_storage = request.files["videofile"]
        if not file_storage.filename:
            return jsonify({"error": "Empty filename"}), 400

        session_name = request.form.get("name", file_storage.filename)

        original_filename = file_storage.filename
        if not original_filename.lower().endswith(".mp4"):
            original_filename = f"{os.path.splitext(original_filename)[0]}.mp4"
            logging.info("📹 Added .mp4 extension: %s", original_filename)

        existing = next(
            (v for v in videos if v.get("file_name") == original_filename),
            None,
        )
        local_filename = original_filename
        local_path = os.path.join(UPLOAD_FOLDER, local_filename)

        if existing:
            video_key = existing["key"]
            project = existing
            logging.info(
                "📹 Using existing video: %s (key: %s)",
                original_filename,
                video_key,
            )
            if not os.path.exists(local_path):
                file_storage.save(local_path)
                logging.info("✅ Restored video file: %s", local_filename)
        else:
            base_name, ext = os.path.splitext(original_filename)
            ext = ext or ".mp4"
            counter = 1
            while os.path.exists(local_path):
                local_filename = f"{base_name}_{counter}{ext}"
                local_path = os.path.join(UPLOAD_FOLDER, local_filename)
                counter += 1
            file_storage.save(local_path)
            logging.info("✅ New video saved: %s", local_filename)

            # Probe duration / fps / codec now that the file is on
            # disk. get_video_metadata() is a quick local ffprobe and
            # its fallbacks (120.0, 30.0, "") keep the dict valid even
            # if the probe fails.
            duration, fps, codec = get_video_metadata(local_path)

            video_key = str(uuid.uuid4())
            project = {
                "key": video_key,
                "name": session_name,
                "file_name": local_filename,
                "uploaded": utc_now_iso(),
                "last_opened": None,
                "duration": duration,
                "fps": fps,
                "codec": codec,
                "file_size": os.path.getsize(local_path),
                "segment_count": 0,
                "languages": request.form.getlist("language") or ["en"],
                "thumbnail_url": None,
                "segmentation_done": False,
                "segmentation_progress": 0,
                "source": request.form.get("source", "Desktop Upload"),
            }
            videos.append(project)

        file_size = os.path.getsize(local_path)

        # Copy the incoming form into a plain dict (skip token).
        form_data = {}
        for key in request.form.keys():
            if key == "token":
                continue
            values = request.form.getlist(key)
            form_data[key] = values[0] if len(values) == 1 else values

        # Do NOT trust a client-supplied `path`. The old Flutter build sends
        # "/home/admin@example.com", and setdefault() never replaces it.
        form_data["path"] = _user_home_path(token)

        expected_mt = request.form.getlist("mtLanguage") or ["de"]
        target_url = _resolve_target_url(request.form.get("targetServer"))
        clear_stale = False

    else:
        # ---------- Mode B: forward an already-stored video ----------
        video_key = (data_in.get("video_key") or "").strip()
        if not video_key:
            return jsonify({"error": "video_key is required"}), 400

        project = next((v for v in videos if v.get("key") == video_key), None)
        if project is None:
            return (
                jsonify({"error": "Video not found", "video_key": video_key}),
                404,
            )

        file_name = project.get("file_name")
        if not file_name:
            return jsonify({"error": "Video has no file_name"}), 400

        local_path = os.path.join(UPLOAD_FOLDER, file_name)
        if not os.path.exists(local_path):
            return (
                jsonify({"error": f'File "{file_name}" not found on disk'}),
                404,
            )

        file_size = os.path.getsize(local_path)
        if file_size < 1000:
            return jsonify({"error": "File is too small to upload"}), 400

        session_name = (
            (data_in.get("name") or "").strip()
            or project.get("name")
            or os.path.splitext(file_name)[0]
        )

        # Build the KIT form data from whatever the client sent in
        # the JSON body, falling back to the previous hard-coded
        # defaults for anything missing. This keeps old clients that
        # only send `video_key` working while letting the current UI
        # pass the full job configuration (languages, features,
        # post-production, timeouts, …).
        def _as_list(v):
            """Normalise a scalar-or-list into a list of strings."""
            if v is None:
                return None
            if isinstance(v, list):
                return [str(x) for x in v]
            return [str(v)]

        form_data = {
            "path": _user_home_path(token),  # never trust a client path
            "name": session_name,
            "topicname": data_in.get("topicname") or session_name,
            "date": (
                data_in.get("date") or datetime.datetime.now().strftime("%Y-%m-%d")
            ),
            "speakername": data_in.get("speakername") or "",
            "availability": data_in.get("availability") or "private",
            "format": data_in.get("format") or "mixed",
            "smartChaptering": data_in.get("smartChaptering") or "online_dynamic",
            "errorCorrection": data_in.get("errorCorrection") or "None",
            "ttsQualityMode": data_in.get("ttsQualityMode") or "low_latency",
            "language": _as_list(data_in.get("language")) or ["en"],
            "mtLanguage": _as_list(data_in.get("mtLanguage")) or ["de"],
            "audioLanguage": _as_list(data_in.get("audioLanguage")) or ["de"],
            "profanity": str(data_in.get("profanity") or "1"),
            "filter_music": str(data_in.get("filter_music") or "1"),
            "summarization": str(data_in.get("summarization") or "1"),
            "logging": str(data_in.get("logging") or "1"),
            "legals": str(data_in.get("legals") or "1"),
            "profile": data_in.get("profile") or "profile_1",
            "profile_names": data_in.get("profile_names") or "",
            "shorten": data_in.get("shorten") or "",
            "mute": str(data_in.get("mute") or "120"),
            "pause": str(data_in.get("pause") or "2"),
            "save_profile": "1",
        }

        # Optional feature flags — only sent when the client asked
        # for them. KIT's own defaults apply otherwise.
        for opt_key in (
            "notes",
            "saasr",
            "aiassistant",
            "distinguish_unknown_speakers",
        ):
            val = data_in.get(opt_key)
            if val:
                form_data[opt_key] = str(val)

        # Post-production shortening rates (e.g. ["50", "90"]).
        postprod = _as_list(data_in.get("postproduction"))
        if postprod:
            form_data["postproduction"] = postprod

        expected_mt = data_in.get("mtLanguage") or data_in.get("mt_languages") or ["de"]
        if isinstance(expected_mt, str):
            expected_mt = [expected_mt]

        target_url = _resolve_target_url(
            data_in.get("targetServer") or request.headers.get("X-Target-Server")
        )
        clear_stale = True  # forward mode always resets stale state

    # ── Delegate to the shared worker ─────────────────────────────
    base_url = target_url.rsplit("/upload_lecture", 1)[0]

    body, status = _upload_to_internal_server_and_register(
        local_path=local_path,
        file_size=file_size,
        session_name=session_name,
        form_data=form_data,
        token=token,
        target_url=target_url,
        base_url=base_url,
        video_key=video_key,
        project=project,
        expected_mt=expected_mt,
        clear_stale_session=clear_stale,
    )
    return jsonify(body), status


@app.route("/check-session", methods=["GET"])
def check_session():
    """Forward a GET request to check if the session is authenticated."""
    headers = {}
    auth = request.headers.get("Authorization")
    if auth:
        headers["Authorization"] = auth
    forwarded_user = request.headers.get("X-Forwarded-User")
    if forwarded_user:
        headers["X-Forwarded-User"] = forwarded_user
    try:
        resp = requests.get(
            INTERNAL_SERVER_URL,
            headers=headers,
            allow_redirects=False,
            timeout=10,
            verify=False,
        )
        final_url = resp.url if hasattr(resp, "url") else INTERNAL_SERVER_URL
        is_login_page = resp.status_code == 200 and (
            "Log in to dex" in resp.text or "dex-container" in resp.text
        )
        authenticated = not (
            "dex" in final_url or resp.status_code == 302 or is_login_page
        )
        return jsonify({"authenticated": authenticated}), 200
    except requests.exceptions.RequestException:
        return jsonify({"authenticated": False, "error": "Request failed"}), 200
