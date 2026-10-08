#!/usr/bin/env python3
"""Convenience entry point: `python run_backend.py` from the project root."""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from backend.app import app  # noqa: E402

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)