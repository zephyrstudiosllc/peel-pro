"""Offline policy fixtures only. These adapters cannot be selected by deployment config."""
import base64
import copy
import io
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace as Model
from unittest.mock import patch

from peel_commerce.app import Application, Pressure, create_app
from peel_commerce.broker import ProcessBroker, validate_response
from peel_commerce.config import Config
from peel_commerce.contract import (APP_APPLE_ID, BUNDLE_ID, LIFETIME, MONTHLY, YEARLY, TRIAL,
                                    MAX_BODY, Request, InvalidRequest, InvalidEvidence, Unavailable)
from peel_commerce.policy import Authority, TRIAL_SECONDS

NOW = 1792512000
TOKEN = "e30.e30.c2ln"
SECOND_TOKEN = "e30.e31.c2ln"


def wire(tokens=None):
    return {"schema": 1, "requestId": "de3d81c8-4ec6-4847-a50f-adf0699088aa",
            "nonce": base64.b64encode(bytes(range(32))).decode(),
            "pairingId": "9664d07b-79b5-4676-a04c-f50807004c98",
            "sessionId": "0e2ce599-1f55-4f7c-a051-34269846b9a9",
            "signedTransactions": [TOKEN] if tokens is None else tokens}


def request(tokens=None):
    return Request.parse(json.dumps(wire(tokens)).encode())


def transaction(product=LIFETIME, **changes):
    obj = Model(transactionId="20000000000001", originalTransactionId="20000000000001",
                productId=product, bundleId=BUNDLE_ID, environment="Production", quantity=1,
                type="Auto-Renewable Subscription" if product in (MONTHLY, YEARLY) else "Non-Consumable",
                inAppOwnershipType="PURCHASED", purchaseDate=(NOW - 3600) * 1000,
                originalPurchaseDate=(NOW - 3600) * 1000, signedDate=(NOW - 100) * 1000,
                expiresDate=(NOW + 3600) * 1000 if product in (MONTHLY, YEARLY) else None,
                revocationDate=None, revocationReason=None, revocationType=None, revocationPercentage=None,
                isUpgraded=False, subscriptionGroupIdentifier="21400000" if product in (MONTHLY, YEARLY) else None)
    obj.__dict__.update(changes)
    return obj


def statuses(tx, status=1, **renewal_changes):
    renewal = Model(environment="Production", originalTransactionId=tx.originalTransactionId,
                    productId=tx.productId, autoRenewProductId=tx.productId, signedDate=NOW * 1000,
                    gracePeriodExpiresDate=None, isInBillingRetryPeriod=None)
    renewal.__dict__.update(renewal_changes)
    item = Model(originalTransactionId=tx.originalTransactionId, status=status,
                 signedTransactionInfo="current", signedRenewalInfo="renewal")
    response = Model(bundleId=BUNDLE_ID, appAppleId=APP_APPLE_ID, environment="Production",
                     data=[Model(subscriptionGroupIdentifier=tx.subscriptionGroupIdentifier, lastTransactions=[item])])
    return response, renewal


class FixtureApple:
    def __init__(self, proof=None, fresh=None):
        self.proof = proof or transaction()
        self.fresh = fresh or copy.deepcopy(self.proof)
        self.fresh.signedDate = NOW * 1000
        self.status_tx = copy.deepcopy(self.fresh)
        self.response, self.renewal = statuses(self.status_tx)
        self.lookups = []
        self.failure = None

    def decode_proof(self, token):
        return self.proof

    def current_transaction(self, transaction_id):
        self.lookups.append(transaction_id)
        if self.failure:
            raise self.failure
        return self.fresh

    def subscription_status(self, transaction_id):
        return self.response

    def decode_current(self, token):
        return self.status_tx

    def decode_renewal(self, token):
        return self.renewal


