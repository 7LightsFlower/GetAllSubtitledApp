"""Upload prepared media to a KIT server and register the session."""

from __future__ import annotations

import base64
import json
import logging
import mimetypes
import os
import re
import shutil
import tempfile
import threading
import time
import uuid

import requests

from .config import (
    USE_CHUNKED_UPLOAD, server_label,
)
from .progress import (
    _clear_cancel, _job_progress_store, _job_start, _request_cancel,
    job_progress_lock,
)
from .state import jobs, save_state, sessions
from .utils import (
    email_from_token, extract_session_id, log_token_email,
    norm_session_name, sanitize_session_name_for_kit, session_dir,
    short_sid, unique_local_name, user_home_path, utc_now_iso,
)
from .video import prepare_upload_source_cached


def post_multipart_with_retries(target_url, body_file, headers, cookies, *,
                                total_size, max_attempts=3, base_delay=5.0):
    last_exc = None
    for attempt in range(1, max_attempts + 1):
        try:
            body_file.seek(0)
            resp = requests.post(
                target_url, data=body_file, headers=headers, cookies=cookies,
                timeout=(60, 3600), verify=False, allow_redirects=False,
            )
            if resp.status_code in (301, 302, 303, 307, 308):
                location = resp.headers.get("Location", "")
                if location:
                    resp = requests.get(
                        location, cookies=cookies, verify=False,
                        timeout=60, allow_redirects=True)
            return resp
        except requests.exceptions.ConnectionError as e:
            last_exc = e
            if attempt < max_attempts:
                delay = base_delay * (2 ** (attempt - 1))
                logging.info("internal_upload: retrying in %.1fs", delay)
                time.sleep(delay)
    raise last_exc


def _extract_session_id_via_archive(base_url, token, session_name):
    """Scrape /archive/<home_b64> to find the newest session id by name."""
    try:
        home_path = user_home_path(token)
        home_b64 = base64.b64encode(home_path.encode("utf-8")).decode("ascii")
        archive_resp = requests.get(
            f"{base_url}/archive/{home_b64}",
            headers={"Authorization": f"Bearer {token}", "X-Forward-Auth": token},
            cookies={"_forward_auth": token},
            verify=False, timeout=20, allow_redirects=True,
        )
        if archive_resp.status_code != 200:
            return None
        candidates = re.findall(r"/archivesession/([A-Za-z0-9_\-=]+)",
                                archive_resp.text)
        wanted = norm_session_name(session_name)
        for cand in candidates:
            padded = cand + "=" * (-len(cand) % 4)
            try:
                decoded = base64.b64decode(padded).decode("utf-8", errors="ignore")
            except (ValueError, UnicodeDecodeError):
                continue
            tail = decoded.rsplit("/", 1)[-1]
            if norm_session_name(tail) == wanted:
                return cand
    except requests.exceptions.RequestException as e:
        logging.warning("could not scrape archive for session id: %s", e)
    return None


