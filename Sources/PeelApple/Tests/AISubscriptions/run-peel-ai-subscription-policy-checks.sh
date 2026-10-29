#!/bin/zsh
set -euo pipefail

STAGING_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d /tmp/peel-ai-subscription-checks.XXXXXX)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

swiftc \
    "$STAGING_ROOT/Shared/Client/PeelAISubscriptionPolicy.swift" \
    "$STAGING_ROOT/Tests/AISubscriptions/PeelAISubscriptionPolicyChecks.swift" \
    -o "$TEMP_ROOT/PeelAISubscriptionPolicyChecks"

"$TEMP_ROOT/PeelAISubscriptionPolicyChecks"
