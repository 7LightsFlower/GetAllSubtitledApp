"""Register all blueprints on the Flask app."""

from . import (
    auth,
    debug,
    exports,
    sessions,
    settings,
    tts,
    upload,
    videos,
    youtube,
)


def register_all(app):
    """Register all application blueprints on the Flask app."""
    for module in (
        auth,
        videos,
        sessions,
        exports,
        tts,
        youtube,
        upload,
        settings,
        debug,
    ):
        app.register_blueprint(module.bp)
