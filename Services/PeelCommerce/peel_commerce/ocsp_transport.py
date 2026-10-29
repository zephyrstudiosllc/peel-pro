"""Only the pinned Apple verifier's HTTP POST transport is replaced.

The official verifier still performs every certificate, OID, OCSP response,
responder signature and freshness check. This module supplies no trust result.
Install only inside the short-lived verification child, never in the WSGI app.
"""
import hashlib
import importlib.metadata
import re
from pathlib import Path
from urllib.parse import urlsplit

from .contract import Unavailable

APPLE_LIBRARY_VERSION = "3.1.2"
VERIFIER_SHA256 = "91a94db6dc0a92b5c0ed2eb94778012b3e113823f244d4801b232d3934ed9c7f"
MAX_OCSP_REQUEST = 4096
MAX_OCSP_RESPONSE = 65536
OCSP_PATH = re.compile(r"/ocsp[0-9]{2}-[a-z0-9-]{1,96}\Z", re.ASCII)


def allowed_ocsp_url(url):
    if type(url) is not str or len(url) > 160 or not url.isascii():
        return False
    try:
        parsed = urlsplit(url)
        # Public Apple WWDR G6 AIA supplies HTTP. OCSP signatures, verified by
        # Apple's unchanged verifier, authenticate that response independently.
        origins = {"http": ("ocsp.apple.com", "ocsp.apple.com:80"),
                   "https": ("ocsp.apple.com", "ocsp.apple.com:443")}
        return (parsed.scheme in origins and parsed.netloc in origins[parsed.scheme] and
                parsed.hostname == "ocsp.apple.com" and not parsed.username and not parsed.password and
                not parsed.query and not parsed.fragment and OCSP_PATH.fullmatch(parsed.path) is not None and
                url == parsed.scheme + "://" + parsed.netloc + parsed.path)
    except (ValueError, TypeError):
        return False


class BoundedOCSPRequests:
    """Narrow requests namespace matching the exact pinned verifier call site."""
    def __init__(self):
        import requests
        self.exceptions = requests.exceptions

    def post(self, url, *, headers, data, timeout):
        import requests
        if (not allowed_ocsp_url(url) or headers != {"Content-Type": "application/ocsp-request"} or
                type(data) is not bytes or not 1 <= len(data) <= MAX_OCSP_REQUEST):
            raise requests.exceptions.RequestException("unavailable")
        # The library passes timeout=30; transport policy deliberately replaces
        # it with finite connect/read bounds. The parent also enforces 12s total.
        with requests.Session() as session:
            session.trust_env = False
            session.headers.update({"Accept-Encoding": "identity"})
            response = session.post(url, headers=headers, data=data, timeout=(2, 4),
                                    allow_redirects=False, stream=True)
            try:
                if response.status_code != 200:
                    raise requests.exceptions.RequestException("unavailable")
                if response.headers.get("Content-Encoding", "").strip().lower() not in ("", "identity"):
                    raise requests.exceptions.RequestException("unavailable")
                body = bytearray()
                # Compressed responses are rejected before reading so that a
                # decompressor cannot allocate a large buffer before yielding.
                for part in response.iter_content(8192):
                    if len(body) + len(part) > MAX_OCSP_RESPONSE:
                        raise requests.exceptions.RequestException("unavailable")
                    body.extend(part)
                # Never access the original response.content property, which
                # would materialize an unbounded body before our cap.
                from types import SimpleNamespace
                return SimpleNamespace(status_code=200, content=bytes(body))
            finally:
                response.close()


def install_bounded_ocsp_transport():
    import requests
    import appstoreserverlibrary.signed_data_verifier as verifier_module
    try:
        source_path = Path(verifier_module.__file__)
        if (importlib.metadata.version("app-store-server-library") != APPLE_LIBRARY_VERSION or
                source_path.suffix != ".py" or source_path.stat().st_size > 30000 or
                hashlib.sha256(source_path.read_bytes()).hexdigest() != VERIFIER_SHA256 or
                (verifier_module.requests is not requests and
                 not isinstance(verifier_module.requests, BoundedOCSPRequests))):
            raise Unavailable("unconfigured")
        # Rebind this module reference only. Never mutate requests.post or the
        # requests package used by the API client, WSGI server or other code.
        verifier_module.requests = BoundedOCSPRequests()
    except (OSError, ValueError, importlib.metadata.PackageNotFoundError) as exc:
        raise Unavailable("unconfigured") from exc
