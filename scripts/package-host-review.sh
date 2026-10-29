#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# This is a review-only packager. It consumes the existing Release product from
# scripts/build-host.sh and never builds, installs, launches, notarizes, or
# uploads anything. All generated state is confined to .build/HostReview.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly WORKSPACE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly RELEASE_PRODUCTS_DIR="${WORKSPACE_DIR}/.build/UnifiedHost/Build/Products/Release"
readonly SOURCE_APP="${RELEASE_PRODUCTS_DIR}/Peel Pro.app"
readonly REVIEW_ROOT="${WORKSPACE_DIR}/.build/HostReview"
REVIEW_DIR="${REVIEW_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly REVIEW_DIR
readonly STAGING_DIR="${REVIEW_DIR}/staging"
readonly STAGED_APP="${STAGING_DIR}/Peel Pro.app"
readonly OUTPUT_DIR="${REVIEW_DIR}/artifacts"
readonly ENTITLEMENTS_DIR="${REVIEW_DIR}/entitlements"
readonly EXPECTED_BUNDLE_ID="com.zephyrstudiosllc.Peel-Host"
readonly EXPECTED_EXECUTABLE="Peel Pro"
readonly EXPECTED_TEAM_ID="V729QMY3V6"

identity=""
identity_set=0
sign_index=0
signed_items=()

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/package-host-review.sh --identity "Developer ID Application: ... (V729QMY3V6)"

Consume the existing .build/UnifiedHost/Build/Products/Release/Peel Pro.app,
sign a copied review staging bundle, and create a ZIP plus SHA-256 sidecar under
.build/HostReview/<UTC-timestamp>-<pid>/artifacts.

The Release product must already exist. This command never builds, installs,
launches, notarizes, publishes, or uploads. It refuses Debug products and
requires the Release build marker and its declared signing-entitlements policy.
Profile-restricted rights (including CloudKit/APNs) require the official
scripts/host-distribution.py archive/export path; this direct signer refuses them.

Required options:
  --identity ID   Full Developer ID Application identity for Team V729QMY3V6.
  -h, --help      Show this help.
EOF
}

validate_identity_argument() {
    [[ -n "$identity" ]] || die "--identity must not be empty."
    [[ "${#identity}" -le 256 ]] || die "--identity is too long."
    [[ "$identity" == "Developer ID Application: "* ]] || \
        die "--identity must be a full Developer ID Application identity."
    [[ "$identity" == *"(${EXPECTED_TEAM_ID})" ]] || \
        die "--identity must belong to Team ${EXPECTED_TEAM_ID}."
    [[ "$identity" != -* ]] || die "--identity must not begin with '-'."
    case "$identity" in
        *$'\n'*|*$'\r'*|*$'\t'*)
            die "--identity must not contain line breaks or tabs."
            ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

read_plist_value() {
    local key="$1"
    local plist="$2"
    plutil -extract "$key" raw -o - "$plist" 2>/dev/null
}

