#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d /tmp/peel-usage-history.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  -strict-concurrency=complete -warnings-as-errors \
  "$root/Apps/Peel/Integration/PeelUsageSnapshot.swift" \
  "$root/Apps/Peel/Integration/PeelUsageHistory.swift" \
  "$root/Tools/PeelUsageHistoryTests/UsageHistoryChecks.swift" -o "$scratch/checks"
"$scratch/checks"
