"""Real Apple adapter; imported only in the killable network worker.

The historical verifier can authenticate an old device snapshot at its signing
time. It never grants. Only an uncached API response verified with online
certificate/revocation checks can become current entitlement evidence.
"""
import hashlib
import json
import os
import stat
from pathlib import Path
from urllib.parse import urlsplit
from .config import SERVICE_ROOT
from .contract import APP_APPLE_ID, BUNDLE_ID, InvalidEvidence, Unavailable, bounded_jws

APPLE_RESPONSE_LIMIT = 1024 * 1024


def apple_roots():
    # No operator/request-provided CA, fixture, or verifier fallback is accepted.
    pins = json.loads((SERVICE_ROOT / "SOURCE-PROVENANCE.json").read_text("utf-8"))
    entries = [item for item in pins["sources"] if item["path"].startswith("certificates/")]
    if len(entries) != 3:
        raise Unavailable("unconfigured")
    roots = []
    for item in entries:
        data = (SERVICE_ROOT / item["path"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise Unavailable("unconfigured")
        roots.append(data)
    return roots


def private_key(path):
    # Runtime only. Never written to output, stdout, a receipt, or a Host.
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or not 1 <= info.st_size <= 8192:
            raise Unavailable("unconfigured")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return stream.read(8193)
    finally:
        os.close(fd)


class AppleAdapter:
    def __init__(self, config):
        from .ocsp_transport import install_bounded_ocsp_transport
        from appstoreserverlibrary.api_client import AppStoreServerAPIClient
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier
        import requests

        install_bounded_ocsp_transport()

        class BoundedAppleClient(AppStoreServerAPIClient):
            def _execute_request(self, method, url, params, headers, json, data):
                expected = ("api.storekit.apple.com" if config.environment == "Production"
                            else "api.storekit-sandbox.apple.com")
                parsed = urlsplit(url)
                # The pinned Apple library chooses these URLs; never follow a redirect.
                if parsed.scheme != "https" or parsed.hostname != expected or method != "GET":
                    raise Unavailable("unavailable")
                with requests.Session() as session:
                    session.trust_env = False
                    response = session.request(method, url, params=params, headers=headers, json=json,
                                               data=data, timeout=(2, 4), allow_redirects=False, stream=True)
                    try:
                        if 300 <= response.status_code < 400:
                            raise Unavailable("unavailable")
                        parts = []
                        size = 0
                        for part in response.iter_content(16384):
                            size += len(part)
                            if size > APPLE_RESPONSE_LIMIT:
                                raise Unavailable("unavailable")
                            parts.append(part)
                        response._content = b"".join(parts)
                        response._content_consumed = True
                        return response
                    finally:
                        response.close()

        environment = Environment.PRODUCTION if config.environment == "Production" else Environment.SANDBOX
        roots = apple_roots()
        self.historical = SignedDataVerifier(roots, False, environment, BUNDLE_ID, APP_APPLE_ID)
        self.current = SignedDataVerifier(roots, True, environment, BUNDLE_ID, APP_APPLE_ID)
        self.client = BoundedAppleClient(private_key(config.private_key_path), config.key_id,
                                        config.issuer_id, BUNDLE_ID, environment)

    def decode_proof(self, signed):
        from appstoreserverlibrary.signed_data_verifier import VerificationException
        if not bounded_jws(signed):
            raise InvalidEvidence("invalid_evidence")
        try:
            return self.historical.verify_and_decode_signed_transaction(signed)
        except VerificationException as exc:
            raise InvalidEvidence("invalid_evidence") from exc

    def decode_current(self, signed):
        if not bounded_jws(signed):
            raise Unavailable("unavailable")
        try:
            return self.current.verify_and_decode_signed_transaction(signed)
        except Exception as exc:
            # Includes online certificate checks: outages must not grant.
            raise Unavailable("unavailable") from exc

    def decode_renewal(self, signed):
        if not bounded_jws(signed):
            raise Unavailable("unavailable")
        try:
            return self.current.verify_and_decode_renewal_info(signed)
        except Exception as exc:
            raise Unavailable("unavailable") from exc

    def current_transaction(self, transaction_id):
        try:
            response = self.client.get_transaction_info(transaction_id)
            return self.decode_current(response.signedTransactionInfo)
        except Exception as exc:
            raise Unavailable("unavailable") from exc

    def subscription_status(self, transaction_id):
        try:
            return self.client.get_all_subscription_statuses(transaction_id)
        except Exception as exc:
            raise Unavailable("unavailable") from exc
