# Focus lifetime regression checks

Run from the integration repository:

```sh
python3 Tools/PeelFocusLifetimeTests/run-checks.py
```

The runner extracts the actual Host focus request, debounce, confirmation, retry,
response, pre-input fallback, and generation-bound network send methods, together
with the received `clientActiveWindow` switch arm and both Apple `windowFocusState`
switch arms. It compiles those production transitions with deterministic scheduling
and socket/AX metadata fixtures. It records hashes of the extracted source and
compiled unit. It opens no sockets, activates no apps, and operates no devices.

Coverage includes replacement before debounce, during AX completion, during a
readiness retry, and before/after the outbound send snapshot; same-generation
request replacement for the same and different windows; display capture superseding
a queued app request; bounded readiness rejection; absence of a received generation;
backwards-compatible unbound network sends; and both client publication/mirroring
paths rejecting obsolete connection success and rejection responses at the main hop.

These tests do not validate macOS AX focus behavior, real permission state,
LaunchServices logging delivery, SwiftUI hit testing, or end-to-end transport. The
AX policy and its internal focus phases are unchanged; an already-started AX
sequence is not cancelled by the Host callback guards. Full Host/Apple builds and
runtime acceptance are separate checks.

Host focus evidence uses `Logger.notice` in subsystem
`com.zephyrstudiosllc.Peel-Host`, category `Host`. Request and terminal-result records
contain numeric window IDs, control generation, a request UUID, and disposition.
Rejected readiness includes locked/asleep, client-visible, Allow Control and AX
trust flags plus target/frontmost numeric PIDs. Receive-level stale-generation,
locked/asleep, and missing-generation rejection is logged before the normal focus
handler. No window titles, app names, user text, or image contents are logged.
