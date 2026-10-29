import XCTest

/// Explicitly opted-in hardware acceptance of system-audio reception. The
/// coordinator must already have approval for audio sharing to this paired device.
final class PeelAudioDeviceTests: XCTestCase {
    @MainActor
    func testApprovedPairedHostSystemAudioReceivesPCM() throws {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { environment[key] ?? environment["TEST_RUNNER_" + key] }
        guard value("PEEL_UI_TEST_APPROVED_SYSTEM_AUDIO") == "1",
              let host = value("PEEL_UI_TEST_HOST_NAME"), !host.isEmpty else {
            throw XCTSkip("Requires approved system-audio sharing and an exact already-paired Host")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        addTeardownBlock {
            await MainActor.run { XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel").terminate() }
        }
        app.launch()
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if back.waitForExistence(timeout: 3) { back.tap() }
        let rows = app.cells.containing(.staticText, identifier: host)
            .containing(NSPredicate(format: "label IN %@", ["Paired", "Connecting…", "Connected"]))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(rows.count, 1)
        let row = rows.element(boundBy: 0)
        if row.staticTexts["Paired"].exists {
            let menu = row.buttons.matching(NSPredicate(format: "label == %@", "More"))
            XCTAssertEqual(menu.count, 1)
            menu.element(boundBy: 0).tap()
            let connect = app.buttons.matching(NSPredicate(format: "label == %@", "Connect"))
            XCTAssertTrue(connect.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(connect.count, 1)
            connect.element(boundBy: 0).tap()
        }
        XCTAssertTrue(row.staticTexts["Connected"].waitForExistence(timeout: 20))
        app.buttons["peel.home.settings"].tap()
        let connectionOptions = app.buttons["Connection Options"]
        XCTAssertTrue(connectionOptions.waitForExistence(timeout: 5))
        connectionOptions.tap()
        let audio = app.buttons["Audio & Voice"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.tap()
        // The browser strips these documented Bonjour prefixes for display;
        // the audio row uses the session's unmodified Host name.
        let hostNames = [host, "Peel on " + host, "Peel Pro on " + host]
        let toggles = app.switches.matching(NSPredicate(format: "label IN %@", hostNames))
        let toggleExists = toggles.firstMatch.waitForExistence(timeout: 5)
        if !toggleExists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Audio controls hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(toggleExists)
        XCTAssertEqual(toggles.count, 1)
        let toggle = toggles.element(boundBy: 0)
        XCTAssertTrue(toggle.isEnabled && toggle.isHittable)
        // SwiftUI exposes an outer labelled row and an inner physical switch.
        // Tap the observed inner control so a row-centre tap cannot hit the label.
        XCTAssertEqual(toggle.switches.count, 1)
        let control = toggle.switches.element(boundBy: 0)
        XCTAssertTrue(control.isEnabled && control.isHittable)
        let initialState = try XCTUnwrap(control.value as? String)
        XCTAssertTrue(["0", "1"].contains(initialState), "Capture a definite playback preference before changing it")
        print("PEEL_SYSTEM_AUDIO_INITIAL_STATE=\(initialState)")
        // Teardown blocks run in reverse registration order, including after a
        // failed assertion, so restore the preference before terminating Peel.
        addTeardownBlock {
            await MainActor.run {
                let cleanupApp = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
                XCTAssertEqual(cleanupApp.state, .runningForeground, "Peel must remain available for playback cleanup")
                guard cleanupApp.state == .runningForeground else {
                    XCTFail("Unable to restore the original playback preference")
                    return
                }
                let cleanupRows = cleanupApp.switches.matching(NSPredicate(format: "label IN %@", hostNames))
                guard cleanupRows.count == 1, cleanupRows.element(boundBy: 0).switches.count == 1 else {
                    XCTFail("Unable to restore the original playback preference")
                    return
                }
                let cleanupControl = cleanupRows.element(boundBy: 0).switches.element(boundBy: 0)
                if cleanupControl.value as? String != initialState { cleanupControl.tap() }
                XCTAssertEqual(cleanupControl.value as? String, initialState, "Restore the original playback preference")
                print("PEEL_SYSTEM_AUDIO_RESTORED_STATE=\(initialState)")
            }
        }
        if control.value as? String != "1" { control.tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            control.value as? String == "1"
        }, object: control)
        let didEnable = XCTWaiter.wait(for: [enabled], timeout: 5)
        if didEnable != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Audio enable failure hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(didEnable, .completed, "The exact Host audio switch must turn on")
        print("PEEL_SYSTEM_AUDIO_SWITCH_ON")
        let receiving = app.staticTexts["Receiving system audio"]
        let receivedPCM = receiving.waitForExistence(timeout: 20)
        if !receivedPCM {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Audio reception failure hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(receivedPCM,
                      "The receiver must accept PCM packets, not merely request audio")
        let receipt = XCTAttachment(string: "Exact paired Host accepted system-audio PCM. This verifies reception and playback admission, not physical audibility.")
        receipt.name = "System audio PCM acceptance"
        receipt.lifetime = .keepAlways
        add(receipt)
        if control.value as? String == "1" { control.tap() }
        XCTAssertEqual(control.value as? String, "0", "The test must end its temporary playback session")
        XCTAssertTrue(app.staticTexts["Off"].waitForExistence(timeout: 5))
    }
}
