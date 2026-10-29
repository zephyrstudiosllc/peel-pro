# Paired SidePulse signals in Peel Host

Peel Host owns pairing and credentials. SidePulse retains its observations,
lighting programs, routing, source selectors and hardware output. The parent
`PeelTrustedSidePulseService` connects these through `SidePulseSignalServicing`.
The standalone SidePulse application keeps its original transport.

## User flow

1. Open Host, expand **Paired Macs & SidePulse Sharing**, select the other Mac,
   and enter the six-digit PIN displayed by that Mac's Peel Host.
2. In **Devices & Macs**, enable sharing on the publisher and nearby discovery
   on the receiver. Select the paired Mac as a Pro/Dot source or follow all Macs.
3. Existing calibration, output power and stale-source fallback apply. Forget
   a device from Host to revoke its key and active signal connections.

Sharing is opt-in. The one-time SidePulse preference migration preserves visual
and hardware settings but does not migrate network sharing consent, follow
targets, node identity or credentials. Existing Host preferences take priority.

## Transport boundary

Bonjour `_peel-signal._tcp` locates reachable candidates. A service name or TXT
host UUID is not authority: the candidate must match a saved Peel host identity
and complete TLS-PSK plus a fresh bilateral HMAC challenge. Both roles, host/node
identities, pairing UUID and independent nonces are bound into that proof.
The endpoint uses standard Peel PSK ordering without a legacy-order retry.

Authenticated frames carry the existing bounded SidePulse signal JSON and LED
program. The service verifies publisher identity and the existing program
validator before routing. It does not accept desktop input, shell commands,
files, arbitrary app launches or credentials; the only action is the
negotiated request to open one of the owner's own current sessions (below). Frames map to the paired Mac identity for
the existing source selector. Trust replacement invalidates pending proofs and
sockets, and admission checks current pairing membership again.

The implementation bounds sockets, input buffers, frame/program sizes, handshake
time, sends and frame rate. It retries failed connections with a delay and lets
the existing SidePulse stale-source logic restore local output. No unpaired
legacy broadcast is admitted into unified Host.

## Paired-Mac agent sessions

The same authenticated socket can also carry negotiated agent metadata,
owner-side session opening and a bounded usage summary. A featured hello and
an explicit featured challenge select v2 proofs that bind both feature lists;
otherwise the socket stays v1 and LED-only. These features have their own
switches (Agent Hub › Paired Macs), default on for existing pairings, and do
not change LED sharing, follow targets or hardware output. Activation accepts
only an opaque owner-minted token; it never accepts a URL, path, command or
process identity. See [paired-Mac agent state](peer-agent-state.md).

## Desktop and status remain separate

Peel's existing control/video/audio sessions carry desktop input, agent
presentation, notifications and Mac Status. Those retain their own capabilities,
fresh proofs, active-session checks and consent. Apple clients can save an
address for a previously paired Mac reachable through a private network or VPN.
The SidePulse endpoint currently discovers Macs through Bonjour; neither path
provides a managed internet relay or initial pairing over the internet.

Host and Apple builds and the focused handshake/message fixtures pass. An inert
native preview confirms the merged controls. Two physical Macs, actual hardware
output, reconnection and revocation during a live session remain device
acceptance work.
