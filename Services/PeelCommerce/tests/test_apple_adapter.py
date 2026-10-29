"""Real pinned Apple models and verifier; all network/credential inputs are injected."""
import base64
import json
import socket
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from appstoreserverlibrary.api_client import AppStoreServerAPIClient
from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.InAppOwnershipType import InAppOwnershipType
from appstoreserverlibrary.models.JWSTransactionDecodedPayload import JWSTransactionDecodedPayload
from appstoreserverlibrary.models.Type import Type
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

from peel_commerce.apple import AppleAdapter, apple_roots, APPLE_RESPONSE_LIMIT
from peel_commerce.config import Config
from peel_commerce.contract import APP_APPLE_ID, BUNDLE_ID, InvalidEvidence, Unavailable
from peel_commerce.policy import Transaction
from test_authority import NOW, transaction


class AppleAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.network = patch.object(socket.socket, "connect", side_effect=AssertionError("offline test attempted network"))
        cls.network.start()

    @classmethod
    def tearDownClass(cls):
        cls.network.stop()

    def adapter(self):
        config = Config("https://commerce.example.invalid", "Production", "ABCDEFGHIJ",
                        "00000000-0000-4000-8000-000000000000", "/not/read/credential.p8")
        with patch("peel_commerce.apple.private_key", return_value=b"not-a-real-private-key"), \
             patch.object(AppStoreServerAPIClient, "__init__", return_value=None):
            return AppleAdapter(config)

    def test_official_roots_parse_and_model_field_mapping_matches_library(self):
        from cryptography import x509
        self.assertEqual(len(apple_roots()), 3)
        for root in apple_roots():
            cert = x509.load_der_x509_certificate(root)
            self.assertEqual(cert.subject, cert.issuer)
        data = transaction().__dict__.copy()
        data.update(type=Type.NON_CONSUMABLE, environment=Environment.PRODUCTION,
                    inAppOwnershipType=InAppOwnershipType.PURCHASED)
        model = JWSTransactionDecodedPayload(**data)
        self.assertEqual(Transaction.from_apple(model, "Production", NOW).product_id, model.productId)

    def test_fabricated_compact_jws_is_rejected_by_real_apple_verifier(self):
        # An alg=none payload and a fabricated signature never become evidence.
        def part(obj):
            return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()
        forged = part({"alg": "none"}) + "." + part({"bundleId": BUNDLE_ID, "environment": "Production"}) + ".c2ln"
        adapter = self.adapter()
        self.assertIsInstance(adapter.historical, SignedDataVerifier)
        self.assertFalse(adapter.historical._enable_online_checks)
        self.assertTrue(adapter.current._enable_online_checks)
        self.assertEqual(adapter.current._app_apple_id, APP_APPLE_ID)
        with self.assertRaises(InvalidEvidence): adapter.decode_proof(forged)
        with self.assertRaises(Unavailable): adapter.decode_current(forged)

    def test_real_adapter_calls_fresh_api_and_online_verifier_every_time(self):
        adapter = self.adapter()
        signed = "e30.e30.c2ln"
        with patch.object(adapter.client, "get_transaction_info", return_value=SimpleNamespace(signedTransactionInfo=signed)) as api, \
             patch.object(adapter.current, "verify_and_decode_signed_transaction", return_value="verified-model") as verifier:
            self.assertEqual(adapter.current_transaction("1234"), "verified-model")
            self.assertEqual(adapter.current_transaction("1234"), "verified-model")
        self.assertEqual(api.call_count, 2)
        self.assertEqual(verifier.call_count, 2)
        with patch.object(adapter.client, "get_all_subscription_statuses", side_effect=TimeoutError):
            with self.assertRaises(Unavailable): adapter.subscription_status("1234")

    def test_api_redirect_size_and_timeouts_use_bounded_transport(self):
        adapter = self.adapter()
        response = SimpleNamespace(status_code=302, close=lambda: None)
        session = SimpleNamespace(trust_env=True, request=lambda *args, **kwargs: response)
        # MagicMock supplies context manager methods for the real adapter transport.
        from unittest.mock import MagicMock
        session_manager = MagicMock()
        session_manager.__enter__.return_value = session
        with patch("requests.Session", return_value=session_manager):
            with self.assertRaises(Unavailable):
                adapter.client._execute_request("GET", "https://api.storekit.apple.com/inApps/v1/transactions/123", {}, {}, None, None)
        self.assertFalse(session.trust_env)
        response.status_code = 200
        response.iter_content = lambda size: iter([b"x" * (APPLE_RESPONSE_LIMIT + 1)])
        with patch("requests.Session", return_value=session_manager):
            with self.assertRaises(Unavailable):
                adapter.client._execute_request("GET", "https://api.storekit.apple.com/inApps/v1/transactions/123", {}, {}, None, None)
        with self.assertRaises(Unavailable):
            adapter.client._execute_request("GET", "https://evil.example/", {}, {}, None, None)


if __name__ == "__main__":
    unittest.main()
