"""HTTP / curl helpers for talking to the KIT server."""

from __future__ import annotations

import logging
import os
import subprocess

import requests
import urllib3

from .config import INTERNAL_SERVER_URL
from .utils import curl_safe_url

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

internal_session = requests.Session()
internal_session.verify = False


def internal_headers(token: str) -> dict:
    return {
        "X-Forward-Auth": token,
        "Authorization": f"Bearer {token}",
        "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
    }


def internal_cookies(token: str) -> dict:
    return {"_forward_auth": token}


def curl_download(url, output_path, token, *, cookie_only=False, media=False,
                  referer=None, anonymous=False) -> bool:
    url = curl_safe_url(url)
    try:
        auth_headers = []
        if not anonymous and not cookie_only:
            auth_headers = [
                "-H", f"X-Forward-Auth: {token}",
                "-H", f"Authorization: Bearer {token}",
            ]

        media_headers = []
        if media:
            media_headers = [
                "-H", "Accept: audio/webm,audio/ogg,audio/*;q=0.9,*/*;q=0.5",
                "-H", "Accept-Encoding: identity;q=1, *;q=0",
                "-H", "Range: bytes=0-",
            ]
            if referer:
                media_headers += ["-H", f"Referer: {referer}"]

        cmd = [
            "curl", "-s", "-L", "--insecure",
            "--connect-timeout", "30", "--max-time", "3600",
            *auth_headers, *media_headers,
            "-H", "User-Agent: Mozilla/5.0 (compatible; LT-Uploader/1.0)",
        ]
        if not anonymous:
            cmd += ["--cookie", f"_forward_auth={token}"]
        cmd += ["-w", "%{http_code}", "-o", output_path, url]

        result = subprocess.run(cmd, capture_output=True, text=True,
                                timeout=3660, check=False)
        try:
            status = int((result.stdout or "").strip())
        except ValueError:
            status = 0

        if (status in (200, 206) and os.path.exists(output_path)
                and os.path.getsize(output_path) > 1000):
            if not output_path.endswith(".html"):
                try:
                    with open(output_path, "rb") as f:
                        head = f.read(32)
                    stripped = head.lstrip().lower()
                    if (stripped.startswith(b"<!doctype html")
                            or stripped.startswith(b"<html")
                            or stripped.startswith(b"<!doctype")):
                        logging.info(
                            "curl_download: %s → 200 but body is HTML; "
                            "treating as failure", url)
                        os.remove(output_path)
                        return False
                except OSError:
                    pass
            return True

        if os.path.exists(output_path):
            os.remove(output_path)
        return False
    except subprocess.TimeoutExpired as e:
        logging.warning("Curl timeout for %s: %s", url, e)
        return False
    except OSError as e:
        logging.warning("Curl error for %s: %s", url, e)
        return False


def remote_size(url: str, token: str, timeout: int = 30) -> tuple[int, int]:
    headers = internal_headers(token)
    headers["Range"] = "bytes=0-0"
    for attempt in range(1, 3):
        try:
            r = requests.get(
                url, headers=headers, cookies=internal_cookies(token),
                verify=False, timeout=(10, timeout),
                allow_redirects=True, stream=True,
            )
            cr = r.headers.get("Content-Range")
            if cr and "/" in cr:
                total = cr.rsplit("/", 1)[-1].strip()
                if total.isdigit():
                    return int(total), r.status_code
            cl = r.headers.get("Content-Length")
            if cl:
                try:
                    return int(cl), r.status_code
                except ValueError:
                    pass
            return 0, r.status_code
        except requests.exceptions.ReadTimeout as e:
            if attempt == 1:
                continue
            logging.warning("ranged GET read timeout for %s: %s", url, e)
            return 0, 0
        except requests.exceptions.RequestException as e:
            logging.warning("ranged GET failed for %s: %s", url, e)
            return 0, 0
    return 0, 0