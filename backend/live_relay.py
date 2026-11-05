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
import tempfile
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
                                                "{\"b64_enc_…\":…,\"start\":<unix s>,\"end\":<unix s>}"
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
        # Permanent (shorten) name: the one asked for, or — when the field
        # was left empty — the random one KIT picked (read from /present).
        self.shorten = str(payload.get("shorten") or "").strip() or self._find_shorten(r)

        if str(payload.get("logging", "0")) == "1":
            try:
                self._http.post(
                    self.server
                    + self.STREAMLOG_PATH.format(session=self.session_id),
                    timeout=(10, 30),
                ).raise_for_status()
            except requests.RequestException as e:
                log.info("live: addstreamlog failed (ignored): %s", e)

    _SHORTEN_RE = re.compile(r"/(?:webapi/)?shorten/(?:webapi/|view2?/)?([A-Za-z0-9]{3,64})")

    def _find_shorten(self, create_resp) -> str:
        """KIT's random permanent name for this session ('' if not found).
        Looks in the /create answer, then in the session's /present page."""
        texts = [create_resp.headers.get("Location", ""), create_resp.text or ""]
        for t in texts:
            m = self._SHORTEN_RE.search(t)
            if m:
                return m.group(1)
        try:
            page = self._http.get(
                f"{self.server}/present/{self.session_id}", timeout=(5, 15)
            )
            m = self._SHORTEN_RE.search(page.text or "")
            if m:
                return m.group(1)
            log.info("live: no permanent name found on /present/%s", self.session_id)
        except requests.RequestException as e:
            log.info("live: reading /present for the permanent name failed: %s", e)
        return ""

    def append_audio(self, pcm: bytes, start_s: float, end_s: float) -> None:
        self._post_append(
            {
                self.AUDIO_KEY: base64.b64encode(pcm).decode("ascii"),
                "start": round(self.t0 + start_s, 3),
                "end": round(self.t0 + end_s, 3),
                # No "seq" here: in the mediator "seq" means *text*, and
                # qbmediator's Interface.process() then also runs
                # save_text() on the audio chunk → json.dumps(bytes) error.
            }
        )
        self.seq += 1

    def end(self, attempts: int = 4) -> bool:
        """Tell KIT the audio is over (the event stream stays open).
        Retries with backoff; True once KIT accepted it."""
        delay = 1.0
        for i in range(attempts):
            try:
                self._control("END")
                return True
            except Exception as e:
                status = getattr(getattr(e, "response", None), "status_code", None)
                if status in (400, 404, 410):
                    # KIT no longer knows the session: nothing left to end.
                    log.info("live: END for %s → HTTP %s (session gone)",
                             self.session_id, status)
                    return True
                log.info("live: END attempt %d/%d failed: %s", i + 1, attempts, e)
                if i + 1 < attempts:
                    time.sleep(delay)
                    delay *= 3
        return False

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
            event_name = ""
            for raw in r.iter_lines(decode_unicode=True):
                if raw is None:
                    continue
                if raw == "":  # end of one SSE event
                    if data_lines:
                        msg = self._decode("\n".join(data_lines))
                        data_lines = []
                        if msg is not None:
                            # The SSE event name is how KIT tags a message
                            # with its language/stream (the archive keeps
                            # it as the first element of each pair).
                            if event_name and event_name != "message":
                                msg.setdefault("_channel", event_name)
                            yield msg
                    event_name = ""
                    continue
                if raw.startswith("data:"):
                    data_lines.append(raw[5:].lstrip())
                elif raw.startswith("event:"):
                    event_name = raw[6:].strip()
                elif not raw.startswith((":", "id:", "retry:")):
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
_LANG_FIELDS = (
    "language", "lang", "tgt_lang", "target_language", "target_lang",
    "mt_language", "language_code", "target",
)
_CODE_RE = re.compile(r"^[a-z]{2,3}(?:[-_][a-z]{2,4})?$", re.I)
_INDEXED_SENDER_RE = re.compile(r"^(mt|tts)[:_](\d+)$", re.I)

# Languages recognisable from their script alone. Used to double-check
# (and if needed correct) the order-based mapping mt:N → N-th language.
_SCRIPTS = [
    (re.compile(r"[\u0400-\u04FF]"), ("ru", "uk", "bg", "sr", "mk", "be", "kk")),
    (re.compile(r"[\u0600-\u06FF]"), ("ar", "fa", "ur", "ps")),
    (re.compile(r"[\u0590-\u05FF]"), ("he", "yi")),
    (re.compile(r"[\u0370-\u03FF]"), ("el",)),
    (re.compile(r"[\u3040-\u30FF]"), ("ja",)),
    (re.compile(r"[\uAC00-\uD7AF]"), ("ko",)),
    (re.compile(r"[\u4E00-\u9FFF]"), ("zh", "ja")),
    (re.compile(r"[\u0900-\u097F]"), ("hi", "mr", "ne")),
    (re.compile(r"[\u0980-\u09FF]"), ("bn",)),
    (re.compile(r"[\u0B80-\u0BFF]"), ("ta",)),
    (re.compile(r"[\u0E00-\u0E7F]"), ("th",)),
    (re.compile(r"[\u10A0-\u10FF]"), ("ka",)),
    (re.compile(r"[\u0530-\u058F]"), ("hy",)),
]


