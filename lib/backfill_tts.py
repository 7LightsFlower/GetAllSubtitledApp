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
    state = getattr(backend, "_state", {})
    return state.get("token") or ""


def main() -> None:
    """Backfill TTS for every session the server currently knows about."""
    token = _token_from_any_session()
    if not token:
        logging.error(
            "No cached token. Open the app once so the server sees one, then re-run."
        )
        return

    sessions = getattr(backend, "sessions", {})
    if not isinstance(sessions, dict):
        logging.warning(
            "Backfill unavailable: backend.sessions is not a dictionary"
        )
        return

    for session_id in list(sessions):
        # Avoid accessing a dynamically supplied attribute directly; the
        # extension analyzer cannot determine that sessions implements get().
        session = getattr(sessions, "get")(session_id)
        if not isinstance(session, dict):
            logging.warning(
                "Backfill unavailable for %s: session entry is not a dictionary",
                session_id[:8],
            )
            continue

        server = session.get("server") or getattr(
            backend, "INTERNAL_SERVER_URL", getattr(backend, "SERVER_URL", "")
        )
        download_tts_files = getattr(backend, "download_tts_files", None)
        if not callable(download_tts_files):
            logging.warning(
                "Backfill unavailable for %s: backend.download_tts_files is not callable",
                session_id[:8],
            )
            continue

        try:
            # Resolve the attribute again so static analyzers do not infer that
            # the value checked above is still a non-callable attribute.
            written = getattr(backend, "download_tts_files")(
                session_id, token, server
            )
            logging.info("%s → %d file(s)", session_id[:8], len(written))
        except (OSError, ValueError, TypeError) as exc:
            logging.warning("Backfill failed for %s: %s", session_id[:8], exc)

    save_state = getattr(backend, "save_state", None)
    if callable(save_state):
        # Resolve the attribute at the call site so static analyzers do not
        # infer the value checked above as a non-callable attribute.
        getattr(backend, "save_state")()


if __name__ == "__main__":
    main()
