#!/usr/bin/env python3
"""Official Xcode archive/export path; plan is read-only, run is explicit and separate.

No main-app codesign/profile/archive metadata forging. Static receipts are not
notarization, system authorization, launch, CloudKit or updater acceptance.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile

if sys.version_info < (3, 9):
    print("GATE: Python3.9 or newer is required", file=sys.stderr)
    sys.exit(2)

TEAM = "V729QMY3V6"
BUNDLE = "com.zephyrstudiosllc.Peel-Host"
CONTAINER = "iCloud.com.zephyrstudiosllc.Peel"
CERTIFICATE = "A1FF9429A62A6B0A958A48010BDF02771748D7C8"
CORE_RESOURCE_BUNDLE = "CodexBar_CodexBarCore.bundle"
HELPER_RESOURCE_BUNDLES = (CORE_RESOURCE_BUNDLE, "SweetCookieKit_SweetCookieKit.bundle", "swift-crypto_Crypto.bundle")
MCP_SHA = "ec0d526e7f10844ff84952527eb6fcdf5c9119efd7d3b7798f4a3501b3085b75"
ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "Sources/PeelHost/Peel-Host/PeelHost.entitlements"
PROJECT = ROOT / "Sources/PeelHost/Peel-Host.xcodeproj"


class Gate(Exception):
    pass


def command(args, **kwargs):
    result = subprocess.run([str(x) for x in args], capture_output=True, **kwargs)
    if result.returncode:
        # Provisioning logs may contain account/device/profile details. Preserve them only
        # in the explicit private run directory; don't dump tool output into error messages.
        raise Gate("command failed: " + str(args[0]))
    return result


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tree_digest(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise Gate("resource bundle must be a real directory")
    entries = []
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            if not path.resolve().is_relative_to(root.resolve()):
                raise Gate("resource symlink escapes bundle")
            entries.append([relative, "symlink", str(path.readlink())])
        elif path.is_file():
            entries.append([relative, "file", sha(path)])
        elif not path.is_dir():
            raise Gate("unsupported resource file type")
    if not entries:
        raise Gate("empty helper resource bundle")
    return hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()


def helper_resource_bundles(manifest):
    """Keep old receipts exact; new universal receipts enumerate the whole set."""
    plural = manifest.get("helper_resource_bundles")
    if plural is None:
        if manifest.get("format") == "peel-archive-support-v2":
            raise Gate("plural helper resources are missing")
        return [{"name": CORE_RESOURCE_BUNDLE, "path": manifest.get("helper_resources"),
                 "sha256": manifest["helper_resources_sha256"]}]
    if manifest.get("format") != "peel-archive-support-v2" or not isinstance(plural, list) or len(plural) != 3:
        raise Gate("invalid plural helper resource manifest")
    result = {}
    for item in plural:
        if not isinstance(item, dict) or set(item) != {"name", "path", "sha256"}:
            raise Gate("invalid helper resource entry")
        name, path, digest = item["name"], item["path"], item["sha256"]
        if (not isinstance(name, str) or name not in HELPER_RESOURCE_BUNDLES or name in result
                or not isinstance(path, str) or not Path(path).is_absolute() or Path(path).name != name
                or any(c in path for c in ("\x00", "\n", "\r"))
                or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise Gate("invalid, duplicate or unexpected helper resource entry")
        result[name] = dict(item)
    if set(result) != set(HELPER_RESOURCE_BUNDLES):
        raise Gate("helper resource bundle set is incomplete")
    core = result[CORE_RESOURCE_BUNDLE]
    if core["path"] != manifest.get("helper_resources") or core["sha256"] != manifest.get("helper_resources_sha256"):
        raise Gate("legacy Core resource identity differs from plural manifest")
    return [result[name] for name in HELPER_RESOURCE_BUNDLES]


def validate_resource_payload(root):
    """These reviewed bundles are data, never another nested-code slot."""
    root = Path(root)
    tree_digest(root)
    try:
        info = plistlib.loads((root / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise Gate("helper resource bundle Info.plist is missing or invalid") from None
    if not isinstance(info, dict) or info.get("CFBundlePackageType") != "BNDL" or "CFBundleExecutable" in info:
        raise Gate("helper resource bundle declares executable content")
    native_magics = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca", b"\x7fELF"}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise Gate("plural helper resource symlinks are not supported")
        if path.is_file():
            with path.open("rb") as stream:
                magic = stream.read(4)
            if path.stat().st_mode & 0o111 or magic in native_magics or magic[:2] in (b"MZ", b"#!"):
                raise Gate("executable content in helper resource bundle")


def checked_helper_resource_sources(manifest):
    entries = helper_resource_bundles(manifest)
    for item in entries:
        if not item["path"] or tree_digest(Path(item["path"])) != item["sha256"]:
            raise Gate("helper resources changed before staging or output declaration")
        if "helper_resource_bundles" in manifest:
            validate_resource_payload(Path(item["path"]))
    return entries


def require_universal_helper_resources(helper, manifest):
    with Path(helper).open("rb") as stream:
        universal = stream.read(4) in FAT_HELPER_MAGICS
    if universal and manifest.get("format") != "peel-archive-support-v2":
        raise Gate("universal helper requires the complete plural resource bundle set")
    if universal:
        helper_resource_bundles(manifest)


def check_app_helper_resources(resources, manifest):
    for item in helper_resource_bundles(manifest):
        path = Path(resources) / item["name"]
        if tree_digest(path) != item["sha256"]:
            raise Gate("exported helper resources differ from reviewed inputs")
        if "helper_resource_bundles" in manifest:
            validate_resource_payload(path)


def prepare_helper_resources(manifest, destination):
    prepared = []
    for item in checked_helper_resource_sources(manifest):
        target = Path(destination) / item["name"]
        if target.exists() or target.is_symlink():
            raise Gate("prepared helper resource destination already exists")
        command(["/usr/bin/ditto", item["path"], target])
        prepared.append(dict(item, path=str(target)))
    result = dict(manifest, helper_resources=prepared[0]["path"])
    if "helper_resource_bundles" in manifest:
        result["helper_resource_bundles"] = prepared
    checked_helper_resource_sources(result)
    return result


def compare_helper_resource_outputs(first, second):
    """Read-only admission for combining CPU builds; never choose one on mismatch."""
    results = []
    for root in (Path(first), Path(second)):
        if root.is_symlink() or {path.name for path in root.glob("*.bundle")} != set(HELPER_RESOURCE_BUNDLES):
            raise Gate("native helper output bundle set differs from the reviewed exact set")
    for name in HELPER_RESOURCE_BUNDLES:
        left, right = Path(first) / name, Path(second) / name
        validate_resource_payload(left)
        validate_resource_payload(right)
        digest = tree_digest(left)
        if digest != tree_digest(right):
            raise Gate("CPU resource payload mismatch: " + name)
        results.append({"name": name, "sha256": digest})
    return results


def restricted(entitlements):
    # Unknown future developer/app/keychain rights must not silently use direct signing.
    return sorted(key for key in entitlements if key.startswith("com.apple.developer.")
                  or key in ("application-identifier", "com.apple.application-identifier", "keychain-access-groups", "aps-environment"))


def decoded_profile(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024*1024:
        raise Gate("missing or invalid embedded provisioning profile")
    raw = command(["/usr/bin/security", "cms", "-D", "-i", path]).stdout
    try:
        profile = plistlib.loads(raw)
    except Exception:
        raise Gate("profile cannot be decoded") from None
    if not isinstance(profile, dict):
        raise Gate("invalid profile data")
    return profile


def allowed(actual, grant):
    if isinstance(actual, list):
        candidates = grant if isinstance(grant, list) else [grant]
        return all(any(allowed(item, value) for value in candidates) for item in actual)
    if isinstance(grant, list):
        return any(allowed(actual, item) for item in grant)
    if isinstance(actual, str) and isinstance(grant, str):
        return actual == grant or (grant.endswith("*") and grant.count("*") == 1 and actual.startswith(grant[:-1]))
    return type(actual) is type(grant) and actual == grant


def validate_profile_metadata(profile, certificate_sha1=CERTIFICATE, signed=None, distribution=True):
    """No raw profile/UDIDs/certificates in returned receipt. Does not claim runtime trust."""
    if distribution and (profile.get("ProvisionsAllDevices") is not True or "ProvisionedDevices" in profile):
        raise Gate("Developer ID all-device distribution authorization is missing; development/registered-device profile is forbidden")
    if profile.get("TeamIdentifier") != [TEAM] or "OSX" not in profile.get("Platform", []):
        raise Gate("profile team/platform mismatch")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime) or expires.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise Gate("profile is expired or has no expiration date")
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("com.apple.application-identifier") != TEAM + "." + BUNDLE:
        raise Gate("profile must authorize the exact Host application identifier")
    if entitlements.get("com.apple.developer.team-identifier") != TEAM:
        raise Gate("profile entitlement team mismatch")
    certs = profile.get("DeveloperCertificates", [])
    if not any(isinstance(x, bytes) and hashlib.sha1(x).hexdigest().upper() == certificate_sha1.upper() for x in certs):
        raise Gate("profile does not authorize the actual selected Developer ID leaf certificate")
    expected = {"com.apple.developer.icloud-container-identifiers": [CONTAINER],
                "com.apple.developer.icloud-services": ["CloudKit"],
                "com.apple.developer.icloud-container-environment": "Production" if distribution else "Development",
                "com.apple.developer.aps-environment": "production" if distribution else "development"}
    for key, value in expected.items():
        if key not in entitlements or not allowed(value, entitlements[key]):
            raise Gate("distribution profile does not authorize required " + key)
    for key in ("get-task-allow", "com.apple.security.get-task-allow"):
        if distribution and entitlements.get(key) is True:
            raise Gate("distribution profile authorizes debugging")
    if signed is not None:
        for key in restricted(signed):
            if key not in entitlements or not allowed(signed[key], entitlements[key]):
                raise Gate("signed restricted entitlement is not authorized by embedded profile: " + key)
    return {"uuid": profile.get("UUID"), "name": profile.get("Name"),
            "expiration": expires.isoformat(), "platform": profile["Platform"],
            "team": TEAM, "provisions_all_devices": profile.get("ProvisionsAllDevices") is True,
            "distribution_audit": distribution,
            "certificate_sha1": certificate_sha1.upper(), "profile_authorization_metadata": "PASS"}


def code_details(path, expected_certificate=CERTIFICATE, identifier=None, distribution=True):
    # The normal display command reports only one architecture. A universal
    # helper must independently satisfy the same certificate/runtime/timestamp
    # rules for EVERY actual slice, never just the host's preferred slice.
    candidate = Path(path)
    if candidate.is_file():
        original = candidate.read_bytes()
        if original[:4] in FAT_HELPER_MAGICS:
            slices = helper_fat_slices(original)
            command(["/usr/bin/codesign", "--verify", "--strict", path])
            per_arch = {}
            with tempfile.TemporaryDirectory(prefix="peel-universal-signatures-") as directory:
                for item in slices:
                    member = Path(directory) / item["architecture"]
                    member.write_bytes(item["data"])
                    per_arch[item["architecture"]] = code_details(member, expected_certificate, identifier, distribution)
            if len({value["certificate_sha1"] for value in per_arch.values()}) != 1:
                raise Gate("universal helper slices use different signing certificates")
            result = dict(next(iter(per_arch.values())))
            result["architectures"] = per_arch
            return result
    command(["/usr/bin/codesign", "--verify", "--strict", path])
    details = command(["/usr/bin/codesign", "-d", "--verbose=4", path]).stderr.decode(errors="replace")
    authority = "Authority=Developer ID Application:" in details
    if "TeamIdentifier=" + TEAM not in details or not (authority or (not distribution and "Authority=Apple Development:" in details)):
        raise Gate("code is not signed by the required team/certificate type")
    timestamped = bool(re.search(r"^Timestamp=.+", details, re.M))
    if "Signature=adhoc" in details or (distribution and not timestamped):
        raise Gate("Developer ID signature requires a secure timestamp")
    flags = re.search(r"flags=0x([0-9a-fA-F]+)", details)
    if not flags or not int(flags[1], 16) & 0x10000:
        raise Gate("Hardened Runtime is missing")
    if identifier and "Identifier=" + identifier + "\n" not in details:
        raise Gate("code identifier mismatch")
    with tempfile.TemporaryDirectory(prefix="peel-public-cert-") as directory:
        prefix = str(Path(directory) / "certificate")
        command(["/usr/bin/codesign", "-d", "--extract-certificates=" + prefix, path])
        leaf = Path(prefix + "0")
        if not leaf.is_file():
            raise Gate("actual code-signing leaf certificate is missing")
        actual_certificate = hashlib.sha1(leaf.read_bytes()).hexdigest().upper()
        if expected_certificate and actual_certificate != expected_certificate.upper():
            raise Gate("actual code-signing leaf certificate differs from selected certificate")
    cdhash = re.search(r"^CDHash=(.+)$", details, re.M)
    return {"certificate_sha1": actual_certificate, "cdhash": cdhash[1] if cdhash else None,
            "hardened_runtime": True, "secure_timestamp": timestamped, "developer_id": authority}


def embedded_entitlements(app):
    candidate = Path(app)
    if candidate.is_file():
        original = candidate.read_bytes()
        if original[:4] in FAT_HELPER_MAGICS:
            slices = helper_fat_slices(original)
            with tempfile.TemporaryDirectory(prefix="peel-universal-entitlements-") as directory:
                for item in slices:
                    member = Path(directory) / item["architecture"]
                    member.write_bytes(item["data"])
                    if embedded_entitlements(member):
                        raise Gate("universal helper slice has entitlements")
            return {}
    raw = command(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app]).stdout
    if not raw.strip():
        return {}
    try:
        value = plistlib.loads(raw)
    except Exception:
        raise Gate("signed entitlements are not readable") from None
    if not isinstance(value, dict):
        raise Gate("signed entitlements must be a dictionary")
    return value


def helper_macho_layout(data):
    """Bounded thin executable parser; unsupported formats require explicit review."""
    if len(data) < 32:
        raise Gate("truncated helper Mach-O header")
    magic, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from("<8I", data)
    page_sizes = {0x0100000C: 16384, 0x01000007: 4096}  # arm64, x86_64
    if magic != 0xFEEDFACF or cpu not in page_sizes or kind != 2 or reserved:
        raise Gate("unsupported helper Mach-O executable format")
    end = 32 + command_bytes
    if not count or count > command_bytes // 8 or end > len(data):
        raise Gate("invalid helper Mach-O load-command bounds")
    offset, segments, signatures = 32, {}, []
    for _ in range(count):
        if offset + 8 > end:
            raise Gate("truncated helper Mach-O load command")
        command_id, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 8 or size > end - offset:
            raise Gate("invalid helper Mach-O load-command size")
        if command_id == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise Gate("truncated helper Mach-O segment")
            _, _, name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sections, segflags = struct.unpack_from("<II16s4Q4I", data, offset)
            if size != 72 + sections * 80 or name in segments or fileoff + filesize > len(data) or vmsize < filesize:
                raise Gate("invalid helper Mach-O segment bounds")
            segments[name] = {"command_offset": offset, "vmaddr": vmaddr, "vmsize": vmsize,
                              "fileoff": fileoff, "filesize": filesize, "sections": sections}
        elif command_id == 0x1D:  # LC_CODE_SIGNATURE
            if size != 16:
                raise Gate("invalid helper Mach-O signature command")
            signatures.append(struct.unpack_from("<II", data, offset + 8))
        offset += size
    if offset != end or len(signatures) > 1:
        raise Gate("invalid helper Mach-O command table")
    linkedit = segments.get(b"__LINKEDIT".ljust(16, b"\0"))
    page = page_sizes[cpu]
    if (linkedit is None or linkedit["sections"] or not linkedit["filesize"]
            or linkedit["fileoff"] < end or linkedit["fileoff"] + linkedit["filesize"] != len(data)
            or linkedit["fileoff"] % page or linkedit["vmaddr"] % page):
        raise Gate("invalid terminal helper __LINKEDIT segment")
    for segment in segments.values():
        if segment is not linkedit and segment["filesize"] and segment["fileoff"] + segment["filesize"] > linkedit["fileoff"]:
            raise Gate("helper segments overlap __LINKEDIT")
    return {"cpu": cpu, "page_size": page, "linkedit": linkedit, "signatures": signatures}


def normalized_unsigned_helper(original, unsigned):
    """Normalize only stale __LINKEDIT VM padding left by Apple's signature removal.

    Require exact 4K/16K signed VM rounding, unchanged segment placement and a
    terminal signature. Apple's remover may also discard at most 15 zero bytes
    aligning that signature to 16 bytes. Canonical VM rounding remains the old
    architecture page size; every other returned unsigned byte remains hashed.
    """
    before, after = helper_macho_layout(original), helper_macho_layout(unsigned)
    old, new = before["linkedit"], after["linkedit"]
    page = before["page_size"]
    rounded = lambda size: (size + page - 1) // page * page
    if before["cpu"] != after["cpu"] or len(before["signatures"]) != 1 or after["signatures"]:
        raise Gate("unexpected helper signature-removal structure")
    signature_offset, signature_size = before["signatures"][0]
    alignment_gap = signature_offset - len(unsigned)
    signed_pages = (page, 16384) if before["cpu"] == 0x01000007 and old["fileoff"] % 16384 == 0 else (page,)
    valid_signed_vm = any(old["vmsize"] == (old["filesize"] + unit - 1) // unit * unit for unit in signed_pages)
    if (not signature_size or signature_offset % 16 or signature_offset < old["fileoff"]
            or signature_offset + signature_size != len(original)
            or not 0 <= alignment_gap <= 15 or any(original[len(unsigned):signature_offset])
            or not valid_signed_vm
            or any(old[key] != new[key] for key in ("vmaddr", "fileoff", "vmsize"))
            or new["filesize"] != len(unsigned) - old["fileoff"]):
        raise Gate("unexpected helper __LINKEDIT signature padding")
    normalized = bytearray(unsigned)
    struct.pack_into("<Q", normalized, new["command_offset"] + 32, rounded(new["filesize"]))
    return bytes(normalized)


FAT_HELPER_MAGICS = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
                     b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca")


def helper_fat_slices(data):
    """Bounded FAT32/FAT64 wrapper for precisely arm64-all + x86_64-all.

    Apple's mach-o/fat.h defines big-endian tables and zero padding. Reject
    aliases, hidden/trailing data, overlaps and mismatching thin headers. The
    existing strict thin parser remains the sole slice/load-command validator.
    """
    if len(data) < 8:
        raise Gate("truncated universal helper header")
    magic, count = struct.unpack_from(">II", data)
    if magic not in (0xCAFEBABE, 0xCAFEBABF) or count != 2:
        raise Gate("unsupported universal helper format or architecture count")
    size = 20 if magic == 0xCAFEBABE else 32
    table_end = 8 + count * size
    if table_end > len(data):
        raise Gate("truncated universal helper architecture table")
    expected = {0x01000007: (3, "x86_64"), 0x0100000C: (0, "arm64")}
    members, seen = [], set()
    for index in range(count):
        record = 8 + index * size
        if size == 20:
            cpu, subtype, offset, length, alignment = struct.unpack_from(">IIIII", data, record)
        else:
            cpu, subtype, offset, length, alignment, reserved = struct.unpack_from(">IIQQII", data, record)
            if reserved:
                raise Gate("universal helper reserved field is nonzero")
        if cpu not in expected or cpu in seen or subtype != expected[cpu][0]:
            raise Gate("universal helper architecture identity is unsupported or duplicated")
        if (alignment > 30 or offset < table_end or offset % (1 << alignment)
                or length < 32 or offset > len(data) or length > len(data) - offset):
            raise Gate("universal helper slice bounds or alignment are invalid")
        member = data[offset:offset + length]
        header_cpu, header_subtype = struct.unpack_from("<II", member, 4)
        if (header_cpu, header_subtype) != (cpu, subtype):
            raise Gate("universal helper slice header differs from its architecture table")
        helper_macho_layout(member)
        members.append({"cpu": cpu, "subtype": subtype, "architecture": expected[cpu][1],
                        "offset": offset, "end": offset + length, "data": member})
        seen.add(cpu)
    previous = table_end
    for item in sorted(members, key=lambda value: value["offset"]):
        if item["offset"] < previous:
            raise Gate("universal helper slices overlap")
        if any(data[previous:item["offset"]]):
            raise Gate("universal helper padding contains unclaimed data")
        previous = item["end"]
    if previous != len(data):
        raise Gate("universal helper has trailing unclaimed data")
    return sorted(members, key=lambda value: value["cpu"])


def unsigned_payload_digest(path):
    # Only disposable copies are stripped; validate the real signed input first.
    original = Path(path).read_bytes()
    if original[:4] in FAT_HELPER_MAGICS:
        slices = helper_fat_slices(original)
        command(["/usr/bin/codesign", "--verify", "--strict", path])
        payloads = []
        # Let Apple's thin signature removal run on each disposable slice copy.
        # This avoids assuming how codesign repacks a FAT file after removal.
        with tempfile.TemporaryDirectory(prefix="peel-universal-payload-") as directory:
            for item in slices:
                member = Path(directory) / item["architecture"]
                member.write_bytes(item["data"])
                payloads.append([item["cpu"], item["subtype"], unsigned_payload_digest(member)])
        identity = {"format": "peel-universal-helper-payload-v1", "slices": payloads}
        return hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    helper_macho_layout(original)
    command(["/usr/bin/codesign", "--verify", "--strict", path])
    with tempfile.TemporaryDirectory(prefix="peel-helper-payload-") as directory:
        copy = Path(directory) / "CodexBarCLI"
        shutil.copy2(path, copy)
        command(["/usr/bin/codesign", "--remove-signature", copy])
        return hashlib.sha256(normalized_unsigned_helper(original, copy.read_bytes())).hexdigest()


def source_release_fields():
    project = json.loads(command(["/usr/bin/plutil", "-convert", "json", "-o", "-", PROJECT / "project.pbxproj"]).stdout)
    objects = project["objects"]
    target = next(value for value in objects.values() if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Peel-Host")
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    release = next(objects[item]["buildSettings"] for item in configurations if objects[item]["name"] == "Release")
    info = plistlib.loads((ROOT / "Sources/PeelHost/Peel-Host/Info.plist").read_bytes())
    return {"version": str(release["MARKETING_VERSION"]), "build": str(release["CURRENT_PROJECT_VERSION"]),
            "feed_url": info["SUFeedURL"], "sparkle_public_ed_key": info["SUPublicEDKey"],
            "team": release["DEVELOPMENT_TEAM"], "bundle": release["PRODUCT_BUNDLE_IDENTIFIER"]}


def notice_text(items):
    pieces = ["Peel Pro — component notices\n"]
    for item in items:
        path = Path(item["path"])
        if not path.resolve().is_relative_to(ROOT) or sha(path) != item["sha256"]:
            raise Gate("component notice input changed")
        pieces.append(path.read_text())
    return "\n\n".join(pieces) + "\n"


def support_inputs(args):
    # Inspect supplied entries before resolve() erases their symlink identity.
    helper_input = Path(args.helper).expanduser()
    resources_input = Path(args.helper_resources).expanduser()
    if helper_input.is_symlink() or resources_input.is_symlink():
        raise Gate("helper and resource inputs must not be symlinked")
    helper, resources = helper_input.resolve(), resources_input.resolve()
    if not helper.is_file() or helper.is_symlink() or not helper.stat().st_mode & 0o111:
        raise Gate("helper input is missing or non-executable")
    if sha(helper) != args.helper_sha256 or tree_digest(resources) != args.helper_resources_sha256:
        raise Gate("trusted helper/resource input hash mismatch")
    adapter = ROOT / "Tools/PeelMCP/peel_mcp_server.py"
    if sha(adapter) != MCP_SHA:
        raise Gate("current MCP source differs from the reviewed nine-tool adapter; review/update the pinned packaging hash")
    notices = [ROOT / name for name in ("Sources/SidePulse/LICENSE", "Sources/SidePulse/NOTICE",
                                      "Sources/CodexBar/LICENSE", "Sources/CodexBar/Sources/CQuickJS/LICENSE")]
    notice_items = [{"path": str(x), "sha256": sha(x)} for x in notices]
    manifest = {"format": "peel-archive-support-v1", "workspace": str(ROOT),
            "helper": str(helper), "helper_sha256": sha(helper),
            "helper_resources": str(resources), "helper_resources_sha256": tree_digest(resources),
            "mcp": str(adapter), "mcp_sha256": MCP_SHA,
            "signing_policy": str(POLICY), "signing_policy_sha256": sha(POLICY),
            "source_release": source_release_fields(),
            "notices": notice_items, "component_notices_sha256": hashlib.sha256(notice_text(notice_items).encode()).hexdigest()}
    additional = getattr(args, "additional_helper_resource", []) or []
    universal = helper.read_bytes()[:4] in FAT_HELPER_MAGICS
    if additional:
        entries = [{"name": CORE_RESOURCE_BUNDLE, "path": str(resources), "sha256": args.helper_resources_sha256}]
        for name, path, digest in additional:
            candidate = Path(path).expanduser()
            if not candidate.is_absolute() or candidate.is_symlink():
                raise Gate("additional helper resources must be absolute real directories")
            entries.append({"name": name, "path": str(candidate.resolve()), "sha256": digest})
        manifest.update(format="peel-archive-support-v2", helper_resource_bundles=entries)
        checked_helper_resource_sources(manifest)
    elif universal:
        raise Gate("universal helper requires the complete plural resource bundle set")
    return manifest


def selected_distribution_profile(args):
    path = getattr(args, "distribution_profile", None)
    if not path:
        return None
    if getattr(args, "allow_provisioning_updates", False):
        raise Gate("manual distribution profile cannot be combined with provisioning updates")
    path = Path(path).expanduser()
    if not path.is_absolute():
        raise Gate("distribution profile must use an absolute path")
    metadata = validate_profile_metadata(decoded_profile(path), args.certificate_sha1)
    profile_uuid = metadata.get("uuid")
    if not isinstance(profile_uuid, str) or not re.fullmatch(
            r"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}", profile_uuid):
        raise Gate("distribution profile must have an actual valid UUID")
    return dict(metadata, path=str(path), profile_sha256=sha(path))


def export_options(profile_uuid=None, certificate=CERTIFICATE):
    options = {"method": "developer-id", "destination": "export", "teamID": TEAM,
               "signingStyle": "automatic", "iCloudContainerEnvironment": "Production",
               "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": False}
    if profile_uuid is not None:
        options.update(signingStyle="manual", signingCertificate=certificate.upper(),
                       provisioningProfiles={BUNDLE: profile_uuid})
    return options


def validate_export_profile_selection(profile, certificate, selected):
    if selected is not None and (profile.get("uuid") != selected["uuid"]
                                 or certificate.upper() != selected["certificate_sha1"].upper()):
        raise Gate("exported profile UUID or signing certificate differs from selected distribution profile")


def support_output_file_list(manifest):
    """V2 declares every root and descendant, including the two new bundles."""
    outputs = []
    for item in checked_helper_resource_sources(manifest):
        resources = Path(item["path"])
        prefix = "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/" + item["name"]
        if "helper_resource_bundles" in manifest and item["name"] != CORE_RESOURCE_BUNDLE:
            outputs.append(prefix)
        for path in sorted(resources.rglob("*")):
            relative = path.relative_to(resources).as_posix()
            if any(character in relative for character in ("\n", "\r", "$")):
                raise Gate("helper resource path cannot be represented in an Xcode file list")
            outputs.append(prefix + "/" + relative)
    return "\n".join(outputs) + "\n"


def archive_commands(args, run_root, manifest_path):
    provisioning = ["-allowProvisioningUpdates"] if args.allow_provisioning_updates else []
    archive = ["xcodebuild", "-project", str(PROJECT), "-scheme", "Peel-Host", "-configuration", "Release",
               "-destination", "generic/platform=macOS", "-derivedDataPath", str(run_root / "DerivedData"),
               "-clonedSourcePackagesDirPath", str(ROOT / ".build/UnifiedHost/SourcePackages"),
               "-archivePath", str(run_root / "PeelHost.xcarchive"), "-jobs", "2",
               "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
               *provisioning, "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=" + TEAM,
               "CODE_SIGNING_ALLOWED=YES", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "PEEL_BUNDLE_ARCHIVE_SUPPORT=YES",
               "PEEL_ARCHIVE_SUPPORT_MANIFEST=" + str(manifest_path),
               "PEEL_ARCHIVE_SUPPORT_DIRECTORY=" + str(run_root / "support"),
               "PEEL_ARCHIVE_SUPPORT_OUTPUT_FILE_LIST=" + str(run_root / "support/support-outputs.xcfilelist"),
               "PEEL_DISTRIBUTION_PYTHON=" + sys.executable, "archive"]
    export = ["xcodebuild", "-exportArchive", "-archivePath", str(run_root / "PeelHost.xcarchive"),
              "-exportPath", str(run_root / "export"), "-exportOptionsPlist", str(run_root / "ExportOptions.plist"),
              *provisioning]
    return archive, export


def verify_export(app, manifest, version, build, feed_url, certificate=CERTIFICATE, archive=False):
    app = Path(app)
    if app.is_symlink() or not app.is_dir():
        raise Gate("exported Host app is missing or symlinked")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected_info = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "Peel Pro", "CFBundleDisplayName": "Peel Pro", "CFBundleName": "Peel Pro", "CFBundlePackageType": "APPL", "CFBundleVersion": build,
                     "CFBundleShortVersionString": version, "PeelBuildConfiguration": "Release", "SUFeedURL": feed_url}
    expected_info["SUPublicEDKey"] = manifest["source_release"]["sparkle_public_ed_key"]
    for key, value in expected_info.items():
        if info.get(key) != value:
            raise Gate("final exported Info.plist mismatch: " + key)
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    details = code_details(app, None if archive else certificate, BUNDLE, distribution=not archive)
    signed = embedded_entitlements(app)
    expected = {"com.apple.application-identifier": TEAM + "." + BUNDLE,
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.developer.icloud-container-identifiers": [CONTAINER],
                "com.apple.developer.icloud-services": ["CloudKit"],
                "com.apple.developer.icloud-container-environment": "Development" if archive else "Production",
                "com.apple.developer.aps-environment": "development" if archive else "production"}
    for key, value in expected.items():
        if signed.get(key) != value:
            raise Gate("final signed entitlement mismatch: " + key)
    if (signed.get("com.apple.security.app-sandbox") is True or (not archive and any(
            signed.get(key) is True for key in ("get-task-allow", "com.apple.security.get-task-allow")))):
        raise Gate("exported Host has debugging or sandbox entitlement")
    if "com.apple.developer.applesignin" in signed:
        raise Gate("native Apple sign-in is not authorized for this Developer ID Host path")
    profile_path = app / "Contents/embedded.provisionprofile"
    profile = validate_profile_metadata(decoded_profile(profile_path), details["certificate_sha1"], signed, distribution=not archive)
    if not archive:
        validate_export_profile_selection(profile, details["certificate_sha1"], manifest.get("distribution_profile"))
    resources = app / "Contents/Resources"
    if sha(resources / "peel_mcp_server.py") != manifest["mcp_sha256"] or manifest["mcp_sha256"] != MCP_SHA:
        raise Gate("exported current MCP adapter identity mismatch")
    if sha(resources / "PeelSigningEntitlements.plist") != manifest["signing_policy_sha256"]:
        raise Gate("exported declared source policy changed; it must not replace actual signed distribution grants")
    check_app_helper_resources(resources, manifest)
    helper = app / "Contents/Helpers/CodexBarCLI"
    require_universal_helper_resources(helper, manifest)
    helper_details = code_details(helper, certificate, BUNDLE + ".CodexBarCLI")
    final_payload = unsigned_payload_digest(helper)
    if final_payload != manifest["helper_payload_sha256"]:
        raise Gate("export changed the helper payload beyond a legitimate signature change")
    if embedded_entitlements(helper):
        raise Gate("this reviewed CodexBar helper must remain entitlement-free")
    if sha(resources / "COMPONENT_NOTICES.txt") != manifest["component_notices_sha256"]:
        raise Gate("component notices differ from the reviewed source")
    if any((app / "Contents/Helpers" / name).exists() or (app / "Contents/Helpers" / name).is_symlink()
           for name in ("peel_mcp_server.py", *HELPER_RESOURCE_BUNDLES)):
        raise Gate("resources are in a nested-code slot")
    return {"status": "PASS development archive static audit; not distributable" if archive else "PASS exported distribution static audit; runtime/notary/update gates OPEN", "app": str(app),
            "version": version, "build": build, "feed_url": feed_url, "signature": details,
            "profile": profile, "profile_sha256": sha(profile_path), "signed_entitlements": signed,
            "mcp_sha256": MCP_SHA, "helper": {"source_sha256": manifest["original_helper_sha256"],
            "source_signature": manifest["original_helper_signature"],
            "prepared_sha256": manifest["helper_sha256"], "prepared_signature": manifest["prepared_helper_signature"],
            "final_sha256": sha(helper), "final_signature": helper_details,
            "normalized_unsigned_payload_sha256": final_payload},
            "authorization_limits": "CMS decoded; metadata/certificate/signature correspondence checked; real system launch, service authorization, notarization and updater acceptance remain required"}


def verify_archive(archive, manifest, version, build, feed_url, certificate=CERTIFICATE):
    archive = Path(archive)
    metadata = plistlib.loads((archive / "Info.plist").read_bytes())
    properties = metadata.get("ApplicationProperties", {})
    if properties.get("ApplicationPath") != "Applications/Peel Pro.app":
        raise Gate("official archive is generic, lacks ApplicationProperties or names a different product; never forge archive metadata")
    app = archive / "Products" / properties["ApplicationPath"]
    result = verify_export(app, manifest, version, build, feed_url, certificate, archive=True)
    result["archive_info_sha256"] = sha(archive / "Info.plist")
    result["archive_application_path"] = properties["ApplicationPath"]
    return result


def write_json(path, value):
    with Path(path).open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    Path(path).chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    inspect = sub.add_parser("inspect-support", help="read-only helper/resource hash inspection")
    inspect.add_argument("--helper", required=True)
    inspect.add_argument("--helper-resources", required=True)
    policy = sub.add_parser("check-direct-policy", help="reject restricted rights before legacy manual review signing")
    policy.add_argument("--entitlements", required=True)
    check = sub.add_parser("check-profile", help="read-only distribution profile metadata gate; never prints raw profile")
    check.add_argument("--profile", required=True)
    check.add_argument("--certificate-sha1", default=CERTIFICATE)
    for name in ("plan", "run"):
        plan = sub.add_parser(name, help="read-only plan" if name == "plan" else "explicit real build/sign/archive/export; never installs/notarizes/publishes")
        plan.add_argument("--helper", required=True)
        plan.add_argument("--helper-resources", required=True)
        plan.add_argument("--helper-sha256", required=True)
        plan.add_argument("--helper-resources-sha256", required=True)
        plan.add_argument("--additional-helper-resource", nargs=3, action="append", default=[],
                          metavar=("BUNDLE_NAME", "ABSOLUTE_PATH", "TREE_SHA256"),
                          help="repeat for the exact SweetCookieKit and swift-crypto bundles; required for universal helpers")
        plan.add_argument("--run-root", required=True)
        plan.add_argument("--version", required=True)
        plan.add_argument("--build", required=True)
        plan.add_argument("--feed-url", required=True)
        plan.add_argument("--certificate-sha1", default=CERTIFICATE)
        plan.add_argument("--distribution-profile", help="existing authorized Developer ID profile for manual export; no provisioning updates")
        plan.add_argument("--allow-provisioning-updates", action="store_true")
    verify = sub.add_parser("verify", help="read-only exported app audit")
    for key in ("app", "manifest", "version", "build", "feed-url", "receipt"):
        verify.add_argument("--" + key, required=True)
    verify.add_argument("--certificate-sha1", default=CERTIFICATE)
    args = parser.parse_args()
    if args.action == "inspect-support":
        print(json.dumps({"helper_sha256": sha(args.helper), "helper_resources_sha256": tree_digest(Path(args.helper_resources))}, sort_keys=True))
        return
    if args.action == "check-direct-policy":
        value = plistlib.loads(Path(args.entitlements).read_bytes())
        if restricted(value):
            raise Gate("profile-restricted rights require the official Developer ID archive/export path; direct review signing is forbidden")
        print("PASS no profile-restricted entitlement requested")
        return
    if args.action == "check-profile":
        print(json.dumps(validate_profile_metadata(decoded_profile(args.profile), args.certificate_sha1), sort_keys=True))
        return
    if args.action == "verify":
        result = verify_export(args.app, json.loads(Path(args.manifest).read_text()), args.version, args.build, args.feed_url, args.certificate_sha1)
        write_json(args.receipt, result)
        print("PASS exported static audit; notarization, launch, CloudKit and installed updater gates remain OPEN")
        return
    from urllib.parse import urlparse
    url = urlparse(args.feed_url)
    if url.scheme != "https" or not url.hostname or url.hostname.endswith(".invalid") or url.username or url.password or url.query or url.fragment:
        raise Gate("an explicitly selected HTTPS update-feed URL is required")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", args.version) or not args.build.isdigit():
        raise Gate("explicit version and numeric build required")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", args.certificate_sha1):
        raise Gate("exact Developer ID certificate SHA1 required")
    run_root = Path(args.run_root).expanduser()
    if (not run_root.is_absolute() or run_root.exists() or run_root.is_symlink()
            or not run_root.parent.is_dir() or not run_root.parent.resolve().is_relative_to(ROOT / ".build")):
        raise Gate("run root must be an absent absolute path under this workspace's real .build directory")
    if any(path.is_symlink() for path in (run_root.parent, *run_root.parent.parents) if path.is_relative_to(ROOT)):
        raise Gate("run-root ancestors must not be symlinked")
    selected_profile = selected_distribution_profile(args)
    manifest = support_inputs(args)
    if selected_profile is not None:
        manifest["distribution_profile"] = selected_profile
    source_matches = all(manifest["source_release"][key] == value for key, value in
                         (("version", args.version), ("build", args.build), ("feed_url", args.feed_url), ("team", TEAM), ("bundle", BUNDLE)))
    archive, export = archive_commands(args, run_root, run_root / "support/support-manifest.json")
    plan = {"mode": args.action, "distribution_authorization": "OPEN; development profile is not Developer ID authorization",
            "export_options": export_options(selected_profile["uuid"] if selected_profile else None, args.certificate_sha1),
            "commands": [archive, export], "support": manifest,
            "allow_provisioning_updates": args.allow_provisioning_updates,
            "source_matches_final_version_build_feed": source_matches,
            "signing": "only entitlement-free helper directly; main app uses official Xcode archive/export",
            "disk_free_bytes": shutil.disk_usage(run_root.parent).free,
            "run_root": str(run_root), "final_version": args.version, "final_build": args.build,
            "final_feed_url": args.feed_url, "certificate_sha1": args.certificate_sha1}
    if args.action == "plan":
        print(json.dumps(plan, indent=2, sort_keys=True))
        return
    if not source_matches:
        raise Gate("source version/build/feed is not frozen to the requested final target; no signing or provisioning attempted")
    # This branch is not exercised by source validation. It performs real signing and
    # may access Apple's portal only when the explicit provisioning switch was supplied.
    run_root.mkdir(mode=0o700)
    write_json(run_root / "plan.json", plan)
    support_dir = run_root / "support"
    support_dir.mkdir(mode=0o700)
    prepared = support_dir / "CodexBarCLI"
    original_details = command(["/usr/bin/codesign", "-d", "--verbose=4", manifest["helper"]]).stderr.decode(errors="replace")
    original_signature = {"ad_hoc": "Signature=adhoc" in original_details,
                          "team": next((x.split("=", 1)[1] for x in original_details.splitlines() if x.startswith("TeamIdentifier=")), None),
                          "cdhash": next((x.split("=", 1)[1] for x in original_details.splitlines() if x.startswith("CDHash=")), None)}
    original_payload = unsigned_payload_digest(manifest["helper"])
    if embedded_entitlements(manifest["helper"]):
        raise Gate("cached helper has entitlements; independent review required before direct helper signing")
    shutil.copy2(manifest["helper"], prepared)
    if sha(prepared) != manifest["helper_sha256"]:
        raise Gate("helper changed before preparation")
    command(["/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime", "--identifier", BUNDLE + ".CodexBarCLI",
             "--sign", args.certificate_sha1, prepared])
    helper_details = code_details(prepared, args.certificate_sha1, BUNDLE + ".CodexBarCLI")
    if unsigned_payload_digest(prepared) != original_payload:
        raise Gate("preparation changed the helper payload")
    manifest = prepare_helper_resources(manifest, support_dir)
    manifest.update(original_helper_sha256=manifest["helper_sha256"], original_helper_signature=original_signature,
                    helper=str(prepared), helper_sha256=sha(prepared), prepared_helper_signature=helper_details,
                    helper_payload_sha256=original_payload,
                    certificate_sha1=args.certificate_sha1.upper())
    write_json(support_dir / "support-manifest.json", manifest)
    with (support_dir / "support-outputs.xcfilelist").open("x") as stream:
        stream.write(support_output_file_list(manifest))
    with (run_root / "ExportOptions.plist").open("xb") as stream:
        plistlib.dump(plan["export_options"], stream)
    for label, argv in (("archive", archive), ("export", export)):
        with (run_root / (label + ".log")).open("xb") as log:
            result = subprocess.run(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        (run_root / (label + ".log")).chmod(0o600)
        if result.returncode:
            raise Gate(label + " failed; inspect the private log. No manual profile/entitlement fallback is permitted")
        if label == "archive":
            archived = verify_archive(run_root / "PeelHost.xcarchive", manifest, args.version, args.build, args.feed_url, args.certificate_sha1)
            write_json(run_root / "archive-audit.json", archived)
    result = verify_export(run_root / "export/Peel Pro.app", manifest, args.version, args.build, args.feed_url, args.certificate_sha1)
    write_json(run_root / "distribution-audit.json", result)
    print("PASS exported static audit. No notarization, packaging, installation, launch, publication, or update acceptance performed.")


if __name__ == "__main__":
    try:
        main()
    except (Gate, OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print("GATE: " + str(error), file=sys.stderr)
        sys.exit(2)
