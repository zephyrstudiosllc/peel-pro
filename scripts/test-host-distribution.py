#!/usr/bin/env python3
"""Focused offline signing-policy tests. Synthetic profile DATA never authorizes code.

No build/archive/export/sign/remove-signature, portal, installed app or real profile mutation.
"""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("distribution", Path(__file__).with_name("host-distribution.py"))
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
bundle_spec = importlib.util.spec_from_file_location("bundle_support", Path(__file__).with_name("bundle-host-support.py"))
bundle_support = importlib.util.module_from_spec(bundle_spec)
bundle_spec.loader.exec_module(bundle_support)


class DistributionPolicyTests(unittest.TestCase):
    def test_embedded_entitlements_requests_xml_and_preserves_empty_helper(self):
        app = Path("/private/fixture.app")
        value = {"com.apple.developer.icloud-container-environment": "Development"}
        for raw, expected in ((plistlib.dumps(value), value), (b"", {})):
            with self.subTest(raw=raw), patch.object(distribution, "command", return_value=subprocess.CompletedProcess([], 0, stdout=raw)) as command:
                self.assertEqual(distribution.embedded_entitlements(app), expected)
                command.assert_called_once_with(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app])

    def test_embedded_entitlements_rejects_text_and_non_dictionary(self):
        for raw in (b"[Dict]\n [Key] environment", plistlib.dumps(["Development"])):
            with self.subTest(raw=raw), patch.object(distribution, "command", return_value=subprocess.CompletedProcess([], 0, stdout=raw)):
                with self.assertRaises(distribution.Gate):
                    distribution.embedded_entitlements(Path("/private/fixture.app"))

    def profile(self):
        certificate = b"synthetic-public-certificate-data-only"
        return {"UUID": "synthetic-fixture", "Name": "test-data-not-a-profile",
                "ProvisionsAllDevices": True, "TeamIdentifier": [distribution.TEAM], "Platform": ["OSX"],
                "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
                "DeveloperCertificates": [certificate], "Entitlements": self.signed()}, hashlib.sha1(certificate).hexdigest().upper()

    def signed(self):
        return {"com.apple.application-identifier": distribution.TEAM + "." + distribution.BUNDLE,
                "com.apple.developer.team-identifier": distribution.TEAM,
                "com.apple.developer.icloud-container-identifiers": [distribution.CONTAINER],
                "com.apple.developer.icloud-services": ["CloudKit"],
                "com.apple.developer.icloud-container-environment": "Production",
                "com.apple.developer.aps-environment": "production"}

    def test_matching_distribution_metadata_has_no_raw_devices_or_certs_in_receipt(self):
        profile, fingerprint = self.profile()
        result = distribution.validate_profile_metadata(profile, fingerprint, self.signed())
        self.assertEqual(result["profile_authorization_metadata"], "PASS")
        self.assertNotIn("DeveloperCertificates", result)
        self.assertNotIn("ProvisionedDevices", result)

    def test_development_archive_profile_is_audited_without_becoming_distribution_authorization(self):
        profile, fingerprint = self.profile()
        profile["ProvisionsAllDevices"] = False
        profile["ProvisionedDevices"] = ["SYNTHETIC-DEVICE"]
        profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Development", "Production"]
        profile["Entitlements"]["com.apple.developer.aps-environment"] = "development"
        signed = self.signed()
        signed["com.apple.developer.icloud-container-environment"] = "Development"
        signed["com.apple.developer.aps-environment"] = "development"
        receipt = distribution.validate_profile_metadata(profile, fingerprint, signed, distribution=False)
        self.assertFalse(receipt["distribution_audit"])
        self.assertNotIn("SYNTHETIC-DEVICE", json.dumps(receipt))
        with self.assertRaises(distribution.Gate):
            distribution.validate_profile_metadata(profile, fingerprint, signed)

    def test_registered_device_development_cannot_masquerade_as_developer_id(self):
        profile, fingerprint = self.profile()
        profile["ProvisionedDevices"] = ["SYNTHETIC-DO-NOT-OUTPUT"]
        with self.assertRaisesRegex(distribution.Gate, "distribution authorization"):
            distribution.validate_profile_metadata(profile, fingerprint)
        del profile["ProvisionedDevices"]
        profile["ProvisionsAllDevices"] = False
        with self.assertRaises(distribution.Gate):
            distribution.validate_profile_metadata(profile, fingerprint)

    def test_wrong_team_platform_app_certificate_or_expired_profile_rejected(self):
        changes = [("TeamIdentifier", ["OTHERTEAM0"]), ("Platform", ["iOS"]),
                   ("ExpirationDate", datetime.now(timezone.utc) - timedelta(seconds=1)),
                   ("DeveloperCertificates", [b"different-public-certificate"])]
        for key, value in changes:
            profile, fingerprint = self.profile()
            profile[key] = value
            with self.subTest(key=key), self.assertRaises(distribution.Gate):
                distribution.validate_profile_metadata(profile, fingerprint)
        profile, fingerprint = self.profile()
        profile["Entitlements"]["com.apple.application-identifier"] = distribution.TEAM + ".*"
        with self.assertRaisesRegex(distribution.Gate, "exact Host"):
            distribution.validate_profile_metadata(profile, fingerprint)

    def test_development_environment_wrong_container_and_missing_cloud_grants_rejected(self):
        changes = [("com.apple.developer.icloud-container-environment", ["Development"]),
                   ("com.apple.developer.aps-environment", "development"),
                   ("com.apple.developer.icloud-container-identifiers", ["iCloud.other.app"]),
                   ("com.apple.developer.icloud-services", ["CloudDocuments"])]
        for key, value in changes:
            profile, fingerprint = self.profile()
            profile["Entitlements"][key] = value
            with self.subTest(key=key), self.assertRaises(distribution.Gate):
                distribution.validate_profile_metadata(profile, fingerprint)
        for key in self.signed():
            profile, fingerprint = self.profile()
            del profile["Entitlements"][key]
            with self.subTest(missing=key), self.assertRaises(distribution.Gate):
                distribution.validate_profile_metadata(profile, fingerprint)

    def test_signed_restricted_right_cannot_exceed_profile_and_debug_right_rejected(self):
        profile, fingerprint = self.profile()
        signed = self.signed()
        signed["com.apple.developer.unapproved-test-right"] = True
        with self.assertRaisesRegex(distribution.Gate, "not authorized"):
            distribution.validate_profile_metadata(profile, fingerprint, signed)
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            profile, fingerprint = self.profile()
            profile["Entitlements"][key] = True
            with self.subTest(key=key), self.assertRaises(distribution.Gate):
                distribution.validate_profile_metadata(profile, fingerprint)

    def test_profile_wildcard_is_only_a_trailing_prefix_not_shell_globbing(self):
        self.assertTrue(distribution.allowed([distribution.CONTAINER], "*"))
        self.assertTrue(distribution.allowed("TEAM.app", "TEAM.*"))
        self.assertFalse(distribution.allowed("OTHER.app", "TEAM.*"))
        self.assertFalse(distribution.allowed("TEAM.app", "TEAM.[a-z]*"))
        self.assertFalse(distribution.allowed(True, 1))

    def test_direct_signing_guard_covers_current_cloud_rights_and_future_developer_rights(self):
        self.assertTrue(distribution.restricted(plistlib.loads(distribution.POLICY.read_bytes())))
        self.assertTrue(distribution.restricted({"aps-environment": "development"}))
        self.assertTrue(distribution.restricted({"com.apple.developer.future-right": True}))
        self.assertEqual(distribution.restricted({"com.apple.security.app-sandbox": False}), [])
        command = [sys.executable, str(Path(__file__).with_name("host-distribution.py")),
                   "check-direct-policy", "--entitlements", str(distribution.POLICY)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("direct review signing is forbidden", result.stderr)

    def test_resource_identity_detects_tamper_and_rejects_escaping_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Resources.bundle"
            root.mkdir()
            (root / "fixture").write_bytes(b"reviewed")
            before = distribution.tree_digest(root)
            (root / "fixture").write_bytes(b"tampered")
            self.assertNotEqual(distribution.tree_digest(root), before)
            (root / "escape").symlink_to(Path(directory).parent)
            with self.assertRaisesRegex(distribution.Gate, "escapes"):
                distribution.tree_digest(root)

    def test_archive_export_has_no_implicit_portal_device_registration_or_upload(self):
        class Arguments:
            allow_provisioning_updates = False
        archive, export = distribution.archive_commands(Arguments(), Path("/private/review"), Path("/private/review/support/manifest.json"))
        self.assertNotIn("-allowProvisioningUpdates", archive + export)
        self.assertNotIn("-allowProvisioningDeviceRegistration", archive + export)
        self.assertIn("-exportArchive", export)
        self.assertIn("archive", archive)
        self.assertEqual(archive[archive.index("-jobs") + 1], "2")
        self.assertIn("PEEL_DISTRIBUTION_PYTHON=" + sys.executable, archive)
        self.assertIn("PEEL_ARCHIVE_SUPPORT_OUTPUT_FILE_LIST=/private/review/support/support-outputs.xcfilelist", archive)
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", archive)
        options = distribution.export_options()
        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["destination"], "export")
        self.assertEqual(options["iCloudContainerEnvironment"], "Production")
        Arguments.allow_provisioning_updates = True
        archive, export = distribution.archive_commands(Arguments(), Path("/private/review"), Path("/private/review/support/manifest.json"))
        self.assertIn("-allowProvisioningUpdates", archive)
        self.assertIn("-allowProvisioningUpdates", export)

    def test_output_list_declares_exact_nested_resources_and_detects_input_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Resources.bundle"
            nested = root / "Contents/Resources"
            nested.mkdir(parents=True)
            (nested / "provider.js").write_text("reviewed")
            manifest = {"helper_resources": str(root), "helper_resources_sha256": distribution.tree_digest(root)}
            prefix = "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/CodexBar_CodexBarCore.bundle"
            self.assertEqual(distribution.support_output_file_list(manifest).splitlines(),
                             [prefix + "/Contents", prefix + "/Contents/Resources", prefix + "/Contents/Resources/provider.js"])
            (nested / "unexpected.js").write_text("changed")
            with self.assertRaisesRegex(distribution.Gate, "resources changed"):
                distribution.support_output_file_list(manifest)

    def test_output_list_rejects_build_setting_and_newline_injection(self):
        for name in ("$(OTHER_PATH)", "file\ninjected", "file\rinjected"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "Resources.bundle"
                root.mkdir()
                (root / name).write_text("fixture")
                manifest = {"helper_resources": str(root), "helper_resources_sha256": distribution.tree_digest(root)}
                with self.assertRaisesRegex(distribution.Gate, "cannot be represented"):
                    distribution.support_output_file_list(manifest)

    def test_output_list_does_not_expand_symlinks_and_rejects_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Resources.bundle"
            (root / "real").mkdir(parents=True)
            (root / "real/data").write_text("reviewed")
            (root / "alias").symlink_to("real", target_is_directory=True)
            manifest = {"helper_resources": str(root), "helper_resources_sha256": distribution.tree_digest(root)}
            outputs = distribution.support_output_file_list(manifest).splitlines()
            self.assertTrue(any(path.endswith("/alias") for path in outputs))
            self.assertFalse(any(path.endswith("/alias/data") for path in outputs))
            (root / "escape").symlink_to(Path(directory).parent, target_is_directory=True)
            with self.assertRaisesRegex(distribution.Gate, "escapes"):
                distribution.support_output_file_list(manifest)

    def test_normal_build_support_phase_skips_without_any_bundle_or_signing(self):
        import os
        environment = dict(os.environ)
        environment.pop("PEEL_BUNDLE_ARCHIVE_SUPPORT", None)
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("bundle-host-support.py"))],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipped", result.stdout)

    def test_output_scaffold_allows_only_expected_empty_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            (source / "Contents/Resources").mkdir(parents=True)
            (source / "Contents/Resources/provider.js").write_text("reviewed")
            destination = Path(directory) / "output"
            bundle_support.validate_resource_destination(destination, source)
            (destination / "Contents/Resources").mkdir(parents=True)
            bundle_support.validate_resource_destination(destination, source)
            for relative in ("Contents/Resources/provider.js", "unexpected"):
                path = destination / relative
                path.write_text("existing data")
                with self.assertRaises(bundle_support.distribution.Gate):
                    bundle_support.validate_resource_destination(destination, source)
                path.unlink()
            (destination / "unexpected").mkdir()
            with self.assertRaises(bundle_support.distribution.Gate):
                bundle_support.validate_resource_destination(destination, source)

    def test_output_scaffold_rejects_root_and_nested_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            (source / "Contents").mkdir(parents=True)
            destination = Path(directory) / "output"
            destination.symlink_to(source, target_is_directory=True)
            with self.assertRaises(bundle_support.distribution.Gate):
                bundle_support.validate_resource_destination(destination, source)
            destination.unlink()
            destination.mkdir()
            (destination / "Contents").symlink_to(source / "Contents", target_is_directory=True)
            with self.assertRaises(bundle_support.distribution.Gate):
                bundle_support.validate_resource_destination(destination, source)


