"""Live microphone ASR + translation relay.

The browser cannot talk to the KIT Lecture Translator directly: KIT
authenticates with the `_forward_auth` cookie, which a page on another
origin can neither set nor send, and KIT does not send CORS headers for
this app's origin. This module is the thin pipe in between.

    Browser (LiveAsrScreen)                Flask (this file)              KIT
    ──────────────────────                ─────────────────              ───
    POST /api/live/start   {lang, mt}  →   adapter.start()          →  open live session
    POST /api/live/<id>/audio  PCM     →   adapter.append_audio()   →  push audio
    GET  /api/live/<id>/events (SSE)   ←   adapter.iter_events()    ←  ASR / MT messages
    POST /api/live/<id>/stop           →   adapter.end()            →  close session

While a session runs, everything is in memory only; the record is
dropped on stop or after IDLE_TIMEOUT_S without audio.

Finished sessions (the final transcript + translations the browser
shows) are saved per user under `storage_dir` and listed by the
"Live Sessions" screen:

    GET    /api/live/saved            list (newest first, summaries)
    POST   /api/live/saved            save a finished session
    GET    /api/live/saved/<id>       full transcript
    DELETE /api/live/saved/<id>       delete

The user is the email inside the KIT token (`<opaque>|<expiry>|<email>`),
so the list follows the person across browsers and devices.

Audio format expected from the browser: raw PCM, signed 16-bit
little-endian, mono, 16 kHz (`pcm_s16le`). Timestamps are derived here
from the cumulative sample count, so the client does not send any.

Every KIT-specific detail (paths, payload field names, response shape)
lives in `KitLiveAdapter`. The KIT live API is not publicly documented;
the paths below follow the mediator's `ltapi` scheme and MUST be checked
against the server you point at before relying on this.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import json
import logging
import os
import re
import threading
import time
import uuid
from typing import Callable, Iterator, Optional

import requests
from flask import Blueprint, Response, jsonify, request

SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2
IDLE_TIMEOUT_S = 120
# After END, keep relaying for this long so the last ASR/MT results
# (which arrive after the audio stops) still reach the browser.
END_GRACE_S = 15
MAX_CHUNK_BYTES = SAMPLE_RATE * BYTES_PER_SAMPLE * 5  # 5 s per POST is plenty

log = logging.getLogger("live_relay")

# KIT's reverse proxy (Traefik) guards /ltapi/ with HTTP Basic auth —
# a separate login from the user's KIT token, which only satisfies the
# Dex/forward-auth check on the web routes (/upload_lecture, …).
#
# Credentials are looked up per server, first match wins:
#   1. lib/state/ltapi_credentials.json (or $KIT_LTAPI_CREDENTIALS_FILE):
#        {
#          "https://lt2srv.iar.kit.edu":        {"user": "…", "password": "…"},
#          "https://lt2srv-backup.iar.kit.edu": {"user": "…", "password": "…"},
#          "*":                                 {"user": "…", "password": "…"}
#        }
#      Keys may be full URLs or bare host names; "*" is the default.
#      The file is re-read on every session start, so edits apply
#      without a restart. lib/state/ is git-ignored and a Docker volume.
#   2. Environment (applies to every server):
#        KIT_LTAPI_USER=…  KIT_LTAPI_PASSWORD=…   or  KIT_LTAPI_BASIC_AUTH=user:pass
CREDENTIALS_FILE = os.environ.get(
    "KIT_LTAPI_CREDENTIALS_FILE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "state",
                 "ltapi_credentials.json"),
)


def _host_key(url: str) -> str:
    u = url.strip().rstrip("/").lower()
    return u.split("://", 1)[-1]


def _credentials_from_file(
    server_url: str,
) -> tuple[Optional[tuple[str, str]], str]:
    """(credentials or None, human-readable note on where they came from)."""
    try:
        # utf-8-sig: Windows editors often prepend a BOM, which plain
        # utf-8 json.load rejects.
        with open(CREDENTIALS_FILE, "r", encoding="utf-8-sig") as f:
            table = json.load(f)
    except FileNotFoundError:
        return None, f"file not found: {CREDENTIALS_FILE}"
    except (OSError, ValueError) as e:
        log.warning("live: cannot read %s: %s", CREDENTIALS_FILE, e)
        return None, f"file unreadable ({e}): {CREDENTIALS_FILE}"
    if not isinstance(table, dict):
        return None, f"file is not a JSON object: {CREDENTIALS_FILE}"

    wanted = _host_key(server_url)
    entry, matched = None, None
    for key, value in table.items():
        if key != "*" and _host_key(key) == wanted:
            entry, matched = value, key
            break
    if entry is None and "*" in table:
        entry, matched = table["*"], "*"
    if entry is None:
        return None, (
            f"no entry for {wanted} (keys: {', '.join(table) or '-'}) "
            f"in {CREDENTIALS_FILE}"
        )
    if not isinstance(entry, dict):
        return None, f"entry {matched!r} is not an object in {CREDENTIALS_FILE}"
    user = str(entry.get("user") or entry.get("username") or "").strip()
    pw = str(entry.get("password") or "")
    if not user:
        return None, f"entry {matched!r} has no \"user\" in {CREDENTIALS_FILE}"
    note = f"user {user!r} from entry {matched!r} in {CREDENTIALS_FILE}"
    if pw != pw.strip():
        note += " (WARNING: password has leading/trailing spaces)"
    if not pw:
        note += " (WARNING: empty password)"
    return (user, pw), note


def _ltapi_credentials(
    server_url: str = "",
) -> tuple[Optional[tuple[str, str]], str]:
    """Basic credentials for /ltapi/ on this server, plus where they came from."""
    found, note = (
        _credentials_from_file(server_url) if server_url else (None, "no server")
    )
    if found:
        return found, note
    user = os.environ.get("KIT_LTAPI_USER", "").strip()
    pw = os.environ.get("KIT_LTAPI_PASSWORD", "")
    if not user:
        combined = os.environ.get("KIT_LTAPI_BASIC_AUTH", "")
        if ":" in combined:
            user, pw = combined.split(":", 1)
            user = user.strip()
    if user:
        return (user, pw), f"user {user!r} from environment ({note})"
    return None, f"none configured — {note}"


def _ltapi_basic_auth(server_url: str = "") -> Optional[tuple[str, str]]:
    return _ltapi_credentials(server_url)[0]


# ═════════════════════════════════════════════════════════════════════
#  KIT adapter — the only place that knows KIT's live protocol
# ═════════════════════════════════════════════════════════════════════
class KitLiveAdapter:
    """HTTP calls to the KIT server for one live session.

    Mirrors what KIT's own live page (/index/live/ → /present/<id>) does
    in the browser, captured from DevTools on lt2srv-backup:

      start   POST /create                      form-urlencoded, same fields
                                                as the live settings form;
                                                answers with /present/<id>
      audio   POST /webapi/<id>/0/append        JSON body that is itself a
                                                JSON-encoded *string*:
                                                "{\"b64_enc_…\":…,\"start\":<unix s>,\"seq\":n}"
      log     POST /webapi/<id>/addstreamlog    no body (only when logging=1)

    Everything goes through the normal web login (the `_forward_auth`
    cookie), so no extra /ltapi/ credentials are needed.

    ⚠️ Still UNVERIFIED — adjust here if KIT disagrees:
      * EVENTS_PATH (results stream) was not in the capture yet.
      * The browser sends Opus (`b64_enc_opus`); we send raw PCM under
        AUDIO_KEY. If KIT returns no text, the mediator needs Opus.
      * How the browser signals "end of audio" was not in the capture;
        we send the mediator's {"controll": "END"} through /append.
    """

    CREATE_PATH = "/create"
    APPEND_PATH = "/webapi/{session}/{stream}/append"
    STREAMLOG_PATH = "/webapi/{session}/addstreamlog"
    EVENTS_PATH = "/webapi/stream"  # ⚠️ guess — query: ?channel=<session>
    STREAM_ID = "0"
    AUDIO_KEY = "b64_enc_pcm_s16le"

    # Kept for error messages / the CLI check; /webapi needs none.
    START_PATH = CREATE_PATH

    # HTML checkboxes are only submitted when ticked, so a "0" must be
    # left out rather than sent (the server may test for presence).
    _CHECKBOX_FIELDS = {
        "profanity", "filter_music", "summarization", "notes", "saasr",
        "aiassistant", "logging", "distinguish_unknown_speakers",
        "legals", "save_profile",
    }

    def __init__(self, server_url: str, token: str):
        self.server = server_url.rstrip("/")
        self.token = token
        self.session_id: Optional[str] = None
        self.stream_id: Optional[str] = None
        self.t0 = 0.0  # unix time of the first audio sample
        self.seq = 0
        self._http = requests.Session()
        self._http.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "X-Forward-Auth": token,
                "User-Agent": "Mozilla/5.0 (compatible; LT-LiveRelay/1.0)",
            }
        )
        self._http.cookies.set("_forward_auth", token)
        self._http.verify = False  # same as the rest of backend.py
        self.basic_auth = None
        self.auth_source = "not needed (/create and /webapi use the login cookie)"

    # ── lifecycle ────────────────────────────────────────────────────
    def start(self, payload: dict) -> None:
        """Create the live session exactly like KIT's live form does."""
        r = self._http.post(
            self.server + self.CREATE_PATH,
            data=self._form(payload),
            headers={
                "Accept": "text/html,application/xhtml+xml",
                "Referer": self.server + "/index/live/",
            },
            allow_redirects=False,
            timeout=(10, 60),
        )
        location = r.headers.get("Location", "")
        if r.status_code in (301, 302, 303, 307, 308) and "/present/" not in location:
            # Bounced to the login page: the cookie was not accepted.
            raise requests.HTTPError(
                f"KIT redirected /create to {location or 'login'}", response=r
            )
        if r.status_code >= 400:
            r.raise_for_status()

        m = re.search(r"/present/(\d+)", location) or re.search(
            r"/present/(\d+)", r.text or ""
        )
        if not m:
            raise RuntimeError(
                "KIT did not return a /present/<id> link after /create "
                f"(HTTP {r.status_code}): {' '.join((r.text or '')[:300].split())}"
            )
        self.session_id = m.group(1)
        self.stream_id = self.STREAM_ID
        self.t0 = time.time()
        self.seq = 0

        if str(payload.get("logging", "0")) == "1":
            try:
                self._http.post(
                    self.server
                    + self.STREAMLOG_PATH.format(session=self.session_id),
                    timeout=(10, 30),
                ).raise_for_status()
            except requests.RequestException as e:
                log.info("live: addstreamlog failed (ignored): %s", e)

    def append_audio(self, pcm: bytes, start_s: float, end_s: float) -> None:
        self._post_append(
            {
                self.AUDIO_KEY: base64.b64encode(pcm).decode("ascii"),
                "start": round(self.t0 + start_s, 3),
                "end": round(self.t0 + end_s, 3),
                "seq": self.seq,
            }
        )
        self.seq += 1

    def end(self) -> None:
        """Tell KIT the audio is over. The event stream stays open."""
        try:
            self._control("END")
        except Exception as e:  # best effort on shutdown
            log.info("live: END failed (ignored): %s", e)

    def close(self) -> None:
        """Drop the HTTP connections (also ends iter_events)."""
        self._http.close()

    def iter_events(self) -> Iterator[dict]:
        """Yield KIT messages (dicts) from the session's event stream."""
        with self._http.get(
            self.server + self.EVENTS_PATH,
            params={"channel": self.session_id},
            headers={"Accept": "text/event-stream"},
            stream=True,
            timeout=(10, None),
        ) as r:
            r.raise_for_status()
            data_lines: list[str] = []
            for raw in r.iter_lines(decode_unicode=True):
                if raw is None:
                    continue
                if raw == "":  # end of one SSE event
                    if data_lines:
                        msg = self._decode("\n".join(data_lines))
                        data_lines = []
                        if msg is not None:
                            yield msg
                    continue
                if raw.startswith("data:"):
                    data_lines.append(raw[5:].lstrip())
                elif not raw.startswith((":", "event:", "id:", "retry:")):
                    # Some mediators emit bare JSON lines, not SSE.
                    msg = self._decode(raw)
                    if msg is not None:
                        yield msg

    # ── helpers ──────────────────────────────────────────────────────
    def _form(self, payload: dict) -> list[tuple[str, str]]:
        """Payload dict → form fields, lists as repeated keys like the
        browser sends (language=en&language=de…)."""
        fields: list[tuple[str, str]] = [("path", ""), ("profile_names", "")]
        for key, value in payload.items():
            if value is None or key == "token":
                continue
            if isinstance(value, (list, tuple)):
                fields.extend((key, str(v)) for v in value)
            elif key in self._CHECKBOX_FIELDS:
                if str(value) not in ("0", "", "false", "False"):
                    fields.append((key, "1"))
            else:
                fields.append((key, str(value)))
        return fields

    def _control(self, what: str) -> None:
        self._post_append({"controll": what})  # sic — KIT's spelling

    def _post_append(self, body: dict) -> None:
        url = self.server + self.APPEND_PATH.format(
            session=self.session_id, stream=self.stream_id
        )
        # KIT's page sends JSON.stringify(JSON.stringify(obj)): the body
        # is a JSON string whose content is the JSON object.
        r = self._http.post(
            url,
            json=json.dumps(body, separators=(",", ":")),
            headers={"Accept": "application/json"},
            timeout=(10, 30),
        )
        r.raise_for_status()

    @staticmethod
    def _decode(text: str) -> Optional[dict]:
        try:
            msg = json.loads(text)
        except ValueError:
            return None
        # Some streams wrap the payload as a JSON string.
        if isinstance(msg, str):
            try:
                msg = json.loads(msg)
            except ValueError:
                return None
        return msg if isinstance(msg, dict) else None


