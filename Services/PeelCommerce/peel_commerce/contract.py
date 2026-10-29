"""Strict native API contract; no decoded JWS is trusted here."""
import base64
import json
import re
import uuid
from dataclasses import dataclass

BUNDLE_ID = "com.zephyrstudiosllc.Peel"
APP_APPLE_ID = 6755941658
LIFETIME = "peel.pro.lifetime"
MONTHLY = "peel.pro.monthly"
YEARLY = "peel.pro.yearly"
TRIAL = "peel.pro.3day.freetrial"
PRODUCTS = frozenset((LIFETIME, MONTHLY, YEARLY, TRIAL))
MAX_BODY = 140000
MAX_TOKEN = 32768
MAX_TOKENS = 4
MAX_LEASE = 300
REQUEST_FIELDS = frozenset(("schema", "requestId", "nonce", "pairingId", "sessionId", "signedTransactions"))
JWS_PATTERN = re.compile(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\Z", re.ASCII)
PAIRING_PATTERN = re.compile(r"[A-Za-z0-9_.:\-]{1,128}\Z", re.ASCII)


class InvalidRequest(ValueError):
    pass


class InvalidEvidence(ValueError):
    pass


class Unavailable(RuntimeError):
    pass


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise InvalidRequest("invalid_request")
        obj[key] = value
    return obj


def strict_json(data):
    try:
        return json.loads(data, object_pairs_hook=unique_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(InvalidRequest("invalid_request")))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise InvalidRequest("invalid_request") from exc


def valid_uuid(value):
    if type(value) is not str or len(value) != 36:
        return False
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False


def bounded_jws(value):
    return type(value) is str and 5 <= len(value) <= MAX_TOKEN and JWS_PATTERN.fullmatch(value) is not None


@dataclass(frozen=True)
class Request:
    request_id: str
    nonce: str
    pairing_id: str
    session_id: str
    tokens: tuple

    @classmethod
    def parse(cls, data):
        if type(data) is not bytes or not 1 <= len(data) <= MAX_BODY:
            raise InvalidRequest("invalid_request")
        obj = strict_json(data)
        if type(obj) is not dict or set(obj) != REQUEST_FIELDS or type(obj["schema"]) is not int or obj["schema"] != 1:
            raise InvalidRequest("invalid_request")
        if not all(valid_uuid(obj[k]) for k in ("requestId", "sessionId")):
            raise InvalidRequest("invalid_request")
        if type(obj["pairingId"]) is not str or PAIRING_PATTERN.fullmatch(obj["pairingId"]) is None:
            raise InvalidRequest("invalid_request")
        nonce = obj["nonce"]
        if type(nonce) is not str or len(nonce) != 44:
            raise InvalidRequest("invalid_request")
        try:
            raw = base64.b64decode(nonce, validate=True)
        except ValueError as exc:
            raise InvalidRequest("invalid_request") from exc
        if len(raw) != 32 or base64.b64encode(raw).decode("ascii") != nonce:
            raise InvalidRequest("invalid_request")
        tokens = obj["signedTransactions"]
        if type(tokens) is not list or len(tokens) > MAX_TOKENS or not all(bounded_jws(t) for t in tokens):
            raise InvalidRequest("invalid_request")
        if len(set(tokens)) != len(tokens):
            raise InvalidRequest("invalid_request")
        return cls(obj["requestId"], nonce, obj["pairingId"], obj["sessionId"], tuple(tokens))

    def wire(self):
        return {"schema": 1, "requestId": self.request_id, "nonce": self.nonce,
                "pairingId": self.pairing_id, "sessionId": self.session_id,
                "signedTransactions": list(self.tokens)}

    def response(self, now, reason="no_entitlement", grant=None):
        obj = {"schema": 1, "requestId": self.request_id, "nonce": self.nonce,
               "pairingId": self.pairing_id, "sessionId": self.session_id,
               "decision": "denied", "reason": reason, "verifiedAt": now, "expiresAt": now}
        if grant is not None:
            obj.update(decision="granted", reason="active", productId=grant.product_id,
                       ownership=grant.ownership, expiresAt=min(now + MAX_LEASE, grant.ends_at))
        return obj