# Frequent short words + typical letters for Latin-script languages. Only
# used to choose among the languages the user selected, so small lists
# are enough to tell e.g. English/German/Turkish apart.
_STOPWORDS = {
    "en": "the and is of to in that it you for was with on are this be have not we they what but so my just".split(),
    "de": "der die das und ist nicht ich es zu den mit sie ein eine auf für auch wir sich dass aber wie von im war mein noch".split(),
    "fr": "le la les et est un une que qui pas je il elle nous vous des du ce pour dans sur mais avec au ne".split(),
    "es": "el la los las y es que un una no en por para con lo se del al como pero yo mi este esta muy".split(),
    "it": "il la le e è di che un una non per con del della mi io sono ma come questo anche nel gli si".split(),
    "pt": "o a os as e é que um uma não em para com do da se mas como eu meu isso por no na".split(),
    "nl": "de het een en is van dat niet ik je op te met zijn voor maar wat er we ze hij ook dit aan".split(),
    "tr": "ve bir bu da de ne için ile ben sen değil var yok gibi çok ama mi mı daha bunu bunun şey kadar her olan ki".split(),
    "pl": "i w nie się na to że jest z do jak ale co tak mnie ja po czy jestem być tylko".split(),
    "cs": "a je v se na to že s z do jak ale co tak já není jsem jsou".split(),
    "sv": "och att det är en som på inte jag med för av till den har de om ett vi men".split(),
    "da": "og at det er en som på ikke jeg med for af til den har de vi men et".split(),
    "no": "og at det er en som på ikke jeg med for av til den har de vi men et".split(),
    "fi": "ja on ei se että oli hän mutta kun niin minä olen tämä".split(),
    "ro": "și este de la în că nu o un cu pe pentru care se sunt dar mai".split(),
    "hu": "a az és hogy nem is egy ez van de meg már csak mint".split(),
    "vi": "và là của không có những một được cho này tôi các".split(),
    "id": "dan yang di ini itu tidak dengan untuk saya ada dari ke".split(),
}
_LETTERS = {
    # ö/ü are shared by German, Turkish, Finnish, Hungarian … — not used.
    "tr": "ğşıİ", "de": "ßä", "pl": "łąęśżźćń", "cs": "řěůč", "ro": "șțăî",
    "hu": "őű", "es": "ñ¿¡", "fr": "çèêàœ", "pt": "ãõ", "sv": "å", "fi": "äö",
    "da": "æø", "no": "æø", "vi": "ơưđ",
}
_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


def _latin_scores(text: str, candidates: list) -> dict:
    words = [w.lower() for w in _WORD_RE.findall(text)]
    scores = {}
    for code in candidates:
        stop = _STOPWORDS.get(code)
        letters = _LETTERS.get(code, "")
        if not stop and not letters:
            continue
        sc = sum(1 for w in words if stop and w in stop)
        sc += 2 * sum(1 for ch in text if ch in letters)
        scores[code] = sc
    return scores


def _script_candidates(text: str) -> tuple[str, ...]:
    """Language codes whose script dominates `text` (empty if Latin/unclear)."""
    letters = [ch for ch in text if ch.isalpha()]
    if len(letters) < 3:
        return ()
    for pattern, codes in _SCRIPTS:
        if len(pattern.findall(text)) >= len(letters) * 0.5:
            if "ru" in codes:  # tell Russian / Ukrainian apart
                if re.search("[іїєґІЇЄҐ]", text):
                    return ("uk",) + tuple(c for c in codes if c != "uk")
                if re.search("[ыэъёЫЭЪЁ]", text):
                    return ("ru",) + tuple(c for c in codes if c != "ru")
            return codes
    return ()


