"""Install the panel log handler on the root logger.

Importing this module has the side effect of attaching the handler.
That mirrors what backend.py did at module scope.
"""

import logging

from .progress import PanelLogHandler

_panel_handler = PanelLogHandler()
_panel_handler.setLevel(logging.INFO)
logging.getLogger().addHandler(_panel_handler)


def install() -> None:
    """Idempotent — safe to call from app.py even if already installed."""
    root = logging.getLogger()
    if not any(isinstance(h, PanelLogHandler) for h in root.handlers):
        root.addHandler(_panel_handler)