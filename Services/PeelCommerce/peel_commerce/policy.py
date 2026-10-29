"""Policy for already signature-verified Apple models, with fresh Apple lookup required."""
from dataclasses import dataclass
from .contract import (APP_APPLE_ID, BUNDLE_ID, LIFETIME, MONTHLY, YEARLY, TRIAL,
                       PRODUCTS, InvalidEvidence, Unavailable)

TRIAL_SECONDS = 3 * 24 * 60 * 60
CLOCK_SKEW_SECONDS = 30
OWNERSHIP = {"PURCHASED": "purchased", "FAMILY_SHARED": "familyShared"}
TYPES = {LIFETIME: "Non-Consumable", TRIAL: "Non-Consumable",
         MONTHLY: "Auto-Renewable Subscription", YEARLY: "Auto-Renewable Subscription"}


def value(v):
    return getattr(v, "value", v)


def integer(v, optional=False):
    if optional and v is None:
        return None
    if type(v) is not int or not 0 < v <= 253402300799000:
        raise InvalidEvidence("invalid_evidence")
    return v


def identifier(v):
    if type(v) is not str or not 1 <= len(v) <= 32 or not v.isascii() or not v.isdigit():
        raise InvalidEvidence("invalid_evidence")
    return v


@dataclass(frozen=True)
class Transaction:
    transaction_id: str
    original_id: str
    product_id: str
    ownership: str
    kind: str
    environment: str
    purchase_ms: int
    original_purchase_ms: int
    signed_ms: int
    expires_ms: int | None
    revoked: bool
    upgraded: bool
    group_id: str | None

    @classmethod
    def from_apple(cls, obj, environment, now):
        product = obj.productId
        kind = value(obj.type)
        ownership = value(obj.inAppOwnershipType)
        if (obj.bundleId != BUNDLE_ID or value(obj.environment) != environment or
                product not in PRODUCTS or kind != TYPES[product] or ownership not in OWNERSHIP or
                type(obj.quantity) is not int or obj.quantity != 1):
            raise InvalidEvidence("invalid_evidence")
        purchase = integer(obj.purchaseDate)
        original = integer(obj.originalPurchaseDate)
        signed = integer(obj.signedDate)
        expires = integer(obj.expiresDate, optional=True)
        revoke = integer(obj.revocationDate, optional=True)
        if (original > purchase or purchase > (now + CLOCK_SKEW_SECONDS) * 1000 or
                signed > (now + CLOCK_SKEW_SECONDS) * 1000 or signed < purchase or
                (expires is not None and expires <= purchase) or
                (revoke is not None and revoke < purchase) or
                (obj.isUpgraded is not None and type(obj.isUpgraded) is not bool)):
            raise InvalidEvidence("invalid_evidence")
        if product in (LIFETIME, TRIAL) and expires is not None:
            raise InvalidEvidence("invalid_evidence")
        if product in (MONTHLY, YEARLY):
            if expires is None or type(obj.subscriptionGroupIdentifier) is not str or not obj.subscriptionGroupIdentifier:
                raise InvalidEvidence("invalid_evidence")
        return cls(identifier(obj.transactionId), identifier(obj.originalTransactionId), product,
                   OWNERSHIP[ownership], kind, environment, purchase, original, signed, expires,
                   revoke is not None or obj.revocationReason is not None or
                   getattr(obj, "revocationType", None) is not None or
                   getattr(obj, "revocationPercentage", None) is not None,
                   obj.isUpgraded is True, obj.subscriptionGroupIdentifier)

    def identity(self):
        # Mutable expiry/revocation/upgrade/signedDate must come from the fresh API.
        return (self.transaction_id, self.original_id, self.product_id, self.ownership,
                self.kind, self.environment, self.purchase_ms, self.original_purchase_ms, self.group_id)


@dataclass(frozen=True)
class Grant:
    product_id: str
    ownership: str
    ends_at: int