# ═════════════════════════════════════════════════════════════════════
#  In-memory session registry (no persistence, by design)
# ═════════════════════════════════════════════════════════════════════
class _LiveSession:
    def __init__(self, adapter: KitLiveAdapter, token: str):
        self.id = uuid.uuid4().hex
        self.adapter = adapter
        self.token = token
        self.samples_sent = 0
        self.last_seen = time.monotonic()
        self.lock = threading.Lock()  # keeps audio chunks in order
        self.closed = False
        self.closed_at = 0.0


_sessions: dict[str, _LiveSession] = {}
_registry_lock = threading.Lock()


def _get(live_id: str) -> Optional[_LiveSession]:
    with _registry_lock:
        return _sessions.get(live_id)


def _close(sess: _LiveSession) -> None:
    with _registry_lock:
        _sessions.pop(sess.id, None)
    if not sess.closed:
        sess.closed = True
        sess.closed_at = time.monotonic()
        sess.adapter.end()
        # Hard stop for the event stream if KIT never ends it.
        threading.Timer(END_GRACE_S, sess.adapter.close).start()
        log.info(
            "live: closed %s after %.1f s of audio",
            sess.id[:8],
            sess.samples_sent / SAMPLE_RATE,
        )


def _reap_idle() -> None:
    now = time.monotonic()
    with _registry_lock:
        stale = [
            s for s in _sessions.values() if now - s.last_seen > IDLE_TIMEOUT_S
        ]
    for s in stale:
        log.info("live: reaping idle session %s", s.id[:8])
        _close(s)


