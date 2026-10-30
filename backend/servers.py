"""Allow-listed KIT servers and target-URL resolution.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import logging
import re


# ─── DEFAULT INTERNAL SERVER ──────────────────────────────
INTERNAL_SERVER_URL = "https://lt2srv.iar.kit.edu"

# ─── ALLOWED TARGET SERVERS ───────────────────────────────
# Any host of the form:
#     lt2srv.iar.kit.edu                          (bare host, no `isl.`)
#     lt2srv-<suffix>.iar.kit.edu
#     lt2srv-<suffix>.isl.iar.kit.edu
# A suffix is mandatory when `isl.` is present — KIT does not publish
# `lt2srv.isl.iar.kit.edu`, and allowing it here let a stale
# `INTERNAL_SERVER_URL` slip past validation and then 404 on every poll.
_ALLOWED_SERVER_RE = re.compile(
    r"^https://(?:"
    r"lt2srv\.iar\.kit\.edu"
    r"|lt2srv-[a-z0-9]+(?:-[a-z0-9]+)*\.iar\.kit\.edu"
    r"|lt2srv-[a-z0-9]+(?:-[a-z0-9]+)*\.isl\.iar\.kit\.edu"
    r")$"
)

_KNOWN_SERVERS = {
    "https://lt2srv.iar.kit.edu",
    "https://lt2srv-backup.iar.kit.edu",
    "https://lt2srv-sscherrer.isl.iar.kit.edu",
}

# Friendly labels for the servers we know about. The client also has
# its own copy; this one is only used when the backend records a job
# without the client having supplied a label.
_SERVER_LABELS = {
    "https://lt2srv.iar.kit.edu": "KIT Lecture Translator",
    "https://lt2srv-backup.iar.kit.edu": "Backup Server",
    "https://lt2srv-sscherrer.isl.iar.kit.edu": "Developer\'s Own (SScherrer)",
}

ALLOWED_TARGET_SERVERS = frozenset(_KNOWN_SERVERS)


def _is_allowed_server(url: str) -> bool:
    """True if we are willing to forward an upload to this host.

    Two ways in:
      1. It's one of the curated `_KNOWN_SERVERS` (fast path).
      2. It matches the `lt2srv-XXXX[.isl].iar.kit.edu` pattern AND
         matches the same regex the Flutter client validates with.
    """
    if not url:
        return False
    candidate = url.rstrip("/")
    return candidate in ALLOWED_TARGET_SERVERS or bool(
        _ALLOWED_SERVER_RE.match(candidate)
    )


def _resolve_target_url(requested: str | None) -> str:
    """Pick a target upload URL, restricted to the allow-list."""
    if requested:
        candidate = requested.rstrip("/")
        if _is_allowed_server(candidate):
            return f"{candidate}/upload_lecture"
        logging.warning("Rejected unknown target server: %r", requested)
    return f"{INTERNAL_SERVER_URL}/upload_lecture"
