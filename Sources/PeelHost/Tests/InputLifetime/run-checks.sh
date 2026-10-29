#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
host_dir=$(CDPATH= cd -- "$test_dir/../../Peel-Host" && pwd)
check_dir=$(mktemp -d /tmp/peel-input-lifetime.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
python3 - "$host_dir/AgentBridge/PeelAgentWindowControl.swift" "$test_dir/InputLifetimeChecks.swift" "$check_dir/InputLifetimeChecks.swift" <<'PYGEN'
import pathlib, sys
source=pathlib.Path(sys.argv[1]).read_text()
start=source.index("    func cancel(input:")
brace=source.index("{",start); end=brace+1; depth=1
while depth:
    depth += (source[end]=="{")-(source[end]=="}"); end+=1
fixture=pathlib.Path(sys.argv[2]).read_text()
assert fixture.count("/* PRODUCTION_AGENT_CANCEL */")==1
pathlib.Path(sys.argv[3]).write_text(fixture.replace("/* PRODUCTION_AGENT_CANCEL */", source[start:end]))
PYGEN
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    "$host_dir/PeelSharedMessages.swift" "$host_dir/PeelStreamDiagnosticsMessages.swift" \
    "$host_dir/PeelHost/PeelPointerInput.swift" "$host_dir/PeelHost/PeelKeyboardEventFactory.swift" \
    "$host_dir/PeelHost/InputSynthesizer.swift" "$check_dir/InputLifetimeChecks.swift" -o "$check_dir/checks"
"$check_dir/checks"