validate_app_bundle() {
    local app="$1"
    local expected_parent="$2"
    local info_plist="${app}/Contents/Info.plist"
    local main_executable="${app}/Contents/MacOS/${EXPECTED_EXECUTABLE}"
    local helper="${app}/Contents/Helpers/CodexBarCLI"
    local sparkle="${app}/Contents/Frameworks/Sparkle.framework"
    local bundle_id
    local package_type
    local executable_name
    local version
    local build

    [[ "$app" == "$expected_parent/Peel Pro.app" ]] || \
        die "Refusing an app outside the expected Release product path: $app"
    [[ -d "$app" && ! -L "$app" ]] || die "Release app is missing or is a symlink: $app"
    [[ -d "${app}/Contents" && ! -L "${app}/Contents" ]] || \
        die "Release app Contents directory is missing or is a symlink."
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || \
        die "Release app Info.plist is missing or is a symlink."
    [[ -f "$main_executable" && ! -L "$main_executable" && -x "$main_executable" ]] || \
        die "Release app executable is missing or not executable."
    [[ -f "$helper" && ! -L "$helper" && -x "$helper" ]] || \
        die "Bundled CodexBarCLI is missing or not executable."
    [[ -d "${app}/Contents/Resources/CodexBar_CodexBarCore.bundle" && ! -L "${app}/Contents/Resources/CodexBar_CodexBarCore.bundle" ]] || \
        die "CodexBar resources are missing from Contents/Resources. Rebuild before packaging."
    [[ -f "${app}/Contents/Resources/peel_mcp_server.py" && ! -L "${app}/Contents/Resources/peel_mcp_server.py" ]] || \
        die "The MCP adapter is missing from Contents/Resources."
    cmp -s "${app}/Contents/Resources/peel_mcp_server.py" "${WORKSPACE_DIR}/Tools/PeelMCP/peel_mcp_server.py" || \
        die "The bundled MCP adapter differs from current source. Rebundle before packaging."
    [[ ! -e "${app}/Contents/Helpers/CodexBar_CodexBarCore.bundle" && ! -e "${app}/Contents/Helpers/peel_mcp_server.py" ]] || \
        die "Obsolete resources remain in Contents/Helpers. Rebuild before packaging."
    [[ -d "$sparkle" && ! -L "$sparkle" ]] || \
        die "Bundled Sparkle.framework is missing or is a symlink."

    bundle_id="$(read_plist_value CFBundleIdentifier "$info_plist")" || \
        die "Release app has no CFBundleIdentifier."
    package_type="$(read_plist_value CFBundlePackageType "$info_plist")" || \
        die "Release app has no CFBundlePackageType."
    executable_name="$(read_plist_value CFBundleExecutable "$info_plist")" || \
        die "Release app has no CFBundleExecutable."
    version="$(read_plist_value CFBundleShortVersionString "$info_plist")" || \
        die "Release app has no CFBundleShortVersionString."
    build="$(read_plist_value CFBundleVersion "$info_plist")" || \
        die "Release app has no CFBundleVersion."

    [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || \
        die "Unexpected source bundle identifier: $bundle_id"
    [[ "$package_type" == "APPL" ]] || \
        die "Unexpected source package type: $package_type"
    [[ "$executable_name" == "$EXPECTED_EXECUTABLE" ]] || \
        die "Unexpected source executable name: $executable_name"
    [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || \
        die "Source version is not a package version: $version"
    [[ "$build" =~ ^[0-9]+$ ]] || die "Source build number is not numeric: $build"

    [[ "$(read_plist_value PeelBuildConfiguration "$info_plist")" == "Release" ]] || \
        die "The app does not declare a Release build configuration. Rebuild with scripts/build-host.sh Release."

    if find "${app}/Contents/MacOS" -type f \( -name '*.debug.dylib' -o -name '__preview.dylib' \) \
        -print -quit | grep -q .; then
        die "Debug-only executable artifacts are present in the Release app."
    fi
}

assert_fixed_output_tree() {
    [[ "$REVIEW_DIR" == "${REVIEW_ROOT}/"* ]] || die "Unexpected review output path."
    [[ ! -L "${WORKSPACE_DIR}/.build" && ! -L "$REVIEW_ROOT" ]] || die "Refusing symlinked output parents."
    [[ ! -e "$REVIEW_DIR" && ! -L "$REVIEW_DIR" ]] || die "Review staging directory already exists."
    mkdir -p "$REVIEW_ROOT"
    mkdir "$REVIEW_DIR" || die "Could not exclusively create review staging directory."
    mkdir "$STAGING_DIR" "$OUTPUT_DIR" "$ENTITLEMENTS_DIR"
}

verify_identity_available() {
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null)" || \
        die "Could not inspect the local code-signing identity list."
    if ! printf '%s\n' "$identities" | grep -F -- "\"${identity}\"" | grep -v 'CSSMERR' >/dev/null; then
        die "The selected Developer ID Application identity is not available as a valid local signing identity."
    fi
}

capture_entitlements() {
    local item="$1"
    local output="$2"
    local required="$3"

    rm -f "$output"
    if ! codesign -d --entitlements :- "$item" > "$output" 2>/dev/null; then
        if [[ "$required" == "1" ]]; then
            die "Could not read entitlements from the source Host app."
        fi
        : > "$output"
        return 0
    fi
    if [[ ! -s "$output" ]]; then
        if [[ "$required" == "1" ]]; then
            die "The Release Host app has no embedded entitlements; refusing to guess them."
        fi
        return 0
    fi
    plutil -lint "$output" >/dev/null 2>&1 || \
        die "Embedded entitlements are not a valid property list: $item"
}

assert_no_debug_entitlement() {
    local entitlements="$1"
    local get_task_allow
    get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true)"
    [[ "$get_task_allow" != "true" ]] || \
        die "The source entitlements contain com.apple.security.get-task-allow=true."
}

