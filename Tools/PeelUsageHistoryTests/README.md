# Usage history verification

Run `sh Tools/PeelUsageHistoryTests/run-checks.sh` for the actual snapshot/history
model under strict Swift 6 concurrency checks. It covers independent provider
source/account/window ownership, a measured two-point hour, cached/out-of-order
and stale readings, gaps, reset boundaries, downward corrections, unknown reset
cycles, account switches, persistence/reload, private file permissions, corrupt
files, retention and total sample bounds. All data is synthetic; the fixture uses
only its temporary directory and never calls a provider or reads real history.

`python3 Tools/PeelUsageHistoryTests/run-account-key-checks.py` compiles the actual
helper identity payload body with Apple's equivalent CryptoKit SHA256 API. The
bundled helper uses swift-crypto's Crypto module. It verifies identity separation
and redaction without compiling the full application/provider test graph.
`Sources/CodexBar/Tests/CodexBarTests/DashboardHistoryIdentityTests.swift` retains
the corresponding package tests for the normal CodexBar test workflow.

`python3 Tools/PeelUsageHistoryTests/run-swap-projection-checks.py` links an
already-built Release `CodexBarCore` library, then compiles the actual dashboard
account builder, identity payload and redaction functions extracted from source.
Only unrelated allowance-window/pace presentation is stubbed. This verifies the
real ClaudeSwap row projection through the real owner hash: organization/email
isolation, whitespace normalization and redaction. The projection retains a
trimmed organization in a transient field; the source-issued account ID and
cloud-synced identity organization remain unchanged. It needs the component's
Release build products and generated CQuickJS modulemap.

On this checkout's macOS Swift toolchain, prepare the Core library explicitly:

```sh
swift build --package-path Sources/CodexBar -c release -j 2 --product CodexBarCore
python3 Tools/PeelUsageHistoryTests/run-swap-projection-checks.py
```

The harness expects `.build/out/Products/Release/libCodexBarCore.a` and
`.build/out/Intermediates.noindex/GeneratedModuleMaps/CQuickJS.modulemap` inside
the CodexBar component, and reports missing prerequisites before compiling.
The normal `scripts/build-host.sh` CLI-only helper build need not create the
Core library in a clean checkout. A different SwiftPM output layout requires
updating these two harness paths; the checks never build products themselves.

The full package workflow is `make test` (Debug by default), with provider-file,
session-file and Keychain isolation enabled by `Scripts/test.sh`. A direct
`swift test -c release` invocation cannot compile tests requiring existing
`#if DEBUG` testing hooks; that attempt does not validate the package suite.
The coordinating task owns the normal full package test run.

Production history is recorded only after an already-enabled usage refresh; it
creates no new polling, account connection or provider access. Disk writes run
in order on a utility queue. Preview mode never reads or writes history. The
local store retains at most 48 hours, 64 series, 1,500 samples per series and
12,000 samples total. Its load and write size limit is 4 MiB. Unreadable saved data
is preserved and a visible error explains that subsequent readings remain in
memory.

Each bar sums observed, nondecreasing changes between fresh samples wholly
inside that hour. It never distributes an observed increase across an unknown
hour boundary. More than ten minutes between readings, a changed/elapsed reset
or a downward correction breaks continuity. Missing reset metadata produces a
partial lower bound. A last-hour summary uses an approximation sign only when
continuous coverage reaches within three minutes of each boundary; otherwise
it explicitly says partial or unavailable. These are percentage points of the
selected allowance, not billing estimates or a percentage of previous usage.

History begins with fresh observations after this implementation is installed.
The helper does not export its standalone app's history or account migration
state; importing that unrelated storage would invent ownership. Missing stable
identity or an allowance-specific timestamp keeps history unavailable. Aggregate
status/cost update times never freshen allowance samples. Multi-account source
slots are scoped by a separate owner fingerprint, so slot reuse cannot inherit
another account's history. Production UI and bundled-helper integration
build/acceptance belong to the coordinating task.
