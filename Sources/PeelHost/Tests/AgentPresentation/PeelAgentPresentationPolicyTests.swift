import Foundation

private enum TestFailure: Error {
    case failed(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw TestFailure.failed(message)
    }
}

private func instance(
    id: UInt32,
    title: String? = nil,
    isDisplay: Bool = false,
    launchTime: TimeInterval? = 1_700_000_000
) -> PeelAgentWindowInstanceFingerprint {
    PeelAgentWindowInstanceFingerprint(
        windowID: id,
        ownerProcessID: isDisplay ? nil : Int32(1_000 + id),
        appBundleIdentifier: isDisplay ? nil : "com.example.fixture",
        appName: isDisplay ? "Peel Display" : "Fixture App",
        title: title ?? "Window \(id)",
        width: 800,
        height: 600,
        appLaunchTimeIntervalSince1970: isDisplay ? nil : launchTime,
        isDisplay: isDisplay,
        displayID: isDisplay ? id + 10 : nil
    )
}

private func testInventoryIsBoundedAndGenerationScoped() throws {
    let scope = PeelAgentPresentationScope(pairingID: "pair-a", generation: 7)
    var inventory = PeelAgentAdvertisedWindowInventory()
    inventory.replace(
        scope: scope,
        instances: (0..<130).map { instance(id: UInt32($0)) }
    )

    try require(
        inventory.count == PeelAgentAdvertisedWindowInventory.maximumWindows,
        "inventory exceeded its bound"
    )
    try require(
        inventory.advertisedInstance(windowID: 3, scope: scope) == instance(id: 3),
        "advertised instance was not retained"
    )
    try require(
        inventory.advertisedInstance(
            windowID: 3,
            scope: .init(pairingID: "pair-a", generation: 8)
        ) == nil,
        "inventory crossed a connection generation"
    )
    try require(
        inventory.advertisedInstance(
            windowID: 3,
            scope: .init(pairingID: "pair-b", generation: 7)
        ) == nil,
        "inventory crossed a pairing"
    )
    try require(
        inventory.advertisedInstance(windowID: 129, scope: scope) == nil,
        "inventory retained a record beyond its bound"
    )

    let reused = instance(id: 3, title: "Replacement")
    try require(
        inventory.advertisedInstance(windowID: 3, scope: scope) != reused,
        "window-id reuse passed the instance fingerprint"
    )

    inventory.clear()
    try require(inventory.count == 0, "inventory did not clear")
}

private func testPendingAcknowledgmentsAreBoundedAndCorrelated() throws {
    let scope = PeelAgentPresentationScope(pairingID: "pair-a", generation: 11)
    let requestIDs = (0..<5).map { _ in UUID() }
    var tracker = PeelAgentPendingPresentationTracker()

    for requestID in requestIDs.prefix(4) {
        try require(
            tracker.insert(
                .init(
                    requestID: requestID,
                    scope: scope,
                    deadlineUptimeNanoseconds: 1_000
                ),
                nowUptimeNanoseconds: 100
            ),
            "tracker rejected an acknowledgment inside its bound"
        )
    }
    try require(
        !tracker.insert(
            .init(
                requestID: requestIDs[4],
                scope: scope,
                deadlineUptimeNanoseconds: 1_000
            ),
            nowUptimeNanoseconds: 100
        ),
        "tracker accepted more than four acknowledgments"
    )

    try require(
        tracker.take(
            requestID: requestIDs[0],
            generation: 12,
            nowUptimeNanoseconds: 200
        ) == .generationMismatch,
        "wrong-generation acknowledgment was accepted"
    )
    try require(tracker.count == 4, "wrong generation removed pending state")

    let expected = PeelAgentPendingPresentation(
        requestID: requestIDs[0],
        scope: scope,
        deadlineUptimeNanoseconds: 1_000
    )
    try require(
        tracker.take(
            requestID: requestIDs[0],
            generation: 11,
            nowUptimeNanoseconds: 200
        ) == .matched(expected),
        "matching acknowledgment was not consumed"
    )
    try require(
        tracker.take(
            requestID: requestIDs[0],
            generation: 11,
            nowUptimeNanoseconds: 200
        ) == .missing,
        "duplicate acknowledgment was not ignored"
    )

    let expiringID = UUID()
    try require(
        tracker.insert(
            .init(
                requestID: expiringID,
                scope: scope,
                deadlineUptimeNanoseconds: 250
            ),
            nowUptimeNanoseconds: 200
        ),
        "tracker rejected an expiring acknowledgment"
    )
    guard case .expired(let expired) = tracker.take(
        requestID: expiringID,
        generation: 11,
        nowUptimeNanoseconds: 250
    ) else {
        throw TestFailure.failed("late acknowledgment was not expired")
    }
    try require(expired.requestID == expiringID, "wrong acknowledgment expired")

    let removed = tracker.removeAll()
    try require(removed.count == 3, "tracker removed an unexpected pending count")
    try require(tracker.count == 0, "tracker did not clear")
}