sign_code_item() {
    local item="$1"
    local entitlement_file="${ENTITLEMENTS_DIR}/item-${sign_index}.plist"
    sign_index=$((sign_index + 1))

    capture_entitlements "$item" "$entitlement_file" 0
    if [[ -s "$entitlement_file" ]]; then assert_no_debug_entitlement "$entitlement_file"; fi
    local sign_args=(codesign --force --timestamp --options runtime)
    if [[ -s "$entitlement_file" ]]; then
        sign_args+=(--entitlements "$entitlement_file")
    fi
    sign_args+=(--sign "$identity" "$item")
    "${sign_args[@]}" >/dev/null
    signed_items+=("$item")
}

sign_sparkle_contents() {
    local sparkle="$1"
    local executable
    local nested
    local nested_count=0
    local macho_count=0

    [[ -d "${sparkle}/Versions" ]] || die "Sparkle.framework has no Versions directory."

    # Sign every Mach-O leaf in the actual framework before signing any of its
    # containing app/XPC/framework bundles. This deliberately signs each level
    # explicitly so each item keeps its own signing options and entitlements.
    while IFS= read -r executable; do
        [[ -n "$executable" ]] || continue
        if file -b "$executable" | grep -q 'Mach-O'; then
            sign_code_item "$executable"
            macho_count=$((macho_count + 1))
        fi
    done < <(find "${sparkle}/Versions" -type f -perm -111 -print | sort)
    (( macho_count > 0 )) || die "No Mach-O code was found inside Sparkle.framework."

    # Sign nested containers deepest-first so each parent records already
    # signed children in its resource envelope.
    while IFS= read -r nested; do
        [[ -n "$nested" ]] || continue
        sign_code_item "$nested"
        nested_count=$((nested_count + 1))
    done < <(
        find "${sparkle}/Versions" -type d \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) -print |
            awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-
    )
    (( nested_count > 0 )) || die "No nested Sparkle app/XPC/framework containers were found."

    # The framework's own code signature is the outermost Sparkle signature.
    sign_code_item "$sparkle"
}

verify_code_item() {
    local item="$1"
    local details

    codesign --verify --strict --verbose=2 "$item" >/dev/null 2>&1 || \
        die "Strict code-signature verification failed: $item"
    if ! details="$(codesign -dv --verbose=4 "$item" 2>&1)"; then
        die "Could not inspect the signed code item: $item"
    fi
    printf '%s\n' "$details" | grep -F -- "TeamIdentifier=${EXPECTED_TEAM_ID}" >/dev/null || \
        die "Signed code item has the wrong Team ID: $item"
    printf '%s\n' "$details" | grep -E 'flags=.*runtime' >/dev/null || \
        die "Signed code item is missing the Hardened Runtime flag: $item"
    if [[ "$item" == "$STAGED_APP" ]]; then
        printf '%s\n' "$details" | grep -F -- "Identifier=${EXPECTED_BUNDLE_ID}" >/dev/null || \
            die "Signed Host app has the wrong bundle identifier."
        printf '%s\n' "$details" | grep -F -- "Authority=${identity}" >/dev/null || \
            die "Signed Host app was not signed by the selected identity."
        if printf '%s\n' "$details" | grep -F -- 'Signature=adhoc' >/dev/null; then
            die "Signed Host app still has an ad hoc signature."
        fi
    fi
}

verify_outer_entitlements() {
    local expected="$1"
    local actual="${ENTITLEMENTS_DIR}/outer-after.plist"
    local expected_binary="${ENTITLEMENTS_DIR}/outer-before.bin"
    local actual_binary="${ENTITLEMENTS_DIR}/outer-after.bin"
    local get_task_allow

    codesign -d --entitlements :- "$STAGED_APP" > "$actual" 2>/dev/null || \
        die "Signed Host app has no readable embedded entitlements."
    # codesign may omit an empty entitlement dictionary entirely.
    if [[ ! -s "$actual" ]]; then
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$actual"
    fi
    plutil -lint "$actual" >/dev/null 2>&1 || \
        die "Signed Host app entitlements are not a valid property list."
    get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$actual" 2>/dev/null || true)"
    [[ "$get_task_allow" != "true" ]] || \
        die "Signed Host app unexpectedly enables the debugger entitlement."

    plutil -convert binary1 -o "$expected_binary" "$expected" >/dev/null 2>&1 || \
        die "Could not normalize source entitlements for comparison."
    plutil -convert binary1 -o "$actual_binary" "$actual" >/dev/null 2>&1 || \
        die "Could not normalize signed entitlements for comparison."
    cmp -s "$expected_binary" "$actual_binary" || \
        die "Signed Host app entitlements differ from the source Release app."
}

