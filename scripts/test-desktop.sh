#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
workspace_dir=${script_dir:h}
test_output="$workspace_dir/.build/PeelSmoke"
mkdir -p "$test_output"
cd "$workspace_dir"

xcrun swiftc -default-isolation MainActor \
    Apps/Peel/Integration/PeelUsageSnapshot.swift \
    Apps/Peel/Tests/PeelUsageSnapshotSmoke.swift \
    -o "$test_output/snapshot-smoke"
"$test_output/snapshot-smoke"

xcrun swiftc -default-isolation MainActor \
    Apps/Peel/Integration/PeelUsageCommand.swift \
    Apps/Peel/Tests/PeelUsageCommandSmoke.swift \
    -o "$test_output/command-smoke"
"$test_output/command-smoke"

xcrun swiftc -default-isolation MainActor \
    Sources/PeelHost/Peel-Host/PeelSharedMessages.swift \
    Sources/PeelHost/Peel-Host/PeelStreamDiagnosticsMessages.swift \
    Apps/Peel/Tests/PeelAgentPairingProofSmoke.swift \
    -o "$test_output/pairing-proof-smoke"
"$test_output/pairing-proof-smoke"
