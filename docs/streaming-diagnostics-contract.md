# Receiver diagnostics contract

Status: receiver lifecycle, encoder recovery and ordered-input fixes are integrated
through Host `afbfe12`. Renderer ownership/current-screen fixes are integrated
through Apple `bd962b8`; combined Host/iPad/visionOS builds pass. The streaming owner installed Host `afbfe12` recoverably and verified
launch/setup; root independently verified the installed executable/signature.
Receiver telemetry is not yet validated on a physical receiving device. See the
release ledger for exact source, artifacts and separate runtime receipts.
This extends Host encoder/local-send diagnostics without changing binary packets.

## Negotiation and transport

- Optional capability `stream-diagnostics-v1` on both peers. Older peers continue
  normally and their receiver metrics remain null.
- New `clientStreamMetrics` control message, sent only after the paired control
  session is ready, both peers advertise support, and the client is visible.
- Bounded cadence: the existing four-second ping triggers snapshots, with a
  one-second minimum interval, at most 32 stream rows and a 64 KiB payload cap.
  Stop/reset with the control connection. No additional
  remote input, capture permission, or arbitrary query surface.
- Host binds reports to the authenticated control connection generation,
  rejects old sequence numbers, validates all finite/range/count limits, and
  clears state on disconnect. Backgrounding clears cached observations while
  retaining replay/cadence protection. Expose report age at Host receipt separately from
  the client's monotonic timestamps. Client reports are peer observations,
  never a substitute for independently observed display acceptance.

## Per-stream fields

Use a renderer-generation UUID that changes with configuration/flush/recreation,
and a monotonically increasing report sequence within the control session.
The row identifies a window ID and renderer kind, never a window title, image,
input content, or pairing secret.

| Measurement | Exact meaning |
| --- | --- |
| received frames / bytes | Valid parsed frames accepted for a configured renderer; count once before renderer routing, excluding undesired/missing-renderer frames |
| renderer enqueue count | Frames passed to the display renderer, explicitly distinct from presentation |
| application queue drops / recovery count | Drops before AVFoundation, including broken reference-chain recovery |
| queue size/age | Current bounded queue and oldest waiting frame, measured with client monotonic time |
| decoder status / requires flush / error code | Current display-layer state, with no error text or content |
| AV total / dropped / corrupt / optimized counts | Raw `AVVideoPerformanceMetrics` counters, with API availability and sample age |
| AV presentation estimate | Delta of AV total minus dropped over the same valid interval; null on first sample, regression/reset or unavailable API; identify as an estimate |
| AV accumulated frame delay | Raw cumulative AV delay; do not relabel it as capture-to-display or input latency |
| display refresh ceiling | OS-reported screen capability, not observed presentation cadence |

Dimensions come from the successfully parsed codec format description. The
display refresh ceiling on conventional UIKit renderers is read on the main
thread from the window/scene currently owning the attached display layer. It
remains null if detached, offscreen, invalid or unsupported. No main-screen
fallback or cached display identity is used. macOS and visionOS currently report
null; visionOS does not expose this UIWindowScene screen API. Spatial rows expose
receive counts only and omit conventional screen, queue, enqueue, drop and
presentation counters. A capability ceiling is not measured presentation FPS.

AV metrics are asynchronous and can return nil. Capture a renderer-generation
token before requesting them; discard results if the renderer changed or was
invalidated. Do not allow overlapping collection tasks to accumulate. Use a
bounded collector independent of MCP reads; reads must not reset measurement
windows. Preserve raw counters so derived rates can be audited.
Presentation estimates expire after five seconds without a new sample. Host
reports become stale after ten seconds without a new report.

Vision's spatial decoder/SwiftUI image path is a different renderer. Report its
decode/composition stages separately. Never attribute the hidden conventional
display layer's performance to the visible spatial surface.

## Clock and latency work

Client and Host uptime values are not directly comparable. Keep each stage's
durations local until a bounded round-trip clock exchange provides an offset and
uncertainty estimate. Input-to-photon acceptance also requires observation of the
resulting displayed frame; neither input injection nor successful local TCP send
provides it. Packet frame IDs/timestamps and acknowledgments, if added later,
must be a separately negotiated extension with old-peer tests.

## Verification gates

Deterministic tests cover first/idle/reset/stale-generation windows,
nonfinite and oversized peer reports, sequence replay, connection replacement,
nil/late AV callbacks, spatial counter suppression, and maximum report size.
Swift 6 checks and all three target builds pass; source routing counts each
accepted frame once. Still run actual moving-content sessions
on the physical iPad. Verify that a stalled/hidden/disconnected renderer cannot
continue reporting a cached healthy FPS. Keep simulation results separate from
physical display measurements.


## Renderer ownership validation

Container layout and replacement attachment modify/remove a prior layer only
while it still belongs to that container. A stale view cannot resize, change the
content mode of, or remove a layer already reparented to a new view. Existing
teardown ownership protection remains.

The exact production container is exercised with real CoreAnimation/display
layers and small UIKit lifecycle/screen stand-ins. Root reproduces the old stale
resize/content-mode/removal failures and passes current ownership, reparenting,
scene-migration and unavailable-screen cases. Strict collector tests suppress
spatial screen capability. iPad and Vision Release builds pass on the combined
source. These checks do not establish real SwiftUI lifecycle or physical screen
acceptance; no simulator/device app was installed for this source milestone.
