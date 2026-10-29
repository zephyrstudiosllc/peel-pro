import XCTest

/// Runs against an installed client; the atomic diagnostic case explicitly
/// requires the Debug fixture opt-in. This neither
/// grants pairing/permissions nor changes StoreKit state or a remote machine.
final class PeelFreeStreamingLaunchTests: XCTestCase {
    @MainActor
    func testInstalledClientLaunchAndSettingsRemainAvailable() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        app.launch()
        defer { app.terminate() } // End any retained background stream after this check.
        let returnButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        let settings = app.buttons["peel.home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "Installed client did not expose its manual access screen")
        XCTAssertTrue(settings.isHittable, "A startup overlay blocks manual access")
        let launchScreenshot = XCTAttachment(screenshot: app.screenshot())
        launchScreenshot.name = "Installed Release client launch"
        launchScreenshot.lifetime = .keepAlways
        add(launchScreenshot)
        settings.tap()
        let restore = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Restore")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "Settings did not expose purchase recovery")
        let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
        settingsScreenshot.name = "Installed Release client settings"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)
    }

    /// Home toolbar reachability only: opens local sheets, never pairs,
    /// connects, purchases, or shares a stream.
    @MainActor
    func testHomeToolbarReachesAudioWatchAndAbout() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        app.launch()
        defer { app.terminate() }
        let returnButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 30), "Home must expose Settings")
        XCTAssertTrue(app.buttons["peel.home.status"].exists, "Home must expose Computer Status")
        let more = app.buttons["peel.home.more"]
        XCTAssertTrue(more.exists && more.isHittable, "Home must expose More Options")

        // Regular width shows Audio beside Status; compact width keeps it under More.
        var audio = app.buttons["peel.home.audio"]
        if !audio.exists {
            more.tap()
            audio = app.buttons["Audio"]
            XCTAssertTrue(audio.waitForExistence(timeout: 5), "Compact More Options must offer Audio")
        }
        audio.tap()
        let audioBar = app.navigationBars["Audio"]
        XCTAssertTrue(audioBar.waitForExistence(timeout: 10), "Audio controls must open from the home toolbar")
        audioBar.buttons["Done"].tap()

        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let watch = app.buttons["Apple Watch & Cloud Agents"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5), "More Options must keep Watch and cloud agent setup reachable")
        XCTAssertTrue(app.buttons["Connect by Address…"].exists, "More Options must offer Connect by Address")
        XCTAssertTrue(app.buttons["About Peel Pro"].exists, "More Options must offer About")
        watch.tap()
        let watchBar = app.navigationBars["Watch & Cloud Agents"]
        XCTAssertTrue(watchBar.waitForExistence(timeout: 10), "Watch companion must open from More Options")
        watchBar.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPairedMiniDesktopOpensWithoutPurchasePrompt() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let expectedHost = environment["PEEL_UI_TEST_HOST_NAME"], !expectedHost.isEmpty,
              let expectedWidth = environment["PEEL_UI_TEST_DISPLAY_WIDTH"], !expectedWidth.isEmpty else {
            throw XCTSkip("Set PEEL_UI_TEST_HOST_NAME and PEEL_UI_TEST_DISPLAY_WIDTH for the explicitly reserved paired machine")
        }
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        app.launch()
        defer { app.terminate() } // End any retained background stream after this check.
        let returnButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        let desktop = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", expectedHost, expectedWidth
        ))
        XCTAssertTrue(desktop.firstMatch.waitForExistence(timeout: 20), "Expected paired mini display was unavailable; never substitute another machine")
        XCTAssertEqual(desktop.count, 1, "The expected display must resolve unambiguously")
        desktop.element(boundBy: 0).tap()
        XCTAssertTrue(returnButton.waitForExistence(timeout: 20), "Manual desktop did not open its stream scene")
        let status = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", expectedHost, "Stream status:"
        )).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Stream scene did not identify its intended machine")
        XCTAssertFalse(app.buttons["Restore Purchases"].exists, "A purchase surface intercepted free desktop access")
        // Observe routing only. Do not type into, click, or screenshot the owner's desktop.
        returnButton.tap()
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPairedStreamExposesReceiverMeasurements() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let expectedHost = environment["PEEL_UI_TEST_HOST_NAME"], !expectedHost.isEmpty,
              let expectedWidth = environment["PEEL_UI_TEST_DISPLAY_WIDTH"], !expectedWidth.isEmpty else {
            throw XCTSkip("Set the explicitly reserved paired Host and display width")
        }
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        addTeardownBlock {
            await MainActor.run {
                XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel").terminate()
            }
        }
        app.launch()
        let returnButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        let desktop = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", expectedHost, expectedWidth))
        XCTAssertTrue(desktop.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(desktop.count, 1, "Never substitute another machine or display")
        desktop.element(boundBy: 0).tap()
        XCTAssertTrue(returnButton.waitForExistence(timeout: 20))
        let expand = app.buttons["Expand toolbar"]
        if expand.exists { expand.tap() }
        let details = app.buttons["Stream Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        func row(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "peel.streamDetails.\(id)").firstMatch
        }
        let received = row("receivedFrames")
        XCTAssertTrue(received.waitForExistence(timeout: 15), "No receiver snapshot became available")
        let hasFrames = NSPredicate { _, _ in
            let value = (received.value as? String) ?? ""
            return (Int(value.filter(\.isNumber)) ?? 0) > 0
        }
        expectation(for: hasFrames, evaluatedWith: received)
        waitForExpectations(timeout: 15)
        let fields = ["resolution", "receivedFrames", "lastReceivedAge", "presentationFPS", "screenMaximumFPS",
                      "queuedFrames", "queueAge", "decoderState", "decoderError", "clientDrops", "decoderDrops", "recoveryRequests"]
        var measurements: [String: String] = [:]
        for field in fields {
            let element = row(field)
            // SwiftUI List creates its lower rows lazily inside the iPad sheet.
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            for _ in 0..<3 where !element.exists {
                XCTAssertTrue(list.exists, "Stream Details must expose its scrollable list")
                list.swipeUp()
            }
            XCTAssertTrue(element.exists, "Missing measurement row: \(field)")
            measurements[field] = element.value as? String ?? element.label
        }
        XCTAssertNotEqual(measurements["resolution"], "Unavailable")
        let payload = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys, .prettyPrinted])
        let receipt = XCTAttachment(data: payload, uniformTypeIdentifier: "public.json")
        receipt.name = "Live paired receiver measurements; not display or latency acceptance"
        receipt.lifetime = .keepAlways
        add(receipt)
        // Do not interact with or explicitly screenshot the remote desktop.
        app.buttons["peel.streamDetails.done"].tap()
        XCTAssertTrue(returnButton.waitForExistence(timeout: 10))
        returnButton.tap()
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }

    /// A single accessibility read returns one immutable, content-free model.
    /// Debug observability is not evidence of production paid-feature behavior.
    @MainActor
    func testPairedStreamExposesAtomicReceiverMeasurements() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["PEEL_UI_TEST_ATOMIC_DIAGNOSTICS"] == "1",
              let expectedHost = environment["PEEL_UI_TEST_HOST_NAME"], !expectedHost.isEmpty,
              let expectedWidth = environment["PEEL_UI_TEST_DISPLAY_WIDTH"], !expectedWidth.isEmpty else {
            throw XCTSkip("Opt in with PEEL_UI_TEST_ATOMIC_DIAGNOSTICS=1 and the reserved Host/display; install a Debug client")
        }
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        app.launchEnvironment["PEEL_STREAM_DIAGNOSTICS_UI_FIXTURE"] = "1"
        addTeardownBlock {
            await MainActor.run { XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel").terminate() }
        }
        app.launch()
        let returnButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        let desktop = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", expectedHost, expectedWidth))
        XCTAssertTrue(desktop.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(desktop.count, 1, "Never substitute another machine or display")
        desktop.element(boundBy: 0).tap()
        XCTAssertTrue(returnButton.waitForExistence(timeout: 20))
        let expand = app.buttons["Expand toolbar"]
        if expand.exists { expand.tap() }
        XCTAssertTrue(app.buttons["Stream Details"].waitForExistence(timeout: 10))
        app.buttons["Stream Details"].tap()
        let copy = app.buttons["peel.streamDetails.copyDiagnostics"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15))

        func readReceipt() -> [String: Any]? {
            guard let text = copy.value as? String, let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["version"] as? Int == 1, value["metric"] is [String: Any] else { return nil }
            return value
        }
        var first: [String: Any]?
        let initial = NSPredicate { _, _ in
            guard let value = readReceipt(), let metric = value["metric"] as? [String: Any],
                  (metric["receivedFrames"] as? NSNumber)?.int64Value ?? 0 > 0 else { return false }
            first = value
            return true
        }
        expectation(for: initial, evaluatedWith: copy)
        waitForExpectations(timeout: 15)
        let before = try XCTUnwrap(first, "Atomic receipt unavailable: the installed client must be Debug with the fixture flag")
        let beforeEnd = try XCTUnwrap(before["samplingCompletedAtClientUptimeSeconds"] as? Double)
        var second: [String: Any]?
        let later = NSPredicate { _, _ in
            guard let value = readReceipt(),
                  let start = value["samplingStartedAtClientUptimeSeconds"] as? Double,
                  start >= beforeEnd + 8 else { return false }
            second = value
            return true
        }
        expectation(for: later, evaluatedWith: copy)
        waitForExpectations(timeout: 20)
        let after = try XCTUnwrap(second)
        let previousMetric = try XCTUnwrap(before["metric"] as? [String: Any])
        let currentMetric = try XCTUnwrap(after["metric"] as? [String: Any])
        let afterStart = try XCTUnwrap(after["samplingStartedAtClientUptimeSeconds"] as? Double)
        let afterEnd = try XCTUnwrap(after["samplingCompletedAtClientUptimeSeconds"] as? Double)
        let beforeStart = try XCTUnwrap(before["samplingStartedAtClientUptimeSeconds"] as? Double)
        let identityMatches = before["observationSessionID"] as? String == after["observationSessionID"] as? String &&
            ["windowId", "rendererGeneration", "rendererKind", "width", "height"].allSatisfy {
                guard let old = previousMetric[$0] as? NSObject, let new = currentMetric[$0] as? NSObject else { return false }
                return old == new
            }
        let fields = ["receivedFrames", "receivedBytes", "enqueuedFrames", "applicationDroppedFrames", "recoveryRequests"]
        var deltas: [String: Any] = [:]
        var comparable = identityMatches && afterStart > beforeEnd && afterEnd >= afterStart && beforeEnd >= beforeStart
        for field in fields {
            switch (previousMetric[field] as? NSNumber, currentMetric[field] as? NSNumber) {
            case let (old?, new?):
                if new.int64Value < old.int64Value { comparable = false }
                else { deltas[field] = new.int64Value - old.int64Value }
            case (nil, nil): break
            default: comparable = false
            }
        }
        var result: [String: Any] = ["first": before, "second": after,
            "sameGenerationCounterDeltaAvailable": comparable,
            "scope": "Debug receiver observations; not scanout, input latency, or production entitlement acceptance"]
        if comparable {
            deltas["minimumIntervalSeconds"] = afterStart - beforeEnd
            deltas["maximumIntervalSeconds"] = afterEnd - beforeStart
            result["counterDelta"] = deltas
        } else {
            result["counterDeltaUnavailableReason"] = "Identity, renderer generation, interval, or counter reset boundary; do not calculate a rate"
        }
        let payload = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: payload, uniformTypeIdentifier: "public.json")
        attachment.name = "Atomic receiver observations and guarded counter deltas"
        attachment.lifetime = .keepAlways
        add(attachment)
        // No clipboard change, remote input, or screenshot of the owner's desktop.
        app.buttons["peel.streamDetails.done"].tap()
        XCTAssertTrue(returnButton.waitForExistence(timeout: 10))
        returnButton.tap()
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }

}
