# Peel commerce authority

This source supplies `POST /v1/entitlements/verify` for the Host's direct call to one fixed operator HTTPS origin. It verifies Apple signatures and obtains current transaction and subscription status from Apple's App Store Server API. It does not depend on Peel Accounts, Sign in with Apple, a cloud entitlement ledger, or a new operator signing key.

**It is disabled by default.** Missing configuration, dependency, IAP key, Apple availability, certificate checks, or malformed evidence cannot produce a grant. This source has not been deployed, and no production Apple call or real purchase acceptance is claimed by the offline tests.

## Operator inputs and hosting

Use Python 3.11 or newer in a dedicated environment with the reviewed dependencies in `requirements.txt` (an exact resolved dependency set and download hashes are recorded in the accompanying source review). Install the service as its own WSGI application using `passenger_wsgi.py` or `peel_commerce.app:application`.

Set `PEEL_COMMERCE_CONFIG` to an **absolute** path to a private JSON configuration based on `config.example.json`. All seven fields are required; unknown fields and duplicate JSON keys fail closed. The example has `enabled: false` deliberately. Actual required values are:

| Input | Meaning |
| --- | --- |
| `enabled` | Operator must explicitly set `true`. |
| `publicOrigin` | Exact lower-case `https://hostname` origin, optional explicit port 443 only, no path/query/credentials. The native Host must use this same fixed origin. |
| `environment` | `Production` normally. No request can change this. |
| `privateSandbox` | `false` for Production. Sandbox requires both `environment: "Sandbox"` and `privateSandbox: true` in a separate private acceptance deployment. Xcode/local testing environments are rejected. |
| `keyId` | Existing App Store Connect **In-App Purchase API key** identifier, ten characters. |
| `issuerId` | Issuer UUID associated with that IAP API key. |
| `privateKeyPath` | Absolute path to that existing IAP API key's `.p8` file, readable by the service, regular file, no symlink, private mode 0600 or stricter, at most 8192 bytes. |

The key/issuer/private key are independent of Sign in with Apple configuration. The Host and client receive none of them. No new operator JWT key is required: Apple's library uses the existing IAP key to authorize calls to Apple. No credential file was read when implementing or testing this source; adapter tests inject non-secret placeholders.