class HelperPayloadTests(unittest.TestCase):
    def pair(self, signature_size=128, cpu=0x0100000C):
        page = 16384 if cpu == 0x0100000C else 4096
        code_size, payload_size = page, 4096
        link_vm = (payload_size + signature_size + page - 1) // page * page
        def segment(name, vmaddr, vmsize, fileoff, filesize):
            return struct.pack("<II16s4Q4I", 0x19, 72, name.ljust(16, b"\0"),
                               vmaddr, vmsize, fileoff, filesize, 1, 1, 0, 0)
        commands = (segment(b"__TEXT", 0x100000000, code_size, 0, code_size)
                    + segment(b"__LINKEDIT", 0x100000000 + code_size, link_vm, code_size, payload_size)
                    + struct.pack("<II16s", 0x1B, 24, b"synthetic-uuid---"))
        unsigned = bytearray(code_size + payload_size)
        unsigned[:32] = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 3, len(commands), 0, 0)
        unsigned[32:32 + len(commands)] = commands
        unsigned[1024:1032] = b"codeDATA"
        unsigned[code_size:code_size + 8] = b"linkDATA"
        signed = bytearray(unsigned + b"S" * signature_size)
        struct.pack_into("<II", signed, 16, 4, len(commands) + 16)
        struct.pack_into("<Q", signed, 104 + 48, payload_size + signature_size)
        struct.pack_into("<4I", signed, 32 + len(commands), 0x1D, 16, len(unsigned), signature_size)
        return signed, unsigned

    def digest(self, pair):
        return hashlib.sha256(distribution.normalized_unsigned_helper(*pair)).hexdigest()

    def test_legitimate_signature_resize_normalizes_only_linkedit_vmsize(self):
        for cpu in (0x0100000C, 0x01000007):
            small, large = self.pair(cpu=cpu), self.pair(32768, cpu)
            with self.subTest(cpu=cpu):
                self.assertEqual(self.digest(small), self.digest(large))
                normalized = distribution.normalized_unsigned_helper(*large)
                differences = [i for i, (a, b) in enumerate(zip(large[1], normalized)) if a != b]
                self.assertTrue(differences)
                self.assertTrue(all(136 <= i < 144 for i in differences))
                self.assertEqual(len(large[1]), len(normalized))

    def test_code_data_and_other_load_command_tamper_changes_full_digest(self):
        expected = self.digest(self.pair())
        for offset in (1024, 16384, 184):  # code bytes, link data, LC_UUID payload
            pair = self.pair()
            for data in pair:
                data[offset] ^= 1
            with self.subTest(offset=offset):
                self.assertNotEqual(self.digest(pair), expected)

    def test_truncated_unsupported_and_malformed_command_tables_rejected(self):
        for offset, value in ((0, 0xCAFEBABE), (4, 0x01000012), (12, 6), (28, 1),
                              (16, 0xFFFFFFFF), (20, 0xFFFFFFFF), (36, 7), (104 + 64, 1)):
            pair = self.pair()
            struct.pack_into("<I", pair[0], offset, value)
            with self.subTest(offset=offset), self.assertRaises(distribution.Gate):
                self.digest(pair)
        for size in (0, 31, 50, 100):
            with self.subTest(size=size), self.assertRaises(distribution.Gate):
                distribution.helper_macho_layout(self.pair()[0][:size])

    def test_invalid_linkedit_bounds_overlap_duplicate_and_alignment_rejected(self):
        for offset, value in ((104 + 24, 0x100004001), (104 + 32, 16385),
                              (104 + 40, 16385), (104 + 48, 0xFFFFFFFF), (32 + 48, 20000)):
            pair = self.pair()
            struct.pack_into("<Q", pair[0], offset, value)
            with self.subTest(offset=offset), self.assertRaises(distribution.Gate):
                self.digest(pair)
        pair = self.pair()
        pair[0][40:56] = b"__LINKEDIT".ljust(16, b"\0")
        with self.assertRaises(distribution.Gate):
            self.digest(pair)

    def test_unexpected_signature_removal_or_vm_padding_is_not_normalized(self):
        for which, offset, value in ((0, 208, 0), (0, 200, 0x1B),
                                    (0, 208, 20481), (1, 136, 32768)):
            pair = self.pair()
            struct.pack_into("<I", pair[which], offset, value)
            with self.subTest(which=which, offset=offset), self.assertRaises(distribution.Gate):
                self.digest(pair)
        pair = self.pair()
        pair[0].extend(b"trailing")
        with self.assertRaises(distribution.Gate):
            self.digest(pair)
        pair = self.pair()
        with self.assertRaises(distribution.Gate):
            distribution.normalized_unsigned_helper(pair[0], pair[0])



