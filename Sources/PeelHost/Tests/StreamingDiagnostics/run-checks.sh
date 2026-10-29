#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(CDPATH= cd -- "$test_dir/../../Peel-Host" && pwd)
check_dir=$(mktemp -d /tmp/peel-stream-diagnostics.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    "$source_dir/AgentBridge/PeelLocalAgentServer.swift" \
    "$source_dir/PeelHost/PeelStreamingDiagnostics.swift" \
    "$source_dir/PeelHost/PeelVideoSendDiagnostics.swift" \
    "$source_dir/PeelHost/PeelVideoEncoderHardwarePolicy.swift" \
    "$test_dir/StreamingDiagnosticsChecks.swift" -o "$check_dir/checks"
"$check_dir/checks"