class _LiveSession:
    def __init__(
        self,
        adapter: KitLiveAdapter,
        token: str,
        input_langs: list[str],
        mt_langs: list[str],
        settings: dict,
    ):
        self.id = uuid.uuid4().hex
        self.adapter = adapter
        self.token = token
        self.input_langs = [l.lower() for l in input_langs]
        self.mt_langs = [l.lower() for l in mt_langs]
        audio = settings.get("audioLanguage") or []
        self.audio_langs = [
            str(l).lower() for l in (audio if isinstance(audio, list) else [audio]) if l
        ]
        self.settings = settings
        self.samples_sent = 0
        self.last_seen = time.monotonic()
        self.lock = threading.Lock()  # keeps audio chunks in order
        self.closed = False
        self.closed_at = 0.0
        self.started_at = time.time()
        # Recording for the full output (Session Output screen).
        self.recorded: list[dict] = []
        # Spoken translation (TTS) chunks: lane, start, end, bytes, hint.
        self.tts_chunks: list[dict] = []
        self._seen_senders: set[str] = set()
        self._sender_lane: dict[str, str] = {}  # decided once per sender
        self._sender_scores: dict[str, dict] = {}
        self._sender_msgs: dict[str, int] = {}
        self._provisional: set[str] = set()  # senders shown under a temp lane
        # Events for the browser, e.g. {"_relabel": True, "from": "mt:2", "to": "tr"}
        self.pending_events: list[dict] = []
        # Spoken-translation language the browser wants to hear live.
        self.tts_listen: Optional[str] = None
        fd, self.pcm_path = tempfile.mkstemp(prefix="live_", suffix=".pcm")
        os.close(fd)
        self.finalized = False
        self.final_lock = threading.Lock()

    # ── language of a message ────────────────────────────────────────
    def lane_for(self, msg: dict) -> Optional[str]:
        """'asr', a target language code, or 'mt:<sender>' when KIT gives
        no usable language. None for senders that carry no text."""
        sender = str(msg.get("sender") or "")
        lane = self._resolve_lane(sender, msg)
        if sender and sender not in self._seen_senders:
            self._seen_senders.add(sender)
            shape = {
                k: (f"<str {len(v)} chars>" if isinstance(v, str) and len(v) > 80
                    else type(v).__name__)
                for k, v in msg.items()
            }
            log.info(
                "live: %s first message from sender %r: channel=%r lane=%r fields=%s",
                self.id[:8], sender, msg.get("_channel"), lane, shape,
            )
        return lane

    def tts_lane_for(self, msg: dict) -> Optional[str]:
        """Language of a spoken-translation (TTS) message."""
        sender = str(msg.get("sender") or "")
        langs = self.audio_langs or self.mt_langs
        candidates = [msg.get("_channel")] + [msg.get(k) for k in _LANG_FIELDS]
        for c in candidates:
            if isinstance(c, str) and _CODE_RE.match(c.strip()):
                return c.strip().lower().split("_")[0].split("-")[0]
        for code in langs:
            if re.search(rf"[:_\-]{re.escape(code)}(?![a-z])", sender, re.I):
                return code
        if len(langs) == 1:
            return langs[0]
        m = _INDEXED_SENDER_RE.match(sender)
        if m:  # tts:N speaks what mt:N translated
            return self._sender_lane.get(f"mt:{m.group(2)}")
        return None

    def record_tts(self, msg: dict) -> Optional[dict]:
        """Keep the audio of a TTS message; returns the stored chunk."""
        lane = self.tts_lane_for(msg)
        best_key, best = None, None
        for k, v in msg.items():
            if not isinstance(v, str) or len(v) < 200 or k.startswith("_"):
                continue
            lk = k.lower()
            if any(t in lk for t in ("b64", "audio", "wav", "pcm", "opus",
                                     "ogg", "mp3", "speech", "data")):
                if best is None or len(v) > len(best):
                    best_key, best = k, v
        if best is None:
            # Large payloads are not inline: KIT stores them in its database
            # and the stream carries a link instead ("send_link" →
            # "/ltapi/stream/data?name=Data/<session>/<n>", or a bare
            # "Data/…" reference). Fetch the audio behind it now — the
            # stored data expires.
            best_key, best = self._fetch_linked_audio(msg)
            if best is None:
                return None
        try:
            raw = base64.b64decode(best.split(",", 1)[-1], validate=False)
        except (ValueError, TypeError):
            return None
        if not raw:
            return None
        rate = None
        for k in ("sample_rate", "sampleRate", "sr", "rate"):
            try:
                rate = int(msg.get(k)) if msg.get(k) else rate
            except (TypeError, ValueError):
                pass
        if rate is None and raw[:4] != b"RIFF" and "pcm" in best_key.lower():
            # KIT sends no rate for raw PCM: derive it from the chunk's
            # length and its start/end, snapped to a standard rate.
            try:
                dur = float(msg.get("end")) - float(msg.get("start"))
            except (TypeError, ValueError):
                dur = 0.0
            if dur > 0.05:
                guess = (len(raw) // 2) / dur
                std = min((8000, 16000, 22050, 24000, 32000, 44100, 48000),
                          key=lambda r: abs(r - guess))
                if abs(std - guess) / std < 0.15:
                    rate = std
                    if not getattr(self, "_rate_logged", False):
                        self._rate_logged = True
                        log.info("live: %s TTS PCM sample rate %d Hz (from chunk timing)",
                                 self.id[:8], rate)
        chunk = {
            "sender": str(msg.get("sender") or "tts"),
            "lane": lane or str(msg.get("sender") or "tts"),
            "start": self._rebase(msg.get("start")) if "start" in msg else None,
            "end": self._rebase(msg.get("end")) if "end" in msg else None,
            "audio": raw,
            "key": best_key,
            "rate": rate,
            "b64": best.split(",", 1)[-1],
        }
        self.tts_chunks.append(chunk)
        return chunk

    def _fetch_linked_audio(self, msg: dict) -> tuple[Optional[str], Optional[str]]:
        """(field name, base64 audio) for a TTS message whose audio is a
        database link, or (None, None)."""
        for k, v in msg.items():
            if not isinstance(v, str) or k.startswith("_"):
                continue
            if v.startswith(("/ltapi/stream/data", "/webapi/stream/data")):
                # Same as KIT's own audio client: /ltapi → /webapi with
                # the login cookie.
                path = "/webapi" + v[len("/ltapi"):] if v.startswith("/ltapi") else v
            elif v.startswith("Data/"):
                path = "/webapi/stream/data?name=" + requests.utils.quote(v, safe="/")
            else:
                continue
            url = self.adapter.server + path
            try:
                r = self.adapter._http.get(url, timeout=(5, 15))
                r.raise_for_status()
                body = r.json()
            except Exception as e:
                if not getattr(self, "_link_err_logged", False):
                    self._link_err_logged = True
                    log.warning("live: %s TTS audio link %s failed: %s",
                                self.id[:8], url, e)
                return None, None
            if isinstance(body, dict):  # be lenient about the wrapper
                body = next((x for x in body.values()
                             if isinstance(x, str) and len(x) > 100), None)
            if not isinstance(body, str) or not body:
                return None, None
            if not getattr(self, "_link_ok_logged", False):
                self._link_ok_logged = True
                log.info("live: %s TTS audio arrives as links — fetching "
                         "them (%s)", self.id[:8], path.split("?")[0])
            return k, body
        return None, None

    def _resolve_lane(self, sender: str, msg: dict) -> Optional[str]:
        if not sender or sender.startswith(
            ("tts", "lip", "textstructurer", "saasr", "summar", "notes")
        ):
            return None
        if sender.startswith("asr"):
            return "asr"
        if not sender.startswith("mt"):
            return None

        candidates = [msg.get("_channel")] + [msg.get(k) for k in _LANG_FIELDS]
        for c in candidates:
            if isinstance(c, str) and c.strip():
                code = c.strip().lower()
                if code in self.mt_langs or _CODE_RE.match(code):
                    return code.split("_")[0].split("-")[0]
        for code in self.mt_langs:
            if re.search(rf"[:_\-]{re.escape(code)}(?![a-z])", sender, re.I):
                return code
        if len(self.mt_langs) == 1:
            return self.mt_langs[0]
        text = msg.get("seq") or msg.get("text") or msg.get("translation") or ""
        lane = self._detect(sender, str(text))
        if lane:
            return lane
        self._provisional.add(sender)
        return sender  # shown under a temporary panel until identified

    def _decide(self, sender: str, lang: str, how: str) -> str:
        self._sender_lane[sender] = lang
        log.info("live: %s %s identified as %s (%s)", self.id[:8], sender, lang, how)
        if sender in self._provisional:
            self.pending_events.append({"_relabel": True, "from": sender, "to": lang})
        return lang

    def _detect(self, sender: str, text: str) -> Optional[str]:
        """Which selected target language a stream (mt:N) is in, from its
        text: script first, then common words/letters; each language is
        given to one stream only. None while still unsure."""
        if sender in self._sender_lane:
            return self._sender_lane[sender]
        claimed = set(self._sender_lane.values())
        free = [l for l in self.mt_langs if l not in claimed]
        if not free:
            return None
        if len(_WORD_RE.findall(text)) == 0:
            return None  # "♪" and the like say nothing
        n = self._sender_msgs[sender] = self._sender_msgs.get(sender, 0) + 1

        by_script = [c for c in _script_candidates(text) if c in free]
        if len(by_script) == 1:
            return self._decide(sender, by_script[0], "script")
        if by_script:
            free = by_script

        acc = self._sender_scores.setdefault(sender, {})
        for code, sc in _latin_scores(text, free).items():
            acc[code] = acc.get(code, 0) + sc
        ranked = sorted(((acc.get(c, 0), c) for c in free), reverse=True)
        best = ranked[0] if ranked else (0, None)
        second = ranked[1][0] if len(ranked) > 1 else 0
        if best[1] and best[0] >= 3 and best[0] >= 2 * second:
            return self._decide(sender, best[1], f"words {best[0]} vs {second}")
        if len(free) == 1 and n >= 2:
            return self._decide(sender, free[0], "last remaining language")
        return None

    def final_lane(self, sender: str, lane: Optional[str]) -> Optional[str]:
        """Lane to use in the saved output, after identification."""
        return self._sender_lane.get(sender, lane)

    # ── recording ────────────────────────────────────────────────────
    def _rebase(self, v):
        """KIT echoes our unix-time timestamps; store them relative to
        the session start like archived sessions."""
        try:
            f = float(v)
        except (TypeError, ValueError):
            return v
        if f > 1e8 and self.adapter.t0:
            f -= self.adapter.t0
        return round(max(0.0, f), 3)

    def record(self, msg: dict, lane: Optional[str]) -> None:
        if lane is None or msg.get("unstable"):
            return
        text = msg.get("seq") or msg.get("text") or msg.get("translation")
        if not isinstance(text, str) or not text.strip():
            return
        m = dict(msg)
        for k in ("start", "end"):
            if k in m:
                m[k] = self._rebase(m[k])
        m["_lane"] = lane
        self.recorded.append(m)

    def write_pcm(self, pcm: bytes) -> None:
        try:
            with open(self.pcm_path, "ab") as f:
                f.write(pcm)
        except OSError as e:
            log.info("live: could not keep audio for %s: %s", self.id[:8], e)


_sessions: dict[str, _LiveSession] = {}
_registry_lock = threading.Lock()


def _get(live_id: str) -> Optional[_LiveSession]:
    with _registry_lock:
        return _sessions.get(live_id)


# Set by create_live_blueprint: builds the Session Output files.
_on_finished: Optional[Callable[[dict], Optional[str]]] = None


def _finalize(sess: _LiveSession) -> None:
    """Hand the recording to the backend once (output files + session)."""
    with sess.final_lock:
        if sess.finalized:
            return
        sess.finalized = True
    info = {
        "session_id": sess.adapter.session_id,
        "server": sess.adapter.server,
        "token": sess.token,
        "name": str(sess.settings.get("name") or ""),
        "input_languages": sess.input_langs,
        "output_languages": sess.mt_langs,
        "settings": sess.settings,
        "started_at": sess.started_at,
        "duration_s": sess.samples_sent / SAMPLE_RATE,
        "messages": [
            {**m, "_lane": sess.final_lane(str(m.get("sender") or ""), m.get("_lane"))}
            for m in sess.recorded
        ],
        "tts_chunks": [
            {
                **{k: v for k, v in c.items() if k not in ("b64", "sender")},
                "lane": c["lane"] if c["lane"] != c.get("sender")
                else sess.tts_lane_for({"sender": c.get("sender")}) or c["lane"],
            }
            for c in sess.tts_chunks
        ],
        "audio_languages": sess.audio_langs,
        "pcm_path": sess.pcm_path,
        "sample_rate": SAMPLE_RATE,
    }
    try:
        if _on_finished and sess.adapter.session_id:
            _on_finished(info)
            log.info(
                "live: %s output built (%d messages)",
                sess.id[:8], len(sess.recorded),
            )
    except Exception as e:  # never break the relay over the output step
        log.warning("live: building output for %s failed: %s", sess.id[:8], e)
    finally:
        # The callback copies/converts the audio; the temp file goes.
        try:
            os.remove(sess.pcm_path)
        except OSError:
            pass


def _close(sess: _LiveSession) -> None:
    with _registry_lock:
        _sessions.pop(sess.id, None)
    if not sess.closed:
        sess.closed = True
        sess.closed_at = time.monotonic()
        if sess.adapter.end():
            _ledger_remove(sess.adapter.session_id)
        else:
            # Stays in the ledger; the sweeper retries every few minutes.
            log.warning(
                "live: END for KIT session %s failed — will retry",
                sess.adapter.session_id,
            )
        # Hard stop for the event stream if KIT never ends it, and make
        # sure the output gets built even if no browser is listening.
        def _hard_stop():
            sess.adapter.close()
            _finalize(sess)
        threading.Timer(END_GRACE_S + 2, _hard_stop).start()
        log.info(
            "live: closed %s after %.1f s of audio",
            sess.id[:8],
            sess.samples_sent / SAMPLE_RATE,
        )


# ─── Open-session ledger ──────────────────────────────────────────────
# Every KIT session this relay opens is written to a small JSON file and
# removed only after KIT accepted the END. Whatever is still listed after
# a crash, restart or failed END gets its END from the sweeper (at
# startup and then every SWEEP_INTERVAL_S), so no session stays open on
# KIT. The file holds the login token needed for that END; it lives next
# to the saved sessions (lib/state, the backend's private volume).
SWEEP_INTERVAL_S = 30
# A running session refreshes its "alive" stamp every sweep. Only entries
# whose stamp is older than this are treated as orphaned — so a second
# process (e.g. Flask's debug reloader) never ENDs another one's session.
LEDGER_ORPHAN_S = IDLE_TIMEOUT_S + 60
LEDGER_RETRY_S = 300          # retry a failed END every 5 minutes …
LEDGER_GIVE_UP_S = 3 * 86400  # … for at most 3 days
_ledger_path: Optional[str] = None
_ledger_lock = threading.Lock()
_sweeper_started = False


def _ledger_load() -> dict:
    if not _ledger_path:
        return {}
    try:
        with open(_ledger_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _ledger_save(data: dict) -> None:
    if not _ledger_path:
        return
    os.makedirs(os.path.dirname(_ledger_path), exist_ok=True)
    tmp = _ledger_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, _ledger_path)


def _ledger_add(kit_session: str, server: str, token: str) -> None:
    with _ledger_lock:
        data = _ledger_load()
        data[kit_session] = {
            "server": server, "token": token,
            "opened": time.time(), "alive": time.time(), "last_try": 0.0,
        }
        _ledger_save(data)


def _ledger_remove(kit_session: str) -> None:
    with _ledger_lock:
        data = _ledger_load()
        if data.pop(kit_session, None) is not None:
            _ledger_save(data)


def _send_end(kit_session: str, server: str, token: str) -> bool:
    adapter = KitLiveAdapter(server, token)
    adapter.session_id = kit_session
    adapter.stream_id = adapter.STREAM_ID
    try:
        return adapter.end(attempts=2)
    finally:
        adapter.close()


def _sweep_ledger() -> None:
    """END every listed KIT session that no running relay session owns."""
    with _registry_lock:
        active = {
            s.adapter.session_id for s in _sessions.values() if not s.closed
        }
    now = time.time()
    with _ledger_lock:
        data = _ledger_load()
        mine = [k for k in data if k in active]
        for k in mine:
            data[k]["alive"] = now
        if mine:
            _ledger_save(data)
    for kit_session, e in list(data.items()):
        if kit_session in active:
            continue
        if now - float(e.get("alive") or 0) < LEDGER_ORPHAN_S:
            continue  # may belong to another process that is still running
        if now - float(e.get("last_try") or 0) < LEDGER_RETRY_S:
            continue
        ok = _send_end(kit_session, e.get("server", ""), e.get("token", ""))
        if ok:
            log.info("live: sent missing END to KIT session %s", kit_session)
            _ledger_remove(kit_session)
        elif now - float(e.get("opened") or now) > LEDGER_GIVE_UP_S:
            log.warning("live: giving up END for KIT session %s", kit_session)
            _ledger_remove(kit_session)
        else:
            with _ledger_lock:
                cur = _ledger_load()
                if kit_session in cur:
                    cur[kit_session]["last_try"] = now
                    _ledger_save(cur)


def _start_sweeper() -> None:
    """Background thread: drop idle sessions (tab closed without Stop)
    and send END for anything left in the ledger."""
    global _sweeper_started
    if _sweeper_started:
        return
    _sweeper_started = True

    def loop():
        while True:
            try:
                _reap_idle()
                _sweep_ledger()
            except Exception as e:  # never let the sweeper die
                log.warning("live: sweeper error: %s", e)
            time.sleep(SWEEP_INTERVAL_S)

    threading.Thread(target=loop, name="live-sweeper", daemon=True).start()


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



# Set by create_live_blueprint, so backend.py's folder rename/delete can
# update live sessions too (folders are shared with the video list).
_store_ref: Optional["_SavedStore"] = None


def _rewrite_folders(change) -> int:
    """Apply `change(folder) -> new folder or None` to every saved live
    session of every user. Returns how many were changed."""
    store = _store_ref
    if store is None or not os.path.isdir(store.root):
        return 0
    changed = 0
    for user in os.listdir(store.root):
        d = os.path.join(store.root, user)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if not name.endswith(".json"):
                continue
            path = os.path.join(d, name)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    rec = json.load(f)
            except (OSError, ValueError):
                continue
            old = rec.get("folder") or None
            if not old:
                continue
            new = change(old)
            if new == old:
                continue
            if new:
                rec["folder"] = new
            else:
                rec.pop("folder", None)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(rec, f, ensure_ascii=False)
            os.replace(tmp, path)
            changed += 1
    return changed


def saved_title_for_output(output_session_id: str) -> str:
    """The name the user gave a live session (Live Sessions list), looked
    up by its Session Output id. '' when none was given."""
    store = _store_ref
    if not output_session_id or store is None or not os.path.isdir(store.root):
        return ""
    for user in os.listdir(store.root):
        d = os.path.join(store.root, user)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(d, name), "r", encoding="utf-8") as f:
                    rec = json.load(f)
            except (OSError, ValueError):
                continue
            if rec.get("output_session_id") == output_session_id:
                return str(rec.get("title") or "").strip()
    return ""


