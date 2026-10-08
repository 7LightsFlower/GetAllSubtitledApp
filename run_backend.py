#!/usr/bin/env python3
"""Convenience entry point: `python run_backend.py` from the project root."""

import os
import sys
from importlib import import_module

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

app = import_module("backend.app").application

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
