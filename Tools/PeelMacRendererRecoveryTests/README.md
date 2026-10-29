# Mac client pending decoder recovery

Run `python3 Tools/PeelMacRendererRecoveryTests/run-checks.py` from the workspace.
Use `--source /path/to/PeelRemoteMacVideoRenderer.swift` to check a saved baseline.

The complete actual renderer class is compiled under Swift 6 complete concurrency
checking with only AV target identity and the monotonic-clock expression replaced.
Real CoreMedia sample buffers enter the production pending-store and drain methods.
Readiness and exact deadlines are deterministic; packet shapes and logging are
stand-ins. Extracted-source and compiled-unit hashes are printed. Existing unused
local warnings are visible and do not prevent the baseline behavioral assertions.

The fixture verifies busy and ready expiry, normal fresh/boundary drain, recovery
admission after a nested pending drain for both incoming P and keyframes, and
stale/invalidated lifecycle guards. It runs no UI, network, native input or actual
decoder. Synchronous controlled drain is not proof of dispatch timing or physical
playback quality. The 80ms deadline bounds pending-slot retention, not combined
pipeline or end-to-end latency. The old renderer compiles and fails expiry cases.
