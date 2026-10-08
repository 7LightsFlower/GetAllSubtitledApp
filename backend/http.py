"""HTTP / curl helpers for talking to the KIT server."""

from __future__ import annotations

import logging
import os
import subprocess

import requests
import urllib3

from .utils import curl_safe_url

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

internal_session = requests.Session()
internal_session.verify = False


def internal_headers(token: str) -> dict:
    """Build authentication headers for requests to the KIT server."""
    return {
        "X-Forward-Auth": token,
        "Authorization": f"Bearer {token}",
        "User-Agent": "Mozilla/5.0 (compatible; LT-Uploader/1.0)",
    }


def internal_cookies(token: str) -> dict:
    """Build authentication cookies for requests to the KIT server."""
    return {"_forward_auth": token}


def _curl_auth_headers(token: str, anonymous: bool, cookie_only: bool) -> list[str]:
    """Build authentication headers for a curl request."""
    if anonymous or cookie_only:
        return []
    return [
        "-H",
        f"X-Forward-Auth: {token}",
        "-H",
        f"Authorization: Bearer {token}",
    ]


def _curl_media_headers(media: bool, referer: str | None) -> list[str]:
    """Build headers used for media downloads."""
    if not media:
        return []

    headers = [
        "-H",
        "Accept: audio/webm,audio/ogg,audio/*;q=0.9,*/*;q=0.5",
        "-H",
        "Accept-Encoding: identity;q=1, *;q=0",
        "-H",
        "Range: bytes=0-",
    ]
    if referer:
        headers.extend(["-H", f"Referer: {referer}"])
    return headers


def _curl_command(
    url: str,
    output_path: str,
    token: str,
    *,
    cookie_only: bool,
    media: bool,
    referer: str | None,
    anonymous: bool,
) -> list[str]:
    """Build the curl command for a download."""
    command = [
        "curl",
        "-s",
        "-L",
        "--insecure",
        "--connect-timeout",
        "30",
        "--max-time",
        "3600",
        *_curl_auth_headers(token, anonymous, cookie_only),
        *_curl_media_headers(media, referer),
        "-H",
        "User-Agent: Mozilla/5.0 (compatible; LT-Uploader/1.0)",
    ]
    if not anonymous:
        command.extend(["--cookie", f"_forward_auth={token}"])
    return [*command, "-w", "%{http_code}", "-o", output_path, url]


def curl_download(url, output_path, token, **options) -> bool:
    """Download a URL with curl and reject empty or HTML responses."""
    cookie_only = options.pop("cookie_only", False)
    media = options.pop("media", False)
    referer = options.pop("referer", None)
    anonymous = options.pop("anonymous", False)
    if options:
        unexpected = ", ".join(sorted(options))
        raise TypeError(f"curl_download() got unexpected keyword argument(s): {unexpected}")

    url = curl_safe_url(url)
    try:
        command = _curl_command(
            url,
            output_path,
            token,
            cookie_only=cookie_only,
            media=media,
            referer=referer,
            anonymous=anonymous,
        )
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=3660, check=False
        )
        try:
            status = int((result.stdout or "").strip())
        except ValueError:
            status = 0

        if (
            status in (200, 206)
            and os.path.exists(output_path)
            and os.path.getsize(output_path) > 1000
        ):
            if not output_path.endswith(".html"):
                try:
                    with open(output_path, "rb") as file:
                        head = file.read(32)
                    stripped = head.lstrip().lower()
                    if (
                        stripped.startswith(b"<!doctype html")
                        or stripped.startswith(b"<html")
                        or stripped.startswith(b"<!doctype")
                    ):
                        logging.info(
                            "curl_download: %s → 200 but body is HTML; "
                            "treating as failure",
                            url,
                        )
                        os.remove(output_path)
                        return False
                except OSError:
                    pass
            return True

        if os.path.exists(output_path):
            os.remove(output_path)
        return False
    except subprocess.TimeoutExpired as error:
        logging.warning("Curl timeout for %s: %s", url, error)
        return False
    except OSError as error:
        logging.warning("Curl error for %s: %s", url, error)
        return False


def remote_size(url: str, token: str, timeout: int = 30) -> tuple[int, int]:
    """Return the remote content size and HTTP status for a ranged request."""
    headers = internal_headers(token)
    headers["Range"] = "bytes=0-0"
    for attempt in range(1, 3):
        try:
            r = requests.get(
                url,
                headers=headers,
                cookies=internal_cookies(token),
                verify=False,
                timeout=(10, timeout),
                allow_redirects=True,
                stream=True,
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
