#!/bin/zsh
# Usage-lane fixtures: dashboard decoding, command bounds, account-safe merge, observed local tokens,
# provider states and compact ranking. Synthetic data only: no bundled helper, provider, network,
# credential, Keychain, log or transcript access. The command smoke spawns only system tools.
#
#   scripts/test-peer-usage.sh             Peel usage smokes (swiftc, MainActor default isolation)
#   scripts/test-peer-usage.sh --codexbar  also run the focused CodexBar cost/dashboard Swift tests
set -euo pipefail

script_dir=${0:A:h}
workspace_dir=${script_dir:h}
test_output="$workspace_dir/.build/PeelUsageLaneSmoke"
run_codexbar=0
for argument in "$@"; do
    case "$argument" in
        --codexbar) run_codexbar=1 ;;
        *) print -u2 "Unknown argument: $argument"; exit 64 ;;
    esac
done

mkdir -p "$test_output"
cd "$workspace_dir"
usage=Apps/Peel/Integration

# Each smoke compiles the same file set the app target uses for that boundary.
xcrun swiftc -default-isolation MainActor \
    "$usage/PeelUsageSnapshot.swift" \
    Apps/Peel/Tests/PeelUsageSnapshotSmoke.swift \
    -o "$test_output/snapshot-smoke"
"$test_output/snapshot-smoke"

xcrun swiftc -default-isolation MainActor \
    "$usage/PeelUsageCommand.swift" \
    Apps/Peel/Tests/PeelUsageCommandSmoke.swift \
    -o "$test_output/command-smoke"
"$test_output/command-smoke"

xcrun swiftc -default-isolation MainActor \
    "$usage/PeelUsageSnapshot.swift" \
    "$usage/PeelUsageCommand.swift" \
    "$usage/PeelUsageTokens.swift" \
    "$usage/PeelUsageMerge.swift" \
    "$usage/PeelUsagePresentation.swift" \
    Apps/Peel/Tests/PeelUsageLaneSmoke.swift \
    -o "$test_output/lane-smoke"
"$test_output/lane-smoke"

if (( run_codexbar )); then
    # Parser/payload tests only; they read no real accounts, logs or Keychain items.
    xcrun swift test \
        --package-path Sources/CodexBar \
        --disable-automatic-resolution \
        --disable-keychain \
        --disable-netrc \
        --filter 'CLICostTests|DashboardSnapshotBuilderTests'
fi

print "test-peer-usage: PASS"
