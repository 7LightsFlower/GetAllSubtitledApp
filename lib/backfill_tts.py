"""One-shot backfill: pull every session's TTS WAVs into its local folder.

Run from the directory that contains backend.py:

    python backfill_tts.py
"""

import logging
import os
import sys

# Ensure the directory containing backend.py is importable even when the editor
# launches this file from a different working directory.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

# pylint: disable=wrong-import-position,import-error
# pyright: ignore[reportMissingImports]
import backend  # type: ignore[import-not-found]

logging.basicConfig(level=logging.INFO)


def _token_from_any_session() -> str:
    """Return any bearer token the server has cached, else ''.

    Reaches into the public surface where possible; the token cache
    is the one piece of state that has no public accessor yet.
    """
    # pylint: disable=protected-access
    return backend._state.get("token") or ""


def main() -> None:
    """Backfill TTS for every session the server currently knows about."""
    token = _token_from_any_session()
    if not token:
        logging.error(
            "No cached token. Open the app once so the server sees one, then re-run."
        )
        return

    for session_id in list(backend.sessions.keys()):
        server = (
            backend.sessions.get(session_id, {}).get("server")
            or backend.INTERNAL_SERVER_URL
        )
        try:
            written = backend.download_tts_files(session_id, token, server)
            logging.info("%s → %d file(s)", session_id[:8], len(written))
        except (OSError, ValueError, TypeError) as exc:
            logging.warning("Backfill failed for %s: %s", session_id[:8], exc)

    backend.save_state()


if __name__ == "__main__":
    main()
