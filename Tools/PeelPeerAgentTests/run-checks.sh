#!/bin/sh
# Pure paired-Mac agent contract fixtures. Synthetic keys only; no Keychain,
# network, process, account or transcript access.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-peer-agent-checks.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
swiftc -swift-version 6 -strict-concurrency=complete \
 "$workspace_dir/Integration/PeelPeerAgentContract.swift" \
 "$workspace_dir/Integration/PeelPeerAgentUsageWire.swift" \
 "$workspace_dir/Integration/PeelPeerAgentOwner.swift" \
 "$workspace_dir/Integration/PeelPeerAgentInventory.swift" \
 "$script_dir/PeelPeerAgentChecks.swift" -o "$work_dir/checks"
"$work_dir/checks"
