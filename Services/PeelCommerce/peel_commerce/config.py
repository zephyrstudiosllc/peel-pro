"""Operator-only configuration. Requests cannot select Apple environments or roots."""
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit
from .contract import InvalidRequest, Unavailable, strict_json, valid_uuid

SERVICE_ROOT = Path(__file__).resolve().parent.parent
CONFIG_FIELDS = frozenset(("enabled", "publicOrigin", "environment", "privateSandbox",
                           "keyId", "issuerId", "privateKeyPath"))


@dataclass(frozen=True)
class Config:
    public_origin: str
    environment: str
    key_id: str
    issuer_id: str
    private_key_path: str

    @classmethod
    def load(cls, path):
        if not path or not Path(path).is_absolute():
            raise Unavailable("unconfigured")
        try:
            with open(path, "rb") as stream:
                data = stream.read(16385)
            if len(data) > 16384:
                raise Unavailable("unconfigured")
            obj = strict_json(data)
            if type(obj) is not dict or set(obj) != CONFIG_FIELDS or obj["enabled"] is not True:
                raise Unavailable("unconfigured")
            origin = obj["publicOrigin"]
            if type(origin) is not str or len(origin) > 255:
                raise Unavailable("unconfigured")
            parsed = urlsplit(origin)
            if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or
                    parsed.path or parsed.query or parsed.fragment or parsed.port not in (None, 443) or
                    origin != "https://" + parsed.netloc or parsed.netloc != parsed.netloc.lower()):
                raise Unavailable("unconfigured")
            environment = obj["environment"]
            if (environment not in ("Production", "Sandbox") or type(obj["privateSandbox"]) is not bool or
                    (environment == "Sandbox") != obj["privateSandbox"]):
                raise Unavailable("unconfigured")
            key = obj["keyId"]
            if type(key) is not str or len(key) != 10 or not key.isascii() or not key.isalnum():
                raise Unavailable("unconfigured")
            if not valid_uuid(obj["issuerId"]):
                raise Unavailable("unconfigured")
            secret = obj["privateKeyPath"]
            if type(secret) is not str or not Path(secret).is_absolute():
                raise Unavailable("unconfigured")
            return cls(origin, environment, key, obj["issuerId"], secret)
        except (OSError, ValueError, TypeError, InvalidRequest) as exc:
            raise Unavailable("unconfigured") from exc
