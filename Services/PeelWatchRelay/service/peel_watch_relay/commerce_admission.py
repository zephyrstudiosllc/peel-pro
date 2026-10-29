"""Direct Apple-authority evidence -> short, nonportable relay paid permits.

All mutable admission state is guarded by relay.lock. Lock order is relay ->
control; verification I/O occurs outside both. Identity and cleanup are separate.
No client verdict, provider credential or raw purchase evidence is persisted.
"""
from __future__ import annotations
import base64
from dataclasses import dataclass
import math
import secrets
import time
from urllib.parse import urlsplit
from uuid import uuid4

from .broker import RelayError, encode
from .http import strict_json
from .rpc import fields
from .webhooks import PublicHTTPSWebhookTransport, WebhookError, _callback_url

PRODUCTS = frozenset(("peel.pro.lifetime", "peel.pro.monthly", "peel.pro.yearly", "peel.pro.3day.freetrial"))
DENIALS = frozenset(("no_entitlement", "invalid_evidence", "revoked", "expired", "unsupported_environment"))


class DirectCommerceVerifier:
    """Only operator-selected fixed HTTPS origin; trusted injection is test-only.

    Reuses reviewed public-address-pinned TLS/total-deadline/no-proxy/no-redirect
    transport, maximum response4096. A transport or HTTP failure cannot grant.
    """
    def __init__(self, origin, *, transport=None):
        try:
            parsed = urlsplit(origin)
            if (type(origin) is not str or len(origin) > 255 or parsed.scheme != "https" or
                    not parsed.hostname or parsed.path or parsed.query or parsed.fragment or
                    parsed.username or parsed.password or parsed.port not in (None, 443) or
                    origin != "https://" + parsed.netloc or parsed.netloc != parsed.netloc.lower()):
                raise ValueError
            self.endpoint = origin + "/v1/entitlements/verify"
            _callback_url(self.endpoint)
        except (ValueError, TypeError, WebhookError):
            raise RelayError("commerce_origin_required") from None
        self.transport = transport or PublicHTTPSWebhookTransport()

    def verify(self, request):
        raw = encode(request)
        if len(raw) > 140000:
            raise RelayError("invalid_pro_evidence")
        try:
            status, raw = self.transport.post(self.endpoint, raw, {"Content-Type": "application/json", "Accept": "application/json"})
            if status != 200 or type(raw) is not bytes or len(raw) > 4096:
                raise RelayError("commerce_unavailable")
            return strict_json(raw)
        except (WebhookError, OSError, TimeoutError, ValueError):
            raise RelayError("commerce_unavailable") from None


@dataclass(frozen=True)
class PaidPermit:
    id: str
    binding: bytes
    verified_at: int
    wall_expiry: int
    monotonic_expiry: float
    epoch: int