create_archive() {
    local version="$1"
    local build="$2"
    local archive="${OUTPUT_DIR}/Peel-Pro-${version}-${build}-signed-review.zip"
    local checksum="${archive}.sha256"

    [[ ! -e "$archive" && ! -L "$archive" ]] || die "Refusing to overwrite an existing archive."
    ditto -c -k --keepParent "$STAGED_APP" "$archive"
    (cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$archive")") > "$checksum"
    printf 'Created signed review archive: %s\n' "$archive"
    printf 'Created SHA-256 sidecar: %s\n' "$checksum"
    printf '%s\n' 'No installation, launch, notarization, publication, upload, or account access was performed.'
}

while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --identity)
            (( $# >= 2 )) || die "$1 requires an identity argument."
            identity="$2"
            identity_set=1
            shift 2
            ;;
        --identity=*)
            identity="${1#*=}"
            identity_set=1
            shift
            ;;
        *)
            die "Unsupported argument: $1"
            ;;
    esac
done

(( identity_set == 1 )) || die "An explicit --identity is required."
validate_identity_argument
require_command python3
# Check current source policy before touching any output or signing identity.
python3 "${SCRIPT_DIR}/host-distribution.py" check-direct-policy \
    --entitlements "${WORKSPACE_DIR}/Sources/PeelHost/Peel-Host/PeelHost.entitlements" || \
    die "Restricted Host rights require official archive/export; see docs/peel-2-release/host-developer-id-distribution.md."
require_command codesign
require_command security
require_command plutil
require_command file
require_command find
require_command awk
require_command sort
require_command cut
require_command cmp
require_command ditto
require_command shasum
[[ -x /usr/libexec/PlistBuddy ]] || die "Required command is unavailable: PlistBuddy"

[[ "$SOURCE_APP" == "${WORKSPACE_DIR}/.build/UnifiedHost/Build/Products/Release/Peel Pro.app" ]] || \
    die "The source path is not the fixed Release output from scripts/build-host.sh."
validate_app_bundle "$SOURCE_APP" "$RELEASE_PRODUCTS_DIR"
verify_identity_available
assert_fixed_output_tree

outer_entitlements="${ENTITLEMENTS_DIR}/outer-before.plist"
# The unsigned build cannot carry an embedded signature policy. The build
# helper packages the explicit, checked-in policy with the Release product.
policy="${SOURCE_APP}/Contents/Resources/PeelSigningEntitlements.plist"
[[ -f "$policy" && ! -L "$policy" ]] || die "Missing Release signing policy. Rebuild with scripts/build-host.sh Release."
cmp -s "$policy" "${WORKSPACE_DIR}/Sources/PeelHost/Peel-Host/PeelHost.entitlements" || \
    die "Built signing policy differs from the current Host source. Rebuild before packaging."
plutil -lint "$policy" >/dev/null || die "Invalid Release signing policy."
cp "$policy" "$outer_entitlements"
assert_no_debug_entitlement "$outer_entitlements"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$outer_entitlements" 2>/dev/null || true)" != "true" ]] || \
    die "Unified Host requires the declared nonsandbox policy for SidePulse and Mechanic."

ditto --rsrc --extattr --acl "$SOURCE_APP" "$STAGED_APP"
validate_app_bundle "$STAGED_APP" "$STAGING_DIR"

sign_code_item "${STAGED_APP}/Contents/Helpers/CodexBarCLI"
sign_sparkle_contents "${STAGED_APP}/Contents/Frameworks/Sparkle.framework"

# Sign the application last, carrying forward exactly the entitlements from the
# source Release policy and enabling the project's required Hardened Runtime.
codesign --force --timestamp --options runtime --entitlements "$outer_entitlements" \
    --sign "$identity" "$STAGED_APP" >/dev/null
signed_items+=("$STAGED_APP")

for item in "${signed_items[@]}"; do
    verify_code_item "$item"
done
verify_outer_entitlements "$outer_entitlements"

version="$(read_plist_value CFBundleShortVersionString "${STAGED_APP}/Contents/Info.plist")"
build="$(read_plist_value CFBundleVersion "${STAGED_APP}/Contents/Info.plist")"
create_archive "$version" "$build"
