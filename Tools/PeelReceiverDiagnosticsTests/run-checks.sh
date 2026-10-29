#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
scratch=$(mktemp -d /tmp/peel-receiver-diagnostics.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
cmp "$root/Sources/PeelHost/Peel-Host/PeelStreamDiagnosticsMessages.swift" \
    "$root/Sources/PeelApple/Shared/All/PeelStreamDiagnosticsMessages.swift"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    "$root/Sources/PeelHost/Peel-Host/PeelStreamDiagnosticsMessages.swift" \
    "$root/Sources/PeelHost/Peel-Host/AgentBridge/PeelLocalAgentServer.swift" \
    "$root/Sources/PeelHost/Peel-Host/PeelHost/PeelReceiverDiagnostics.swift" \
    "$root/Sources/PeelApple/Shared/Client/PeelClientVideoDiagnostics.swift" \
    "$test_dir/ReceiverDiagnosticsChecks.swift" -o "$scratch/checks"
"$scratch/checks"
