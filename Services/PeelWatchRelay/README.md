# Peel Watch relay — isolated source foundation

This implements new-message inbox/reply storage and the documented Dot MCP
Events contract. It does not import chat history, invoke a generic model, modify
the installed app or create a live account/plugin/subscription. Candidate source
only; root review and actual Dot reply proof precede product integration.

Proposed integration location is parent `Services/PeelWatchRelay`, beside the
existing optional Python account service. The service does not reuse that
service's Apple identity as ChatGPT/X identity. The current stdio
`Tools/PeelMCP` remains the local native Host adapter and is unchanged. This
foundation is a POSIX backend; it does not add a Python runtime to Windows Peel.

## Implemented

- A bounded durable SQLite inbox, accepted-send receipts, stable event IDs,
  idempotent correlated replies and a reply-arrival cursor. A late reply to an
  earlier request is not lost. Reply pages use exact encoded UTF-8 JSON bytes
  under256KiB; all WSGI responses are capped at256KiB.
- Explicit `pluginRelay` references bound to principal/provider/account generation,
  exact device/pairing generation and new route generation. No relay ID pretends
  to be a native provider conversation ID. Trusted auth/pairing callbacks are
  required; no default/unverified route is enabled.
- MCP2.0 discovery and Dot event list/subscribe/unsubscribe, callback verification,
  durable scoped subscriptions, finite expiry/refresh, bounded success cache,
  overlapping signatures for secret rotation and bounded durable delivery retries.
- `peel_watch_confirm_connection`, `peel_watch_inbox`, `peel_watch_reply` tools.
  Tool arguments cannot widen the authenticated route grant. Incoming message text
  remains data; standing user instructions and existing agent approvals govern work.
- Standard Webhooks signatures over persisted exact bytes. Production HTTPS
  transport validates DNS on each connection, rejects all nonpublic answers,
  pins numeric TCP while checking TLS against the original hostname, refuses
  redirects and bounds both time and response bytes. Injected transports are
  explicitly trusted test/application code, never caller-supplied parameters.
- Grok uses the same conditional inbox/reply tools with `manualReady`,
  `deliveryMode=manual`, `automaticDeliveryReady=false`. Challenge confirmation
  proves its scoped link, not routine installation. `minimumRoutineIntervalSeconds`
  is300 scheduling metadata, not a restriction on reading available replies.
  Personal-Bot plugin availability and automatic wake remain unverified.

The exact native success/error wire and missing credential adapter are in
[HTTP-CONTRACT.md](HTTP-CONTRACT.md). `source-inventory.json` records the inspected
existing product seams and why this service location is isolated.

## Execution boundary

Python3.11+ and its standard library are sufficient for this source. No package
install, inference SDK, callback key, API token, provider credential or database
is bundled. Importing the modules starts no listener or worker. There is no
default server command, origin, public endpoint or installable plugin manifest:
those require a real reviewed deployment/auth configuration rather than a fake URL.

Create `RelayStore` **after worker fork**, with one shared store for that process's
threads. Do not preload/fork a live store or fork while its threads are running.
An exclusive POSIX owner lock rejects another store process/instance; a PID guard
rejects inherited stores. WSGI authentication must independently verify each
principal and pair proof, then produce the scoped `RequestAuthority`. It must
not trust account/device fields in request JSON. The candidate supplies that
mandatory seam, not a real JWT/OIDC/session verifier. Live identity registration,
account/plugin linking and current native pairing composition are still missing.

Run event delivery on a dedicated service worker, not the phone/UI request loop.
One admitted HTTPS attempt (up to10seconds) serializes with revoke. Revoke may wait
for that admitted attempt; after it acknowledges, no new route delivery starts.
Already received events or running remote work cannot be recalled by this service.
A2xx webhook response means event receipt only. Actual replies exist only after
the authorized agent calls the reply tool and storage succeeds.

Storage uses an owned0700 directory,0600 database/lock files, one writer owner and
atomic SQL transitions. Callback signing secrets are durable private service
state, never public receipts; this candidate uses file permissions and does not
claim encrypted-at-rest/vault deployment. Production secret management, backups,
deployment quotas and key rotation policy require review before hosting.

Foundation capacity is explicit:256 lifetime requests per route,64 lifetime routes
per principal,8 subscriptions per route and1024 bounded callback-cache entries.
Answered/revoked records are not silently reclaimed. Capacity exhaustion rejects
new work without forgetting uncertain sends. Retention/reclamation is a remaining
production task, not an invented free/paid product limit.

## Local verification and scope

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=service python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Tests exercise real broker/SQL/RPC/WSGI/signature/transport code with synthetic
authority, callback sockets and clocks. They cover expiry/replay/account switches,
device/generation mismatch, duplicate sends/replies, restart persistence, callback
refresh/revoke races, byte paging, private-address/DNS rebinding, exact signature
bytes and bounded I/O. These are local contract/security tests, not real Dot/Grok
messages, physical Watch acceptance, provider sign-in or native app build results.
One owned fork test proves inherited stores fail closed and do not unlock the
parent; it does not authorize preloading/forking the deployed store.

Native work remains: the approved credential/account verifier and paired-device
adapter, explicit relay-route Watch wire, phone HTTP/session/state integration,
durable iPhone reply inbox and bounded Watch chunk/page handoff under its actual
60KiB limit, one coherent Connect UI and actual provider tests. Current installed
Watch messaging is not changed by these service tests.

The first live acceptance must send one unique Watch request to the actual linked
Dot, observe its signed event/task and correlate its real reply back on Watch.
Then prove sign-out/account switch/revoke/reconnect and ambiguous-send behavior.
No old history is needed. Grok follows only with verified Bot plugin access and
honest manual/routine wake semantics. Root owns these actions while the user is away.

Primary contracts: [OpenAI MCP Events](https://developers.openai.com/plugins/build/mcp-events),
[custom MCP](https://developers.openai.com/api/docs/guides/custom-mcp-server),
[private MCP tunnel and public-distribution boundary](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels),
[Grok Bot Team MCP](https://docs.x.ai/grok-bot/team-bots),
[Grok routines](https://docs.x.ai/grok-bot/skills-routines-and-automations).
