"""Signed MCP Events callbacks using a pinned, public-address HTTPS transport.

Only ``PublicHTTPSWebhookTransport`` is the production network boundary. Injected
transports, resolvers and connectors are trusted test/application code, never
subscription input. An alternate transport must enforce the same connection-time
address and TLS policy. URL syntax is checked even when verification is injected.
No callback URLs, signing keys, response bodies or underlying errors enter errors.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import http.client
import ipaddress
import json
import math
import queue
import re
import secrets
import socket
import ssl
import threading
import time
import uuid
from urllib.parse import urlsplit


MAX_RESPONSE_BYTES = 4096
MAX_EVENT_BYTES = 262144
_DNS_SLOTS = threading.BoundedSemaphore(8)
_IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,256}\Z")
_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
_MESSAGES = {
    "invalid_secret": "Invalid webhook signing secret.",
    "invalid_callback": "Invalid HTTPS callback destination.",
    "invalid_request": "Invalid webhook request.",
    "blocked_address": "Callback destination is not public.",
    "dns_failed": "Callback destination could not be resolved.",
    "network_error": "Callback connection failed.",
    "timeout": "Callback request timed out.",
    "redirect_rejected": "Callback redirects are not allowed.",
    "response_too_large": "Callback response exceeds the limit.",
    "challenge_failed": "Callback verification failed.",
}


class WebhookError(ValueError):
    """A categorized error with static, credential-safe public text."""

    def __init__(self, code: str, message: str | None = None):
        # Callers cannot accidentally expose remote text through this error type.
        self.code = code if code in _MESSAGES else "network_error"
        self.message = _MESSAGES[self.code]
        super().__init__(self.message)


def parse_signing_secret(value: str) -> bytes:
    if not isinstance(value, str) or not value.startswith("whsec_"):
        raise WebhookError("invalid_secret")
    encoded = value[6:]
    if not 32 <= len(encoded) <= 88:
        raise WebhookError("invalid_secret")
    try:
        key = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise WebhookError("invalid_secret") from None
    if not 24 <= len(key) <= 64 or base64.b64encode(key).decode("ascii") != encoded:
        raise WebhookError("invalid_secret")
    return key


def signed_headers(event_id: str, secret: str, body: bytes, timestamp: int,
                   subscription_id: str) -> dict[str, str]:
    key = parse_signing_secret(secret)
    if (not isinstance(event_id, str) or not _IDENTIFIER.fullmatch(event_id)
            or not isinstance(subscription_id, str)
            or not _IDENTIFIER.fullmatch(subscription_id)
            or type(timestamp) is not int or not 0 <= timestamp < 2**63
            or not isinstance(body, bytes) or len(body) > MAX_EVENT_BYTES):
        raise WebhookError("invalid_request")
    timestamp_text = str(timestamp)
    signed = event_id.encode("ascii") + b"." + timestamp_text.encode("ascii") + b"." + body
    signature = base64.b64encode(hmac.new(key, signed, hashlib.sha256).digest()).decode("ascii")
    return {
        "Content-Type": "application/json",
        "webhook-id": event_id,
        "webhook-timestamp": timestamp_text,
        "webhook-signature": "v1," + signature,
        "X-MCP-Subscription-Id": subscription_id,
    }


def _callback_url(value: str) -> tuple[str, str]:
    if (not isinstance(value, str) or not value or len(value) > 8192
            or "#" in value or "\\" in value
            or any(ord(c) < 33 or ord(c) == 127 or c.isspace() for c in value)):
        raise WebhookError("invalid_callback")
    try:
        parsed = urlsplit(value)
        if (parsed.scheme.lower() != "https" or not parsed.netloc
                or parsed.username is not None or parsed.password is not None
                or "@" in parsed.netloc or "%" in parsed.netloc
                or parsed.port not in (None, 443) or not parsed.hostname):
            raise ValueError
        host = parsed.hostname
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            host = host.encode("idna").decode("ascii").lower()
            if (len(host) > 253 or "." not in host
                    or not all(_LABEL.fullmatch(label) for label in host.split("."))
                    or host.endswith((".localhost", ".local", ".internal", ".invalid", ".test"))):
                raise ValueError
        else:
            _public_address(address)
            host = str(address)
        target = parsed.path or "/"
        if parsed.query:
            target += "?" + parsed.query
        target.encode("ascii")  # Non-ASCII paths must arrive percent-encoded.
        if len(target) > 8192:
            raise ValueError
        return host, target
    except WebhookError:
        raise
    except (ValueError, UnicodeError):
        raise WebhookError("invalid_callback") from None


def _public_address(value):
    try:
        address = ipaddress.ip_address(value)
    except (ValueError, TypeError):
        raise WebhookError("blocked_address") from None
    # Reject transition encodings as well as native non-public destinations.
    if (not address.is_global or address.is_private or address.is_loopback
            or address.is_link_local or address.is_multicast or address.is_reserved
            or address.is_unspecified or getattr(address, "is_site_local", False)
            or getattr(address, "scope_id", None) is not None
            or getattr(address, "ipv4_mapped", None) is not None
            or getattr(address, "sixtofour", None) is not None
            or getattr(address, "teredo", None) is not None
            or (address.version == 6 and (
                address in ipaddress.ip_network("64:ff9b::/96")
                or address in ipaddress.ip_network("64:ff9b:1::/48")))):
        raise WebhookError("blocked_address")
    return str(address)


def _remaining(deadline, clock):
    remaining = deadline - clock()
    if not math.isfinite(remaining) or remaining <= 0:
        raise WebhookError("timeout")
    return remaining


def _default_resolver(host, port):
    return [record[4][0] for record in socket.getaddrinfo(
        host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)]


def _default_connector(address, port, timeout):
    family = socket.AF_INET6 if ipaddress.ip_address(address).version == 6 else socket.AF_INET
    connection = socket.socket(family, socket.SOCK_STREAM)
    try:
        connection.settimeout(timeout)
        connection.connect((address, port))  # Numeric address: never resolves the hostname again.
        return connection
    except BaseException:
        connection.close()
        raise


def _resolve_public(host, resolver, deadline, clock):
    """Bound otherwise uninterruptible getaddrinfo, with at most eight DNS workers."""
    if not _DNS_SLOTS.acquire(blocking=False):
        raise WebhookError("dns_failed")
    result = queue.Queue(maxsize=1)

    def resolve():
        try:
            # Bound the answer list before materialization, including injected iterators.
            answers = []
            for value in resolver(host, 443):
                if len(answers) >= 64:
                    raise WebhookError("dns_failed")
                answers.append(value)
            result.put((True, answers))
        except Exception:
            result.put((False, None))
        finally:
            _DNS_SLOTS.release()

    try:
        threading.Thread(target=resolve, daemon=True, name="peel-webhook-dns").start()
    except RuntimeError:
        _DNS_SLOTS.release()
        raise WebhookError("dns_failed") from None
    try:
        okay, answers = result.get(timeout=_remaining(deadline, clock))
    except queue.Empty:
        raise WebhookError("timeout") from None
    _remaining(deadline, clock)
    if not okay or not answers:
        raise WebhookError("dns_failed")
    # Reject the entire set if *any* answer is unsafe, even when the first is public.
    return tuple(dict.fromkeys(_public_address(value) for value in answers))


class _DeadlineConnection(http.client.HTTPSConnection):
    def __init__(self, host, address, deadline, clock, connector, context, track_socket):
        super().__init__(host, port=443, timeout=_remaining(deadline, clock), context=context)
        self._address = address
        self._deadline = deadline
        self._clock = clock
        self._connector = connector
        self._track_socket = track_socket

    def connect(self):
        raw = self._connector(self._address, 443, _remaining(self._deadline, self._clock))
        self._track_socket(raw)
        try:
            raw.settimeout(_remaining(self._deadline, self._clock))
            secured = self._context.wrap_socket(
                raw, server_hostname=self.host, do_handshake_on_connect=False)
            self.sock = secured
            self._track_socket(secured)
            secured.settimeout(_remaining(self._deadline, self._clock))
            secured.do_handshake()
            secured.settimeout(_remaining(self._deadline, self._clock))
        except BaseException:
            raw.close()
            raise


class PublicHTTPSWebhookTransport:
    """No proxies/redirects; fresh DNS, pinned numeric TCP destination and verified TLS.

    ``resolver(host, 443)`` returns numeric address strings. ``connector(address,
    443, remaining_seconds)`` returns a connected plain socket. These are trusted
    injection seams, not tenant-configurable callbacks. ``clock`` is monotonic.
    """

    def __init__(self, *, resolver=None, connector=None, clock=time.monotonic, timeout=10.0):
        if (isinstance(timeout, bool) or not isinstance(timeout, (int, float))
                or not math.isfinite(timeout) or not 0 < timeout <= 10):
            raise WebhookError("invalid_request")
        self._resolver = resolver or _default_resolver
        self._connector = connector or _default_connector
        self._clock = clock
        self._timeout = float(timeout)
        self._context = ssl.create_default_context()

    def post(self, url: str, body: bytes, headers: dict[str, str]) -> tuple[int, bytes]:
        host, target = _callback_url(url)
        if not isinstance(body, bytes) or len(body) > MAX_EVENT_BYTES or not isinstance(headers, dict):
            raise WebhookError("invalid_request")
        seen = set()
        total = 0
        for key, value in headers.items():
            if (not isinstance(key, str) or not isinstance(value, str)
                    or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", key)
                    or any(ord(c) < 32 or ord(c) > 126 for c in value)
                    or key.lower() in seen
                    or key.lower() in {"host", "content-length", "transfer-encoding", "connection"}
                    or key.lower().startswith("proxy-")):
                raise WebhookError("invalid_request")
            seen.add(key.lower())
            total += len(key) + len(value)
        if len(headers) > 16 or total > 8192:
            raise WebhookError("invalid_request")
        deadline = self._clock() + self._timeout
        addresses = _resolve_public(host, self._resolver, deadline, self._clock)
        active = []
        lock = threading.Lock()
        expired = threading.Event()

        def track(connection):
            with lock:
                active.append(connection)
                if expired.is_set():
                    connection.close()
                    raise WebhookError("timeout")

        def expire():
            expired.set()
            with lock:
                for connection in active:
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    connection.close()

        # A watchdog interrupts slow header/body reads, not merely each individual IO.
        watchdog = threading.Timer(_remaining(deadline, self._clock), expire)
        watchdog.daemon = True
        connection = _DeadlineConnection(host, addresses[0], deadline, self._clock,
                                         self._connector, self._context, track)
        watchdog.start()
        try:
            connection.request("POST", target, body=body, headers=headers)
            connection.sock.settimeout(_remaining(deadline, self._clock))
            response = connection.getresponse()
            _remaining(deadline, self._clock)
            if 300 <= response.status < 400:
                raise WebhookError("redirect_rejected")
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdigit() or int(length) > MAX_RESPONSE_BYTES):
                raise WebhookError("response_too_large")
            if connection.sock is not None:
                connection.sock.settimeout(_remaining(deadline, self._clock))
            response_body = response.read(MAX_RESPONSE_BYTES + 1)
            _remaining(deadline, self._clock)
            if len(response_body) > MAX_RESPONSE_BYTES:
                raise WebhookError("response_too_large")
            return response.status, response_body
        except WebhookError:
            raise
        except (TimeoutError, socket.timeout):
            raise WebhookError("timeout") from None
        except (OSError, http.client.HTTPException, ValueError):
            code = "timeout" if expired.is_set() or self._clock() >= deadline else "network_error"
            raise WebhookError(code) from None
        finally:
            watchdog.cancel()
            connection.close()
            with lock:
                for tracked in active:
                    tracked.close()


def verify_callback(url: str, secret: str, subscription_id: str, transport=None,
                    *, now=time.time, challenge_factory=None) -> None:
    """Verify one fresh challenge. Injected transports are explicitly trusted; see module docs."""
    _callback_url(url)
    parse_signing_secret(secret)
    challenge = (challenge_factory or (lambda: secrets.token_urlsafe(32)))()
    if (not isinstance(challenge, str) or not challenge or len(challenge.encode("utf-8")) > 256):
        raise WebhookError("invalid_request")
    body = json.dumps({"type": "verification", "challenge": challenge},
                      separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    try:
        instant = now() if callable(now) else now
        if isinstance(instant, bool) or not math.isfinite(instant) or instant < 0:
            raise ValueError
        timestamp = int(instant)
    except (ValueError, TypeError, OverflowError):
        raise WebhookError("invalid_request") from None
    headers = signed_headers("msg_verification_" + uuid.uuid4().hex, secret, body,
                             timestamp, subscription_id)
    status, response = (transport if transport is not None else PublicHTTPSWebhookTransport()).post(
        url, body, headers)
    if (type(status) is not int or not 200 <= status < 300
            or not isinstance(response, bytes) or len(response) > MAX_RESPONSE_BYTES):
        raise WebhookError("challenge_failed")
    try:
        def unique_pairs(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError
                result[key] = value
            return result
        result = json.loads(response.decode("utf-8"), object_pairs_hook=unique_pairs)
        if (not isinstance(result, dict) or set(result) != {"challenge"}
                or not isinstance(result["challenge"], str)
                or not hmac.compare_digest(result["challenge"].encode("utf-8"), challenge.encode("utf-8"))):
            raise ValueError
    except (ValueError, UnicodeError):
        raise WebhookError("challenge_failed") from None
