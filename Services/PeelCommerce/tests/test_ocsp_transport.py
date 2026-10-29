"""Offline real-verifier transport regressions; no real OCSP endpoint calls."""
import unittest
from unittest.mock import MagicMock, patch

import requests
import appstoreserverlibrary.signed_data_verifier as verifier_module
from cryptography import x509
from OpenSSL import crypto

from peel_commerce.config import SERVICE_ROOT
from peel_commerce.contract import Unavailable
from peel_commerce.ocsp_transport import (BoundedOCSPRequests, MAX_OCSP_REQUEST, MAX_OCSP_RESPONSE,
                                          allowed_ocsp_url, install_bounded_ocsp_transport)

URL = "http://ocsp.apple.com/ocsp03-applerootcag3"
HEADERS = {"Content-Type": "application/ocsp-request"}


class OCSPTransportTests(unittest.TestCase):
    def setUp(self):
        self.previous = verifier_module.requests
        self.addCleanup(setattr, verifier_module, "requests", self.previous)

    def response(self, parts=(b"OCSP bytes",), status=200):
        response = MagicMock()
        response.status_code = status
        response.headers = {}
        response.iter_content.return_value = iter(parts)
        # Accidental unbounded .content access is a test failure.
        type(response).content = property(lambda _: (_ for _ in ()).throw(AssertionError("unbounded content read")))
        session = MagicMock()
        session.post.return_value = response
        manager = MagicMock()
        manager.__enter__.return_value = session
        return manager, session, response

    def post(self, **changes):
        args = dict(url=URL, headers=HEADERS, data=b"DER request", timeout=30)
        args.update(changes)
        return BoundedOCSPRequests().post(**args)

    def test_actual_public_certificate_aia_origin_and_strict_url_allowlist(self):
        cert = x509.load_der_x509_certificate((SERVICE_ROOT / "references/AppleWWDRCAG6.cer").read_bytes())
        aia = cert.extensions.get_extension_for_oid(x509.ExtensionOID.AUTHORITY_INFORMATION_ACCESS).value
        urls = [d.access_location.value for d in aia if d.access_method == x509.AuthorityInformationAccessOID.OCSP]
        self.assertEqual(urls, [URL])
        for url in (URL, URL.replace("http:", "https:"), URL.replace(".com/", ".com:80/")):
            self.assertTrue(allowed_ocsp_url(url))
        for url in ("http://ocsp.apple.com.evil.example/ocsp03-a", "http://evil.example/ocsp03-a",
                    "http://user@ocsp.apple.com/ocsp03-a", "http://ocsp.apple.com:443/ocsp03-a",
                    "https://ocsp.apple.com:80/ocsp03-a", URL + "?dest=evil", URL + "#x",
                    "http://ocsp.apple.com/../private", "http://ocsp.apple.com/%2fprivate",
                    "http://ocsp.apple.com\\evil.example/ocsp03-a", "http://127.0.0.1/ocsp03-a",
                    URL + "\n", URL.replace("ocsp03", "ocspé3")):
            with self.subTest(url=url): self.assertFalse(allowed_ocsp_url(url))

    def test_bounded_stream_proxy_redirect_timeout_and_session_lifetime(self):
        manager, session, response = self.response()
        with patch("requests.Session", return_value=manager):
            result = self.post()
        self.assertEqual(result.content, b"OCSP bytes")
        self.assertFalse(session.trust_env)
        session.headers.update.assert_called_once_with({"Accept-Encoding": "identity"})
        session.post.assert_called_once_with(URL, headers=HEADERS, data=b"DER request", timeout=(2, 4),
                                             allow_redirects=False, stream=True)
        response.close.assert_called_once()
        manager.__exit__.assert_called_once()

    def test_redirect_is_rejected_before_read_and_never_followed(self):
        manager, session, response = self.response(status=302)
        with patch("requests.Session", return_value=manager), self.assertRaises(requests.exceptions.RequestException):
            self.post()
        response.iter_content.assert_not_called()
        response.close.assert_called_once()
        self.assertFalse(session.post.call_args.kwargs["allow_redirects"])

    def test_response_size_is_capped_and_compressed_responses_rejected_before_read(self):
        manager, _, response = self.response(parts=(b"x" * MAX_OCSP_RESPONSE, b"y"))
        with patch("requests.Session", return_value=manager), self.assertRaises(requests.exceptions.RequestException):
            self.post()
        response.close.assert_called_once()
        manager, _, response = self.response()
        response.headers = {"Content-Encoding": "gzip", "Content-Length": "20"}
        with patch("requests.Session", return_value=manager), self.assertRaises(requests.exceptions.RequestException):
            self.post()
        response.iter_content.assert_not_called()
        response.close.assert_called_once()

    def test_reject_url_input_and_oversize_der_before_egress(self):
        for change in ({"url": "http://evil.example/ocsp03-a"}, {"headers": {"Content-Type": "text/plain"}},
                       {"headers": {**HEADERS, "Authorization": "unwanted"}}, {"data": b""},
                       {"data": b"x" * (MAX_OCSP_REQUEST + 1)}, {"data": "text"}):
            with patch("requests.Session") as session, self.subTest(change=change), \
                 self.assertRaises(requests.exceptions.RequestException):
                self.post(**change)
            session.assert_not_called()

    def test_socket_timeout_propagates_without_success_result(self):
        manager, session, _ = self.response()
        session.post.side_effect = requests.exceptions.ReadTimeout("fixture")
        with patch("requests.Session", return_value=manager), self.assertRaises(requests.exceptions.ReadTimeout):
            self.post()
        manager.__exit__.assert_called_once()

    def test_namespace_change_is_exact_pinned_module_only(self):
        original_post = requests.post
        install_bounded_ocsp_transport()
        self.assertIsInstance(verifier_module.requests, BoundedOCSPRequests)
        self.assertIs(verifier_module.requests.exceptions, requests.exceptions)
        self.assertIs(requests.post, original_post)
        with patch("importlib.metadata.version", return_value="future-version"), self.assertRaises(Unavailable):
            install_bounded_ocsp_transport()
        with patch("peel_commerce.ocsp_transport.VERIFIER_SHA256", "0" * 64), self.assertRaises(Unavailable):
            install_bounded_ocsp_transport()

    def test_real_apple_ocsp_check_rejects_malformed_body_via_bounded_namespace(self):
        install_bounded_ocsp_transport()
        intermediate = crypto.X509.from_cryptography(x509.load_der_x509_certificate(
            (SERVICE_ROOT / "references/AppleWWDRCAG6.cer").read_bytes()))
        root = crypto.X509.from_cryptography(x509.load_der_x509_certificate(
            (SERVICE_ROOT / "certificates/AppleRootCA-G3.cer").read_bytes()))
        manager, session, _ = self.response(parts=(b"not an OCSP DER response",))
        with patch("requests.Session", return_value=manager), self.assertRaises(ValueError):
            # Real pinned OCSP parser/body/signature code, never replaced.
            verifier_module._ChainVerifier([]).check_ocsp_status(intermediate, root, root)
        self.assertEqual(session.post.call_args.args[0], URL)


if __name__ == "__main__":
    unittest.main()