def rename_folder(old: str, new: str) -> int:
    """Folder renamed on the video list → live sessions follow."""
    return _rewrite_folders(lambda f: new if f.lower() == old.lower() else f)


def clear_folder(name: str) -> int:
    """Folder deleted → its live sessions become unsorted."""
    return _rewrite_folders(lambda f: None if f.lower() == name.lower() else f)


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
        "output_session_id": rec.get("output_session_id") or "",
        "folder": rec.get("folder") or "",
        # Free name chosen by the user, shown next to the structured
        # `name` (live_<date>-<time>). Empty = not set.
        "title": rec.get("title") or "",
        # From the session's settings: the permanent name of the
        # <server>/webapi/shorten/<name> link and the spoken (TTS) languages.
        "permanent_name": str((rec.get("settings") or {}).get("shorten") or ""),
        "tts_languages": [
            str(x) for x in ((rec.get("settings") or {}).get("audioLanguage") or [])
            if isinstance(x, str)
        ] if isinstance((rec.get("settings") or {}).get("audioLanguage"), list) else [],
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
    on_finished: Optional[Callable[[dict], Optional[str]]] = None,
) -> Blueprint:
    """Build the blueprint.

    `resolve_server(requested)` must return an allow-listed KIT base URL
    (no trailing slash), falling back to the default server.
    `storage_dir` is where finished sessions are saved (created on demand;
    put it on a persistent volume).
    """
    global _on_finished
    _on_finished = on_finished
    bp = Blueprint("live_relay", __name__, url_prefix="/api/live")
    store = _SavedStore(storage_dir)
    global _store_ref, _ledger_path
    _store_ref = store
    _ledger_path = os.path.join(storage_dir, "_open_kit_sessions.json")
    # Sessions left open by a crash/restart get their END from the
    # sweeper once their "alive" stamp is stale (a few minutes).
    _start_sweeper()

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
            # KIT session id under which Session Output has the files.
            "output_session_id": re.sub(
                r"[^0-9A-Za-z_\-]", "", str(body.get("output_session_id") or "")
            )[:200],
        }
        previous = store.load(email, sid)
        for keep in ("folder", "title"):  # set from the list, keep on re-save
            if previous and previous.get(keep):
                record[keep] = previous[keep]
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

    @bp.route("/saved/<sid>/title", methods=["POST"])
    def saved_title(sid):
        """Give a live session a chosen name: {"title": "…"} ("" clears)."""
        email, err = _caller_email()
        if err:
            return err
        rec = store.load(email, sid) if _SAVED_ID_RE.match(sid) else None
        if rec is None:
            return jsonify({"error": "Not found"}), 404
        title = re.sub(
            r"\s+", " ", str((request.get_json(silent=True) or {}).get("title") or "")
        ).strip()[:200]
        if title:
            rec["title"] = title
        else:
            rec.pop("title", None)
        store.save(email, rec)
        return jsonify({"success": True, "title": rec.get("title") or ""}), 200

    @bp.route("/saved/<sid>/folder", methods=["POST"])
    def saved_move(sid):
        """Move a live session into a folder: {"folder": "Name"} / null."""
        email, err = _caller_email()
        if err:
            return err
        rec = store.load(email, sid) if _SAVED_ID_RE.match(sid) else None
        if rec is None:
            return jsonify({"error": "Not found"}), 404
        folder = re.sub(r"\s+", " ", str((request.get_json(silent=True) or {}).get("folder") or "")).strip()[:80]
        if folder:
            rec["folder"] = folder
        else:
            rec.pop("folder", None)
        store.save(email, rec)
        return jsonify({"success": True, "folder": rec.get("folder")}), 200

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
        if payload.get("format") == "offline":
            # Offline = KIT processes only after the end: useless live.
            log.info("live: format 'offline' requested — using 'online'")
            payload["format"] = "online"

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

        sess = _LiveSession(adapter, token, language, mt, payload)
        with _registry_lock:
            _sessions[sess.id] = sess
        _ledger_add(adapter.session_id, server, token)

        def _silence_check():
            # Audio is flowing but KIT has sent nothing back: say so, with
            # the settings most likely responsible.
            if not sess.closed and not sess._seen_senders and sess.samples_sent:
                log.warning(
                    "live: %s no results from KIT after 20 s of the session "
                    "(%.1f s audio sent; format=%r, language=%s, mt=%s) — "
                    "format 'offline' only produces output after the end",
                    sess.id[:8], sess.samples_sent / SAMPLE_RATE,
                    payload.get("format"), ",".join(language), ",".join(mt),
                )
        threading.Timer(20, _silence_check).start()
        log.info(
            "live: started %s on %s (%s → %s)",
            sess.id[:8],
            server,
            ",".join(language),
            ",".join(mt) or "-",
        )
        return (
            jsonify(
                {
                    "live_id": sess.id,
                    "sample_rate": SAMPLE_RATE,
                    # Id the finished session gets in Session Output.
                    "session_id": adapter.session_id,
                    # Permanent name → <server>/webapi/shorten/<name>.
                    "shorten": getattr(adapter, "shorten", "") or "",
                }
            ),
            200,
        )

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
            sess.write_pcm(pcm)
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
                    lane = sess.lane_for(msg)
                    while sess.pending_events:
                        yield f"data: {json.dumps(sess.pending_events.pop(0))}\n\n"
                    if str(msg.get("sender") or "").startswith("tts"):
                        # Spoken translation: kept for the WAVs and sent to
                        # the browser as it arrives (every language: the live
                        # screen lists the parts). `listen` marks the language
                        # the browser plays aloud.
                        chunk = sess.record_tts(msg)
                        if chunk:
                            out = {
                                "_tts": True,
                                "_lane": chunk["lane"],
                                "listen": bool(sess.tts_listen)
                                and chunk["lane"] == sess.tts_listen,
                                "sender": msg.get("sender"),
                                "format": chunk["key"],
                                "rate": chunk["rate"],
                                "start": chunk["start"],
                                "end": chunk["end"],
                                "audio": chunk["b64"],
                            }
                            yield f"data: {json.dumps(out)}\n\n"
                        continue
                    if lane is not None:
                        msg["_lane"] = lane
                    sess.record(msg, lane)
                    # Session-relative times (same clock as the TTS parts),
                    # so the browser can find the text a TTS part speaks.
                    if "start" in msg:
                        msg["_start"] = sess._rebase(msg.get("start"))
                    if "end" in msg:
                        msg["_end"] = sess._rebase(msg.get("end"))
                    yield f"data: {json.dumps(msg, ensure_ascii=False)}\n\n"
                    if (
                        sess.closed
                        and time.monotonic() - sess.closed_at > END_GRACE_S
                    ):
                        break
            except GeneratorExit:  # browser went away
                if sess.closed:
                    _finalize(sess)
                raise
            except Exception as e:
                if not sess.closed:  # errors after stop are expected
                    log.info("live: event stream %s ended: %s", live_id[:8], e)
                    yield f"event: relay-error\ndata: {json.dumps(str(e))}\n\n"
            if sess.closed:
                _finalize(sess)  # before `end`, so Session Output is ready
            yield "event: end\ndata: {}\n\n"

        return Response(
            gen(),  # no stream_with_context: gen() never touches `request`
            mimetype="text/event-stream",
            headers={
                "Cache-Control": "no-store",
                "X-Accel-Buffering": "no",  # nginx: don't buffer SSE
            },
        )

    @bp.route("/<live_id>/tts", methods=["POST"])
    def live_tts(live_id):
        """Choose which spoken translation the browser hears live
        ({"lane": "de"} or {"lane": null} for off)."""
        sess = _get(live_id)
        if sess is None:
            return jsonify({"error": "Unknown or closed live session"}), 404
        if _bearer() != sess.token:
            return jsonify({"error": "Forbidden"}), 403
        lane = (request.get_json(silent=True) or {}).get("lane")
        sess.tts_listen = str(lane).lower() if lane else None
        return ("", 204)

    @bp.route("/<live_id>/stop", methods=["POST"])
    def live_stop(live_id):
        sess = _get(live_id)
        if sess is None:
            return ("", 204)  # already gone — stopping is idempotent
        token = _bearer()
        if not token:
            # navigator.sendBeacon (tab closing) cannot set headers; it
            # sends the token as a text/plain body instead.
            try:
                token = str(
                    (json.loads(request.get_data(as_text=True) or "{}") or {})
                    .get("token") or ""
                ).strip()
            except (ValueError, AttributeError):
                token = ""
        if token != sess.token:
            return jsonify({"error": "Forbidden"}), 403
        # END (with retries) off the request thread: a closing tab does
        # not wait for the answer.
        threading.Thread(target=_close, args=(sess,), daemon=True).start()
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