class PolicyTests(unittest.TestCase):
    def verify(self, apple):
        return Authority(apple, clock=lambda: NOW).verify(request())

    def test_old_lifetime_has_no_price_or_purchase_date_cutoff_and_requires_fresh_lookup(self):
        old = transaction(purchaseDate=1500000000000, originalPurchaseDate=1500000000000,
                          signedDate=1500000001000, price=999)
        apple = FixtureApple(old)
        result = self.verify(apple)
        self.assertEqual((result["decision"], result["productId"], result["expiresAt"]), ("granted", LIFETIME, NOW + 300))
        self.assertEqual(apple.lookups, [old.transactionId])
        for key in ("requestId", "nonce", "pairingId", "sessionId"):
            self.assertEqual(result[key], wire()[key])

    def test_old_valid_jws_cannot_override_fresh_refund(self):
        apple = FixtureApple()
        apple.fresh.revocationDate = (NOW - 5) * 1000
        result = self.verify(apple)
        self.assertEqual((result["decision"], result["reason"], result["expiresAt"]), ("denied", "revoked", NOW))
        self.assertNotIn("ownership", result)

    def test_outage_never_grants_from_old_valid_jws(self):
        apple = FixtureApple()
        apple.failure = Unavailable("unavailable")
        with self.assertRaises(Unavailable):
            self.verify(apple)

    def test_family_shared_lifetime_and_subscriptions(self):
        for product in (LIFETIME, MONTHLY, YEARLY):
            with self.subTest(product=product):
                result = self.verify(FixtureApple(transaction(product, inAppOwnershipType="FAMILY_SHARED")))
                self.assertEqual((result["decision"], result["ownership"]), ("granted", "familyShared"))

    def test_trial_uses_original_purchase_and_caps_lease(self):
        tx = transaction(TRIAL, purchaseDate=(NOW - 5) * 1000,
                         originalPurchaseDate=(NOW - TRIAL_SECONDS + 7) * 1000, signedDate=NOW * 1000)
        result = self.verify(FixtureApple(tx))
        self.assertEqual(result["expiresAt"], NOW + 7)
        tx.originalPurchaseDate = (NOW - TRIAL_SECONDS) * 1000
        result = self.verify(FixtureApple(tx))
        self.assertEqual((result["decision"], result["reason"]), ("denied", "expired"))

    def test_monthly_yearly_match_status_and_expiry(self):
        for product in (MONTHLY, YEARLY):
            result = self.verify(FixtureApple(transaction(product, expiresDate=(NOW + 19) * 1000)))
            self.assertEqual((result["decision"], result["expiresAt"]), ("granted", NOW + 19))

    def test_grace_requires_matching_signed_renewal_and_caps_at_real_grace_end(self):
        apple = FixtureApple(transaction(MONTHLY, expiresDate=(NOW - 10) * 1000))
        apple.response, apple.renewal = statuses(apple.status_tx, status=4,
                                               gracePeriodExpiresDate=(NOW + 11) * 1000,
                                               isInBillingRetryPeriod=True)
        result = self.verify(apple)
        self.assertEqual(result["expiresAt"], NOW + 11)
        apple.renewal.originalTransactionId = "99999"
        with self.assertRaises(InvalidEvidence):
            self.verify(apple)

    def test_no_grace_from_billing_retry_expired_missing_or_revoked_status(self):
        for status in (2, 3, 4, 5):
            with self.subTest(status=status):
                apple = FixtureApple(transaction(MONTHLY, expiresDate=(NOW - 10) * 1000))
                apple.response, apple.renewal = statuses(apple.status_tx, status=status)
                self.assertEqual(self.verify(apple)["decision"], "denied")

    def test_upgrade_never_grants(self):
        apple = FixtureApple(transaction(MONTHLY))
        apple.fresh.isUpgraded = True
        self.assertEqual(self.verify(apple)["decision"], "denied")

    def test_immutable_fresh_identity_must_match_proof(self):
        for field, bad in (("transactionId", "222"), ("originalTransactionId", "222"),
                           ("productId", TRIAL), ("inAppOwnershipType", "FAMILY_SHARED"),
                           ("originalPurchaseDate", (NOW - 4000) * 1000), ("bundleId", "com.other"),
                           ("environment", "Sandbox"), ("type", "Consumable")):
            with self.subTest(field=field):
                apple = FixtureApple()
                setattr(apple.fresh, field, bad)
                with self.assertRaises(InvalidEvidence):
                    self.verify(apple)

    def test_invalid_signed_field_types_sku_ownership_environment_and_dates(self):
        for field, bad in (("productId", "other"), ("quantity", True), ("purchaseDate", True),
                           ("signedDate", (NOW + 31) * 1000), ("inAppOwnershipType", "UNKNOWN"),
                           ("environment", "Xcode"), ("isUpgraded", 1), ("transactionId", "../12")):
            with self.subTest(field=field):
                apple = FixtureApple()
                setattr(apple.proof, field, bad)
                with self.assertRaises(InvalidEvidence):
                    self.verify(apple)

    def test_status_fixed_app_id_group_transaction_and_environment(self):
        for mutation in (lambda a: setattr(a.response, "appAppleId", 123),
                         lambda a: setattr(a.response, "bundleId", "other"),
                         lambda a: setattr(a.response, "environment", "Sandbox"),
                         lambda a: setattr(a.status_tx, "transactionId", "9999"),
                         lambda a: setattr(a.response.data[0], "subscriptionGroupIdentifier", "other")):
            apple = FixtureApple(transaction(MONTHLY))
            mutation(apple)
            try:
                result = self.verify(apple)
                self.assertEqual(result["decision"], "denied")
            except InvalidEvidence:
                pass

    def test_status_revocation_overrides_first_fresh_snapshot(self):
        apple = FixtureApple(transaction(MONTHLY))
        apple.status_tx.revocationDate = NOW * 1000
        self.assertEqual(self.verify(apple)["reason"], "revoked")

    def test_duplicate_proof_identity_and_empty_proof(self):
        with self.assertRaises(InvalidEvidence):
            Authority(FixtureApple(), clock=lambda: NOW).verify(request([TOKEN, SECOND_TOKEN]))
        self.assertEqual(Authority(FixtureApple(), clock=lambda: NOW).verify(request([]))["reason"], "no_entitlement")


