"""Flask app object, CORS, response hooks, UTF-8 subprocess patch.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import logging
import subprocess
import urllib
from flask import Flask, request
from flask_cors import CORS
import urllib3


urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# BeautifulSoup is imported only when needed for HTML parsing
has_bs4 = False
try:
    from bs4 import BeautifulSoup

    has_bs4 = True
except ImportError:
    logging.warning("BeautifulSoup not installed. Export functions will be limited.")

logging.basicConfig(level=logging.INFO)
logging.getLogger("urllib3").setLevel(logging.INFO)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 1024 * 1024 * 1024
app.config["DEBUG"] = True

CORS(
    app,
    origins=[
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://localhost:5000",
        "http://127.0.0.1:5000",
        "https://get-all-subtitled.isl.iar.kit.edu",
    ],
    supports_credentials=True,
    methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=[
        "Content-Type",
        "Authorization",
        "X-Forwarded-User",
        "Accept",
        "Cache-Control",
        "Pragma",
        "Expires",
        "Range",
    ],
    expose_headers=["Location", "Content-Disposition"],
)

_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


def _curl_safe_url(url: str) -> str:
    """Percent-encode a URL so curl can parse it.

    Spaces, parentheses, and other characters that are legal in a
    *filename* but not in a *URL* must be encoded before curl sees
    them, or curl exits with code 3 and returns no status.
    """
    parts = urllib.parse.urlsplit(url)
    path = urllib.parse.quote(parts.path, safe="/%=")
    query = urllib.parse.quote(parts.query, safe="=&%")
    return urllib.parse.urlunsplit(
        (parts.scheme, parts.netloc, path, query, parts.fragment)
    )


@app.after_request
def add_no_cache_for_api(response):
    """Disable client and intermediary caching for API responses."""
    if request.path.startswith(
        (
            "/job_progress/",
            "/job-progress/",
            "/session_output/",
            "/session-output/",
            "/session_file/",
            "/session-file/",
            "/session_languages/",
            "/session-languages/",
            "/session_transcript_json/",
            "/session-transcript-json/",
            "/session_tts/",
            "/session-tts/",
            "/video-job-settings/",     
            "/video-job-history/",       
            "/job-settings-presets",
            "/api/",
        )
    ):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response

_orig_subprocess_run = subprocess.run


def _utf8_run(*args, **kwargs):
    """subprocess.run wrapper: UTF-8 text mode everywhere.

    On Windows, text=True defaults to cp1252, which crashes on
    Cyrillic filenames echoed by ffmpeg. Force UTF-8 with byte
    replacement so it never raises.
    """
    if kwargs.get("text") or kwargs.get("universal_newlines"):
        kwargs.setdefault("encoding", "utf-8")
        kwargs.setdefault("errors", "replace")
    return _orig_subprocess_run(*args, **kwargs)


subprocess.run = _utf8_run
