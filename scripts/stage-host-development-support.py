#!/usr/bin/env python3
"""Opt-in private Apple Development Debug phase: stage support BEFORE main CodeSign.

Stages the audited arm64-only CodexBarCLI for private ARM Debug builds, all three helper resource bundles and
the current MCP adapter, signing policy and component notices into the Host
product. Only a disposable copy of the helper is signed, with the Apple
Development identity Xcode selected for this build; Xcode then signs the main
app with its own profile and unchanged entitlements. No Developer ID, ad hoc
fallback, profile, Keychain item or account access. The Release archive phase
and host-distribution.py stay the distribution path; this is not distribution,
notarization, installation or runtime acceptance.

Immutable audited payloads are pinned here. Mutable current payloads (MCP,
notices) are bound by root's frozen build settings and recorded in the receipt.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("peel_distribution", Path(__file__).with_name("host-distribution.py"))
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
Gate = distribution.Gate

# Private ARM Debug228 input: PeelUsageSilent-20261021-R3/arm64-product/receipt.json.
# The complete dirty-source manifest identifies the silent-auth implementation.
HELPER_SHA = "01b8bab5d9aeb2b39221dcf3bc29ef0ce72eb2fc16a5ecc377bed3194ba0bad4"
HELPER_BYTES = 40372384
HELPER_PAYLOAD_SHA = "b364bd122422154255148333402482d995a6fea58a4ce3a26e6e87ea26412edf"
COMPOSITION_RECEIPT_SHA = "1b11557f02d606d1b76fee8a560c45ef31bc661d3184c3439fe85cb03dcdec66"
AUDITED_NORMALIZER_SHA = "4d55f15531147f9d494d0adda4b9b6e36de766f002c898ec3ac6a88008a7366b"
CODEXBAR_REVISION = "c8e1bcf507b38140e3e680fb4d51ce2bf4c58a48"
# Bind the exact reviewed ARM artifact and its complete source, independent of its base revision.
HELPER_ARCHITECTURE = "arm64"
CODEXBAR_SOURCE_MANIFEST_SHA256 = "d5b5e7e6a38fb6e3fa4814f274cde95938d316bf0423e1e043904bc14dda78b2"
RESOURCE_TREES = {
    "CodexBar_CodexBarCore.bundle": "e596f1559c21e55e8e30b39a968c2253847f018968c77c961cbec75f902ab689",
    "SweetCookieKit_SweetCookieKit.bundle": "8ce132f9995f36ff82bbcdae416f1af9993c7a19cdedd199669fa7b53141124a",
    "swift-crypto_Crypto.bundle": "2875ee2e6dcf4b3ba14fa22b6981f6c3f05ecbd3fb119d5b2de9332763ed39dc"
}
ENTITLEMENTS_SHA = "acbc5bab1dd674529ef7e6bfa78d1d3c50e8e479581258f01448d4e0ae3301e6"
HELPER_IDENTIFIER = distribution.BUNDLE + ".CodexBarCLI"
MCP = distribution.ROOT / "Tools/PeelMCP/peel_mcp_server.py"
NOTICE_INPUTS = ("Sources/SidePulse/LICENSE", "Sources/SidePulse/NOTICE",
                 "Sources/CodexBar/LICENSE", "Sources/CodexBar/Sources/CQuickJS/LICENSE")
PRIVATE_BUILD = distribution.ROOT / ".build"
RECEIPT_NAME = "peel-development-support-receipt.json"

REQUIRED_SETTINGS = {
    "ACTION": "build", "CONFIGURATION": "Debug", "PLATFORM_NAME": "macosx", "DEPLOYMENT_LOCATION": "NO",
    "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_REQUIRED": "YES", "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": distribution.TEAM, "PRODUCT_BUNDLE_IDENTIFIER": distribution.BUNDLE,
    "PRODUCT_NAME": "Peel Pro", "WRAPPER_NAME": "Peel Pro.app", "MARKETING_VERSION": "2.0",
    "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "NO",
    # The untouched Release phase (and its v2 file list) already declares every
    # support output; declaring them again is a duplicate-producer error, so this
    # phase writes them undeclared and needs the script sandbox off for this route.
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
}


def setting(name):
    value = os.environ.get(name, "")
    if any(character in value for character in ("\x00", "\n", "\r")):
        raise Gate("invalid build setting: " + name)
    return value


def digest_setting(name):
    value = setting(name)
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise Gate(name + " must be root's frozen lowercase SHA-256 of the current input")
    return value


def regular_file(path):
    if path.is_symlink() or not path.is_file():
        raise Gate("missing or symlinked input: " + str(path))
    return path


def exact_real_path(value, label):
    path = Path(value)
    if not value or not path.is_absolute() or path.resolve() != path:
        raise Gate(label + " must be an absolute path without symlinks or relative components")
    return path


def private_build_path(value, label):
    path = exact_real_path(value, label)
    if PRIVATE_BUILD.is_symlink() or not path.is_relative_to(PRIVATE_BUILD):
        raise Gate(label + " must be inside this workspace's real .build directory")
    return path


def check_build_architecture(architectures, current_architecture):
    if architectures.split() != [HELPER_ARCHITECTURE]:
        raise Gate("ARM-only development helper requires ARCHS=arm64")
    # Target-level script phases can report undefined_arch; ARCHS still defines
    # the complete build target. A concrete different current architecture fails.
    if current_architecture not in ("", "undefined_arch", HELPER_ARCHITECTURE):
        raise Gate("current Xcode build architecture differs from the ARM development helper")


def check_helper_architecture(data):
    layout = distribution.helper_macho_layout(data)
    if HELPER_ARCHITECTURE != "arm64" or struct.unpack_from("<II", data, 4) != (0x0100000C, 0):
        raise Gate("development helper must be a thin arm64-all executable")
    if len(layout["signatures"]) != 1:
        raise Gate("development helper must carry its audited build-artifact signature")


def check_composition_identity(composition):
    if not isinstance(composition, dict):
        raise Gate("ARM helper receipt must be a JSON object")
    if (not isinstance(CODEXBAR_SOURCE_MANIFEST_SHA256, str)
            or not re.fullmatch(r"[0-9a-f]{64}", CODEXBAR_SOURCE_MANIFEST_SHA256)):
        raise Gate("new ARM helper source-manifest pin has not been admitted")
    if (composition.get("format") != "peel-silent-arm64-helper-v1"
            or composition.get("architecture") != HELPER_ARCHITECTURE
            or composition.get("sourceManifestSHA256") != CODEXBAR_SOURCE_MANIFEST_SHA256
            or composition.get("baseRevision") != CODEXBAR_REVISION
            or composition.get("helperSHA256") != HELPER_SHA
            or composition.get("helperBytes") != HELPER_BYTES
            or composition.get("unsignedPayloadSHA256") != HELPER_PAYLOAD_SHA
            or composition.get("resources") != RESOURCE_TREES
            or composition.get("entitlements") != {}):
        raise Gate("ARM helper receipt does not bind the pinned payload and complete source manifest")


def checked_configuration():
    for name, expected in REQUIRED_SETTINGS.items():
        if setting(name) != expected:
            raise Gate("private development staging requires " + name + "=" + expected)
    if setting("PEEL_BUNDLE_ARCHIVE_SUPPORT") not in ("", "NO"):
        raise Gate("the Release archive-support phase must stay inactive for the development route")
    if not sys.flags.isolated:
        raise Gate("run the staging script with an isolated interpreter (-I)")
    check_build_architecture(setting("ARCHS"), setting("CURRENT_ARCH"))
    build = setting("CURRENT_PROJECT_VERSION")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build) or int(build.split(".")[0]) < 228:
        raise Gate("explicit ARM development CURRENT_PROJECT_VERSION 228 or later required; older records stay untouched")
    project = exact_real_path(setting("PROJECT_DIR"), "PROJECT_DIR")
    if project != distribution.PROJECT.parent:
        raise Gate("PROJECT_DIR is not this workspace's Host project")
    declared = setting("CODE_SIGN_ENTITLEMENTS")
    if not declared or (project / declared).resolve() != distribution.POLICY:
        raise Gate("main CodeSign must use the unchanged Peel-Host/PeelHost.entitlements")
    identity = setting("EXPANDED_CODE_SIGN_IDENTITY")
    name = setting("EXPANDED_CODE_SIGN_IDENTITY_NAME")
    # The signed helper's actual authority, team and leaf certificate are verified after signing.
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity) or not (name == "Apple Development" or name.startswith("Apple Development: ")):
        raise Gate("Xcode did not select an Apple Development certificate; ad hoc, local and Developer ID identities are refused")
    # Joining an absolute CONTENTS_FOLDER_PATH would discard the checked base, so only
    # Xcode's exact generated relative value is accepted and the path is built from constants.
    if setting("CONTENTS_FOLDER_PATH") != "Peel Pro.app/Contents":
        raise Gate("CONTENTS_FOLDER_PATH must be exactly Xcode's generated Peel Pro.app/Contents")
    target = private_build_path(setting("TARGET_BUILD_DIR"), "TARGET_BUILD_DIR")
    contents = target / "Peel Pro.app" / "Contents"
    if contents.parent.parent != target or contents.resolve() != contents or not contents.is_relative_to(PRIVATE_BUILD):
        raise Gate("staging output is not the current target's Host Contents")
    derived = private_build_path(setting("DERIVED_FILE_DIR"), "DERIVED_FILE_DIR")
    return {"build": build, "identity": identity.upper(), "identity_name": name,
            "contents": contents, "derived": derived}


def verified_inputs(helper_directory, mcp_sha=None, notices_sha=None):
    """Pure hash/structure checks; no native tool runs here."""
    helper_directory = exact_real_path(helper_directory, "PEEL_DEVELOPMENT_HELPER_DIRECTORY")
    if not helper_directory.is_dir() or helper_directory.is_relative_to(PRIVATE_BUILD):
        raise Gate("helper input must be the audited directory outside build products")
    receipt = regular_file(helper_directory / "receipt.json")
    if distribution.sha(receipt) != COMPOSITION_RECEIPT_SHA:
        raise Gate("helper composition receipt differs from the audited receipt")
    composition = json.loads(receipt.read_text())
    check_composition_identity(composition)
    helper = regular_file(helper_directory / "CodexBarCLI")
    data = helper.read_bytes()
    if len(data) != HELPER_BYTES or hashlib.sha256(data).hexdigest() != HELPER_SHA or not helper.stat().st_mode & 0o111:
        raise Gate("helper bytes differ from the audited ARM development helper")
    check_helper_architecture(data)
    resources = {}
    for name in distribution.HELPER_RESOURCE_BUNDLES:
        path = helper_directory / name
        if path.is_symlink() or distribution.tree_digest(path) != RESOURCE_TREES[name]:
            raise Gate("helper resource bundle differs from the audited input: " + name)
        distribution.validate_resource_payload(path)
        resources[name] = path
    mcp = regular_file(MCP).read_bytes()
    if mcp_sha is not None and hashlib.sha256(mcp).hexdigest() != mcp_sha:
        raise Gate("current MCP adapter differs from root's frozen PEEL_DEVELOPMENT_MCP_SHA256")
    policy = regular_file(distribution.POLICY).read_bytes()
    if hashlib.sha256(policy).hexdigest() != ENTITLEMENTS_SHA:
        raise Gate("PeelHost.entitlements changed; the development route preserves the reviewed rights only")
    notice_items = [{"path": str(distribution.ROOT / name), "sha256": distribution.sha(regular_file(distribution.ROOT / name))}
                    for name in NOTICE_INPUTS]
    notices = distribution.notice_text(notice_items).encode()
    if notices_sha is not None and hashlib.sha256(notices).hexdigest() != notices_sha:
        raise Gate("component notices differ from root's frozen PEEL_DEVELOPMENT_NOTICES_SHA256")
    return {"directory": helper_directory, "helper": helper, "resources": resources,
            "mcp": mcp, "mcp_mode": MCP.stat().st_mode & 0o755, "policy": policy,
            "notice_items": notice_items, "notices": notices}


def signed_helper_details(path, identity):
    details = distribution.code_details(path, identity, HELPER_IDENTIFIER, distribution=False)
    if details["developer_id"]:
        raise Gate("development helper must not carry a Developer ID signature")
    if distribution.embedded_entitlements(path):
        raise Gate("staged helper must remain entitlement-free")
    if distribution.unsigned_payload_digest(path) != HELPER_PAYLOAD_SHA:
        raise Gate("signed helper payload differs from the audited unsigned payload")
    return details


def stage_helper(source, destination, scratch, identity, log_directory):
    """Reuse an earlier staged helper only when it is this payload signed by this identity."""
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise Gate("staged helper slot is not a regular file")
    if destination.is_file():
        try:
            return signed_helper_details(destination, identity), "reused"
        except Gate:
            pass
    copy = scratch / "CodexBarCLI"
    shutil.copy2(source, copy)
    if distribution.sha(copy) != HELPER_SHA:
        raise Gate("disposable helper copy differs from the audited helper")
    result = subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none",
                             "--options", "runtime", "--identifier", HELPER_IDENTIFIER, str(copy)],
                            capture_output=True)
    if result.returncode:
        log = log_directory / "helper-codesign.log"
        log.write_bytes(result.stderr)
        log.chmod(0o600)
        raise Gate("Apple Development signing of the disposable helper copy failed; private log " + str(log))
    details = signed_helper_details(copy, identity)
    os.replace(copy, destination)
    return details, "signed"


def stage_bundle(source, destination, scratch, expected):
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise Gate("staged resource bundle slot is not a real directory")
    if destination.is_dir():
        try:
            if distribution.tree_digest(destination) == expected:
                distribution.validate_resource_payload(destination)
                return "unchanged"
        except Gate:
            pass
    staged = scratch / source.name
    distribution.command(["/usr/bin/ditto", source, staged])
    if distribution.tree_digest(staged) != expected:
        raise Gate("resource bundle copy differs from the audited input")
    distribution.validate_resource_payload(staged)
    if destination.is_dir():
        shutil.rmtree(destination)
    os.rename(staged, destination)
    return "staged"


def stage_file(data, destination, scratch, mode):
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise Gate("staged support file slot is not a regular file")
    if destination.is_file() and destination.read_bytes() == data and destination.stat().st_mode & 0o777 == mode:
        return "unchanged"
    staged = scratch / destination.name
    staged.write_bytes(data)
    staged.chmod(mode)
    os.replace(staged, destination)
    return "staged"


def write_receipt(path, value):
    staged = path.with_name(path.name + ".partial")
    if staged.is_symlink() or path.is_symlink():
        raise Gate("symlinked receipt path")
    with staged.open("w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    staged.chmod(0o600)
    os.replace(staged, path)


def stage_for_xcode():
    configuration = checked_configuration()
    inputs = verified_inputs(setting("PEEL_DEVELOPMENT_HELPER_DIRECTORY"),
                             digest_setting("PEEL_DEVELOPMENT_MCP_SHA256"),
                             digest_setting("PEEL_DEVELOPMENT_NOTICES_SHA256"))
    if distribution.embedded_entitlements(inputs["helper"]):
        raise Gate("audited helper unexpectedly carries entitlements")
    if distribution.unsigned_payload_digest(inputs["helper"]) != HELPER_PAYLOAD_SHA:
        raise Gate("audited helper's unsigned payload differs from the composition receipt")
    contents, identity = configuration["contents"], configuration["identity"]
    helpers, resources = contents / "Helpers", contents / "Resources"
    for directory in (helpers, resources):
        if directory.is_symlink():
            raise Gate("symlinked support output directory")
        directory.mkdir(parents=True, exist_ok=True)
    if {path.name for path in helpers.iterdir()} - {"CodexBarCLI"}:
        raise Gate("Contents/Helpers holds unexpected entries; resources never belong in a nested-code slot")
    work = configuration["derived"] / "PeelDevelopmentSupport"
    if work.is_symlink():
        raise Gate("symlinked private staging directory")
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stage-", dir=work) as directory:
        scratch = Path(directory)
        helper_details, helper_action = stage_helper(inputs["helper"], helpers / "CodexBarCLI", scratch, identity, work)
        bundle_actions = {name: stage_bundle(source, resources / name, scratch, RESOURCE_TREES[name])
                          for name, source in inputs["resources"].items()}
        file_actions = {
            "peel_mcp_server.py": stage_file(inputs["mcp"], resources / "peel_mcp_server.py", scratch, inputs["mcp_mode"]),
            "PeelSigningEntitlements.plist": stage_file(inputs["policy"], resources / "PeelSigningEntitlements.plist", scratch, 0o644),
            "COMPONENT_NOTICES.txt": stage_file(inputs["notices"], resources / "COMPONENT_NOTICES.txt", scratch, 0o644),
        }
    staged_helper = distribution.sha(helpers / "CodexBarCLI")
    if sorted(path.name for path in helpers.iterdir()) != ["CodexBarCLI"]:
        raise Gate("Contents/Helpers must contain only CodexBarCLI")
    for name, expected in RESOURCE_TREES.items():
        if distribution.tree_digest(resources / name) != expected:
            raise Gate("staged resource bundle failed final identity check: " + name)
    for name, data in (("peel_mcp_server.py", inputs["mcp"]), ("PeelSigningEntitlements.plist", inputs["policy"]),
                       ("COMPONENT_NOTICES.txt", inputs["notices"])):
        if (resources / name).read_bytes() != data:
            raise Gate("staged support file failed final identity check: " + name)
    normalizer = distribution.sha(Path(distribution.__file__))
    receipt = {
        "format": "peel-development-support-receipt-v1",
        "recordedUTC": datetime.now(timezone.utc).isoformat(),
        "status": "Support staged before main Xcode CodeSign; main signature, profile, nested verification and runtime are root-owned and OPEN",
        "workspace": str(distribution.ROOT), "product": str(contents.parent),
        "configuration": {name: setting(name) for name in (*REQUIRED_SETTINGS, "CURRENT_PROJECT_VERSION", "ARCHS", "CURRENT_ARCH", "CODE_SIGN_ENTITLEMENTS", "CONTENTS_FOLDER_PATH")},
        "signingIdentity": {"certificateSHA1": identity, "name": configuration["identity_name"]},
        "helper": {"source": str(inputs["helper"]), "sourceSHA256": HELPER_SHA, "sourceBytes": HELPER_BYTES,
                   "unsignedPayloadSHA256": HELPER_PAYLOAD_SHA, "compositionReceiptSHA256": COMPOSITION_RECEIPT_SHA,
                   "architecture": HELPER_ARCHITECTURE, "codexBarRevision": CODEXBAR_REVISION,
                   "codexBarBaseRevision": CODEXBAR_REVISION,
                   "sourceManifestSHA256": CODEXBAR_SOURCE_MANIFEST_SHA256,
                   "sourceIdentity": "Complete manifested dirty source; base revision alone does not contain the fix",
                   "stagedPath": "Contents/Helpers/CodexBarCLI",
                   "stagedSHA256": staged_helper, "action": helper_action, "signature": helper_details},
        "resourceBundles": [{"name": name, "treeSHA256": RESOURCE_TREES[name], "action": bundle_actions[name],
                             "stagedPath": "Contents/Resources/" + name} for name in distribution.HELPER_RESOURCE_BUNDLES],
        "mcp": {"source": str(MCP), "sha256": hashlib.sha256(inputs["mcp"]).hexdigest(),
                "action": file_actions["peel_mcp_server.py"], "stagedPath": "Contents/Resources/peel_mcp_server.py"},
        "signingPolicy": {"source": str(distribution.POLICY), "sha256": ENTITLEMENTS_SHA,
                          "action": file_actions["PeelSigningEntitlements.plist"]},
        "notices": {"inputs": inputs["notice_items"], "sha256": hashlib.sha256(inputs["notices"]).hexdigest(),
                    "action": file_actions["COMPONENT_NOTICES.txt"]},
        "scripts": {"stage-host-development-support.py": distribution.sha(Path(__file__)),
                    "host-distribution.py": normalizer,
                    "hostDistributionIsAuditedNormalizer": normalizer == AUDITED_NORMALIZER_SHA,
                    "project.pbxproj": distribution.sha(distribution.PROJECT / "project.pbxproj")},
        "limits": "Private Apple Development build only. Not Developer ID, notarization, distribution, installation, "
                  "provider account access or physical acceptance; main app signature and profile coverage are not checked here.",
    }
    write_receipt(configuration["derived"] / RECEIPT_NAME, receipt)
    print("Peel development support: audited helper (" + helper_action + "), three resource bundles, current MCP, "
          "policy and notices staged before main CodeSign; receipt " + str(configuration["derived"] / RECEIPT_NAME))


def inspect(helper_directory):
    """Read-only freeze aid for root: pure hashes only, never codesign."""
    inputs = verified_inputs(helper_directory)
    normalizer = distribution.sha(Path(distribution.__file__))
    print(json.dumps({
        "helperDirectory": str(inputs["directory"]), "helperSHA256": HELPER_SHA,
        "architecture": HELPER_ARCHITECTURE, "codexBarBaseRevision": CODEXBAR_REVISION,
        "sourceManifestSHA256": CODEXBAR_SOURCE_MANIFEST_SHA256,
        "unsignedPayloadSHA256": HELPER_PAYLOAD_SHA, "unsignedPayloadVerified": "at stage time only (needs codesign)",
        "resourceTrees": RESOURCE_TREES, "entitlementsSHA256": ENTITLEMENTS_SHA,
        "PEEL_DEVELOPMENT_MCP_SHA256": hashlib.sha256(inputs["mcp"]).hexdigest(),
        "PEEL_DEVELOPMENT_NOTICES_SHA256": hashlib.sha256(inputs["notices"]).hexdigest(),
        "noticeInputs": inputs["notice_items"],
        "stage-host-development-support.py": distribution.sha(Path(__file__)),
        "host-distribution.py": normalizer, "hostDistributionIsAuditedNormalizer": normalizer == AUDITED_NORMALIZER_SHA,
        "project.pbxproj": distribution.sha(distribution.PROJECT / "project.pbxproj"),
    }, indent=2, sort_keys=True))


def main():
    if len(sys.argv) > 1:
        parser = argparse.ArgumentParser(description=__doc__)
        sub = parser.add_subparsers(dest="action", required=True)
        check = sub.add_parser("inspect", help="read-only pure-hash input check; prints values for root's freeze")
        check.add_argument("--helper-directory", required=True)
        args = parser.parse_args()
        inspect(args.helper_directory)
        return
    if setting("PEEL_STAGE_DEVELOPMENT_SUPPORT") != "YES":
        print("Peel development support phase: skipped (opt-in PEEL_STAGE_DEVELOPMENT_SUPPORT=YES)")
        return
    stage_for_xcode()


if __name__ == "__main__":
    try:
        main()
    except (Gate, OSError, ValueError, KeyError) as error:
        print("GATE: " + str(error), file=sys.stderr)
        sys.exit(2)