def upload_and_register(*, local_path, file_size, session_name, form_data,
                        token, target_url, base_url, video_key, project,
                        expected_mt, clear_stale_session=False):
    """Upload the prepared media and register the session. Returns (body, status)."""
    session_name = sanitize_session_name_for_kit(session_name)
    log_token_email(token, "internal_upload")

    email_used = email_from_token(token)
    pipeline_url = base_url
    pipeline_label = server_label(base_url)

    upload_source_path = local_path
    upload_filename_used = os.path.basename(local_path)
    gs_cleanup: list = []
    temp_multipart_path = None

    try:
        upload_source_path, upload_filename_used, gs_cleanup = (
            prepare_upload_source_cached(local_path, video_key))

        boundary = f"----WebKitFormBoundary{uuid.uuid4().hex[:16]}"
        content_type = f"multipart/form-data; boundary={boundary}"
        total_size = 0

        with tempfile.NamedTemporaryFile(delete=False) as temp_mp:
            temp_multipart_path = temp_mp.name
            for key, value in form_data.items():
                values = value if isinstance(value, list) else [value]
                for v in values:
                    part = (
                        f"--{boundary}\r\n"
                        f"Content-Disposition: form-data; "
                        f'name="{key}"\r\n\r\n{v}\r\n'
                    ).encode("utf-8")
                    temp_mp.write(part)
                    total_size += len(part)

            upload_filename = upload_filename_used
            if not upload_filename.lower().endswith(".mp4"):
                upload_filename = f"{upload_filename}.mp4"
            mimetype = mimetypes.guess_type(upload_filename)[0] or "video/mp4"
            header = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="videofile"; '
                f'filename="{upload_filename}"\r\n'
                f"Content-Type: {mimetype}\r\n\r\n"
            ).encode("utf-8")
            temp_mp.write(header)
            total_size += len(header)

            with open(upload_source_path, "rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    temp_mp.write(chunk)
                    total_size += len(chunk)

            trailer = f"\r\n--{boundary}--\r\n".encode("utf-8")
            temp_mp.write(trailer)
            total_size += len(trailer)

        headers = {
            "X-Forward-Auth": token,
            "Authorization": f"Bearer {token}",
            "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
            "Content-Type": content_type,
        }
        if not USE_CHUNKED_UPLOAD:
            headers["Content-Length"] = str(total_size)
        cookies = {"_forward_auth": token}

        with open(temp_multipart_path, "rb") as body_file:
            resp = post_multipart_with_retries(
                target_url=target_url, body_file=body_file,
                headers=headers, cookies=cookies, total_size=total_size)

        if resp.status_code >= 400:
            return (
                {"error": f"Internal server returned {resp.status_code}",
                 "response": resp.text[:1000],
                 "pipeline": pipeline_label, "pipeline_url": pipeline_url,
                 "email": email_used},
                502,
            )

        session_id = extract_session_id(resp)
        if not session_id:
            session_id = _extract_session_id_via_archive(base_url, token, session_name)
        if not session_id:
            logging.error("internal_upload: KIT did not return a session id. "
                          "Raw response: %s", resp.text[:3000])
            return (
                {"error": "KIT accepted the upload but did not return a session id.",
                 "status_code": resp.status_code,
                 "pipeline": pipeline_label, "pipeline_url": pipeline_url,
                 "email": email_used},
                502,
            )

        if clear_stale_session:
            stale_dir = session_dir(session_id)
            if os.path.exists(stale_dir):
                try:
                    shutil.rmtree(stale_dir)
                except OSError:
                    pass
            with job_progress_lock:
                _job_progress_store.pop(session_id, None)

        _clear_cancel(session_id)
        project["session_id"] = session_id
        project["session_url"] = f"{base_url}/archivesession/{session_id}"

        sessions[session_id] = {
            "id": session_id,
            "name": session_name,
            "local_name": unique_local_name(session_name),
            "video_key": video_key,
            "created_at": utc_now_iso(),
            "url": f"{base_url}/archivesession/{session_id}",
            "server": base_url,
            "expected_mt": expected_mt,
            "token": token,
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
            "pipeline_label": pipeline_label,
            "pipeline_url": pipeline_url,
            "email_used": email_used,
            "remarks": "",
        }
        _job_start(session_id, video_key, session_name)

        # Cancel orphan workers for the same video.
        for other_sid, other_job in list(jobs.items()):
            if (other_job.get("video_key") == video_key
                    and other_job.get("status") == "processing"
                    and other_sid != session_id):
                _request_cancel(other_sid)
                other_job["status"] = "cancelled"
                with job_progress_lock:
                    _job_progress_store.pop(other_sid, None)

        from .session_worker import process_session_in_background
        threading.Thread(
            target=process_session_in_background,
            args=(session_id, token, video_key, base_url, expected_mt),
            daemon=True,
        ).start()
        save_state()

        try:
            body = json.loads(resp.text)
            if not isinstance(body, dict):
                body = {}
        except json.JSONDecodeError:
            body = {"status": "success",
                    "message": "Upload successful!",
                    "response": resp.text[:500]}

        body.update({
            "success": True,
            "session_id": session_id,
            "video_key": video_key,
            "session_url": f"{base_url}/archivesession/{session_id}",
            "output_url": f"/session-output/{session_id}",
            "download_url": f"/session-zip/{session_id}",
            "pipeline_label": pipeline_label,
            "pipeline_url": pipeline_url,
            "email": email_used,
        })
        return body, resp.status_code

    except requests.exceptions.Timeout:
        return ({"error": "Request timeout - file may be too large",
                 "pipeline": pipeline_label, "pipeline_url": pipeline_url,
                 "email": email_used}, 504)
    except requests.exceptions.RequestException as e:
        return ({"error": f"Request failed: {type(e).__name__}: {e}",
                 "pipeline": pipeline_label, "pipeline_url": pipeline_url,
                 "email": email_used}, 500)
    except OSError as e:
        return ({"error": f"Upload failed: {type(e).__name__}: {e}",
                 "pipeline": pipeline_label, "pipeline_url": pipeline_url,
                 "email": email_used}, 500)
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
            except OSError:
                pass