class Authority:
    """apple must verify signatures, then perform uncached authenticated Apple API calls."""
    def __init__(self, apple, environment="Production", clock=None):
        import time
        self.apple = apple
        self.environment = environment
        self.clock = clock or time.time

    def verify(self, request):
        now = int(self.clock())
        proofs = [Transaction.from_apple(self.apple.decode_proof(token), self.environment, now)
                  for token in request.tokens]
        if len({p.transaction_id for p in proofs}) != len(proofs):
            raise InvalidEvidence("invalid_evidence")
        grants = []
        reasons = []
        for proof in proofs:
            # A valid old JWS cannot tell us whether Apple later refunded it.
            fresh_model = self.apple.current_transaction(proof.transaction_id)
            fresh = Transaction.from_apple(fresh_model, self.environment, int(self.clock()))
            if fresh.identity() != proof.identity() or fresh.signed_ms < proof.signed_ms:
                raise InvalidEvidence("invalid_evidence")
            if fresh.revoked:
                reasons.append("revoked")
                continue
            if fresh.upgraded:
                reasons.append("no_entitlement")
                continue
            now = int(self.clock())
            if fresh.product_id == LIFETIME:
                end = now + 300
            elif fresh.product_id == TRIAL:
                end = fresh.original_purchase_ms // 1000 + TRIAL_SECONDS
            else:
                end, reason = self.subscription_end(fresh)
                if reason is not None:
                    reasons.append(reason)
                    continue
            if end <= now:
                reasons.append("expired")
                continue
            grants.append(Grant(fresh.product_id, fresh.ownership, end))
        # verifiedAt is after all cryptographic/network operations, never before.
        now = int(self.clock())
        grants = [g for g in grants if g.ends_at > now]
        if grants:
            grant = max(grants, key=lambda g: (g.ends_at, g.product_id == LIFETIME))
            return request.response(now, grant=grant)
        reason = next((r for r in ("revoked", "expired", "no_entitlement") if r in reasons), "no_entitlement")
        return request.response(now, reason=reason)

    def subscription_end(self, fresh):
        response = self.apple.subscription_status(fresh.transaction_id)
        # StatusResponse.appAppleId is not a JWSTransaction payload field.
        if (response.bundleId != BUNDLE_ID or value(response.environment) != self.environment or
                type(response.appAppleId) is not int or response.appAppleId != APP_APPLE_ID or
                type(response.data) is not list or len(response.data) > 16):
            raise InvalidEvidence("invalid_evidence")
        match = None
        count = 0
        for group in response.data:
            if type(group.lastTransactions) is not list:
                raise InvalidEvidence("invalid_evidence")
            for item in group.lastTransactions:
                count += 1
                if count > 32:
                    raise Unavailable("unavailable")
                transaction = Transaction.from_apple(self.apple.decode_current(item.signedTransactionInfo),
                                                     self.environment, int(self.clock()))
                renewal = self.apple.decode_renewal(item.signedRenewalInfo)
                signed = integer(renewal.signedDate)
                grace = integer(renewal.gracePeriodExpiresDate, optional=True)
                if (value(renewal.environment) != self.environment or
                        identifier(renewal.originalTransactionId) != transaction.original_id or
                        renewal.productId != transaction.product_id or
                        group.subscriptionGroupIdentifier != transaction.group_id or
                        item.originalTransactionId != transaction.original_id or
                        transaction.product_id not in (MONTHLY, YEARLY) or
                        (renewal.autoRenewProductId is not None and renewal.autoRenewProductId not in (MONTHLY, YEARLY)) or
                        signed > (int(self.clock()) + CLOCK_SKEW_SECONDS) * 1000 or signed < transaction.purchase_ms or
                        (renewal.isInBillingRetryPeriod is not None and type(renewal.isInBillingRetryPeriod) is not bool) or
                        (grace is not None and grace <= transaction.expires_ms)):
                    raise InvalidEvidence("invalid_evidence")
                status = value(item.status)
                if type(status) is not int or status not in (1, 2, 3, 4, 5):
                    raise InvalidEvidence("invalid_evidence")
                if transaction.transaction_id == fresh.transaction_id:
                    if match is not None or transaction.identity() != fresh.identity() or transaction.signed_ms < fresh.signed_ms:
                        raise InvalidEvidence("invalid_evidence")
                    if transaction.revoked or status == 5:
                        match = (0, "revoked")
                    elif transaction.upgraded:
                        match = (0, "no_entitlement")
                    elif status == 1:
                        match = (min(transaction.expires_ms, fresh.expires_ms) // 1000, None)
                    elif status == 4 and grace is not None:
                        match = (grace // 1000, None)
                    else:
                        match = (0, "expired")
        return match if match is not None else (0, "no_entitlement")
