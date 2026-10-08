"""Register all blueprints on the Flask app."""

from . import auth, debug, exports, sessions, tts, upload, videos, youtube


def register_all(app):
    for module in (auth, videos, sessions, exports, tts, youtube, upload, debug):
        app.register_blueprint(module.bp)