private func testInvalidLaunchIdentityIsUnavailable() throws {
    let invalid: [TimeInterval?] = [nil, .nan, .infinity, -.infinity, -1, 0]
    for value in invalid {
        try require(instance(id: 1, launchTime: value).appLaunchTimeBitPattern == nil,
                    "invalid launch time became a durable identity")
        try require(!instance(id: 1, launchTime: value).hasDurableIdentity,
                    "unidentifiable app window was offered for presentation")
    }
    try require(instance(id: 1).appLaunchTimeBitPattern != nil,
                "valid launch time was rejected")
    try require(instance(id: 1).hasDurableIdentity, "identified app window was unavailable")
    try require(instance(id: 1, isDisplay: true).hasDurableIdentity,
                "desktop incorrectly required an app process")

    for missingProcess in [true, false] {
        let window = PeelAgentWindowInstanceFingerprint(
            windowID: 1, ownerProcessID: missingProcess ? nil : 1001,
            appBundleIdentifier: missingProcess ? "com.example.fixture" : nil,
            appName: "Fixture", title: "Window", width: 800, height: 600,
            appLaunchTimeIntervalSince1970: 1_700_000_000,
            isDisplay: false, displayID: nil)
        try require(!window.hasDurableIdentity,
                    "partially identified app window was offered for presentation")
    }
    let missingDisplay = PeelAgentWindowInstanceFingerprint(
        windowID: 1, ownerProcessID: nil, appBundleIdentifier: nil,
        appName: "Desktop", title: "Desktop", width: 800, height: 600,
        appLaunchTimeIntervalSince1970: nil, isDisplay: true, displayID: nil)
    try require(!missingDisplay.hasDurableIdentity,
                "unidentified desktop was offered for presentation")
}

private func testDeliveryPreservesAuthoritativeInventory() throws {
    let source = (0..<140).map { index in
        PeelWindow(
            windowId: UInt32(index),
            appName: String(repeating: "A", count: 121),
            title: String(repeating: "🪟", count: 300) + String(index),
            width: 800, height: 600,
            statusSummary: "ready", appIconPNGBase64: "unused-icon",
            appLaunchTimeIntervalSince1970: 1_700_000_000
        )
    }
    let message = try PeelAgentWindowDelivery.currentList(source)
    let decoded = try JSONDecoder().decode(
        WindowListMessage.self, from: JSONEncoder().encode(message)
    )
    try require(decoded.windows.count == source.count,
                "authoritative delivery dropped windows beyond the MCP limit")
    for (original, delivered) in zip(source, decoded.windows) {
        try require(delivered.windowId == original.windowId &&
                    delivered.appName == original.appName &&
                    delivered.title == original.title &&
                    delivered.width == original.width && delivered.height == original.height &&
                    delivered.appLaunchTimeIntervalSince1970 == original.appLaunchTimeIntervalSince1970,
                    "delivery changed the client window-instance identity")
        try require(delivered.appIconPNGBase64 == nil, "delivery retained unused icon data")
        let presentationWindow = PeelAgentWindowDelivery.window(original)
        try require(presentationWindow.title == delivered.title &&
                    presentationWindow.appName == delivered.appName,
                    "presentation and inventory disagree about identity")
    }
    let oversized = PeelWindow(
        windowId: 999, appName: "fixture", title: String(repeating: "x", count: 256 * 1024),
        width: 1, height: 1, statusSummary: nil, appIconPNGBase64: nil,
        appLaunchTimeIntervalSince1970: 1_700_000_000
    )
    do {
        _ = try PeelAgentWindowDelivery.currentList(source + [oversized])
        throw TestFailure.failed("oversized delivery was accepted or silently truncated")
    } catch PeelAgentWindowDelivery.DeliveryError.payloadTooLarge {
        // Explicit rejection preserves the client's existing authoritative list.
    }
}

@main
private struct PeelAgentPresentationPolicyTestMain {
    static func main() throws {
        try testInventoryIsBoundedAndGenerationScoped()
        print("PASS: bounded generation-scoped inventory")
        try testPendingAcknowledgmentsAreBoundedAndCorrelated()
        print("PASS: bounded generation-aware acknowledgments")
        try testInvalidLaunchIdentityIsUnavailable()
        print("PASS: invalid launch identities fail closed")
        try testDeliveryPreservesAuthoritativeInventory()
        print("PASS: complete exact window delivery and oversized rejection")
    }
}
