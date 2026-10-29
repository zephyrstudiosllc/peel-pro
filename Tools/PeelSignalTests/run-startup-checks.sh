#!/bin/sh
# Focused startup-diagnostic checks for the actual paired signal service.
# Fake listener/browser drivers, in-memory pairing metadata and synthetic keys
# only: no network I/O, Keychain, TLS, defaults, processes or accounts. The
# fixture refuses to compile without PEEL_SIGNAL_STARTUP_TESTS. Mirrors the
# Host target's Swift 5 / MainActor / approachable-concurrency settings.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-signal-startup-checks.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
sidepulse_dir="$workspace_dir/Sources/SidePulse/sidepuls-z-swift"
integration_dir="$workspace_dir/Integration"
xcrun swiftc -swift-version 5 -default-isolation MainActor \
 -enable-upcoming-feature DisableOutwardActorInference \
 -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
 -enable-upcoming-feature InferIsolatedConformances \
 -enable-upcoming-feature InferSendableFromCaptures \
 -enable-upcoming-feature NonisolatedNonsendingByDefault \
 -enable-upcoming-feature MemberImportVisibility \
 -D PEEL_WORKSPACE -D PEEL_HOST_INTEGRATION -D PEEL_SIGNAL_STARTUP_TESTS \
 "$sidepulse_dir/LEDProgramRenderer.swift" \
 "$sidepulse_dir/Models.swift" \
 "$sidepulse_dir/NearbySignalModels.swift" \
 "$sidepulse_dir/NearbySignalService.swift" \
 "$sidepulse_dir/SidePulseSignalServicing.swift" \
 "$integration_dir/PeelTrustedSidePulseContract.swift" \
 "$integration_dir/PeelPeerAgentContract.swift" \
 "$integration_dir/PeelPeerAgentOwner.swift" \
 "$integration_dir/PeelPeerAgentUsageWire.swift" \
 "$integration_dir/PeelTrustedSidePulseService.swift" \
 "$script_dir/PeelTrustedSidePulseStartupChecks.swift" -o "$work_dir/checks"
"$work_dir/checks"
