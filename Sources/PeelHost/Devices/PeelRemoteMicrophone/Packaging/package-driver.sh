#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# This helper only builds and packages the standalone AudioServerPlugIn. It
# intentionally has no install, service-management, or postinstall path.
readonly PACKAGING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DRIVER_DIR="${PACKAGING_DIR}/../Driver"
readonly DRIVER_BUILD_DIR="${DRIVER_DIR}/build"
readonly BUNDLE_NAME="PeelRemoteMicrophone.driver"
readonly BUNDLE_PATH="${DRIVER_BUILD_DIR}/${BUNDLE_NAME}"
readonly PACKAGING_BUILD_DIR="${DRIVER_BUILD_DIR}/packaging"
readonly STAGING_DIR="${PACKAGING_BUILD_DIR}/staging"
readonly PAYLOAD_DIR="${STAGING_DIR}/payload"
readonly PKG_DIR="${PACKAGING_BUILD_DIR}/pkg"
readonly INSTALL_LOCATION="/Library/Audio/Plug-Ins/HAL"
readonly EXPECTED_DESTINATION="${INSTALL_LOCATION}/${BUNDLE_NAME}"
readonly DRIVER_BUNDLE_ID="com.zephyrstudiosllc.PeelRemoteMicrophone.Driver"
readonly DRIVER_PACKAGE_TYPE="BNDL"
readonly DRIVER_EXECUTABLE="PeelRemoteMicrophone"
readonly DEVICE_UID="com.zephyrstudiosllc.PeelRemoteMicrophone.Device.v1"
readonly HOST_BUNDLE_ID="com.zephyrstudiosllc.Peel-Host"
readonly HOST_TEAM_ID="V729QMY3V6"

bundle_signing_identity=""
package_signing_identity=""
bundle_signing_identity_set=0
package_signing_identity_set=0
bundle_version=""
package_path=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: package-driver.sh [options]

Build and package the Peel Remote Microphone AudioServerPlugIn into the
ignored Driver/build/packaging staging and pkg directories. The default output
is an explicitly unsigned review package.

Options:
  --signing-identity ID          Sign the driver bundle with codesign.
  --bundle-signing-identity ID   Alias for --signing-identity.
  --package-signing-identity ID Sign the component package with pkgbuild.
  -h, --help                     Show this help.

The script never installs a package, changes /Library, loads a plug-in,
restarts coreaudiod, starts a daemon, or runs a postinstall action.
EOF
}

validate_identity() {
    local label="$1"
    local identity="$2"
    [[ -n "$identity" ]] || die "${label} must not be empty."
    [[ "$identity" != -* ]] || die "${label} must not begin with '-'."
    [[ "${#identity}" -le 256 ]] || die "${label} is too long."
    case "$identity" in
        *$'\n'*|*$'\r'*|*$'\t'*)
            die "${label} must not contain line breaks or tabs."
            ;;
    esac
}

while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --signing-identity|--bundle-signing-identity)
            (( $# >= 2 )) || die "$1 requires an identity argument."
            bundle_signing_identity="$2"
            bundle_signing_identity_set=1
            shift 2
            ;;
        --signing-identity=*|--bundle-signing-identity=*)
            bundle_signing_identity="${1#*=}"
            bundle_signing_identity_set=1
            shift
            ;;
        --package-signing-identity)
            (( $# >= 2 )) || die "$1 requires an identity argument."
            package_signing_identity="$2"
            package_signing_identity_set=1
            shift 2
            ;;
        --package-signing-identity=*)
            package_signing_identity="${1#*=}"
            package_signing_identity_set=1
            shift
            ;;
        *)
            die "Unsupported argument: $1"
            ;;
    esac
done

if (( bundle_signing_identity_set )); then
    validate_identity "Bundle signing identity" "$bundle_signing_identity"
fi
if (( package_signing_identity_set )); then
    validate_identity "Package signing identity" "$package_signing_identity"
fi

[[ "$(uname -s)" == "Darwin" ]] || die "This packaging helper requires macOS."

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

require_literal() {
    local file="$1"
    local literal="$2"
    [[ -f "$file" ]] || die "Required source file is missing: $file"
    if ! grep -Fq -- "$literal" "$file"; then
        die "Source contract is missing from $file: $literal"
    fi
}

assert_fixed_path() {
    local path="$1"
    local expected="$2"
    [[ "$path" == "$expected" ]] || die "Refusing unexpected packaging path: $path"
    [[ "$path" != "/" && "$path" != "." ]] || die "Refusing unsafe packaging path."
}

assert_build_tree_is_local() {
    [[ -d "$DRIVER_DIR" && ! -L "$DRIVER_DIR" ]] || \
        die "Driver directory is missing or is a symlink: $DRIVER_DIR"
    [[ ! -L "$DRIVER_BUILD_DIR" ]] || \
        die "Refusing symlinked driver build directory: $DRIVER_BUILD_DIR"
    [[ ! -L "$PACKAGING_BUILD_DIR" ]] || \
        die "Refusing symlinked packaging build directory: $PACKAGING_BUILD_DIR"
}

