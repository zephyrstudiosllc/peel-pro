"""Network-free signing, callback and pinned-transport security tests."""

import base64
import io
import json
import os
import socket
import ssl
import threading
import time
import unittest
from unittest.mock import patch

from peel_watch_relay import webhooks as wh


SECRET = "whsec_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
URL = "https://callbacks.example.com/events?subscription=one"


class Clock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        return self.value


class FakeSocket:
    def __init__(self, response=b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"):
        self.response = response
        self.sent = []
        self.timeouts = []
        self.closed = False
        self.shutdown_event = threading.Event()
        self.handshake = lambda: None

    def settimeout(self, value):
        self.timeouts.append(value)

    def connect(self, address):
        self.address = address

    def do_handshake(self):
        self.handshake()

    def sendall(self, data):
        self.sent.append(bytes(data))

    def makefile(self, mode):
        return io.BytesIO(self.response)

    def shutdown(self, mode):
        self.shutdown_event.set()

    def close(self):
        self.closed = True


class FakeContext:
    check_hostname = True
    verify_mode = ssl.CERT_REQUIRED

    def __init__(self):
        self.wraps = []

    def wrap_socket(self, raw, **kwargs):
        self.wraps.append(kwargs)
        return raw


class RecordingTransport:
    def __init__(self, status=200, response=None):
        self.status = status
        self.response = response
        self.calls = []

    def post(self, url, body, headers):
        self.calls.append((url, body, headers))
        response = self.response
        if response is None:
            response = json.dumps({"challenge": json.loads(body)["challenge"]}).encode()
        return self.status, response


class WebhookTests(unittest.TestCase):
    def setUp(self):
        # Any accidental production DNS/socket call makes the test fail, not connect.
        self.dns_guard = patch.object(wh.socket, "getaddrinfo", side_effect=AssertionError("live DNS forbidden"))
        self.socket_guard = patch.object(wh.socket, "socket", side_effect=AssertionError("live sockets forbidden"))
        self.dns_guard.start()
        self.socket_guard.start()
        self.addCleanup(self.dns_guard.stop)
        self.addCleanup(self.socket_guard.stop)

    def assert_code(self, code, callable_, *args, **kwargs):
        with self.assertRaises(wh.WebhookError) as raised:
            callable_(*args, **kwargs)
        self.assertEqual(raised.exception.code, code)
        return raised.exception

    def transport(self, response=None, addresses=None, clock=None, resolver=None, raw=None, timeout=10):
        raw = raw or FakeSocket() if response is None else FakeSocket(response)
        context = FakeContext()
        connections = []

        def connect(address, port, remaining):
            connections.append((address, port, remaining))
            return raw

        with patch.object(wh.ssl, "create_default_context", return_value=context) as context_factory:
            transport = wh.PublicHTTPSWebhookTransport(
                resolver=resolver or (lambda host, port: addresses or ["1.1.1.1"]),
                connector=connect, clock=clock or time.monotonic, timeout=timeout)
        context_factory.assert_called_once_with()
        return transport, raw, context, connections

    def test_standard_webhooks_fixed_signature(self):
        headers = wh.signed_headers("evt_fixture", SECRET, b'{"hello":"world"}', 1700000000, "sub_fixture")
        self.assertEqual(headers, {
            "Content-Type": "application/json", "webhook-id": "evt_fixture",
            "webhook-timestamp": "1700000000",
            "webhook-signature": "v1,V6IBaHuoPX2+GgGnTjYe2BK4WkDtxBtxhBlBcC4btec=",
            "X-MCP-Subscription-Id": "sub_fixture"})
        self.assertNotEqual(headers["webhook-signature"], wh.signed_headers(
            "evt_fixture", SECRET, b'{"hello": "world"}', 1700000000, "sub_fixture")["webhook-signature"])

    def test_strict_secret_boundaries(self):
        for size in (24, 32, 64):
            key = bytes(range(size))
            self.assertEqual(wh.parse_signing_secret("whsec_" + base64.b64encode(key).decode()), key)
        for value in (None, b"whsec_x", "", SECRET + "\n", SECRET + "=", SECRET[:-1],
                      SECRET.replace("A", "-", 1), "whsec_" + base64.b64encode(b"a" * 23).decode(),
                      "whsec_" + base64.b64encode(b"a" * 65).decode(),
                      "whsec_" + base64.b64encode(b"a" * 25).decode()[:-3] + "Zh=="):
            with self.subTest(value_type=type(value).__name__):
                self.assert_code("invalid_secret", wh.parse_signing_secret, value)

    def test_safe_errors_never_echo_remote_text(self):
        error = wh.WebhookError("challenge_failed", "secret body https://private/path")
        self.assertEqual(str(error), "Callback verification failed.")
        self.assertEqual(error.message, str(error))
        self.assertNotIn("private", repr(error))

    def test_invalid_signing_inputs(self):
        for event, timestamp, subscription, body in (
            ("bad\r\nHeader", 1, "sub", b"{}"), ("evt", True, "sub", b"{}"),
            ("evt", -1, "sub", b"{}"), ("evt", 1.5, "sub", b"{}"),
            ("evt", 2**63, "sub", b"{}"), ("evt", 1, "bad\n", b"{}"),
            ("evt", 1, "sub", "{}"), ("evt", 1, "sub", b"x" * 262145)):
            self.assert_code("invalid_request", wh.signed_headers, event, SECRET, body, timestamp, subscription)

    def test_verification_signs_exact_body_and_accepts_exact_echo(self):
        recorder = RecordingTransport()
        with patch.object(wh.hmac, "compare_digest", wraps=wh.hmac.compare_digest) as compare:
            wh.verify_callback(URL, SECRET, "sub_test", recorder, now=lambda: 1700000000,
                               challenge_factory=lambda: "fresh-fixed-challenge")
        compare.assert_called_once_with(b"fresh-fixed-challenge", b"fresh-fixed-challenge")
        url, body, headers = recorder.calls[0]
        self.assertEqual(url, URL)
        self.assertEqual(body, b'{"type":"verification","challenge":"fresh-fixed-challenge"}')
        self.assertEqual(headers, wh.signed_headers(headers["webhook-id"], SECRET, body, 1700000000, "sub_test"))

    def test_verification_ids_and_default_challenges_are_fresh(self):
        recorder = RecordingTransport()
        wh.verify_callback(URL, SECRET, "sub_test", recorder)
        wh.verify_callback(URL, SECRET, "sub_test", recorder)
        self.assertNotEqual(recorder.calls[0][2]["webhook-id"], recorder.calls[1][2]["webhook-id"])
        self.assertNotEqual(recorder.calls[0][1], recorder.calls[1][1])

    def test_challenge_failure_variants(self):
        for status, response in ((199, None), (300, None), (500, None), (True, None),
                                 (200, b'{"challenge":"wrong"}'), (200, b'not json'),
                                 (200, b'{"challenge":"a","challenge":"fresh"}'),
                                 (200, b'{"challenge":"fresh","extra":true}'),
                                 (200, b'{"challenge":12}'), (200, b"x" * 4097),
                                 (200, "not bytes")):
            with self.subTest(status=status, response_type=type(response).__name__):
                self.assert_code("challenge_failed", wh.verify_callback, URL, SECRET, "sub_test",
                                 RecordingTransport(status, response), now=1,
                                 challenge_factory=lambda: "fresh")

    def test_invalid_callback_before_injected_transport(self):
        bad_urls = ["http://callbacks.example.com/", "https://localhost/", "https://printer/",
                    "https://a.localhost/", "https://a.local/", "https://a.internal/",
                    "https://callbacks.example.com:444/", "https://u:p@callbacks.example.com/",
                    "https://callbacks.example.com/#", "https://callbacks.example.com/#frag",
                    "https://callbacks.example.com\\@evil.com/", "https://callbacks.example.com/\nX",
                    "https://callbacks.example.com/\tX", "https://a..example.com/", "https://-a.example.com/",
                    "https://callbacks.example.com./", "https://callbacks.example.com/é", "https://%31.example.com/"]
        for url in bad_urls:
            recorder = RecordingTransport()
            with self.subTest(url=url):
                self.assert_code("invalid_callback", wh.verify_callback, url, SECRET, "sub", recorder)
                self.assertEqual(recorder.calls, [])

    def test_direct_private_ip_rejected_before_injected_transport(self):
        for host in ("127.0.0.1", "10.0.0.1", "169.254.169.254", "[::1]", "[::ffff:127.0.0.1]"):
            recorder = RecordingTransport()
            self.assert_code("blocked_address", wh.verify_callback, "https://" + host + "/", SECRET, "sub", recorder)
            self.assertFalse(recorder.calls)

    def test_mixed_dns_and_ipv6_encodings_block_before_connect(self):
        for unsafe in ("127.0.0.1", "10.0.0.1", "100.64.0.1", "169.254.169.254", "0.0.0.0",
                       "224.0.0.1", "240.0.0.1", "::1", "fc00::1", "fe80::1", "ff02::1",
                       "2001:db8::1", "::ffff:127.0.0.1", "::ffff:8.8.8.8", "2002:7f00:1::1",
                       "2606:4700:4700::1111%eth0", "64:ff9b::a00:1", "64:ff9b:1::a00:1"):
            transport, raw, _, connections = self.transport(addresses=["1.1.1.1", unsafe])
            with self.subTest(unsafe=unsafe):
                self.assert_code("blocked_address", transport.post, URL, b"{}", {})
                self.assertFalse(connections)
                self.assertFalse(raw.sent)

    def test_dns_rechecked_every_post_rebinding_is_blocked(self):
        answers = iter((["1.1.1.1"], ["127.0.0.1"]))
        calls = []

        def resolve(host, port):
            calls.append((host, port))
            return next(answers)

        transport, _, _, connections = self.transport(resolver=resolve)
        self.assertEqual(transport.post(URL, b"{}", {}), (200, b"{}"))
        self.assert_code("blocked_address", transport.post, URL, b"{}", {})
        self.assertEqual(calls, [("callbacks.example.com", 443)] * 2)
        self.assertEqual(len(connections), 1)

    def test_dns_empty_errors_or_excessive_answers_are_safe(self):
        def fail(host, port):
            raise OSError("private resolver details")

        for resolver in (lambda h, p: [], fail, lambda h, p: ["1.1.1.1"] * 65):
            transport, _, _, connections = self.transport(resolver=resolver)
            self.assert_code("dns_failed", transport.post, URL, b"{}", {})
            self.assertFalse(connections)

    def test_pinned_address_original_idna_sni_and_http_host(self):
        transport, raw, context, connections = self.transport(addresses=["1.1.1.1", "8.8.8.8"])
        with patch.dict(os.environ, {"HTTPS_PROXY": "http://127.0.0.1:9", "ALL_PROXY": "http://127.0.0.1:9"}):
            self.assertEqual(transport.post("https://bücher.example.com/events?q=1", b"{}", {}), (200, b"{}"))
        self.assertEqual(connections[0][:2], ("1.1.1.1", 443))
        self.assertEqual(context.wraps, [{"server_hostname": "xn--bcher-kva.example.com", "do_handshake_on_connect": False}])
        request = b"".join(raw.sent)
        self.assertIn(b"POST /events?q=1 HTTP/1.1\r\n", request)
        self.assertIn(b"Host: xn--bcher-kva.example.com\r\n", request)
        self.assertTrue(raw.closed)

    def test_global_ipv6_pinned(self):
        transport, _, context, connections = self.transport(addresses=["2606:4700:4700::1111"])
        transport.post(URL, b"{}", {})
        self.assertEqual(connections[0][:2], ("2606:4700:4700::1111", 443))
        self.assertEqual(context.wraps[0]["server_hostname"], "callbacks.example.com")

    def test_default_connector_connects_numeric_address_without_dns(self):
        raw = FakeSocket()
        with patch.object(wh.socket, "socket", return_value=raw) as factory:
            self.assertIs(wh._default_connector("1.1.1.1", 443, 3.0), raw)
        factory.assert_called_once_with(socket.AF_INET, socket.SOCK_STREAM)
        self.assertEqual(raw.address, ("1.1.1.1", 443))

    def test_redirect_is_refused_without_second_connection(self):
        response = b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/secret\r\nContent-Length: 0\r\n\r\n"
        transport, _, _, connections = self.transport(response)
        self.assert_code("redirect_rejected", transport.post, URL, b"{}", {})
        self.assertEqual(len(connections), 1)

    def test_non_success_status_returned_for_broker_policy(self):
        transport, _, _, _ = self.transport(b"HTTP/1.1 410 Gone\r\nContent-Length: 0\r\n\r\n")
        self.assertEqual(transport.post(URL, b"{}", {}), (410, b""))

    def test_response_body_bounds_fixed_and_chunked(self):
        responses = [b"HTTP/1.1 200 OK\r\nContent-Length: 4097\r\n\r\n" + b"x" * 4097,
                     b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1001\r\n" + b"x" * 4097 + b"\r\n0\r\n\r\n"]
        for response in responses:
            transport, _, _, _ = self.transport(response)
            self.assert_code("response_too_large", transport.post, URL, b"{}", {})
        transport, _, _, _ = self.transport(b"HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n" + b"x" * 4096)
        self.assertEqual(len(transport.post(URL, b"{}", {})[1]), 4096)

    def test_dns_deadline_prevents_connection(self):
        clock = Clock()

        def resolver(host, port):
            clock.value = 10.0
            return ["1.1.1.1"]

        transport, _, _, connections = self.transport(clock=clock, resolver=resolver)
        self.assert_code("timeout", transport.post, URL, b"{}", {})
        self.assertFalse(connections)

    def test_slow_dns_has_bounded_wall_clock_wait(self):
        release = threading.Event()

        def resolver(host, port):
            release.wait(1)
            return ["1.1.1.1"]

        transport, _, _, connections = self.transport(resolver=resolver, timeout=0.025)
        start = time.monotonic()
        try:
            self.assert_code("timeout", transport.post, URL, b"{}", {})
        finally:
            release.set()
        self.assertLess(time.monotonic() - start, 0.5)
        self.assertFalse(connections)

    def test_tls_deadline_closes_socket(self):
        clock = Clock()
        raw = FakeSocket()
        raw.handshake = lambda: setattr(clock, "value", 11)
        transport, _, _, _ = self.transport(clock=clock, raw=raw)
        self.assert_code("timeout", transport.post, URL, b"{}", {})
        self.assertTrue(raw.closed)

    def test_watchdog_interrupts_blocked_header_read(self):
        raw = FakeSocket()

        class BlockedReader(io.BytesIO):
            def readline(self, *args):
                if not raw.shutdown_event.wait(1):
                    raise AssertionError("watchdog did not interrupt read")
                raise OSError("closed during read")

        raw.makefile = lambda mode: BlockedReader()
        transport, _, _, _ = self.transport(raw=raw, timeout=0.025)
        start = time.monotonic()
        self.assert_code("timeout", transport.post, URL, b"{}", {})
        self.assertLess(time.monotonic() - start, 0.5)
        self.assertTrue(raw.shutdown_event.is_set())
        self.assertTrue(raw.closed)

    def test_watchdog_interrupts_blocked_body_read(self):
        raw = FakeSocket()

        class BlockedBody(io.BytesIO):
            def read(self, *args):
                if not raw.shutdown_event.wait(1):
                    raise AssertionError("watchdog did not interrupt body read")
                raise OSError("closed during read")

        raw.makefile = lambda mode: BlockedBody(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
        transport, _, _, _ = self.transport(raw=raw, timeout=0.025)
        self.assert_code("timeout", transport.post, URL, b"{}", {})
        self.assertTrue(raw.shutdown_event.is_set())
        self.assertTrue(raw.closed)

    def test_default_tls_context_requires_certificate_and_hostname(self):
        transport = wh.PublicHTTPSWebhookTransport()
        self.assertTrue(transport._context.check_hostname)
        self.assertEqual(transport._context.verify_mode, ssl.CERT_REQUIRED)

    def test_tls_certificate_error_is_safe(self):
        raw = FakeSocket()
        raw.handshake = lambda: (_ for _ in ()).throw(ssl.SSLCertVerificationError("private host details"))
        transport, _, _, _ = self.transport(raw=raw)
        error = self.assert_code("network_error", transport.post, URL, b"{}", {})
        self.assertNotIn("private", str(error))
        self.assertTrue(raw.closed)

    def test_request_framing_and_header_injection_rejected(self):
        for headers in ({"Host": "127.0.0.1"}, {"Content-Length": "1"}, {"Transfer-Encoding": "chunked"},
                        {"Proxy-Authorization": "secret"}, {"X-Test": "value\r\nHost: localhost"},
                        {"x-test": "one", "X-Test": "two"}, {"Bad Key": "x"}):
            transport, _, _, connections = self.transport()
            self.assert_code("invalid_request", transport.post, URL, b"{}", headers)
            self.assertFalse(connections)

    def test_timeout_configuration_never_exceeds_ten_seconds(self):
        for value in (0, -1, 10.1, float("inf"), float("nan"), True):
            self.assert_code("invalid_request", wh.PublicHTTPSWebhookTransport, timeout=value)


if __name__ == "__main__":
    unittest.main()
