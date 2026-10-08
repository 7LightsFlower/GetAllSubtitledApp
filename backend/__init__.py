"""Flask backend for the ASR live translator.

Split out of a single backend.py into focused modules. The Flask app
lives in :mod:`backend.app`.
"""

from .app import create_app

__all__ = ["create_app"]