class CommerceAdmission:
    MAX_PENDING = 256
    MAX_LEASES = 512

    def __init__(self, relay, resolve_context, verifier, *, now=time.time, monotonic=time.monotonic):
        if not callable(resolve_context) or not callable(getattr(verifier, "verify", None)):
            raise RelayError("commerce_adapter_required")
        self.relay, self.resolve_context, self.verifier = relay, resolve_context, verifier
        self.now, self.monotonic = now, monotonic
        self.pending, self.current, self.permits, self.epochs = {}, {}, {}, {}

    def clocks(self):
        wall, mono = self.now(), self.monotonic()
        if any(type(x) not in (int,float) or not math.isfinite(x) or x < 0 for x in (wall,mono)):
            raise RelayError("invalid_commerce_clock")
        return float(wall), float(mono)

    @staticmethod
    def key(binding):
        return encode(binding)

    @staticmethod
    def public(binding):
        return {k:v for k,v in binding.items() if k != "principal"}

    def _context(self, account, device, route=None):
        enrollment = route["commerce_enrollment"] if route is not None else None
        if route is not None and not enrollment:
            raise RelayError("pro_required")  # Pre-integration route cannot invent enrollment binding.
        result = self.resolve_context(account, device, enrollment)
        result.update(routeID=route["id"] if route is not None else None,
                      routeGeneration=route["generation"] if route is not None else None)
        return result

    def _cleanup(self):
        wall, mono = self.clocks()
        self.pending = {k:v for k,v in self.pending.items() if v["wall"] > wall and v["mono"] > mono}
        self.permits = {k:v for k,v in self.permits.items() if v.wall_expiry > wall and v.monotonic_expiry > mono}
        self.current = {k:v for k,v in self.current.items() if v in self.permits}
        active = {v["binding"]["enrollmentID"] for v in self.pending.values()} | {strict_json(v.binding)["enrollmentID"] for v in self.permits.values()}
        self.epochs = {k:v for k,v in self.epochs.items() if k in active}

    def challenge(self, authority, body):
        fields(body, (), ("routeID", "routeGeneration"))
        if bool("routeID" in body) != bool("routeGeneration" in body):
            raise RelayError("invalid_parameters")
        with self.relay.lock:
            self.relay.authorize(authority.account, "watch.connect")
            if authority.device is None:
                raise RelayError("paired_device_authority_required")
            route = None
            if body:
                self.relay.assert_device(authority.account, authority.device, body["routeID"])
                route = self.relay._route(authority.account, body["routeID"])
                if route["generation"] != body["routeGeneration"]:
                    raise RelayError("route_generation_changed")
            binding = self._context(authority.account, authority.device, route)
            self._cleanup()
            key = self.key(binding)
            self.pending = {k:v for k,v in self.pending.items() if self.key(v["binding"]) != key}
            if len(self.pending) >= self.MAX_PENDING:
                raise RelayError("commerce_capacity")
            wall, mono = self.clocks()
            c = {"type":"proEntitlementChallenge", "requestId":str(uuid4()),
                 "nonce":base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
                 "pairingId":binding["enrollmentID"], "sessionId":str(uuid4()), "expiresAt":int(wall)+30}
            self.pending[c["requestId"]] = {"challenge":c, "binding":binding, "wall":c["expiresAt"],
                "mono":mono + min(30,c["expiresAt"]-wall), "epoch":self.epochs.get(binding["enrollmentID"],0)}
            return {"schema":1,"challenge":c,"binding":self.public(binding)}

    def evidence(self, authority, body):
        fields(body, ("type","requestId","nonce","pairingId","sessionId","signedTransactions"))
        if body["type"] != "proEntitlementProof":
            raise RelayError("invalid_pro_evidence")
        tokens = body["signedTransactions"]
        if type(tokens) is not list or len(tokens)>4 or any(type(t) is not str or not 5<=len(t)<=32768 or
                any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_- ." for c in t) or
                t.count(".") != 2 or " " in t or any(not p for p in t.split(".")) for t in tokens) or len(set(tokens)) != len(tokens):
            raise RelayError("invalid_pro_evidence")
        with self.relay.lock:
            self.relay.authorize(authority.account,"watch.connect")
            self._cleanup()
            pending = self.pending.get(body["requestId"]) if type(body["requestId"]) is str else None
            if pending is None or pending.get("consumed"):
                raise RelayError("pro_challenge_unavailable")
            pending["consumed"] = True
            c, binding = pending["challenge"], pending["binding"]
            if any(body[k] != c[k] for k in ("requestId","nonce","pairingId","sessionId")):
                raise RelayError("invalid_pro_evidence")
            self._check_pending(authority,pending)
            request = dict(schema=1, **{k:c[k] for k in ("requestId","nonce","pairingId","sessionId")}, signedTransactions=tokens)
        # Never hold the relay/control effect locks over authority network IO.
        try:
            response = self.verifier.verify(request)
        except Exception:
            raise RelayError("commerce_unavailable") from None
        with self.relay.lock:
            self._check_pending(authority,pending)
            wall, mono = self.clocks()
            self._validate_response(response,request,wall)
            self.pending.pop(c["requestId"],None)
            key = self.key(binding)
            if response["decision"] == "granted":
                self._cleanup()
                if len(self.permits) >= self.MAX_LEASES:
                    raise RelayError("commerce_capacity")
                expiry = min(response["expiresAt"],binding["applicationSessionExpiresAt"])
                duration = min(300,expiry-max(wall,response["verifiedAt"]))
                if duration <= 0:
                    raise RelayError("pro_expired")
                permit = PaidPermit(str(uuid4()), key, response["verifiedAt"], expiry, mono+duration, pending["epoch"])
                self.permits[permit.id] = permit; self.current[key] = permit.id
                lease_id, state = permit.id, "verified"
            else:
                self._withdraw_enrollment(binding["enrollmentID"])
                lease_id, state = None, "denied"
                expiry = response["verifiedAt"]
            return {"schema":1,"requestId":c["requestId"],"sessionId":c["sessionId"],
                "binding":self.public(binding),"state":state,"reason":response["reason"],
                "leaseID":lease_id,"verifiedAt":response["verifiedAt"],"expiresAt":expiry}

    def _check_pending(self, authority, pending):
        wall, mono = self.clocks()
        binding = pending["binding"]
        if wall >= pending["wall"] or mono >= pending["mono"]:
            raise RelayError("pro_challenge_expired")
        if self.pending.get(pending["challenge"]["requestId"]) is not pending or pending["epoch"] != self.epochs.get(binding["enrollmentID"],0):
            raise RelayError("pro_challenge_unavailable")
        route = self.relay._route(authority.account,binding["routeID"]) if binding["routeID"] is not None else None
        if self._context(authority.account,authority.device,route) != binding:
            raise RelayError("pro_context_changed")

    @staticmethod
    def _validate_response(obj,request,now):
        base={"schema","requestId","nonce","pairingId","sessionId","decision","reason","verifiedAt","expiresAt"}
        grant=type(obj) is dict and obj.get("decision")=="granted"
        if type(obj) is not dict or set(obj) != (base|{"productId","ownership"} if grant else base):
            raise RelayError("commerce_unavailable")
        if (type(obj["schema"]) is not int or obj["schema"]!=1 or
                any(obj[k]!=request[k] for k in ("requestId","nonce","pairingId","sessionId")) or
                type(obj["verifiedAt"]) is not int or type(obj["expiresAt"]) is not int or
                not now-30 <= obj["verifiedAt"] <= now+1):
            raise RelayError("commerce_unavailable")
        if grant:
            if (obj["reason"]!="active" or type(obj["productId"]) is not str or obj["productId"] not in PRODUCTS or
                    type(obj["ownership"]) is not str or obj["ownership"] not in ("purchased","familyShared") or
                    not now < obj["expiresAt"] <= obj["verifiedAt"]+300):
                raise RelayError("commerce_unavailable")
        elif obj["decision"]!="denied" or type(obj["reason"]) is not str or obj["reason"] not in DENIALS or obj["expiresAt"]!=obj["verifiedAt"]:
            raise RelayError("commerce_unavailable")

    def _invalidate_binding(self,key):
        self.current.pop(key,None)
        self.permits={k:v for k,v in self.permits.items() if v.binding!=key}

    def _withdraw_enrollment(self,enrollment):
        self.epochs[enrollment]=self.epochs.get(enrollment,0)+1
        self.pending={k:v for k,v in self.pending.items() if v["binding"]["enrollmentID"]!=enrollment}
        keys={v.binding for v in self.permits.values() if strict_json(v.binding)["enrollmentID"]==enrollment}
        for key in keys:self._invalidate_binding(key)

    def withdraw(self,authority,body):
        fields(body)
        with self.relay.lock:
            self.relay.authorize(authority.account,"watch.connect")
            binding=self._context(authority.account,authority.device)
            self._withdraw_enrollment(binding["enrollmentID"])
            return {"withdrawn":True}

    def _require(self,binding,permit_id=None):
        wall,mono=self.clocks(); key=self.key(binding)
        permit=self.permits.get(permit_id or self.current.get(key))
        if permit is None:raise RelayError("pro_required")
        if (permit.binding!=key or permit.epoch!=self.epochs.get(binding["enrollmentID"],0) or
                wall>=permit.wall_expiry or mono>=permit.monotonic_expiry):
            raise RelayError("pro_expired")
        return permit

    def effective_expiry(self,permit):
        wall,mono=self.clocks()
        return min(permit.wall_expiry,int(wall+max(0,permit.monotonic_expiry-mono)))

    def require_connect(self,account,device):
        return self._require(self._context(account,device))

    def bind_route(self,account,device,route,initial):
        binding=self._context(account,device,route)
        old=strict_json(initial.binding)
        if any(old[k]!=binding[k] for k in old if k not in ("routeID","routeGeneration")):
            raise RelayError("pro_context_changed")
        self._require(old,initial.id)
        key=self.key(binding)
        permit=PaidPermit(initial.id,key,initial.verified_at,initial.wall_expiry,initial.monotonic_expiry,initial.epoch)
        self.permits[permit.id]=permit; self.current.pop(initial.binding,None); self.current[key]=permit.id

    def require_route(self,account,route,permit_id=None):
        from .broker import DeviceGrant
        return self._require(self._context(account,DeviceGrant(route["device_id"],route["pairing_generation"]),route),permit_id)


class UnavailableCommerce:
    """Unconfigured factory output; never silently grants free paid calls."""
    def require_connect(self,*args):raise RelayError("commerce_unavailable")
    def require_route(self,*args):raise RelayError("commerce_unavailable")
    def challenge(self,*args):raise RelayError("commerce_unavailable")
    def evidence(self,*args):raise RelayError("commerce_unavailable")
    def withdraw(self,*args):return {"withdrawn":True}
