"""Explicit private operator configuration; import never starts a listener."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import threading
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import serialization

from .auth_application import AuthenticatedApplication
from .auth_crypto import unb64
from .broker import RelayError, RelayStore
from .control_plane import ControlPlane
from .commerce_admission import CommerceAdmission, DirectCommerceVerifier
from .http import strict_json
from .plugin_oauth import PluginOAuth
from .provider_auth import ProviderCodeVerifier, Registration
from .rpc import fields
from .webhooks import PublicHTTPSWebhookTransport


def private_file(path, maximum):
    # Operator-selected paths only; no environment search or credential fallback.
    path = Path(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        meta = os.fstat(fd)
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) & 0o077 or not 1 <= meta.st_size <= maximum:
            raise RelayError("unsafe_private_config")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(maximum + 1)
        if len(raw) != meta.st_size or len(raw) > maximum:
            raise RelayError("unsafe_private_config")
        return raw
    finally:
        os.close(fd)


def load_config(path):
    config = strict_json(private_file(path, 32768))
    fields(config, ("enabled", "publicOrigin", "nativeApprovalURI", "dataDirectory", "principalKeyFile", "brokerSigningKeyFile", "brokerSigningKeyID", "providerRegistrations", "pluginClients", "deliveryWorkerEnabled"), ("commerceOrigin",))
    if config["enabled"] is not True or config["deliveryWorkerEnabled"] not in (True, False) or type(config["deliveryWorkerEnabled"]) is not bool:
        raise RelayError("explicit_service_enablement_required")
    origin = config["publicOrigin"]
    parsed = urlsplit(origin) if isinstance(origin, str) else None
    if parsed is None or parsed.scheme != "https" or not parsed.hostname or parsed.hostname.endswith((".invalid", ".test", ".local", ".localhost")) or "." not in parsed.hostname or parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password or parsed.port not in (None,443):
        raise RelayError("public_https_origin_required")
    for name in ("dataDirectory", "principalKeyFile", "brokerSigningKeyFile"):
        if not isinstance(config[name], str) or not Path(config[name]).is_absolute():
            raise RelayError("absolute_private_path_required")
    registrations = []
    if not isinstance(config["providerRegistrations"], list) or not 1 <= len(config["providerRegistrations"]) <= 2:
        raise RelayError("provider_registration_required")
    for registration in config["providerRegistrations"]:
        fields(registration, ("provider", "clientID", "redirectURI", "approvalReference"))
        registrations.append(Registration(registration["provider"], registration["clientID"], registration["redirectURI"], registration["approvalReference"]))
    if not isinstance(config["pluginClients"], list) or len(config["pluginClients"]) > 16:
        raise RelayError("invalid_plugin_clients")
    key = serialization.load_pem_private_key(private_file(config["brokerSigningKeyFile"], 8192), password=None)
    principal_key = unb64(private_file(config["principalKeyFile"], 128).decode("ascii").strip(), size=32)
    return config, registrations, key, principal_key


class DeliveryWorker:
    def __init__(self, control, relay, transport):
        self.control, self.relay, self.transport = control, relay, transport
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True, name="peel-event-delivery")

    def start(self):
        self.thread.start()

    def run(self):
        while not self.stop_event.is_set():
            for account, device in self.control.delivery_accounts():
                with self.relay.lock:
                    routes = self.relay.db.execute("SELECT id FROM routes WHERE principal=? AND provider=? AND account_generation=? AND device_id=? AND pairing_generation=? AND revoked=0",
                        (account.principal,account.provider,account.generation,device.device_id,device.pairing_generation)).fetchall()
                for route in routes:
                    if self.stop_event.is_set():
                        return
                    try:
                        self.relay.deliver_one(account, route["id"], self.transport)
                    except (RelayError, OSError):
                        pass  # No remote text/tokens/request contents in operational logs.
            self.stop_event.wait(1)


def create_application(config_path):
    config, registrations, signing_key, principal_key = load_config(config_path)
    control = ControlPlane(Path(config["dataDirectory"]) / "auth", ProviderCodeVerifier(registrations),
        issuer=config["publicOrigin"], principal_key=principal_key, signing_key=signing_key, signing_kid=config["brokerSigningKeyID"])
    relay = None
    try:
        relay = RelayStore(Path(config["dataDirectory"]) / "relay", control.current_device)
        if config.get("commerceOrigin") is not None:
            relay.commerce = CommerceAdmission(relay, control.commerce_context, DirectCommerceVerifier(config["commerceOrigin"]))
        transport = PublicHTTPSWebhookTransport()
        application = AuthenticatedApplication(control, relay, PluginOAuth(control, config["pluginClients"]), transport,
                                               native_approval_uri=config["nativeApprovalURI"])
        application.delivery_worker = DeliveryWorker(control, relay, transport)
        if config["deliveryWorkerEnabled"]:
            application.delivery_worker.start()
        return application
    except BaseException:
        if relay is not None:
            relay.close()
        control.close()
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--port", type=int)
    args = parser.parse_args()
    try:
        if args.preflight:
            # Validates formats/private files only: no DB, listener, DNS or token calls.
            config, registrations, signing_key, principal_key = load_config(args.config)
            from cryptography.hazmat.primitives.asymmetric import ec
            if not isinstance(signing_key, ec.EllipticCurvePrivateKey) or not isinstance(signing_key.curve,ec.SECP256R1):
                raise RelayError("broker_signing_key_required")
            print('{"configuration":"valid","liveAcceptance":"not_run"}')
            return 0
        if args.port is None or not 1024 <= args.port <= 65535:
            raise RelayError("explicit_loopback_port_required")
        # Diagnostic loopback listener only. Production uses the reviewed WSGI
        # runner/TLS proxy contract described in DEPLOYMENT.md, never wsgiref.
        from wsgiref.simple_server import make_server, WSGIRequestHandler
        class QuietHandler(WSGIRequestHandler):
            def log_message(self, *args):
                pass
        application = create_application(args.config)
        with make_server("127.0.0.1", args.port, application, handler_class=QuietHandler) as server:
            server.serve_forever()
    except (RelayError, OSError, ValueError):
        print('{"configuration":"blocked","liveAcceptance":"not_run"}')
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
