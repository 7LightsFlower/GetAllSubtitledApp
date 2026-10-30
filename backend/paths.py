"""Where the backend keeps its data.

Uploads, sessions, state (incl. saved live sessions and folders) and
per-video settings live under DATA_DIR. Default: <project>/lib — the same
folders the former lib/backend.py used, and the ones the Docker volumes
are mounted on (/app/lib/uploads, /app/lib/sessions, /app/lib/state).
Override with the BACKEND_DATA_DIR environment variable.
"""

import os

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.environ.get("BACKEND_DATA_DIR") or os.path.join(PROJECT_DIR, "lib")
