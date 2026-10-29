import Foundation
import CoreGraphics

// The production local listing parser over synthetic window-server rows. Its
// only providers are the rows and an app lookup: no AX, pixel or icon pass
// can run. No window list, process or screen is read.

/// Constant-only stand-in so the production PeelLocalComputerAccess compiles for
/// its window policy. Mirrors the flag in Peel-Host/PeelHost/InputSynthesizer.swift;
/// the real synthesizer, flag and authority are covered by the LocalComputerRoute
/// and AgentControl harnesses. No events are synthesized here.
enum InputSynthesizer {
    nonisolated static let localControlGenerationFlag: UInt64 = 1 << 63
}

@main struct LocalWindowInventoryChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS \(message)")
    }

    static func row(_ id: UInt32, pid: pid_t, owner: String = "App", title: String? = "Doc", layer: Int = 0,
                    sharing: Int = 1, alpha: Double = 1, width: Int = 800, height: Int = 600) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer, kCGWindowSharingState as String: sharing, kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: height).dictionaryRepresentation as NSDictionary
        ]
        if let title { row[kCGWindowName as String] = title }
        return row
    }

    static func main() {
        let ownPID: pid_t = 100, ownBundle = "org.peel.fixture.host"
        let apps: [pid_t: PeelLocalWindowInventory.Application] = [
            ownPID: .init(bundleIdentifier: ownBundle, launchTimeIntervalSince1970: 1000, isRegular: true, isTerminated: false),
            200: .init(bundleIdentifier: "com.apple.SecurityAgent", launchTimeIntervalSince1970: 1000, isRegular: true, isTerminated: false),
            300: .init(bundleIdentifier: "com.example.menu", launchTimeIntervalSince1970: 1000, isRegular: false, isTerminated: false),
            400: .init(bundleIdentifier: "com.example.gone", launchTimeIntervalSince1970: 1000, isRegular: true, isTerminated: true),
            500: .init(bundleIdentifier: nil, launchTimeIntervalSince1970: 1000, isRegular: true, isTerminated: false),
            600: .init(bundleIdentifier: "com.example.fixture", launchTimeIntervalSince1970: 2000, isRegular: true, isTerminated: false)
        ]
        var lookups: [pid_t] = []
        let lookup: (pid_t) -> PeelLocalWindowInventory.Application? = { pid in lookups.append(pid); return apps[pid] }

        var rows = [
            row(1, pid: ownPID, owner: "Peel Pro"), row(2, pid: 200, owner: "SecurityAgent"),
            row(3, pid: 300), row(4, pid: 400), row(5, pid: 500), row(6, pid: 999),
            row(7, pid: 600, layer: 25), row(8, pid: 600, sharing: 0), row(9, pid: 600, alpha: 0),
            row(10, pid: 600, width: 100, height: 50), row(11, pid: 600, owner: "Fixture", title: "  ")
        ]
        rows += (0..<140).map { row(1000 + UInt32($0), pid: 600, owner: "Fixture", title: "Window \($0)") }

        let entries = PeelLocalWindowInventory.entries(rows, application: lookup)
        require(Set(lookups) == Set(apps.keys).union([999]) && lookups.count == Set(lookups).count,
                "one app lookup per owning process, however many rows")
        require(!entries.contains { [7, 8, 9, 10, 3, 4, 6].contains($0.window.windowId) },
                "non-normal layer, unshared, transparent, tiny, non-regular, terminated and vanished owners skipped")
        require(entries.allSatisfy { $0.window.appIconPNGBase64 == nil && $0.window.statusSummary == nil },
                "no icon or status pass in the local listing")
        let blank = entries.first { $0.window.windowId == 11 }
        require(blank?.window.title == "Window" && blank?.fingerprint.title == "Window" &&
                blank?.fingerprint.ownerProcessID == 600 && blank?.fingerprint.appBundleIdentifier == "com.example.fixture" &&
                blank?.fingerprint.appLaunchTimeBitPattern == (2000.0).bitPattern && blank?.fingerprint.hasDurableIdentity == true,
                "row binds exact PID, bundle and launch identity")

        // Host route order: eligibility, then the advertised cap.
        let eligible = entries.filter {
            PeelLocalComputerWindowPolicy.isEligible($0.fingerprint, ownProcessID: ownPID, ownBundleIdentifier: ownBundle)
        }
        require(!eligible.contains { [1, 2, 5].contains($0.window.windowId) }, "own, authentication-agent and bundle-less windows excluded")
        let current = Array(eligible.prefix(PeelAgentAdvertisedWindowInventory.maximumWindows))
        require(current.count == 128 && eligible.count > current.count && current.first?.window.windowId == 11,
                "capped at 128 in window-server order and reported truncated")

        // A listing published under one grant generation is not usable under another.
        var inventory = PeelAgentAdvertisedWindowInventory()
        let listedScope = PeelAgentPresentationScope(pairingID: "local", generation: 4)
        inventory.replace(scope: listedScope, instances: current.map(\.fingerprint))
        require(inventory.advertisedInstance(windowID: 11, scope: listedScope) == blank?.fingerprint,
                "listed window advertised under its own generation")
        require(inventory.advertisedInstance(windowID: 11, scope: .init(pairingID: "local", generation: 5)) == nil,
                "stale-generation listing refused")

        // The single-row focus recheck parses the same fingerprint as the listing.
        let recheck = PeelLocalWindowInventory.entry(rows[10], application: { apps[$0] })
        require(recheck?.fingerprint == blank?.fingerprint, "focus recheck row matches the listed fingerprint")
        require(PeelLocalWindowInventory.entry(rows[9], application: { apps[$0] }) != nil,
                "focus recheck keeps no listing size floor")
    }
}
