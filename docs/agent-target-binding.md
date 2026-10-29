# Binding agent requests to a paired device

The existing TLS listener registers all known pairing keys. `clientHello.pairingID`
is then checked against pairing metadata in `noteConnectedClient`; it is not proof
that this specific key authenticated the current socket. The Security SDK header
for `sec_protocol_metadata_access_pre_shared_keys` explicitly describes locally
supported PSKs, not the negotiated peer identity. Do not use that API as peer proof.

Before enabling target-specific presentation, add a capability-gated application
challenge for the agent extension. Keep existing TLS cipher, PSK derivation and
pairing storage unchanged. This adds authorization for new agent actions only.

1. After a compatible client hello, retain its opt-in capability and an immutable
   control connection/generation snapshot. Clear authorization on every replacement,
   disconnect, opt-out and revoked pairing.
2. Host sends one random 32-byte challenge with UUID, claimed pairing ID and expiry,
   tied to that exact socket generation. Limit lifetime to 60 seconds and bound
   pending state to the single active control session.
3. The client requires current connection identity, its own active pairing ID,
   fresh challenge and local opt-in. It computes a domain-separated HMAC-SHA256
   over an unambiguous encoding of challenge UUID, nonce, pairing ID and expiry
   using that pairing's existing PSK. It replies over the same control socket.
4. Host verifies with the claimed pairing's PSK and constant-time HMAC verification,
   consumes the challenge once and records the authorized immutable generation.
   Tests must inject synthetic keys; never probe real Keychain entries for tests.
5. Native local bridge requests specify targetPairingId. Reject unless the Host
   bridge preference, current pairing, proved generation, client opt-in/visibility,
   unlocked Host and authoritative window-instance checks all hold. Capture and
   revalidate the target under sendStateLock; enqueue through outboundSendQueue.
   Never re-resolve an old request to whatever client connected later.
6. Incoming hello, proof and presentation-result dispatches need the originating
   connection/generation carried across queue hops. The current generic Host receive
   dispatch lacks this guard; add it at the new action boundary without changing
   remote input timing or video backpressure semantics.
7. The MCP result must describe actual client acknowledgment. A socket write is
   only delivery progress. Correlate request UUID plus target generation, bound
   pending acknowledgments, expire them and ignore late/reconnected replies.

The challenge and generation-bound send primitive are implemented. The native bridge
now exposes six MCP tools: `peel_list_devices`, `peel_list_windows`,
`peel_list_apps`, `peel_launch_app`, `peel_present_window` and `peel_notify`.
`listApps` and `launchApp` use bounded opaque IDs from the latest app inventory for
that exact paired connection; launching starts the listed app, after which windows
must be refreshed before presentation. `presentWindow` revalidates the advertised
window or desktop target and succeeds only after the matching visible client scene
acknowledges activation. `notify` requires a connected, foreground-visible,
opted-in client with the notification capability; its acknowledgment confirms local
delivery acceptance, not that the person read it, and there is no push/background
delivery path. The native bridge remains off by default.

Older clients continue existing streaming; this extension adds no general desktop
control or arbitrary process interaction. New actions remain behind the additive
paired-device proof bound to the current control connection/generation, pairing,
visibility, local opt-in and Host target checks. Authorization is cleared on
replacement, disconnect, lock, visibility loss, opt-out and revoked pairing.
Physical-device presentation and reconnect/opt-out behavior remain acceptance gates
for this preview.
