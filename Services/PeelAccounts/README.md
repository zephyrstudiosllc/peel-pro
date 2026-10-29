# Peel optional company account backend — local source candidate

This is a tested, unpublished backend candidate for optional native Sign in with Apple and consented company email storage. It is separate from the static Zephyr/Peel Pro websites and from private CloudKit device/agent metadata. It has no pairing, streaming, remote control, payment, or marketing delivery endpoint. Authentication and cloud records never establish device trust.

**Release status: not accepted for production.** Disabled native source wiring now lives in `Sources/PeelApple/Shared/Account/PeelCompanyAccount*.swift`, mirrored in `Integration/Account`. It has no configured origin or enabled feature flag, and the installed apps do not call this backend or send company email. No account service, database, credentials or account-hosting configuration was created. The separate company marketing website has been published; it does not deploy this service. The example configuration is disabled and deliberately invalid; incomplete configuration returns503.

## Implementation

- Flask WSGI with maintained PyJWT and cryptography. Apple ID tokens accept RS256 only, fixed Apple JWKS URL, issuer and the existing native audience `com.zephyrstudiosllc.Peel`; signature, strict scalar audience, integer times, recent issuance, subject, nonce and optional authorization-code hash are checked. Public keys rotate through a bounded one-hour cache; unknown-key refresh is limited to once per minute. A failed refresh never falls back to expired keys.
- Five-minute server challenges are consumed atomically once after identity verification and before OAuth exchange. Parallel replay produces one exchange. The returned Apple ID token must match subject and nonce. The server obtains its own refresh credential using an actual Sign in with Apple P-256 private key, generating a five-minute ES256 client secret. The client never receives this private key or refresh credential.
- Accounts use a random public ID and keyed subject lookup, encrypted optional email and refresh credentials, and SHA-256-hashed random bearer sessions. Sessions last 30 days, with server verification of Apple authorization once per successful day. Different devices can hold separate sessions (32 active company sessions maximum). An encrypted ledger retains every distinct known Apple refresh grant (128 maximum); no older grant is silently evicted. Code-exchange capacity is reserved atomically before network work, and every ledger grant is queued for explicit revocation at deletion. A user-grant rejection removes the company profile and sessions; service-key errors fail closed without deleting valid accounts. Stale refresh completions cannot undo deletion or erase a newer sign-in.
- Saving verified Apple email and receiving marketing have separate consent fields. Both default off. Native Apple Share/Hide My Email does not set marketing consent. Only signed Apple email claims are eligible for storage. Withdrawing email consent clears the saved email and marketing consent. No mailing platform or sender exists here.
- Deletion accepts a company session issued within five minutes or a fresh nonce-bound native Apple proof, including when an expired bearer or full grant ledger prevents normal sign-in. Local profile and all sessions disappear atomically while all known encrypted Apple refresh grants enter a durable revocation queue. In-flight exchange/refresh operations are tracked durably by keyed subject association; deletion stays pending until these finish/reconcile, even after a timeout or profile removal. Apple success returns 200; outage returns explicit 202 with revocation pending. Retry maintenance emits counts only. A short deletion fence prevents an in-flight old sign-in from resurrecting the profile.
- A signed Apple server notification endpoint handles account deletion, consent revocation, and forwarding disabled. It verifies Apple signature/issuer/audience/issuance and event shape, deduplicates JWT IDs for seven days, and ignores old deletion events against a newly created account. Re-enabling forwarding never restores email or marketing consent automatically. Actual portal registration and delivery remain untested.
- HTTPS and the configured host are mandatory. No browser cookie, CORS, query-string credentials, caller-selected key URL, debug logging, or token-containing error body is enabled. JSON size/fields/duplicates, per-IP request rates, active challenges, and notification deduplication storage are bounded. Edge abuse protection and operational monitoring still require hosting acceptance.

## Local verification

Run from this folder in an isolated environment:

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock -r requirements-test.txt
.venv/bin/python -m pytest -q -W error --junitxml=evidence/tests.xml
.venv/bin/python -m pip check
```

Tests use synthetic local RSA/P-256 keys and fake Apple exchanges. An autouse fixture denies real socket connections. They exercise the production app, SQLite transactions, Fernet encryption, JWT libraries and HTTP transport contract. They are not Apple account, HTTPS-hosting, real-device, private-relay delivery or App Review acceptance.

`requirements.lock` pins the complete production set. `requirements.txt` declares direct dependencies; `requirements-test.txt` adds pytest. The receipt records installed versions and source hashes. Deploying to a different Python/Linux environment requires its own clean install, import, dependency and service smoke checks.

Before starting WSGI, the operator may run the read-only configuration check:

```sh
python -m peel_accounts.preflight --config /absolute/private/config.json
```

It never starts Flask, creates/opens the account database, contacts Apple/DNS, or
prints paths, key IDs, key material or parser exception text. It requires an explicit
configuration path and ignores ambient `PEEL_ACCOUNT_CONFIG`. A fixed JSON result
and exit2 identify the failed check; exit0 means only `configuration_valid`, with
`live_acceptance: not_run`. It checks private file ownership/modes, bounded unique
configuration fields, native-compatible origin syntax and key formats. It does
not establish ownership/TLS, Apple key authorization, schema deployment, payment
proof or runtime database/hosting acceptance. WSGI independently validates the
same file parser. Every unconfigured HTTP503 retains no-store/security headers.

Read [HOSTING.md](HOSTING.md) for concrete deployment prerequisites, [NATIVE-CONTRACT.md](NATIVE-CONTRACT.md) for the disabled native integration and remaining real acceptance, and [references/SOURCES.md](references/SOURCES.md) for current primary references. Native wiring does not enable a service or close the final signed-device release gates.
