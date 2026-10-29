# Controlled encoder capability check

`run-encoder-bench.py` compiles the exact current production `VideoH264Encoder`,
its color metadata helper, codec enum, and diagnostic collector with optimization.
It hashes the extracted encoder, combined fixture and compiled support sources. Marker changes fail
the extraction; no manually copied encoder implementation is maintained here.

The fixture preallocates eight synthetic moving-bar frames over static stripes,
then offers them at a bounded cadence for 2–30 seconds. It touches no screen
capture, windows, pairing, input, network or device settings. Default BGRA matches
the current ScreenCaptureKit configuration; NV12 separately tests a possible
capture-format optimization. Do not run during another performance measurement.

```sh
python3 Tools/PeelStreamingBench/run-encoder-bench.py --compile-only
python3 Tools/PeelStreamingBench/run-encoder-bench.py --width 5120 --height 2880 --fps 120 --seconds 10 --codec hevc --pixel-format bgra
```

Output includes source-offered FPS, actual hardware/codec selection, encoded FPS,
encoding callback durations, discarded pending raw frames and resets. The encoder
can fall back; verify the reported codec and hardware flag rather than the requested
codec. Rates reflect the collector's trailing-five-second window. Ten seconds is
a capability probe, not a sustained acceptance run.

This isolates **encoding**. Cached synthetic frames are easier than a real desktop
and exclude capture/conversion, transport, decode, display, input and thermal soak.
It cannot certify 5K120 streaming, sharp text, latency or client display cadence.
Real end-to-end tests need a suitable source and a capable receiving display.

## Bitstream and synthetic luma check

Add `--capture-dir NEW_DIRECTORY` to collect at most 32 access units /32 MiB from
the production encoder or an explicitly transformed variant. The receipt labels
these runs as instrumented. Captured frame timestamps select the exact reference
pattern phase, including skipped source frames. Actual AVCC output is converted
to Annex B with bounded NAL validation and its original codec parameter sets.
No desktop content is read. Existing capture directories are never overwritten.

For an NV12 capture, run `python3 Tools/PeelStreamingBench/check-captured-luma.py
NEW_DIRECTORY`. Installed FFmpeg/FFprobe verify actual dimensions, full-range
metadata, decoder success and compared-frame count, then measure luma differences
against the exact synthetic phases. The v2 receipt derives approximate aggregate
PSNR from per-frame PSNR, avoiding a false lossless result from rounded MSE values.
It retains command/version/source hashes and the checker source. Earlier v1
receipts use rounded MSE; preserve them and prefer v2 for comparisons.

`test-quality-verifier.py CAPTURE_DIRECTORY` checks a matching source, a deliberately
wrong bar phase, and a missing final access unit in disposable copies. The last
case must fail; wrong image content must materially worsen the score. These checks
cannot certify chroma fidelity, real text readability, the Apple hardware decoder,
display cadence or professional image quality. The monochrome pattern is easy.

## Explicit experiments

The default `--variant production` compiles the exact production encoder. Other
variants are **not production behavior**; both the variant and compiled source
hashes are included in the receipt:

- `hardware-realtime-experiment`: removes low-latency encoder selection and
  requests no reordering and zero frame delay. An unsupported property fails
  that session normally; no silent success is reported.
- `hardware-realtime-flush-experiment`: disables reordering and completes each
  submitted frame synchronously to avoid waiting for future input.
- `hardware-capability`: uses an independent, bounded four-frame hardware
  pipeline. This isolates hardware throughput; it has no production recovery,
  wire framing, or live-stream acceptance claim.

`xcrun swift Tools/PeelStreamingBench/InspectEncoders.swift` discovers the low-latency
and standard hardware-required HEVC/H.264 selections and queries/sets documented properties on
throwaway sessions. It encodes no frames and changes no application preferences.

## Recovery faults

With `--variant production`, `--fault drop-one-output` suppresses the tenth
encoder callback to reproduce a watchdog after a productive session. The encoder
object persists through recovery, so the callback is suppressed exactly once.
`drop-all-outputs` suppresses every delivered callback; `fail-all-session-creates`
replaces the creation call with `kVTInvalidSessionErr` without creating any codec
session. These explicit source transforms leave the repository source unchanged.
Receipts record both original/compiled encoder hashes and the selected fault.
Their frame rates are recovery evidence, never a throughput benchmark.

The transient case should recover the negotiated HEVC path and emit a fresh
keyframe/configuration. Captured access units can be checked with the decoder
above. Persistent failures should enter a visible cooldown after a bounded burst,
then retry only negotiated codecs. Policy checks live at
`Sources/PeelHost/Tests/EncoderRecovery/run-checks.sh`. Resolution fallback and
real ScreenCaptureKit/client recovery still require separate acceptance.
