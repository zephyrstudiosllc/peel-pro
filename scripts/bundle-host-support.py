#!/usr/bin/env python3
"""Opt-in Xcode phase: copy reviewed support inputs BEFORE main CodeSign.

Never signs, builds, changes an archive after creation or creates authorization.
Normal existing builds skip this phase; build-host.sh keeps its existing bundler.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("peel_distribution", Path(__file__).with_name("host-distribution.py"))
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)


def validate_resource_destination(destination, source):
    """Xcode may precreate declared output parents, but never accept old data."""
    if destination.is_symlink():
        raise distribution.Gate("symlinked support bundle output")
    if not destination.exists():
        return
    if not destination.is_dir():
        raise distribution.Gate("support bundle output is not an empty directory scaffold")
    for path in destination.rglob("*"):
        expected = source / path.relative_to(destination)
        if path.is_symlink() or not path.is_dir() or expected.is_symlink() or not expected.is_dir():
            raise distribution.Gate("support bundle output contains existing data or unexpected paths")


def bundle():
    if os.environ.get("PEEL_BUNDLE_ARCHIVE_SUPPORT") != "YES":
        print("Peel archive support phase: skipped (existing build-host.sh path)")
        return
    if os.environ.get("CONFIGURATION") != "Release" or os.environ.get("CODE_SIGNING_ALLOWED") != "YES":
        raise distribution.Gate("archive support requires a signing-enabled Release build")
    manifest_path = Path(os.environ.get("PEEL_ARCHIVE_SUPPORT_MANIFEST", ""))
    if not manifest_path.is_absolute() or manifest_path.is_symlink() or not manifest_path.resolve().is_relative_to(distribution.ROOT / ".build"):
        raise distribution.Gate("archive support requires the explicit private workspace support manifest")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("format") not in ("peel-archive-support-v1", "peel-archive-support-v2") or manifest.get("workspace") != str(distribution.ROOT):
        raise distribution.Gate("archive support manifest scope mismatch")
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    if app.name != "Contents" or app.parent.name != "Peel Pro.app" or app.is_symlink() or app.parent.is_symlink():
        raise distribution.Gate("archive support output is not the current target's Host Contents")
    if not app.resolve().is_relative_to(distribution.ROOT / ".build"):
        raise distribution.Gate("archive target must be in this workspace's private .build tree")
    for key in ("helper", "helper_resources", "mcp", "signing_policy"):
        path = Path(manifest[key])
        if path.is_symlink() or not path.resolve().is_relative_to(distribution.ROOT):
            raise distribution.Gate("archive support input escapes workspace")
    resource_bundles = distribution.checked_helper_resource_sources(manifest)
    for item in resource_bundles:
        path = Path(item["path"])
        if path.is_symlink() or not path.resolve().is_relative_to(distribution.ROOT):
            raise distribution.Gate("archive support resource input escapes workspace")
    for key in ("helper", "mcp", "signing_policy"):
        if distribution.sha(manifest[key]) != manifest[key + "_sha256"]:
            raise distribution.Gate("archive support input changed: " + key)
    if manifest["mcp_sha256"] != distribution.MCP_SHA:
        raise distribution.Gate("wrong MCP adapter identity")
    distribution.require_universal_helper_resources(manifest["helper"], manifest)
    distribution.code_details(manifest["helper"], manifest["certificate_sha1"], distribution.BUNDLE + ".CodexBarCLI")
    if distribution.embedded_entitlements(manifest["helper"]):
        raise distribution.Gate("prepared helper must be entitlement-free")
    for directory in (app / "Helpers", app / "Resources"):
        if directory.is_symlink():
            raise distribution.Gate("symlinked archive support output")
        directory.mkdir(parents=True, exist_ok=True)
    helper = app / "Helpers/CodexBarCLI"
    resources = app / "Resources"
    for path in (helper, resources / "peel_mcp_server.py", resources / "PeelSigningEntitlements.plist", resources / "COMPONENT_NOTICES.txt"):
        if path.is_symlink():
            raise distribution.Gate("symlinked archive support file")
    shutil.copy2(manifest["helper"], helper)
    shutil.copy2(manifest["mcp"], resources / "peel_mcp_server.py")
    shutil.copy2(manifest["signing_policy"], resources / "PeelSigningEntitlements.plist")
    for item in resource_bundles:
        bundle_path = resources / item["name"]
        validate_resource_destination(bundle_path, Path(item["path"]))
    for item in resource_bundles:
        distribution.command(["/usr/bin/ditto", item["path"], resources / item["name"]])
    text = distribution.notice_text(manifest["notices"])
    import hashlib
    if hashlib.sha256(text.encode()).hexdigest() != manifest["component_notices_sha256"]:
        raise distribution.Gate("component notice manifest mismatch")
    (resources / "COMPONENT_NOTICES.txt").write_text(text)
    if distribution.sha(helper) != manifest["helper_sha256"] or distribution.sha(resources / "peel_mcp_server.py") != distribution.MCP_SHA:
        raise distribution.Gate("archive support copy failed identity check")
    distribution.check_app_helper_resources(resources, manifest)
    print("Peel archive support: reviewed helper/resources/current MCP copied before main CodeSign")


if __name__ == "__main__":
    try:
        bundle()
    except (distribution.Gate, OSError, ValueError, KeyError) as error:
        print("GATE: " + str(error), file=sys.stderr)
        sys.exit(2)
