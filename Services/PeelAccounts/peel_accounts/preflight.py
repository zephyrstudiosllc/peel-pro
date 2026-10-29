"""Read-only, secret-safe local account configuration check. No service is started."""
import argparse
import ipaddress
import json
from pathlib import Path

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import load_pem_private_key

from .config import Settings, parse_https_origin


def native_origin_supported(origin):
    """Match native production origin policy; DNS/TLS acceptance remains external."""
    try:
        components = parse_https_origin(origin)
    except ValueError:
        return False
    host = components.hostname or ""
    if (len(host) > 253 or "." not in host or components.netloc != components.netloc.lower()
            or any(host.endswith(x) for x in (".local", ".invalid", ".test", ".example", ".localhost"))
            or any(host == x or host.endswith("." + x) for x in ("example.com", "example.net", "example.org"))
            or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-." for c in host)):
        return False
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        pass
    return all(label and len(label) <= 63 and not label.startswith("-") and not label.endswith("-")
               for label in host.split(".")) and not all(label.isdecimal() for label in host.split("."))


def check(config_path=None):
    checks = []
    def passed(name):
        checks.append({"check": name, "status": "pass"})
    stage = "configuration_file"
    try:
        if not config_path:
            raise ValueError()
        settings = Settings.from_file(config_path)
        passed(stage)
        stage = "enabled_private_storage"
        settings.validate()
        passed(stage)
        stage = "native_origin_policy"
        if not native_origin_supported(settings.public_origin):
            raise ValueError()
        passed(stage)
        stage = "apple_sign_in_key_format"
        key = load_pem_private_key(settings.apple_key_path.read_bytes(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
            raise ValueError()
        passed(stage)
        stage = "encryption_key_format"
        Fernet(settings.encryption_key_path.read_bytes().strip())
        passed(stage)
        stage = "lookup_key_length"
        if len(settings.lookup_key_path.read_bytes()) < 32:
            raise ValueError()
        passed(stage)
    except Exception:
        # Fixed check identifiers only. Do not serialize exceptions, paths, config,
        # key IDs or key material, including failures from third-party parsers.
        checks.append({"check": stage, "status": "fail"})
        return {"schema": 1, "service": "peel-accounts-v1", "status": "not_ready",
                "checks": checks, "live_acceptance": "not_run"}
    return {"schema": 1, "service": "peel-accounts-v1", "status": "configuration_valid",
            "checks": checks, "live_acceptance": "not_run"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="Explicit private configuration file; never its contents")
    args = parser.parse_args()
    result = check(args.config)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "configuration_valid" else 2


if __name__ == "__main__":
    raise SystemExit(main())
