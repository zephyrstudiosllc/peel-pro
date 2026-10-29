#!/usr/bin/env bash
set -euo pipefail

peel_workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-ipad}" in
  ipad) peel_scheme="Peel-iPad"; peel_destination="generic/platform=iOS Simulator" ;;
  vision) peel_scheme="Peel"; peel_destination="generic/platform=visionOS Simulator" ;;
  *) printf 'Usage: %s [ipad|vision]\n' "$0" >&2; exit 2 ;;
esac

# Simulator signing embeds the configured application identity used by Keychain.
# CODE_SIGNING_ALLOWED=NO can launch, but cannot validate the pairing-key path.
# These destinations build simulator products only; this script installs nothing.
xcodebuild \
  -project "$peel_workspace_root/Sources/PeelApple/Peel.xcodeproj" \
  -scheme "$peel_scheme" \
  -configuration Debug \
  -destination "$peel_destination" \
  -derivedDataPath "$peel_workspace_root/.build/AppleValidation" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  COMPILER_INDEX_STORE_ENABLE=NO build