class ManualDistributionProfileTests(unittest.TestCase):
    UUID = "11111111-2222-4333-8444-555555555555"  # synthetic data, never an installed profile

    def profile(self):
        value, fingerprint = DistributionPolicyTests().profile()
        value["UUID"] = self.UUID
        return value, fingerprint

    def arguments(self, profile, fingerprint, **extra):
        from types import SimpleNamespace
        return SimpleNamespace(distribution_profile=str(profile), certificate_sha1=fingerprint,
                               allow_provisioning_updates=extra.get("allow_provisioning_updates", False))

    def test_manual_options_pin_actual_profile_and_selected_certificate_without_changing_automatic_default(self):
        automatic = distribution.export_options()
        self.assertEqual(automatic["signingStyle"], "automatic")
        self.assertNotIn("signingCertificate", automatic)
        self.assertNotIn("provisioningProfiles", automatic)
        manual = distribution.export_options(self.UUID, "a" * 40)
        self.assertEqual(manual["signingStyle"], "manual")
        self.assertEqual(manual["signingCertificate"], "A" * 40)
        self.assertEqual(manual["provisioningProfiles"], {distribution.BUNDLE: self.UUID})
        self.assertEqual({k: v for k, v in manual.items() if k not in
                          ("signingStyle", "signingCertificate", "provisioningProfiles")},
                         {k: v for k, v in automatic.items() if k != "signingStyle"})

    def test_profile_preflight_uses_actual_metadata_and_records_only_public_selection(self):
        profile, fingerprint = self.profile()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.provisionprofile"
            path.write_bytes(b"synthetic CMS stand-in, not an actual profile")
            with patch.object(distribution, "decoded_profile", return_value=profile) as decode:
                selected = distribution.selected_distribution_profile(self.arguments(path, fingerprint))
            decode.assert_called_once_with(path)
            self.assertEqual(selected["uuid"], self.UUID)
            self.assertEqual(selected["certificate_sha1"], fingerprint)
            self.assertEqual(selected["profile_sha256"], distribution.sha(path))
            self.assertNotIn("DeveloperCertificates", selected)
            self.assertNotIn("ProvisionedDevices", selected)
            self.assertNotIn("synthetic-public-certificate-data", json.dumps(selected))

    def test_manual_profile_requires_an_actual_uuid_not_a_name_or_missing_value(self):
        profile, fingerprint = self.profile()
        for bad in (None, "", "synthetic-fixture", "not-a-profile-uuid", [self.UUID]):
            value = deepcopy(profile)
            value["UUID"] = bad
            with self.subTest(uuid=bad), patch.object(distribution, "decoded_profile", return_value=value), \
                    self.assertRaisesRegex(distribution.Gate, "actual valid UUID"):
                distribution.selected_distribution_profile(self.arguments(Path("/private/fake-profile"), fingerprint))

    def argv(self, workspace, profile, fingerprint, action="run", allow=False):
        result = ["host-distribution.py", action, "--helper", "/private/not-read-helper",
                  "--helper-resources", "/private/not-read-resources", "--helper-sha256", "0" * 64,
                  "--helper-resources-sha256", "1" * 64, "--run-root", str(workspace / ".build/run"),
                  "--version", "2.0", "--build", "225", "--feed-url", "https://example.com/appcast.xml",
                  "--certificate-sha1", fingerprint, "--distribution-profile", str(profile)]
        if allow:
            result.append("--allow-provisioning-updates")
        return result

    def test_cli_manual_and_broad_provisioning_are_rejected_before_profile_helper_or_subprocess(self):
        profile, fingerprint = self.profile()
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory).resolve()
            (workspace / ".build").mkdir()
            with patch.object(distribution, "ROOT", workspace), \
                    patch.object(sys, "argv", self.argv(workspace, workspace / "unused", fingerprint, allow=True)), \
                    patch.object(distribution, "decoded_profile") as decode, \
                    patch.object(distribution, "support_inputs") as support, \
                    patch.object(distribution.subprocess, "run") as subprocess_run, \
                    self.assertRaisesRegex(distribution.Gate, "cannot be combined"):
                distribution.main()
            decode.assert_not_called()
            support.assert_not_called()
            subprocess_run.assert_not_called()
            self.assertFalse((workspace / ".build/run").exists())

    def test_cli_rejects_ineligible_profile_before_any_helper_sign_or_build(self):
        original, fingerprint = self.profile()
        cases = []
        for key, value in (("ProvisionsAllDevices", False), ("ProvisionedDevices", ["SYNTHETIC-NOT-OUTPUT"]),
                           ("DeveloperCertificates", [b"wrong-certificate"]),
                           ("ExpirationDate", datetime.now(timezone.utc) - timedelta(days=1))):
            profile = deepcopy(original)
            profile[key] = value
            cases.append((key, profile))
        for key, value in (("com.apple.application-identifier", distribution.TEAM + ".wrong"),
                           ("com.apple.developer.icloud-container-identifiers", ["iCloud.wrong"]),
                           ("com.apple.developer.aps-environment", "development")):
            profile = deepcopy(original)
            profile["Entitlements"][key] = value
            cases.append((key, profile))
        for name, profile in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                workspace = Path(directory).resolve()
                (workspace / ".build").mkdir()
                with patch.object(distribution, "ROOT", workspace), \
                        patch.object(sys, "argv", self.argv(workspace, workspace / "fake", fingerprint)), \
                        patch.object(distribution, "decoded_profile", return_value=profile), \
                        patch.object(distribution, "support_inputs") as support, \
                        patch.object(distribution.subprocess, "run") as subprocess_run, \
                        self.assertRaises(distribution.Gate):
                    distribution.main()
                support.assert_not_called()
                subprocess_run.assert_not_called()
                self.assertFalse((workspace / ".build/run").exists())

    def test_cli_plan_uses_manual_options_and_no_portal_flag_without_creating_run_directory(self):
        import io
        profile, fingerprint = self.profile()
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory).resolve()
            (workspace / ".build").mkdir()
            path = workspace / "fixture.provisionprofile"
            path.write_bytes(b"synthetic public-profile stand-in")
            manifest = {"source_release": {"version": "2.0", "build": "225",
                        "feed_url": "https://example.com/appcast.xml", "team": distribution.TEAM,
                        "bundle": distribution.BUNDLE}}
            output = io.StringIO()
            with patch.object(distribution, "ROOT", workspace), \
                    patch.object(sys, "argv", self.argv(workspace, path, fingerprint, action="plan")), \
                    patch.object(sys, "stdout", output), \
                    patch.object(distribution, "decoded_profile", return_value=profile), \
                    patch.object(distribution, "support_inputs", return_value=manifest), \
                    patch.object(distribution.subprocess, "run") as subprocess_run:
                distribution.main()
            plan = json.loads(output.getvalue())
            self.assertTrue(plan["source_matches_final_version_build_feed"])
            self.assertEqual(plan["export_options"], distribution.export_options(self.UUID, fingerprint))
            self.assertEqual(plan["support"]["distribution_profile"]["uuid"], self.UUID)
            for command in plan["commands"]:
                self.assertNotIn("-allowProvisioningUpdates", command)
            self.assertIn("-clonedSourcePackagesDirPath", plan["commands"][0])
            self.assertFalse((workspace / ".build/run").exists())
            subprocess_run.assert_not_called()

    def artifact(self, root, fingerprint, archive=False):
        app = root / "Fixture.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        info = {"CFBundleIdentifier": distribution.BUNDLE, "CFBundleExecutable": "Peel Pro",
                "CFBundleDisplayName": "Peel Pro", "CFBundleName": "Peel Pro", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "225", "CFBundleShortVersionString": "2.0", "PeelBuildConfiguration": "Release",
                "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "synthetic-public-key"}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        values = {"peel_mcp_server.py": b"synthetic reviewed adapter", "PeelSigningEntitlements.plist": b"policy",
                  "COMPONENT_NOTICES.txt": b"notices"}
        for name, data in values.items():
            (resources / name).write_bytes(data)
        bundle = resources / "CodexBar_CodexBarCore.bundle"
        bundle.mkdir()
        (bundle / "data").write_bytes(b"resources")
        (app / "Contents/Helpers").mkdir()
        (app / "Contents/Helpers/CodexBarCLI").write_bytes(b"synthetic helper")
        (app / "Contents/embedded.provisionprofile").write_bytes(b"synthetic CMS facade")
        manifest = {"source_release": {"sparkle_public_ed_key": info["SUPublicEDKey"]},
                    "distribution_profile": {"uuid": self.UUID, "certificate_sha1": fingerprint},
                    "mcp_sha256": distribution.sha(resources / "peel_mcp_server.py"),
                    "signing_policy_sha256": distribution.sha(resources / "PeelSigningEntitlements.plist"),
                    "helper_resources_sha256": distribution.tree_digest(bundle), "helper_payload_sha256": "payload",
                    "component_notices_sha256": distribution.sha(resources / "COMPONENT_NOTICES.txt"),
                    "original_helper_sha256": "source-helper", "original_helper_signature": {},
                    "helper_sha256": "prepared-helper", "prepared_helper_signature": {}}
        return app, manifest

    def audit(self, app, manifest, profile, fingerprint, actual_fingerprint=None, archive=False):
        signed = DistributionPolicyTests().signed()
        if archive:
            signed["com.apple.developer.icloud-container-environment"] = "Development"
            signed["com.apple.developer.aps-environment"] = "development"
        details = {"certificate_sha1": actual_fingerprint or fingerprint, "developer_id": not archive}
        def entitlements(path):
            return signed if path == app else {}
        with patch.object(distribution, "command", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(distribution, "code_details", return_value=details), \
                patch.object(distribution, "embedded_entitlements", side_effect=entitlements), \
                patch.object(distribution, "decoded_profile", return_value=profile), \
                patch.object(distribution, "unsigned_payload_digest", return_value="payload"), \
                patch.object(distribution, "MCP_SHA", manifest["mcp_sha256"]):
            return distribution.verify_export(app, manifest, "2.0", "225", "https://example.com/appcast.xml",
                                              fingerprint, archive=archive)

    def test_actual_export_audit_accepts_selected_uuid_certificate_and_all_resource_guards(self):
        profile, fingerprint = self.profile()
        with tempfile.TemporaryDirectory() as directory:
            app, manifest = self.artifact(Path(directory), fingerprint)
            result = self.audit(app, manifest, profile, fingerprint)
            self.assertEqual(result["profile"]["uuid"], self.UUID)
            self.assertEqual(result["signature"]["certificate_sha1"], fingerprint)

    def test_actual_export_audit_rejects_different_valid_profile_uuid(self):
        profile, fingerprint = self.profile()
        profile["UUID"] = "22222222-3333-4444-8555-666666666666"
        with tempfile.TemporaryDirectory() as directory:
            app, manifest = self.artifact(Path(directory), fingerprint)
            with self.assertRaisesRegex(distribution.Gate, "differs from selected"):
                self.audit(app, manifest, profile, fingerprint)

    def test_actual_export_audit_rejects_other_profile_authorized_certificate(self):
        profile, fingerprint = self.profile()
        other = b"another-synthetic-public-certificate"
        profile["DeveloperCertificates"].append(other)
        actual = hashlib.sha1(other).hexdigest().upper()
        with tempfile.TemporaryDirectory() as directory:
            app, manifest = self.artifact(Path(directory), fingerprint)
            with self.assertRaisesRegex(distribution.Gate, "differs from selected"):
                self.audit(app, manifest, profile, fingerprint, actual_fingerprint=actual)

    def test_manual_distribution_selection_does_not_replace_cached_development_archive_profile(self):
        profile, fingerprint = self.profile()
        profile["UUID"] = "33333333-4444-4555-8666-777777777777"
        profile["ProvisionsAllDevices"] = False
        profile["ProvisionedDevices"] = ["SYNTHETIC-DEVICE-NOT-OUTPUT"]
        profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = "Development"
        profile["Entitlements"]["com.apple.developer.aps-environment"] = "development"
        with tempfile.TemporaryDirectory() as directory:
            app, manifest = self.artifact(Path(directory), fingerprint, archive=True)
            result = self.audit(app, manifest, profile, fingerprint, archive=True)
            self.assertFalse(result["profile"]["distribution_audit"])
            self.assertEqual(result["profile"]["uuid"], profile["UUID"])
            self.assertNotIn("SYNTHETIC-DEVICE-NOT-OUTPUT", json.dumps(result))


class UniversalHelperTests(unittest.TestCase):
    def pair(self, signature_size=128):
        pairs = {}
        for cpu in (0x01000007, 0x0100000C):
            signed, unsigned = HelperPayloadTests().pair(signature_size, cpu)
            if cpu == 0x01000007:
                for data in (signed, unsigned):
                    struct.pack_into("<I", data, 8, 3)
            pairs[cpu] = (signed, unsigned)
        return pairs

    def fat(self, pairs=None, fat64=False, offsets=None):
        pairs = pairs or self.pair()
        count, size = 2, 32 if fat64 else 20
        positions, end = [], 8 + count * size
        for cpu in (0x01000007, 0x0100000C):
            position = ((end + 16383) // 16384) * 16384 if offsets is None else offsets[cpu]
            positions.append((cpu, position, pairs[cpu][0]))
            end = max(end, position + len(pairs[cpu][0]))
        data = bytearray(end)
        struct.pack_into(">II", data, 0, 0xCAFEBABF if fat64 else 0xCAFEBABE, count)
        for index, (cpu, position, member) in enumerate(positions):
            subtype = 3 if cpu == 0x01000007 else 0
            values = (cpu, subtype, position, len(member), 14)
            struct.pack_into(">IIQQII" if fat64 else ">IIIII", data, 8 + index * size,
                             *(values + (0,) if fat64 else values))
        for cpu, position, member in sorted(positions, key=lambda value: value[1]):
            data[position:position + len(member)] = member
        return data

    def payload_digest(self, data, pairs=None, remove_unchanged=False):
        pairs = pairs or self.pair()
        originals = {hashlib.sha256(bytes(value[0])).hexdigest(): bytes(value[1]) for value in pairs.values()}
        operations = []
        def fake_command(arguments, **kwargs):
            operations.append(list(arguments))
            if "--remove-signature" in arguments:
                target = Path(arguments[-1])
                if not remove_unchanged:
                    target.write_bytes(originals[hashlib.sha256(target.read_bytes()).hexdigest()])
            return subprocess.CompletedProcess(arguments, 0, stdout=b"", stderr=b"")
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "original"
            original.write_bytes(data)
            with patch.object(distribution, "command", side_effect=fake_command):
                result = distribution.unsigned_payload_digest(original)
            self.assertEqual(original.read_bytes(), data)
            self.assertTrue(all(str(original) != str(argv[-1]) for argv in operations if "--remove-signature" in argv))
            return result

    def test_fat32_and_fat64_bind_exact_actual_slice_bytes(self):
        for fat64 in (False, True):
            pairs = self.pair()
            members = distribution.helper_fat_slices(self.fat(pairs, fat64))
            self.assertEqual([x["architecture"] for x in members], ["x86_64", "arm64"])
            for item in members:
                self.assertEqual(item["data"], pairs[item["cpu"]][0])

    def test_malformed_count_endianness_table_bounds_alignment_and_reserved_are_rejected(self):
        changes = [(0, 0xBEBAFECA), (4, 0), (4, 3), (4, 0xFFFFFFFF),
                   (8, 0x01000012), (12, 0), (16, 7), (20, 0xFFFFFFFF), (24, 31)]
        for offset, value in changes:
            data = self.fat(); struct.pack_into(">I", data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(distribution.Gate):
                distribution.helper_fat_slices(data)
        data = self.fat(fat64=True); struct.pack_into(">I", data, 8 + 28, 1)
        with self.assertRaises(distribution.Gate): distribution.helper_fat_slices(data)
        for size in (0, 7, 40):
            with self.subTest(size=size), self.assertRaises(distribution.Gate):
                distribution.helper_fat_slices(self.fat()[:size])

    def test_overlapping_valid_slices_are_rejected(self):
        data = self.fat(offsets={0x01000007: 32768 + 16384, 0x0100000C: 32768})
        with self.assertRaisesRegex(distribution.Gate, "overlap"): distribution.helper_fat_slices(data)

    def test_duplicate_architecture_header_mismatch_and_hidden_data_are_rejected(self):
        data = self.fat(); struct.pack_into(">I", data, 28, 0x01000007)
        with self.assertRaises(distribution.Gate): distribution.helper_fat_slices(data)
        data = self.fat(); data[16384 + 4] ^= 1
        with self.assertRaises(distribution.Gate): distribution.helper_fat_slices(data)
        for offset in (48, 16383):
            data = self.fat(); data[offset] = 1
            with self.subTest(offset=offset), self.assertRaises(distribution.Gate):
                distribution.helper_fat_slices(data)
        with self.assertRaises(distribution.Gate): distribution.helper_fat_slices(self.fat() + b"extra")

    def test_each_slice_uses_existing_normalizer_and_signature_size_changes_preserve_payload(self):
        small, large = self.pair(128), self.pair(32768)
        self.assertEqual(self.payload_digest(self.fat(small), small), self.payload_digest(self.fat(large), large))
        for cpu in small:
            expected = hashlib.sha256(distribution.normalized_unsigned_helper(*small[cpu])).hexdigest()
            self.assertEqual(self.payload_digest(small[cpu][0], small), expected)

    def test_tampered_intel_code_link_data_and_uuid_cannot_hide_in_arm_slice(self):
        expected = self.payload_digest(self.fat())
        for offset in (1024, 4096, 184):
            pairs = self.pair()
            for data in pairs[0x01000007]: data[offset] ^= 1
            with self.subTest(offset=offset):
                self.assertNotEqual(self.payload_digest(self.fat(pairs), pairs), expected)

    def test_signature_removal_that_does_not_remove_actual_slice_signature_is_rejected(self):
        with self.assertRaises(distribution.Gate): self.payload_digest(self.fat(), remove_unchanged=True)

    def signature_command(self, bad_intel_certificate=False, no_intel_timestamp=False):
        certificate = b"synthetic-public-certificate-only"
        fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        def command(arguments, **kwargs):
            arch = Path(arguments[-1]).name
            if "--verbose=4" in arguments:
                timestamp = "" if no_intel_timestamp and arch == "x86_64" else "Timestamp=synthetic\n"
                details = "Authority=Developer ID Application: fixture\nTeamIdentifier=" + distribution.TEAM + "\n"
                details += timestamp + "flags=0x10000(runtime)\nIdentifier=fixture.helper\nCDHash=synthetic\n"
                return subprocess.CompletedProcess(arguments, 0, stdout=b"", stderr=details.encode())
            prefix = next((x.split("=", 1)[1] for x in arguments if str(x).startswith("--extract-certificates=")), None)
            if prefix:
                Path(prefix + "0").write_bytes(b"different" if bad_intel_certificate and arch == "x86_64" else certificate)
            return subprocess.CompletedProcess(arguments, 0, stdout=b"", stderr=b"")
        return command, fingerprint

    def test_all_architectures_require_selected_certificate_runtime_and_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "helper"; original.write_bytes(self.fat())
            command, fingerprint = self.signature_command()
            with patch.object(distribution, "command", side_effect=command):
                details = distribution.code_details(original, fingerprint, "fixture.helper")
                self.assertEqual(set(details["architectures"]), {"arm64", "x86_64"})
            for kwargs in ({"bad_intel_certificate": True}, {"no_intel_timestamp": True}):
                command, fingerprint = self.signature_command(**kwargs)
                with patch.object(distribution, "command", side_effect=command), self.assertRaises(distribution.Gate):
                    distribution.code_details(original, fingerprint, "fixture.helper")

    def test_nonempty_entitlements_in_only_one_slice_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "helper"; original.write_bytes(self.fat())
            for with_right in (False, True):
                seen = []
                def command(arguments, **kwargs):
                    arch = Path(arguments[-1]).name; seen.append(arch)
                    value = {"synthetic.right": True} if with_right and arch == "x86_64" else {}
                    return subprocess.CompletedProcess(arguments, 0, stdout=plistlib.dumps(value), stderr=b"")
                with patch.object(distribution, "command", side_effect=command):
                    if with_right:
                        with self.assertRaises(distribution.Gate): distribution.embedded_entitlements(original)
                    else:
                        self.assertEqual(distribution.embedded_entitlements(original), {})
                        self.assertEqual(set(seen), {"arm64", "x86_64"})


class PluralHelperResourceTests(unittest.TestCase):
    def resource_set(self, root):
        entries = []
        for index, name in enumerate(distribution.HELPER_RESOURCE_BUNDLES):
            path = root / name
            contents = path / "Contents/Resources"; contents.mkdir(parents=True)
            (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL"}))
            (contents / ("PrivacyInfo.xcprivacy" if index == 2 else "data")).write_bytes(b"reviewed data " + str(index).encode())
            entries.append({"name": name, "path": str(path), "sha256": distribution.tree_digest(path)})
        return {"format": "peel-archive-support-v2", "helper_resources": entries[0]["path"],
                "helper_resources_sha256": entries[0]["sha256"], "helper_resource_bundles": entries}

    def test_v2_requires_exact_complete_set_and_consistent_legacy_core(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.resource_set(Path(directory))
            self.assertEqual(len(distribution.helper_resource_bundles(manifest)), 3)
            for mutation in (lambda m: m.pop("helper_resource_bundles"),
                             lambda m: m["helper_resource_bundles"].pop(),
                             lambda m: m["helper_resource_bundles"].append(deepcopy(m["helper_resource_bundles"][0])),
                             lambda m: m["helper_resource_bundles"][1].update(name=distribution.CORE_RESOURCE_BUNDLE),
                             lambda m: m["helper_resource_bundles"][1].update(name="unexpected.bundle"),
                             lambda m: m["helper_resource_bundles"][1].update(sha256="0"),
                             lambda m: m["helper_resource_bundles"][1].update(path="relative.bundle"),
                             lambda m: m.update(helper_resources_sha256="0" * 64),
                             lambda m: m.update(format="peel-archive-support-v1")):
                changed = deepcopy(manifest); mutation(changed)
                with self.subTest(changed=changed), self.assertRaises(distribution.Gate):
                    distribution.helper_resource_bundles(changed)

    def test_xcode_list_declares_new_roots_and_all_privacy_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.resource_set(Path(directory))
            outputs = distribution.support_output_file_list(manifest).splitlines()
            prefix = "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/"
            # The existing PBX phase already declares Core's root statically.
            self.assertNotIn(prefix + distribution.CORE_RESOURCE_BUNDLE, outputs)
            for name in distribution.HELPER_RESOURCE_BUNDLES:
                if name != distribution.CORE_RESOURCE_BUNDLE:
                    self.assertIn(prefix + name, outputs)
                self.assertIn(prefix + name + "/Contents/Info.plist", outputs)
            self.assertIn(prefix + "swift-crypto_Crypto.bundle/Contents/Resources/PrivacyInfo.xcprivacy", outputs)
            self.assertEqual(len(outputs), len(set(outputs)))

    def test_resource_preparation_copies_and_rechecks_all_three(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest = self.resource_set(root / "source"); target = root / "prepared"; target.mkdir()
            seen = []
            def copy(args):
                self.assertEqual(args[0], "/usr/bin/ditto"); seen.append(Path(args[2]).name)
                import shutil
                shutil.copytree(args[1], args[2])
            with patch.object(distribution, "command", side_effect=copy):
                prepared = distribution.prepare_helper_resources(manifest, target)
            self.assertEqual(seen, list(distribution.HELPER_RESOURCE_BUNDLES))
            distribution.check_app_helper_resources(target, prepared)
            self.assertEqual(prepared["helper_resources"], str(target / distribution.CORE_RESOURCE_BUNDLE))
            self.assertEqual([i["sha256"] for i in prepared["helper_resource_bundles"]], [i["sha256"] for i in manifest["helper_resource_bundles"]])

    def test_changed_secondary_source_is_rejected_before_any_preparation_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest = self.resource_set(root / "source")
            (Path(manifest["helper_resource_bundles"][2]["path"]) / "Contents/Resources/PrivacyInfo.xcprivacy").write_bytes(b"changed")
            with patch.object(distribution, "command") as command, self.assertRaises(distribution.Gate):
                distribution.prepare_helper_resources(manifest, root / "target")
            command.assert_not_called()

    def test_changed_copy_is_not_accepted_as_prepared_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest = self.resource_set(root / "source"); target = root / "prepared"; target.mkdir()
            def copy(args):
                import shutil
                shutil.copytree(args[1], args[2])
                if Path(args[2]).name == "swift-crypto_Crypto.bundle":
                    (Path(args[2]) / "Contents/Resources/PrivacyInfo.xcprivacy").write_bytes(b"changed during copy")
            with patch.object(distribution, "command", side_effect=copy), self.assertRaises(distribution.Gate):
                distribution.prepare_helper_resources(manifest, target)

    def test_every_exported_bundle_must_exist_and_match_and_remain_data(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest = self.resource_set(root)
            distribution.check_app_helper_resources(root, manifest)
            for item in manifest["helper_resource_bundles"]:
                path = Path(item["path"]); saved = path.with_name(path.name + ".saved"); path.rename(saved)
                with self.subTest(missing=item["name"]), self.assertRaises(distribution.Gate):
                    distribution.check_app_helper_resources(root, manifest)
                saved.rename(path)
                info = path / "Contents/Info.plist"; original = info.read_bytes(); info.write_bytes(original + b"tamper")
                with self.subTest(tampered=item["name"]), self.assertRaises(distribution.Gate):
                    distribution.check_app_helper_resources(root, manifest)
                info.write_bytes(original)

    def test_native_payload_modes_symlinks_and_declared_executable_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest = self.resource_set(root)
            bundle = Path(manifest["helper_resources"]); file = bundle / "Contents/Resources/injected"
            for contents in (b"\xcf\xfa\xed\xfe" + b"padding", b"\x7fELF", b"MZexecutable", b"#!/bin/sh"):
                file.write_bytes(contents)
                with self.subTest(contents=contents), self.assertRaises(distribution.Gate): distribution.validate_resource_payload(bundle)
            file.write_bytes(b"plain data"); file.chmod(0o755)
            with self.assertRaises(distribution.Gate): distribution.validate_resource_payload(bundle)
            file.unlink(); file.symlink_to("data")
            with self.assertRaises(distribution.Gate): distribution.validate_resource_payload(bundle)
            file.unlink(); info = bundle / "Contents/Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL", "CFBundleExecutable": "hidden"}))
            with self.assertRaises(distribution.Gate): distribution.validate_resource_payload(bundle)

    def test_cpu_comparison_accepts_exact_set_and_stops_on_different_payload_or_extra_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); left = self.resource_set(root / "arm64"); right = self.resource_set(root / "x86_64")
            self.assertEqual(len(distribution.compare_helper_resource_outputs(root / "arm64", root / "x86_64")), 3)
            privacy = Path(right["helper_resource_bundles"][2]["path"]) / "Contents/Resources/PrivacyInfo.xcprivacy"
            old = privacy.read_bytes(); privacy.write_bytes(b"different CPU product")
            with self.assertRaisesRegex(distribution.Gate, "CPU resource payload mismatch"):
                distribution.compare_helper_resource_outputs(root / "arm64", root / "x86_64")
            privacy.write_bytes(old); (root / "x86_64/unreviewed.bundle").mkdir()
            with self.assertRaises(distribution.Gate): distribution.compare_helper_resource_outputs(root / "arm64", root / "x86_64")

    def test_universal_plan_requires_extras_and_records_exact_three_without_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); manifest = self.resource_set(root / "inputs")
            helper = root / "helper"; helper.write_bytes(UniversalHelperTests().fat()); helper.chmod(0o755)
            adapter = root / "Tools/PeelMCP/peel_mcp_server.py"; adapter.parent.mkdir(parents=True); adapter.write_bytes(b"fixture adapter")
            policy = root / "policy"; policy.write_bytes(b"fixture policy")
            for name in ("Sources/SidePulse/LICENSE", "Sources/SidePulse/NOTICE", "Sources/CodexBar/LICENSE", "Sources/CodexBar/Sources/CQuickJS/LICENSE"):
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"fixture notice")
            args = type("Arguments", (), {"helper": str(helper), "helper_sha256": distribution.sha(helper),
                "helper_resources": manifest["helper_resources"], "helper_resources_sha256": manifest["helper_resources_sha256"],
                "additional_helper_resource": []})()
            with patch.object(distribution, "ROOT", root), patch.object(distribution, "POLICY", policy), \
                    patch.object(distribution, "MCP_SHA", distribution.sha(adapter)), patch.object(distribution, "source_release_fields", return_value={}), \
                    patch.object(distribution, "command") as command:
                with self.assertRaisesRegex(distribution.Gate, "complete plural"): distribution.support_inputs(args)
                args.additional_helper_resource = [(i["name"], i["path"], i["sha256"]) for i in manifest["helper_resource_bundles"][1:]]
                accepted = distribution.support_inputs(args)
                self.assertEqual(accepted["format"], "peel-archive-support-v2")
                self.assertEqual(accepted["helper_resource_bundles"], manifest["helper_resource_bundles"])
                command.assert_not_called()

    def test_export_audit_rejects_extra_resources_in_nested_code_slot(self):
        audit = ManualDistributionProfileTests(); profile, fingerprint = audit.profile()
        with tempfile.TemporaryDirectory() as directory:
            app, manifest = audit.artifact(Path(directory), fingerprint)
            for name in distribution.HELPER_RESOURCE_BUNDLES[1:]:
                path = app / "Contents/Helpers" / name; path.mkdir()
                with self.subTest(name=name), self.assertRaisesRegex(distribution.Gate, "nested-code"):
                    audit.audit(app, manifest, profile, fingerprint)
                path.rmdir()

    def test_universal_export_cannot_downgrade_to_legacy_core_only_receipt(self):
        audit = ManualDistributionProfileTests(); profile, fingerprint = audit.profile()
        with tempfile.TemporaryDirectory() as directory:
            app, manifest = audit.artifact(Path(directory), fingerprint)
            (app / "Contents/Helpers/CodexBarCLI").write_bytes(UniversalHelperTests().fat())
            with self.assertRaisesRegex(distribution.Gate, "complete plural"):
                audit.audit(app, manifest, profile, fingerprint)

    def test_actual_archive_phase_copies_all_resources_before_app_signing(self):
        import os
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); support = root / ".build/support"; support.mkdir(parents=True)
            manifest = self.resource_set(support)
            for key, name, data in (("helper", "CodexBarCLI", b"synthetic helper"), ("mcp", "mcp.py", b"fixture adapter"),
                                    ("signing_policy", "policy.plist", b"fixture policy")):
                path = support / name; path.write_bytes(data); manifest[key] = str(path); manifest[key + "_sha256"] = distribution.sha(path)
            text = "fixture component notices\n"
            manifest.update(workspace=str(root), certificate_sha1="A" * 40, notices=[],
                            component_notices_sha256=hashlib.sha256(text.encode()).hexdigest())
            manifest_path = support / "support-manifest.json"; manifest_path.write_text(json.dumps(manifest))
            target = root / ".build/target"; contents = target / "Peel Pro.app/Contents"
            seen = []
            def copy(args):
                self.assertEqual(args[0], "/usr/bin/ditto"); seen.append(Path(args[2]).name)
                shutil.copytree(args[1], args[2])
            env = {"PEEL_BUNDLE_ARCHIVE_SUPPORT": "YES", "CONFIGURATION": "Release", "CODE_SIGNING_ALLOWED": "YES",
                   "PEEL_ARCHIVE_SUPPORT_MANIFEST": str(manifest_path), "TARGET_BUILD_DIR": str(target),
                   "CONTENTS_FOLDER_PATH": "Peel Pro.app/Contents"}
            module = bundle_support.distribution
            with patch.dict(os.environ, env, clear=True), patch.object(module, "ROOT", root), \
                    patch.object(module, "MCP_SHA", manifest["mcp_sha256"]), patch.object(module, "code_details"), \
                    patch.object(module, "embedded_entitlements", return_value={}), \
                    patch.object(module, "notice_text", return_value=text), patch.object(module, "command", side_effect=copy):
                bundle_support.bundle()
            self.assertEqual(seen, list(distribution.HELPER_RESOURCE_BUNDLES))
            distribution.check_app_helper_resources(contents / "Resources", manifest)
            self.assertEqual((contents / "Helpers/CodexBarCLI").read_bytes(), b"synthetic helper")