The application fixes the bundle ID to `com.zephyrstudiosllc.Peel` and the primary App Store app ID to **6755941658**. Requests cannot provide alternate app IDs, environments, Apple API URLs, trust roots or verifiers. Apple API origins are selected by the pinned official library and independently restricted by the adapter. Apple public root certificates are bundled from the [official Apple PKI page](https://www.apple.com/certificateauthority/) and hash checked against `SOURCE-PROVENANCE.json`.

Run behind a maintained TLS reverse proxy/WSGI server, with one service instance limited to two simultaneous verification children. Configure the trusted WSGI adapter to set `wsgi.url_scheme=https` and preserve the exact Host header. Forwarded headers supplied by a caller are ignored; the reverse proxy must sanitize or replace them. Do not expose the WSGI listener directly. Limit request bodies to 140000 bytes, require a content length, disable compressed/chunked bodies, apply a request header/body read deadline (recommended 5 seconds), disable request/response body logging and caching, and set a worker request deadline slightly above the application's 12-second Apple-worker deadline. These ingress read deadlines are a proxy/server responsibility because a WSGI input stream has no portable socket deadline API. Apply an aggregate instance-wide pressure limit if using multiple WSGI processes or replicas. The in-process guard allows at most 60 requests/minute total and 12 per `REMOTE_ADDR`/minute; it retains at most 2048 source entries per minute and does not trust `X-Forwarded-For`.

The native endpoint provides no CORS, cookies, browser login, redirects, transaction storage, entitlement cache, or retry queue. It rejects browser Origin headers. The authority writes no request bodies, JWS, transaction IDs, bindings, key material, or exception details to logs or files. Reverse proxy/runtime tooling must preserve that property. No background notification ingestion is required for a 300-second lease; each grant independently contacts Apple.

## Verification and freshness

1. Parse the exact schema-1 request and bounded JWS strings. Require UUID request/session IDs, an opaque 1–128-character ASCII pairing ID using letters/digits/`_.:-`, a canonical 32-byte standard Base64 nonce, at most four tokens, 32768 bytes per token, and at most 140000 bytes per body. Reject duplicate or unknown request keys, JSON coercions, duplicate tokens and duplicate transaction identities.
2. Authenticate each submitted proof using the official `SignedDataVerifier` and Apple's pinned roots. Historical proof verification uses the JWS `signedDate` as its certificate validation time (`enable_online_checks=False`) **solely for authenticated lookup evidence**. This permits a valid old lifetime JWS whose historical leaf certificate has since expired. It never grants access.
3. For every candidate, call `AppStoreServerAPIClient.get_transaction_info(transactionId)` on the configured environment. Verify the returned signed transaction with the official `SignedDataVerifier(enable_online_checks=True)`, including current certificate and OCSP checks. Match transaction ID, original transaction ID, bundle, environment, SKU, product type, ownership, purchase dates and subscription group to the submitted proof. A stale device snapshot cannot override current revocation, upgrade or expiry. No cached or offline-only path grants.
4. For subscriptions, also call `get_all_subscription_statuses(transactionId)`. Validate fixed bundle/environment/app ID and verify the signed transaction and renewal objects. Require the current status item to match the exact proof transaction and subscription group. Active grants end at the shorter verified transaction expiry. Grace is allowed only for status 4 with matching verified renewal data and its genuine grace expiry; billing retry alone does not grant. A renewed transaction with a new ID requires fresh proof from the client.
5. Emit one bound response after all verification. `verifiedAt` and `expiresAt` are UTC epoch seconds. A grant expires within 300 seconds and no later than its genuine expiry/grace/trial boundary. A denial has `expiresAt == verifiedAt` and no product or ownership fields. The Host must independently enforce the contract's monotonic expiry and session fencing.

The official library uses current wall time when online checks are enabled; this historical/current separation follows its actual [3.1.2 verifier implementation](https://github.com/apple/app-store-server-library-python/blob/v3.1.2/appstoreserverlibrary/signed_data_verifier.py). Freshness comes from a new authenticated TLS Apple API request for every candidate and verified returned data, not an assumption that a device JWS's signing time is recent. All Apple verification runs in a short-lived isolated child process, killed at a 12-second total deadline. Apple API transport has a 2-second connect/4-second read timeout, rejects redirects, disables environment proxy/cookie persistence, and bounds response bodies to 1 MiB. No timeout or outage creates or extends a grant.

The pinned official library also makes direct OCSP HTTP POSTs. Inside the verification child, `ocsp_transport.py` replaces **only** that module's `requests` reference with a narrow bounded POST transport; it leaves the `requests` package and all official certificate/OID/OCSP response/signature/freshness code unchanged. Installation fails closed unless both installed library version 3.1.2 and the exact reviewed verifier source SHA-256 match. Each OCSP POST requires the exact OCSP content-type header and at most 4096 DER bytes, disables environment proxies and cross-request cookie state, uses 2-second connect/4-second read bounds, refuses redirects, requests identity encoding, rejects compressed responses before reading, and streams at most 65536 response bytes. The 12-second parent deadline remains an additional total bound.

OCSP egress accepts only `http://ocsp.apple.com` or `https://ocsp.apple.com` with their default ports and a bounded ASCII `/ocspNN-*` path. Credentials, query/fragment, alternate ports, encoded paths, suffix-matching hosts and alternate destinations are rejected before egress. HTTP is required by Apple's public WWDR G6 certificate AIA, `http://ocsp.apple.com/ocsp03-applerootcag3`; Apple's unchanged OCSP signature checks authenticate the returned data. `references/AppleWWDRCAG6.cer` and `references/OCSP-AIA-EVIDENCE.json` preserve this public-primary certificate evidence and hash. That intermediate is an evidence reference, never an additional trust root. A future Apple OCSP origin/path change requires explicit source review rather than permissive fallback.

## Product policy and limitations

All valid existing `peel.pro.lifetime` non-consumables are eligible, regardless of purchase date or price. `peel.pro.monthly` and `peel.pro.yearly` auto-renewable subscriptions provide the same Pro entitlement. The intended 4.99 monthly / 29.99 yearly / 119.99 lifetime pricing is a storefront policy, not signed validity evidence. Both signed `PURCHASED` and `FAMILY_SHARED` ownership are accepted, reported as `purchased` or `familyShared`; no family toggle or claim is trusted. Existing `peel.pro.3day.freetrial` non-consumables remain eligible until exactly three days after the original purchase, with no reset from restoration/reinstallation. Refund/revocation or upgrade denies that candidate.

The service verifies purchase evidence; it does **not** attest that the calling Host or peer owns a physical device, Apple account or transaction. A copied genuine current JWS may be replayed for another attacker-selected binding, subject to fresh Apple checks. Exact echoed bindings protect the Host's local asynchronous session/operation fencing; they are not device attestation or proof of Apple-account possession. App Attest or another independently reviewed device/account-bound issuance scheme would be separate future scope. No stronger anti-sharing claim should be made for this implementation.

Success and denial use HTTP 200 and the exact shared contract. Grant reason is `active`; denial reasons are `no_entitlement`, `invalid_evidence`, `revoked`, `expired`, or `unsupported_environment` (the last is reserved; incompatible signed evidence currently maps to generic invalid evidence). Configuration/Apple/verification infrastructure failure returns HTTP 503 `{"error":"unavailable"}`. Malformed request returns 400; unsupported method 405; oversized body 413; unsupported body format 415; pressure 429. Every response uses `Cache-Control: no-store`. There is no grant on an HTTP error.

## Offline checks

From this directory, with the pinned dependencies installed:

```sh
python -m unittest discover -s tests -v
```

The policy uses injected fixtures only in test source; the deployment factory can never select those adapters. Adapter tests use the real Apple model classes and actual official verifier to reject fabricated JWS, and mock outbound transport/API calls. Tests do not create real production grants, read credentials, call Apple, or prove live sandbox acceptance. Real sandbox purchase/refund/family/grace acceptance remains a separate operator-configured test before activation.

`references/apple-library-3.1.2/` contains read-only official source snapshots for exact model/API review. The Apple source's MIT license is preserved in `LICENSE.txt`; public certificates are Apple PKI material and are not relicensed as MIT. `SOURCE-PROVENANCE.json` records original HTTPS source URLs, version, byte counts and SHA-256 hashes.
