#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
workspace_dir=${script_dir:h:h}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-machine-status-projection.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    "$workspace_dir/Apps/Peel/Integration/PeelUsageSnapshot.swift" \
    "$workspace_dir/Sources/PeelHost/Peel-Host/PeelMachineStatusMessages.swift" \
    "$workspace_dir/Integration/PeelRemoteMachineStatusProvider.swift" \
    "$script_dir/PeelRemoteMachineStatusProviderChecks.swift" \
    -o "$temporary_dir/PeelRemoteMachineStatusProviderChecks"

"$temporary_dir/PeelRemoteMachineStatusProviderChecks"
