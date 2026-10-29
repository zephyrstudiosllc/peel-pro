#!/usr/bin/env python3
"""Native StoreKit tests of frozen production sources in one disposable simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
APPLE = ROOT / "Sources/PeelApple"
BUNDLE = "dev.peel.provalidation.storekit.host"
PHASES = [
    "testPhase1CatalogFreeAndCancelled",
    "testPhase2MonthlyPurchaseRestoreCancellationAndRefund",
    "testPhase3YearlyPurchaseAndExpiration",
    "testPhase4GrandfatheredLifetimePurchase",
    "testPhase5LifetimeRelaunchRestoreAndRefund",
    "testPhase6RevokedRelaunchAndNewLifetimePurchase",
    "testPhase7PendingAndDeclinedWithoutAccess",
]

LIFECYCLE_PHASES = ["testPhase1CatalogFree", *PHASES[1:6]]
LIFETIME_PHASES = ["testIndependentGrandfatheredLifetime", *PHASES[4:6]]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true", help="Generate only; no simulator, build, or test")
    parser.add_argument("--lifecycle-only", action="store_true", help="Signed external purchases and production entitlement/restore lifecycle; excludes purchase-action completion and pending")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17e")
    args = parser.parse_args()
    phases = LIFECYCLE_PHASES if args.lifecycle_only else PHASES
    output = ROOT / ".build" / ("pro-storekit-" + uuid.uuid4().hex[:10])
    output.mkdir(parents=True)
    snapshot = output / "ProductionSources"
    snapshot.mkdir()
    manifest = {"scope": "Local Xcode StoreKit tests of production PeelStore; no real Apple Account or charge",
                "runtime": args.runtime, "name": "Peel-Pro-StoreKit-" + output.name,
                "sources": [], "phases": [], "commands": [], "status": "preparing",
                "mode": "signed-external-lifecycle" if args.lifecycle_only else "purchase-action", "expectedPhases": phases}
    device = None

    def save():
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def run(command, log, timeout=300, check=True):
        with (output / log).open("w") as stream:
            try:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
            except subprocess.TimeoutExpired:
                manifest["commands"].append({"argv": command, "log": log, "exitCode": None, "timeoutSeconds": timeout})
                save()
                raise
        manifest["commands"].append({"argv": command, "log": log, "exitCode": result.returncode})
        save()
        if check and result.returncode:
            raise RuntimeError(f"Exit {result.returncode}: {command[:3]}, see {output / log}")
        return result

    try:
        sources = []
        for relative in ["Shared/Client/PeelStore.swift", "Shared/Client/PeelCapabilityPolicy.swift",
                         "Shared/Client/PeelAISubscriptionPolicy.swift", "Shared/Client/PeelLegacyPurchasePolicy.swift",
                         "Shared/Client/PaywallView.swift", "Shared/Client/PeelProFeature.swift",
                         "Shared/Client/PeelAISubscriptionSection.swift"]:
            source = APPLE / relative
            target = snapshot / source.name
            shutil.copyfile(source, target)
            sources.append(str(target))
            manifest["sources"].append({"path": str(source), "sha256": sha(source), "copy": str(target)})
        # The exact production runtime gate is embedded in a much larger wire
        # schema. Extract it unchanged; do not replace it with a test stub.
        shared = APPLE / "Shared/All/PeelSharedMessages.swift"
        text = shared.read_text()
        start = text.index("nonisolated enum PeelAIFeatureAccess {")
        end = text.index("\nenum PeelAgentPresentation", start)
        gate = snapshot / "PeelAIFeatureAccess.swift"
        gate.write_text("import Foundation\n\n" + text[start:end] + "\n")
        sources.append(str(gate))
        manifest["sources"].append({"path": str(shared), "sha256": sha(shared), "extractedPath": str(gate),
                                    "extractedSHA256": sha(gate), "startOffset": start, "endOffset": end})
        catalog_source = APPLE / "Shared/All/Peel Storekit Config.storekit"
        catalog = output / "ProProducts.storekit"
        shutil.copyfile(catalog_source, catalog)
        catalog_data = json.loads(catalog.read_text())
        flat = list(catalog_data["products"])
        flat += [item for group in catalog_data["subscriptionGroups"] for item in group["subscriptions"]]
        expected = {"peel.pro.monthly": "4.99", "peel.pro.yearly": "29.99", "peel.pro.lifetime": "119.99"}
        for identifier, price in expected.items():
            product = next(p for p in flat if p["productID"] == identifier)
            assert product["displayPrice"] == price, (identifier, "wrong configured USD price")
            assert product["familyShareable"] is True, (identifier, "not locally family-shareable")
        manifest["sources"].append({"path": str(catalog_source), "sha256": sha(catalog_source), "copy": str(catalog)})
        info_source = APPLE / "Peel-iPad/Info.plist"
        info = plistlib.loads(info_source.read_bytes())
        subscription_ids = info["PeelAISubscriptionProductIDs"]
        assert set(subscription_ids) == {"peel.pro.monthly", "peel.pro.yearly"}
        manifest["sources"].append({"path": str(info_source), "sha256": sha(info_source)})
        # SwiftUI's named Image lookup needs a compiled asset catalog. Copy
        # this one production image set rather than the entire product catalog.
        icon_source = APPLE / "Peel/Assets.xcassets/PeelHostMenuBarIcon_256x256.imageset"
        icon_catalog = output / "FixtureAssets.xcassets"
        icon_catalog.mkdir()
        (icon_catalog / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
        shutil.copytree(icon_source, icon_catalog / icon_source.name)
        for resource in icon_source.iterdir():
            if resource.is_file():
                manifest["sources"].append({"path": str(resource), "sha256": sha(resource),
                                            "copy": str(icon_catalog / icon_source.name / resource.name)})

        if not args.prepare_only:
            run(["xcrun", "simctl", "create", manifest["name"], args.device_type, args.runtime], "create.log")
            device = (output / "create.log").read_text().strip()
            uuid.UUID(device)
            manifest["simulatorUDID"] = device
        else:
            manifest["simulatorUDID"] = "PREPARE-ONLY-NO-DEVICE"
        test_sources = [str(HERE / "ProStoreKitTests.swift"), *sources,
                        {"path": str(catalog), "buildPhase": "resources"}]
        manifest["harnessSources"] = [{"path": str(p), "sha256": sha(p)} for p in HERE.glob("*.swift")]
        spec = {
            "name": "PeelProStoreKitValidation",
            "options": {"deploymentTarget": {"iOS": "17.0"}},
            "settings": {"base": {"SWIFT_VERSION": "5.0", "CODE_SIGN_IDENTITY": "-", "GENERATE_INFOPLIST_FILE": "YES"}},
            "targets": {
                "ProStoreKitHost": {"type": "application", "platform": "iOS", "sources": [str(HERE / "HostApp.swift"),
                    {"path": str(icon_catalog), "buildPhase": "resources"}],
                    "info": {"path": "HostInfo.plist", "properties": {"PeelAISubscriptionProductIDs": subscription_ids}},
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": BUNDLE,
                        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES", "TARGETED_DEVICE_FAMILY": "1,2",
                        "ASSETCATALOG_COMPILER_APPICON_NAME": ""}}},
                "ProStoreKitTests": {"type": "bundle.unit-test", "platform": "iOS", "sources": test_sources,
                    "dependencies": [{"target": "ProStoreKitHost"}],
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "dev.peel.provalidation.storekit.tests",
                        "ENABLE_TESTING_SEARCH_PATHS": "YES"}}}},
            "schemes": {"PeelProStoreKit": {
                "build": {"targets": {"ProStoreKitHost": "all", "ProStoreKitTests": ["test"]}},
                "run": {"storeKitConfiguration": "ProProducts.storekit"},
                "test": {"targets": ["ProStoreKitTests"], "parallelizable": False, "gatherCoverageData": False,
                         "environmentVariables": {"PEEL_PRO_TEST_UDID": manifest["simulatorUDID"], "PEEL_PRO_LIFECYCLE_ONLY": "1" if args.lifecycle_only else "0"}}}}
        }
        (output / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
        run(["xcodegen", "generate", "--spec", str(output / "project.json"), "--project", str(output)], "generate.log")
        print(f"Prepared native StoreKit project: {output}", flush=True)
        if args.prepare_only:
            manifest["status"] = "prepared-not-built-or-run"
        else:
            base = ["xcodebuild", "-project", str(output / "PeelProStoreKitValidation.xcodeproj"),
                    "-scheme", "PeelProStoreKit", "-destination", f"platform=iOS Simulator,id={device}",
                    "-derivedDataPath", str(output / "DerivedData"), "-jobs", "2",
                    "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
            run(base + ["build-for-testing"], "build.log", timeout=600)
            # Own the boot explicitly so Xcode does not shut the simulator down
            # between the independent test-host process launches.
            run(["xcrun", "simctl", "boot", device], "boot.log", timeout=60)
            run(["xcrun", "simctl", "bootstatus", device, "-b"], "bootstatus.log", timeout=180)
            for number, phase in enumerate(phases, 1):
                print(f"Running {phase}", flush=True)
                result = run(base + ["test-without-building", f"-only-testing:ProStoreKitTests/ProStoreKitTests/{phase}",
                                    "-resultBundlePath", str(output / f"phase{number}.xcresult")],
                             f"phase{number}.log", timeout=240 if number == 1 else 180, check=False)
                manifest["phases"].append({"phase": phase, "exitCode": result.returncode})
                run(["xcrun", "simctl", "terminate", device, BUNDLE], f"terminate{number}.log", check=False)
                if result.returncode:
                    raise RuntimeError(f"StoreKit phase {number} failed; see phase{number}.log")
                phase_log = (output / f"phase{number}.log").read_text()
                executed = (f"PEEL_PRO_STOREKIT_PHASE_{number}_PASS" in phase_log
                            and f"{phase}]' passed" in phase_log
                            and "Executed 1 test, with 0 failures" in phase_log)
                manifest["phases"][-1]["executedExactlyOnePassingTest"] = executed
                if not executed:
                    raise RuntimeError(f"StoreKit phase {number} did not report exactly one passing named test")
            manifest["status"] = "passed"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        print(str(error), file=sys.stderr, flush=True)
    finally:
        if device:
            try:
                run(["xcrun", "simctl", "shutdown", device], "shutdown.log", timeout=45, check=False)
            except subprocess.TimeoutExpired:
                manifest["cleanupWarning"] = "Owned simulator shutdown timed out; coordinator must inspect this exact UUID"
        save()
        print(f"Result {manifest['status']}; manifest {output / 'manifest.json'}", flush=True)
    return 0 if manifest["status"] in {"passed", "prepared-not-built-or-run"} else 1


if __name__ == "__main__":
    sys.exit(main())