def _bearer() -> str:
    auth = request.headers.get("Authorization", "")
    return auth[7:].strip() if auth.startswith("Bearer ") else ""


# ═════════════════════════════════════════════════════════════════════
#  Routes
# ═════════════════════════════════════════════════════════════════════
# ═════════════════════════════════════════════════════════════════════
#  Saved (finished) live sessions — one JSON file per session
# ═════════════════════════════════════════════════════════════════════
_SAVED_ID_RE = re.compile(r"^[0-9a-f]{32}$")
MAX_SAVED_BYTES = 5 * 1024 * 1024  # a long lecture × several languages fits
PREVIEW_CHARS = 160


def _email_from_token(token: str) -> str:
    parts = (token or "").split("|")
    if len(parts) >= 3 and "@" in parts[-1]:
        return parts[-1].strip().lower()
    return ""


class _SavedStore:
    """Per-user folder of `<id>.json` files. Thread-safe enough for one
    gunicorn worker: every write goes through a temp file + os.replace."""

    def __init__(self, root: str):
        self.root = root

    def _user_dir(self, email: str) -> str:
        key = hashlib.sha256(email.encode("utf-8")).hexdigest()[:24]
        return os.path.join(self.root, key)

    def _path(self, email: str, sid: str) -> str:
        return os.path.join(self._user_dir(email), f"{sid}.json")

    def save(self, email: str, record: dict) -> None:
        d = self._user_dir(email)
        os.makedirs(d, exist_ok=True)
        path = self._path(email, record["id"])
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(record, f, ensure_ascii=False)
        os.replace(tmp, path)

    def load(self, email: str, sid: str) -> Optional[dict]:
        try:
            with open(self._path(email, sid), "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def delete(self, email: str, sid: str) -> bool:
        try:
            os.remove(self._path(email, sid))
            return True
        except OSError:
            return False

    def list(self, email: str) -> list[dict]:
        d = self._user_dir(email)
        if not os.path.isdir(d):
            return []
        out = []
        for name in os.listdir(d):
            if not name.endswith(".json"):
                continue
            rec = self.load(email, name[:-5])
            if rec:
                out.append(_summary(rec))
        out.sort(key=lambda r: r.get("created_at") or "", reverse=True)
        return out


def _summary(rec: dict) -> dict:
    lanes = rec.get("lanes") or []
    original = next((l for l in lanes if l.get("key") == "asr"), None)
    text = ((original or (lanes[0] if lanes else {})).get("text") or "").strip()
    return {
        "id": rec.get("id"),
        "name": rec.get("name") or "",
        "created_at": rec.get("created_at"),
        "duration_s": rec.get("duration_s") or 0,
        "server": rec.get("server") or "",
        "input_languages": rec.get("input_languages") or [],
        "output_languages": rec.get("output_languages") or [],
        "lanes": [l.get("key") for l in lanes],
        "word_count": len(text.split()),
        "preview": text[:PREVIEW_CHARS],
    }


def _clean_lanes(raw) -> list[dict]:
    lanes = []
    for l in raw if isinstance(raw, list) else []:
        if not isinstance(l, dict):
            continue
        key = str(l.get("key") or "").strip()[:32]
        if not key:
            continue
        lanes.append(
            {
                "key": key,
                "title": str(l.get("title") or key)[:200],
                "text": str(l.get("text") or ""),
            }
        )
    return lanes


def create_live_blueprint(
    resolve_server: Callable[[Optional[str]], str],
    storage_dir: str,
) -> Blueprint:
    """Build the blueprint.

    `resolve_server(requested)` must return an allow-listed KIT base URL
    (no trailing slash), falling back to the default server.
    `storage_dir` is where finished sessions are saved (created on demand;
    put it on a persistent volume).
    """
    bp = Blueprint("live_relay", __name__, url_prefix="/api/live")
    store = _SavedStore(storage_dir)

    def _caller_email():
        """(email, error_response). Saved sessions belong to the email
        in the KIT token; a token without one cannot own any."""
        token = _bearer()
        if not token:
            return None, (jsonify({"error": "Missing token"}), 401)
        email = _email_from_token(token)
        if not email:
            return None, (
                jsonify({"error": "Token carries no user email"}),
                401,
            )
        return email, None

    @bp.route("/saved", methods=["GET"])
    def saved_list():
        email, err = _caller_email()
        if err:
            return err
        return jsonify({"sessions": store.list(email)}), 200

    @bp.route("/saved", methods=["POST"])
    def saved_create():
        email, err = _caller_email()
        if err:
            return err
        if (request.content_length or 0) > MAX_SAVED_BYTES:
            return jsonify({"error": "Session too large to save"}), 413
        body = request.get_json(silent=True) or {}
        lanes = _clean_lanes(body.get("lanes"))
        if not any(l["text"].strip() for l in lanes):
            return jsonify({"error": "Nothing to save"}), 400

        sid = str(body.get("id") or "")
        if not _SAVED_ID_RE.match(sid):
            sid = uuid.uuid4().hex

        def str_list(v):
            return [str(x) for x in v][:50] if isinstance(v, list) else []

        settings = body.get("settings")
        record = {
            "id": sid,
            "name": str(body.get("name") or "").strip()[:200]
            or f"live_{sid[:8]}",
            "created_at": str(body.get("created_at") or "")
            or datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "saved_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "duration_s": float(body.get("duration_s") or 0),
            "server": str(body.get("server") or "")[:200],
            "input_languages": str_list(body.get("input_languages")),
            "output_languages": str_list(body.get("output_languages")),
            "settings": settings if isinstance(settings, dict) else {},
            "lanes": lanes,
        }
        try:
            store.save(email, record)
        except OSError as e:
            log.warning("live: saving %s failed: %s", sid[:8], e)
            return jsonify({"error": "Could not write to disk"}), 500
        log.info("live: saved session %s (%d lanes)", sid[:8], len(lanes))
        return jsonify({"id": sid}), 201

    @bp.route("/saved/<sid>", methods=["GET"])
    def saved_get(sid):
        email, err = _caller_email()
        if err:
            return err
        rec = store.load(email, sid) if _SAVED_ID_RE.match(sid) else None
        if rec is None:
            return jsonify({"error": "Not found"}), 404
        return jsonify(rec), 200

    @bp.route("/saved/<sid>", methods=["DELETE"])
    def saved_delete(sid):
        email, err = _caller_email()
        if err:
            return err
        if not _SAVED_ID_RE.match(sid) or not store.delete(email, sid):
            return jsonify({"error": "Not found"}), 404
        return ("", 204)

    @bp.route("/start", methods=["POST"])
    def live_start():
        _reap_idle()
        body = request.get_json(silent=True) or {}
        token = (body.get("token") or _bearer()).strip()
        if not token:
            return jsonify({"error": "Missing token"}), 401

        def as_list(v) -> list[str]:
            if isinstance(v, str):
                return [v] if v.strip() else []
            return [x for x in (v or []) if isinstance(x, str) and x.strip()]

        language = as_list(body.get("language"))
        mt = as_list(body.get("mtLanguage"))
        if not language:
            return jsonify({"error": "Missing input language"}), 400

        # Same field names as the offline /upload body. Unknown keys are
        # passed through so new KIT options need no relay change.
        settings = body.get("settings") or {}
        if not isinstance(settings, dict):
            settings = {}
        payload = {
            "format": "online",
            "logging": "0",  # default: KIT does not archive the session
            **{k: v for k, v in settings.items() if k not in ("token",)},
            "language": language,
            "mtLanguage": mt,
        }

        server = resolve_server(body.get("targetServer"))
        adapter = KitLiveAdapter(server, token)
        try:
            adapter.start(payload)
        except requests.HTTPError as e:
            resp = e.response
            code = resp.status_code if resp is not None else 502
            # Log what KIT actually answered — the status alone can't tell
            # "wrong token" from "this path isn't the live API".
            detail = ""
            if resp is not None:
                hdrs = {
                    k: v
                    for k, v in resp.headers.items()
                    if k.lower()
                    in ("www-authenticate", "location", "content-type", "server")
                }
                body_snip = " ".join((resp.text or "")[:300].split())
                detail = f"headers={hdrs} body={body_snip!r}"
            log.warning(
                "live: KIT refused start (%s) at %s as %s — basic auth: %s — %s",
                code,
                adapter.server + adapter.START_PATH,
                _email_from_token(token) or "<no email in token>",
                adapter.auth_source,
                detail,
            )
            challenge = (
                (resp.headers.get("WWW-Authenticate") or "")
                if resp is not None
                else ""
            )
            if code == 401 and challenge.lower().startswith("basic"):
                # Proxy-level Basic auth: the user's token is not the issue.
                msg = (
                    f"The live API on {server} (/ltapi/) is protected by a "
                    "separate HTTP Basic login at KIT's proxy. Your KIT token "
                    "is fine but cannot open it. "
                    + (
                        f"The credentials configured for this server (user "
                        f"'{adapter.basic_auth[0]}') were rejected."
                        if adapter.basic_auth
                        else "No credentials found for this server ("
                        + adapter.auth_source
                        + ")."
                    )
                )
                return (
                    jsonify(
                        {
                            "error": msg,
                            "kit_status": code,
                            "reason": "ltapi_basic_auth",
                        }
                    ),
                    502,
                )
            if code in (401, 403) or 300 <= code < 400:
                return (
                    jsonify(
                        {
                            "error": (
                                f"{server} rejected the login (HTTP {code}"
                                + (", redirected to its login page"
                                   if 300 <= code < 400 else "")
                                + "). "
                                "Make sure the token was taken from this "
                                "server's /gettoken page."
                            ),
                            "kit_status": code,
                        }
                    ),
                    401,
                )
            if code == 404:
                return (
                    jsonify(
                        {
                            "error": (
                                f"{server} has no live API at "
                                f"{adapter.START_PATH} (HTTP 404)."
                            ),
                            "kit_status": code,
                        }
                    ),
                    502,
                )
            return jsonify({"error": f"KIT error {code}", "kit_status": code}), 502
        except Exception as e:
            log.warning("live: start failed: %s", e)
            return jsonify({"error": str(e)}), 502

        sess = _LiveSession(adapter, token)
        with _registry_lock:
            _sessions[sess.id] = sess
        log.info(
            "live: started %s on %s (%s → %s)",
            sess.id[:8],
            server,
            ",".join(language),
            ",".join(mt) or "-",
        )
        return jsonify({"live_id": sess.id, "sample_rate": SAMPLE_RATE}), 200

    @bp.route("/<live_id>/audio", methods=["POST"])
    def live_audio(live_id):
        sess = _get(live_id)
        if sess is None:
            return jsonify({"error": "Unknown or closed live session"}), 404
        if _bearer() != sess.token:
            return jsonify({"error": "Forbidden"}), 403

        pcm = request.get_data(cache=False)
        if not pcm:
            return ("", 204)
        if len(pcm) > MAX_CHUNK_BYTES:
            return jsonify({"error": "Chunk too large"}), 413
        if len(pcm) % BYTES_PER_SAMPLE:
            pcm = pcm[:-1]

        with sess.lock:
            n = len(pcm) // BYTES_PER_SAMPLE
            start_s = sess.samples_sent / SAMPLE_RATE
            end_s = (sess.samples_sent + n) / SAMPLE_RATE
            try:
                sess.adapter.append_audio(pcm, start_s, end_s)
            except Exception as e:
                log.warning("live: append failed for %s: %s", live_id[:8], e)
                return jsonify({"error": "Forwarding audio to KIT failed"}), 502
            sess.samples_sent += n
            sess.last_seen = time.monotonic()
        return ("", 204)

    @bp.route("/<live_id>/events", methods=["GET"])
    def live_events(live_id):
        # EventSource cannot send headers, so this endpoint is guarded
        # only by the unguessable live_id (uuid4).
        sess = _get(live_id)
        if sess is None:
            return jsonify({"error": "Unknown or closed live session"}), 404

        def gen():
            yield "retry: 3000\n\n"
            try:
                for msg in sess.adapter.iter_events():
                    yield f"data: {json.dumps(msg, ensure_ascii=False)}\n\n"
                    if (
                        sess.closed
                        and time.monotonic() - sess.closed_at > END_GRACE_S
                    ):
                        break
            except GeneratorExit:  # browser went away
                raise
            except Exception as e:
                if not sess.closed:  # errors after stop are expected
                    log.info("live: event stream %s ended: %s", live_id[:8], e)
                    yield f"event: relay-error\ndata: {json.dumps(str(e))}\n\n"
            yield "event: end\ndata: {}\n\n"

        return Response(
            gen(),  # no stream_with_context: gen() never touches `request`
            mimetype="text/event-stream",
            headers={
                "Cache-Control": "no-store",
                "X-Accel-Buffering": "no",  # nginx: don't buffer SSE
            },
        )

    @bp.route("/<live_id>/stop", methods=["POST"])
    def live_stop(live_id):
        sess = _get(live_id)
        if sess is None:
            return ("", 204)  # already gone — stopping is idempotent
        if _bearer() != sess.token:
            return jsonify({"error": "Forbidden"}), 403
        _close(sess)
        return ("", 204)

    return bp


# ═════════════════════════════════════════════════════════════════════
#  Command-line check:  python lib/live_relay.py [server-url ...]
# ═════════════════════════════════════════════════════════════════════
def _check_cli(servers: list[str]) -> None:
    """Show which /ltapi/ credentials each server gets and whether the
    proxy accepts them. Sends one GET to <server>/ltapi/ — no session is
    created and no passwords are printed."""
    import urllib3

    urllib3.disable_warnings()
    print(f"credentials file: {CREDENTIALS_FILE}")
    print(f"  exists: {os.path.exists(CREDENTIALS_FILE)}")
    if not servers:
        try:
            with open(CREDENTIALS_FILE, "r", encoding="utf-8-sig") as f:
                servers = [k for k in json.load(f) if k != "*"]
        except Exception as e:
            print(f"  cannot read it: {e}")
    for server in servers:
        server = server.rstrip("/")
        if "://" not in server:
            server = "https://" + server
        creds, note = _ltapi_credentials(server)
        print(f"\n{server}")
        print(f"  basic auth: {note}")
        for label, auth in (("without credentials", None), ("with credentials", creds)):
            if label == "with credentials" and not creds:
                continue
            try:
                r = requests.get(
                    server + "/ltapi/", auth=auth, verify=False, timeout=15,
                    allow_redirects=False,
                )
                chal = r.headers.get("WWW-Authenticate", "")
                verdict = (
                    "REJECTED by proxy (Basic auth)"
                    if r.status_code == 401 and chal.lower().startswith("basic")
                    else "passed the proxy"
                )
                print(f"  {label:20}: HTTP {r.status_code} -> {verdict}"
                      + (f"  [{chal}]" if chal else ""))
            except requests.RequestException as e:
                print(f"  {label:20}: request failed: {e}")


if __name__ == "__main__":
    import sys

    _check_cli(sys.argv[1:])
