"""Native-only WSGI API. No cookies, browser sessions, CORS, auth or cloud ledger."""
import json
import os
import threading
import time
from urllib.parse import urlsplit
from .broker import ProcessBroker
from .config import Config
from .contract import MAX_BODY, InvalidEvidence, InvalidRequest, Request, Unavailable

PATH = "/v1/entitlements/verify"


class Pressure:
    """Bounded process-local pressure guard. Front proxy also needs global limits."""
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.Lock()
        self.window = None
        self.total = 0
        self.peers = {}

    def allow(self, peer):
        with self.lock:
            now = int(self.clock() // 60)
            if self.window != now:
                self.window, self.total, self.peers = now, 0, {}
            if self.total >= 60 or len(self.peers) >= 2048 and peer not in self.peers or self.peers.get(peer, 0) >= 12:
                return False
            self.total += 1
            self.peers[peer] = self.peers.get(peer, 0) + 1
            return True


class Application:
    def __init__(self, config=None, verifier=None, pressure=None):
        self.config = config
        self.verifier = verifier
        self.pressure = pressure or Pressure()

    @staticmethod
    def reply(start_response, status, obj, extra=()):
        payload = json.dumps(obj, separators=(",", ":")).encode("ascii")
        headers = [("Content-Type", "application/json"), ("Content-Length", str(len(payload))),
                   ("Cache-Control", "no-store"), ("Pragma", "no-cache"),
                   ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer")]
        start_response(status, headers + list(extra))
        return [payload]

    def __call__(self, environ, start_response):
        def error(status, code, extra=()):
            return self.reply(start_response, status, {"error": code}, extra)
        if environ.get("PATH_INFO") != PATH:
            return error("404 Not Found", "not_found")
        if environ.get("REQUEST_METHOD") != "POST":
            return error("405 Method Not Allowed", "method_not_allowed", (("Allow", "POST"),))
        if self.config is None or self.verifier is None:
            return error("503 Service Unavailable", "unavailable")
        # Trusted WSGI/proxy must set URL scheme; forwarded headers are ignored.
        expected = urlsplit(self.config.public_origin).netloc
        if environ.get("wsgi.url_scheme") != "https" or environ.get("HTTP_HOST") != expected:
            return error("400 Bad Request", "invalid_request")
        if environ.get("QUERY_STRING") or environ.get("HTTP_ORIGIN"):
            return error("400 Bad Request", "invalid_request")
        if (environ.get("CONTENT_TYPE", "").lower() != "application/json" or
                environ.get("HTTP_CONTENT_ENCODING") or environ.get("HTTP_TRANSFER_ENCODING")):
            return error("415 Unsupported Media Type", "invalid_request")
        length = environ.get("CONTENT_LENGTH", "")
        if type(length) is not str or not length.isascii() or not length.isdigit() or len(length) > 6:
            return error("400 Bad Request", "invalid_request")
        size = int(length)
        if not 1 <= size <= MAX_BODY:
            return error("413 Payload Too Large", "invalid_request")
        # REMOTE_ADDR comes from WSGI, never a request's X-Forwarded-For value.
        peer = environ.get("REMOTE_ADDR", "")
        peer = peer[:128] if type(peer) is str else ""
        if not self.pressure.allow(peer):
            return error("429 Too Many Requests", "busy", (("Retry-After", "60"),))
        try:
            body = environ["wsgi.input"].read(size)
            if len(body) != size:
                raise InvalidRequest("invalid_request")
            request = Request.parse(body)
            try:
                result = self.verifier.verify(request)
            except InvalidEvidence:
                result = request.response(int(time.time()), reason="invalid_evidence")
            return self.reply(start_response, "200 OK", result)
        except InvalidRequest:
            return error("400 Bad Request", "invalid_request")
        except Exception:
            # No exception strings, tokens, transaction IDs or keys in responses/logs.
            return error("503 Service Unavailable", "unavailable")


def create_app(config_path=None):
    path = config_path if config_path is not None else os.environ.get("PEEL_COMMERCE_CONFIG")
    try:
        config = Config.load(path)
        return Application(config, ProcessBroker(path))
    except Exception:
        return Application()


application = create_app()