class RequestTests(unittest.TestCase):
    def test_pairing_is_bounded_safe_ascii_opaque_binding(self):
        obj = wire()
        for pairing in ("peer-1", "A.b_c:0", "a" * 128):
            obj["pairingId"] = pairing
            self.assertEqual(Request.parse(json.dumps(obj).encode()).pairing_id, pairing)
        for pairing in ("", "white space", "é", "a" * 129, "slash/path", "newline\n"):
            obj["pairingId"] = pairing
            with self.subTest(pairing=pairing), self.assertRaises(InvalidRequest):
                Request.parse(json.dumps(obj).encode())

    def test_strict_types_unknown_duplicate_and_limits(self):
        invalid = []
        for key, val in (("schema", True), ("schema", 1.0), ("nonce", "A" * 44),
                         ("requestId", "any"), ("pairingId", None), ("sessionId", 7),
                         ("signedTransactions", TOKEN), ("signedTransactions", [TOKEN] * 5),
                         ("signedTransactions", [TOKEN, TOKEN]), ("signedTransactions", ["a" * 32769])):
            obj = wire(); obj[key] = val
            invalid.append(json.dumps(obj).encode())
        obj = wire(); obj["environment"] = "Sandbox"
        invalid.extend((json.dumps(obj).encode(), b'{"schema":1,"schema":1}',
                        b'{"schema":NaN}', b"[" * 1200, b"x" * (MAX_BODY + 1)))
        for data in invalid:
            with self.subTest(data=data[:60]), self.assertRaises(InvalidRequest):
                Request.parse(data)

    def test_exact_response_binding_and_lease_validation(self):
        req = request()
        result = Authority(FixtureApple(), clock=lambda: NOW).verify(req)
        self.assertEqual(validate_response(result, req, NOW), result)
        for key, val in (("nonce", "x"), ("expiresAt", NOW + 301), ("productId", "other"),
                         ("reason", "bypass"), ("verifiedAt", True), ("ownership", "any")):
            changed = dict(result); changed[key] = val
            with self.subTest(key=key), self.assertRaises(Unavailable):
                validate_response(changed, req, NOW)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.config = Config("https://commerce.example.invalid", "Production", "ABCDEFGHIJ",
                             "00000000-0000-4000-8000-000000000000", "/private/not-read.p8")

    def call(self, app, body=None, **changes):
        body = json.dumps(wire()).encode() if body is None else body
        env = {"PATH_INFO": "/v1/entitlements/verify", "REQUEST_METHOD": "POST", "wsgi.url_scheme": "https",
               "HTTP_HOST": "commerce.example.invalid", "CONTENT_TYPE": "application/json",
               "CONTENT_LENGTH": str(len(body)), "wsgi.input": io.BytesIO(body), "REMOTE_ADDR": "192.0.2.1"}
        env.update(changes)
        captured = []
        output = app(env, lambda status, headers: captured.extend((status, dict(headers))))
        return captured[0], captured[1], json.loads(b"".join(output))

    def test_unconfigured_is_503_and_no_store(self):
        status, headers, body = self.call(create_app("/no/such/config"))
        self.assertTrue(status.startswith("503"))
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(body, {"error": "unavailable"})

    def test_tls_fixed_origin_method_content_size_and_unknown_fields(self):
        verifier = Model(verify=lambda r: Authority(FixtureApple(), clock=lambda: NOW).verify(r))
        for change, code in (({"wsgi.url_scheme": "http"}, "400"), ({"HTTP_HOST": "evil.example"}, "400"),
                             ({"REQUEST_METHOD": "GET"}, "405"), ({"HTTP_ORIGIN": "https://browser.invalid"}, "400"),
                             ({"CONTENT_TYPE": "text/plain"}, "415"), ({"CONTENT_LENGTH": "140001"}, "413"),
                             ({"HTTP_TRANSFER_ENCODING": "chunked"}, "415"), ({"QUERY_STRING": "environment=Sandbox"}, "400")):
            with self.subTest(change=change):
                self.assertTrue(self.call(Application(self.config, verifier), **change)[0].startswith(code))
        self.assertTrue(self.call(Application(self.config, verifier), b'{"schema":true}')[0].startswith("400"))

    def test_pressure_and_exception_contents_never_leak(self):
        def fail(_):
            raise Unavailable("private credential and transaction value")
        app = Application(self.config, Model(verify=fail))
        for _ in range(12):
            status, headers, body = self.call(app)
            self.assertEqual((status, body), ("503 Service Unavailable", {"error": "unavailable"}))
            self.assertNotIn("Set-Cookie", headers)
        self.assertTrue(self.call(app)[0].startswith("429"))

    def test_worker_capacity_is_nonblocking(self):
        broker = ProcessBroker("/not/read", maximum_workers=1)
        broker.capacity.acquire()
        with self.assertRaises(Unavailable), patch("subprocess.Popen") as popen:
            broker.verify(request())
        popen.assert_not_called()

    def test_real_worker_missing_config_exits_without_grant(self):
        broker = ProcessBroker("/no/such/peel-commerce-fixture-config")
        with self.assertRaises(Unavailable):
            broker.verify(request())

    def test_worker_deadline_kills_stalled_fixture_process_and_releases_capacity(self):
        actual_popen = subprocess.Popen
        children = []
        def stall(_args, **kwargs):
            child = actual_popen([sys.executable, "-I", "-c", "import time; time.sleep(10)"], **kwargs)
            children.append(child)
            return child
        broker = ProcessBroker("/not/read", timeout=0.05, maximum_workers=1)
        start = time.monotonic()
        with patch("subprocess.Popen", side_effect=stall), self.assertRaises(Unavailable):
            broker.verify(request())
        self.assertLess(time.monotonic() - start, 2)
        self.assertIsNotNone(children[0].poll())
        self.assertTrue(broker.capacity.acquire(blocking=False))

    def test_private_sandbox_is_operator_only_and_config_unknowns_rejected(self):
        obj = {"enabled": True, "publicOrigin": self.config.public_origin, "environment": "Production",
               "privateSandbox": False, "keyId": self.config.key_id, "issuerId": self.config.issuer_id,
               "privateKeyPath": self.config.private_key_path}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.json"
            path.write_text(json.dumps(obj)); self.assertEqual(Config.load(str(path)).environment, "Production")
            obj["environment"] = "Sandbox"; path.write_text(json.dumps(obj))
            with self.assertRaises(Unavailable): Config.load(str(path))
            obj["privateSandbox"] = True; path.write_text(json.dumps(obj))
            self.assertEqual(Config.load(str(path)).environment, "Sandbox")
            obj["rootCertificates"] = ["test-root"]; path.write_text(json.dumps(obj))
            with self.assertRaises(Unavailable): Config.load(str(path))


if __name__ == "__main__":
    unittest.main()