class NativeSignerAlignmentTests(unittest.TestCase):
    def pair(self, gap=8, signature_size=128, vm_page=16384, cpu=0x01000007, vm_offset=12288):
        code_size = 16384
        payload_size = 4096 + ((16 - gap) % 16)
        size = payload_size + gap + signature_size
        vm_size = (size + vm_page - 1) // vm_page * vm_page
        def segment(name, vmaddr, vmsize, fileoff, filesize):
            return struct.pack("<II16s4Q4I", 0x19, 72, name.ljust(16, b"\0"), vmaddr, vmsize, fileoff, filesize, 1, 1, 0, 0)
        commands = (segment(b"__TEXT", 0x100000000, code_size, 0, code_size)
                    + segment(b"__LINKEDIT", 0x100000000 + code_size + vm_offset, vm_size, code_size, payload_size)
                    + struct.pack("<II16s", 0x1B, 24, b"synthetic-uuid---"))
        unsigned = bytearray(code_size + payload_size)
        unsigned[:32] = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 3, len(commands), 0, 0)
        unsigned[32:32 + len(commands)] = commands
        unsigned[1024:1032] = b"codeDATA"; unsigned[code_size:code_size + 8] = b"linkDATA"
        signed = bytearray(unsigned + b"\0" * gap + b"S" * signature_size)
        struct.pack_into("<II", signed, 16, 4, len(commands) + 16)
        struct.pack_into("<Q", signed, 104 + 48, size)
        struct.pack_into("<4I", signed, 32 + len(commands), 0x1D, 16, len(unsigned) + gap, signature_size)
        return signed, unsigned

    def test_all_minimal_zero_alignment_gaps_and_both_x86_vm_roundings(self):
        for gap in range(16):
            normalized = []
            for page in (4096, 16384):
                signed, unsigned = self.pair(gap=gap, vm_page=page)
                value = distribution.normalized_unsigned_helper(signed, unsigned); normalized.append(value)
                expected = bytearray(unsigned)
                layout = distribution.helper_macho_layout(unsigned); link = layout["linkedit"]
                struct.pack_into("<Q", expected, link["command_offset"] + 32, (link["filesize"] + 4095) // 4096 * 4096)
                self.assertEqual(value, bytes(expected))
                self.assertEqual(len(value), len(unsigned))
            self.assertEqual(normalized[0], normalized[1])

    def test_nonzero_excessive_or_negative_alignment_gap_is_rejected(self):
        signed, unsigned = self.pair(); signed[len(unsigned)] = 1
        with self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(signed, unsigned)
        signed, unsigned = self.pair(gap=0); unsigned = unsigned[:-16]
        struct.pack_into("<Q", unsigned, 104 + 48, len(unsigned) - 16384)
        with self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(signed, unsigned)
        signed, unsigned = self.pair(gap=0); unsigned.extend(b"\0" * 16)
        struct.pack_into("<Q", unsigned, 104 + 48, len(unsigned) - 16384)
        with self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(signed, unsigned)

    def test_16k_rounding_does_not_require_16k_vm_start_but_keeps_4k_parser_checks(self):
        signed, unsigned = self.pair(vm_offset=12288)
        distribution.normalized_unsigned_helper(signed, unsigned)
        for offset in (104 + 24, 104 + 40):
            pair = [bytearray(signed), bytearray(unsigned)]
            for value in pair:
                original = struct.unpack_from("<Q", value, offset)[0]; struct.pack_into("<Q", value, offset, original + 1)
            with self.subTest(offset=offset), self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(*pair)

    def test_16k_rounding_is_rejected_for_unaligned_fileoff_and_other_vm_sizes(self):
        signed, unsigned = HelperPayloadTests().pair(cpu=0x01000007)
        for value in (signed, unsigned): struct.pack_into("<Q", value, 104 + 32, 16384)
        with self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(signed, unsigned)
        for extra in (1, 4096, 16384):
            pair = self.pair()
            for value in pair:
                old = struct.unpack_from("<Q", value, 104 + 32)[0]; struct.pack_into("<Q", value, 104 + 32, old + extra)
            with self.subTest(extra=extra), self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(*pair)

    def test_actual_unsigned_payload_and_other_load_commands_remain_in_digest(self):
        baseline = self.pair(); expected = hashlib.sha256(distribution.normalized_unsigned_helper(*baseline)).hexdigest()
        for offset in (1024, 16384, len(baseline[1]) - 1, 184):
            pair = self.pair()
            for value in pair: value[offset] ^= 1
            with self.subTest(offset=offset):
                self.assertNotEqual(hashlib.sha256(distribution.normalized_unsigned_helper(*pair)).hexdigest(), expected)

    def test_signature_terminal_cpu_and_preserved_vm_size_guards_remain(self):
        for index, offset, value in ((0, 208, 0), (0, 212, 0), (1, 4, 0x0100000C), (1, 136, 32768)):
            pair = self.pair()
            struct.pack_into("<I", pair[index], offset, value)
            with self.subTest(index=index, offset=offset), self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(*pair)
        signed, unsigned = self.pair(); signed.extend(b"hidden")
        with self.assertRaises(distribution.Gate): distribution.normalized_unsigned_helper(signed, unsigned)

    def test_old_supported_layouts_keep_exact_canonical_bytes(self):
        for cpu in (0x0100000C, 0x01000007):
            for size in (128, 32768):
                signed, unsigned = HelperPayloadTests().pair(size, cpu)
                expected = bytearray(unsigned); page = 16384 if cpu == 0x0100000C else 4096
                payload = len(unsigned) - page
                struct.pack_into("<Q", expected, 136, (payload + page - 1) // page * page)
                self.assertEqual(distribution.normalized_unsigned_helper(signed, unsigned), bytes(expected))

if __name__ == "__main__":
    unittest.main(verbosity=2)