validate_source_contract() {
    require_literal \
        "${DRIVER_DIR}/PeelRemoteMicrophoneDriver.c" \
        "#define kPeelDeviceUID \"${DEVICE_UID}\""
    require_literal \
        "${DRIVER_DIR}/ProducerAuthentication.c" \
        "identifier \\\"${HOST_BUNDLE_ID}\\\""
    require_literal \
        "${DRIVER_DIR}/ProducerAuthentication.c" \
        "certificate leaf[subject.OU] = \\\"${HOST_TEAM_ID}\\\""
}

build_driver() {
    printf '%s\n' "Building and checking ${BUNDLE_PATH}..."
    # Force the Driver Makefile's fixed local build directory. No caller path
    # is accepted, so staging and cleanup remain inside the ignored build tree.
    make -C "$DRIVER_DIR" BUILD_DIR=build check
}

read_plist_value() {
    local key="$1"
    local plist="$2"
    plutil -extract "$key" raw -o - "$plist" 2>/dev/null
}

validate_bundle() {
    local bundle="$1"
    local info_plist="${bundle}/Contents/Info.plist"
    local executable="${bundle}/Contents/MacOS/${DRIVER_EXECUTABLE}"
    local bundle_id
    local package_type
    local executable_name
    local short_version
    local executable_description

    [[ -d "$bundle" && ! -L "$bundle" ]] || die "Driver bundle is missing or is a symlink: $bundle"
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || die "Driver Info.plist is missing: $info_plist"
    [[ -f "$executable" && ! -L "$executable" && -x "$executable" ]] || \
        die "Driver executable is missing or not executable: $executable"

    bundle_id="$(read_plist_value CFBundleIdentifier "$info_plist")" || \
        die "Driver Info.plist has no CFBundleIdentifier."
    package_type="$(read_plist_value CFBundlePackageType "$info_plist")" || \
        die "Driver Info.plist has no CFBundlePackageType."
    executable_name="$(read_plist_value CFBundleExecutable "$info_plist")" || \
        die "Driver Info.plist has no CFBundleExecutable."
    short_version="$(read_plist_value CFBundleShortVersionString "$info_plist")" || \
        die "Driver Info.plist has no CFBundleShortVersionString."

    [[ "$bundle_id" == "$DRIVER_BUNDLE_ID" ]] || \
        die "Unexpected driver bundle ID: $bundle_id"
    [[ "$package_type" == "$DRIVER_PACKAGE_TYPE" ]] || \
        die "Unexpected driver package type: $package_type"
    [[ "$executable_name" == "$DRIVER_EXECUTABLE" ]] || \
        die "Unexpected driver executable name: $executable_name"
    [[ "$short_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || \
        die "Driver version is not a package version: $short_version"

    executable_description="$(file -b "$executable")"
    [[ "$executable_description" == *Mach-O* ]] || \
        die "Driver executable is not a Mach-O image: $executable_description"

    bundle_version="$short_version"
}

reset_staging() {
    assert_build_tree_is_local
    assert_fixed_path "$STAGING_DIR" "${PACKAGING_BUILD_DIR}/staging"
    [[ ! -L "$STAGING_DIR" ]] || die "Refusing symlinked staging directory: $STAGING_DIR"
    if [[ -e "$STAGING_DIR" ]]; then
        # This is a script-derived, fixed path under Driver/build. It is never
        # supplied by the caller and is guarded above before removal.
        rm -rf "$STAGING_DIR"
    fi
    mkdir -p "$PAYLOAD_DIR"
}

prepare_package_directory() {
    assert_build_tree_is_local
    assert_fixed_path "$PKG_DIR" "${PACKAGING_BUILD_DIR}/pkg"
    [[ ! -L "$PKG_DIR" ]] || die "Refusing symlinked package directory: $PKG_DIR"
    mkdir -p "$PKG_DIR"
}

sign_bundle_if_requested() {
    [[ -z "$bundle_signing_identity" ]] && return 0
    require_command codesign
    printf '%s\n' "Signing the driver bundle with the explicitly supplied identity."
    codesign --force --sign "$bundle_signing_identity" --timestamp=none "$BUNDLE_PATH"
    codesign --verify --strict "$BUNDLE_PATH"
}

stage_bundle() {
    reset_staging
    cp -R "$BUNDLE_PATH" "$PAYLOAD_DIR/"
    validate_bundle "${PAYLOAD_DIR}/${BUNDLE_NAME}"
    [[ "$EXPECTED_DESTINATION" == "/Library/Audio/Plug-Ins/HAL/PeelRemoteMicrophone.driver" ]] || \
        die "Packaging destination changed unexpectedly: $EXPECTED_DESTINATION"
}

payload_contains() {
    local relative_path="$1"
    local listing="$2"
    if grep -Fqx -- "./${relative_path}" "$listing"; then
        return 0
    fi
    grep -Fqx -- "$relative_path" "$listing"
}

build_package() {
    local package_name
    local listing="${STAGING_DIR}/payload-files.txt"
    local expanded_package="${STAGING_DIR}/expanded-package"
    local package_info="${expanded_package}/PackageInfo"
    local pkgbuild_args=(
        --root "$PAYLOAD_DIR"
        --identifier "$DRIVER_BUNDLE_ID"
        --version "$bundle_version"
        --install-location "$INSTALL_LOCATION"
        --ownership recommended
    )

    if (( !bundle_signing_identity_set && !package_signing_identity_set )); then
        package_name="PeelRemoteMicrophone-unsigned-review.pkg"
        printf '%s\n' "Packaging an unsigned review artifact (unsigned bundle and unsigned installer)."
    elif (( bundle_signing_identity_set && !package_signing_identity_set )); then
        package_name="PeelRemoteMicrophone-bundle-signed-unsigned-installer-review.pkg"
        printf '%s\n' "Packaging a bundle-signed, unsigned-installer review artifact."
    elif (( !bundle_signing_identity_set && package_signing_identity_set )); then
        package_name="PeelRemoteMicrophone-unsigned-bundle-signed-installer-review.pkg"
        printf '%s\n' "Packaging an unsigned-bundle, installer-signed review artifact."
    else
        package_name="PeelRemoteMicrophone-bundle-and-installer-signed-review.pkg"
        printf '%s\n' "Packaging a bundle-signed, installer-signed review artifact."
    fi
    package_path="${PKG_DIR}/${package_name}"
    case "$package_name" in
        PeelRemoteMicrophone-unsigned-review.pkg|\
        PeelRemoteMicrophone-bundle-signed-unsigned-installer-review.pkg|\
        PeelRemoteMicrophone-unsigned-bundle-signed-installer-review.pkg|\
        PeelRemoteMicrophone-bundle-and-installer-signed-review.pkg)
            ;;
        *)
            die "Refusing unexpected package output name: $package_name"
            ;;
    esac
    [[ "$package_path" == "${PKG_DIR}/${package_name}" ]] || \
        die "Refusing unexpected package output path: $package_path"
    prepare_package_directory

    if (( package_signing_identity_set )); then
        pkgbuild_args+=(--sign "$package_signing_identity")
    fi

    printf '%s\n' "Creating ${package_path} for ${EXPECTED_DESTINATION}..."
    pkgbuild "${pkgbuild_args[@]}" "$package_path"

    require_command pkgutil
    pkgutil --payload-files "$package_path" > "$listing"
    payload_contains \
        "${BUNDLE_NAME}/Contents/Info.plist" "$listing" || \
        die "Package payload is missing the driver Info.plist."
    payload_contains \
        "${BUNDLE_NAME}/Contents/MacOS/${DRIVER_EXECUTABLE}" "$listing" || \
        die "Package payload is missing the driver executable."

    pkgutil --expand-full "$package_path" "$expanded_package"
    [[ -f "$package_info" ]] || die "Expanded package has no PackageInfo metadata."
    grep -Fq -- "install-location=\"${INSTALL_LOCATION}\"" "$package_info" || \
        die "Package install location is not ${INSTALL_LOCATION}."
    grep -Fq -- 'postinstall-action="none"' "$package_info" || \
        die "Package unexpectedly declares a postinstall action."
    [[ ! -d "${expanded_package}/Scripts" ]] || \
        die "Package unexpectedly contains installer scripts."
}

require_command grep
require_command make
require_command plutil
require_command file
require_command pkgbuild
validate_source_contract
build_driver
validate_bundle "$BUNDLE_PATH"
sign_bundle_if_requested
validate_bundle "$BUNDLE_PATH"
stage_bundle
build_package

printf '\nCreated review package: %s\n' "$package_path"
if (( !bundle_signing_identity_set && !package_signing_identity_set )); then
    printf '%s\n' "Signing mode: unsigned bundle + unsigned installer (clearly labeled)."
elif (( bundle_signing_identity_set && !package_signing_identity_set )); then
    printf '%s\n' "Signing mode: signed bundle + unsigned installer (clearly labeled)."
elif (( !bundle_signing_identity_set && package_signing_identity_set )); then
    printf '%s\n' "Signing mode: unsigned bundle + signed installer (clearly labeled)."
else
    printf '%s\n' "Signing mode: signed bundle + signed installer."
fi
printf 'Declared installation destination: %s\n' "$EXPECTED_DESTINATION"
printf '%s\n' "No installation, plug-in load, Core Audio restart, daemon, or postinstall action was performed."
