import XCTest

/// Targets one explicit synthetic Host window. Host report deltas independently
/// establish delivered input; passing client automation alone is insufficient.
final class PeelStreamingFixtureTests: XCTestCase {
    private struct Fixture {
        let title: String
        let host: String

        static func fromEnvironment() throws -> Fixture {
            let environment = ProcessInfo.processInfo.environment
            func value(_ key: String) -> String? { environment[key] ?? environment["TEST_RUNNER_" + key] }
            guard let title = value("PEEL_FIXTURE_WINDOW_TITLE"),
                  title.hasPrefix("Peel Fixture "),
                  title.count == "Peel Fixture ".count + 8,
                  title.suffix(8).allSatisfy({ $0.isHexDigit }),
                  let host = value("PEEL_UI_TEST_HOST_NAME"), !host.isEmpty else {
                throw XCTSkip("Provide the exact fresh owned fixture title and already-paired Host")
            }
            return Fixture(title: title, host: host)
        }
    }

    @MainActor
    private func client() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        addTeardownBlock {
            await MainActor.run { XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel").terminate() }
        }
        return app
    }

    @MainActor
    private func launchClient(_ app: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        let attachRunning = environment["PEEL_UI_TEST_ATTACH_RUNNING_CLIENT"]
            ?? environment["TEST_RUNNER_PEEL_UI_TEST_ATTACH_RUNNING_CLIENT"]
        if attachRunning == "1" {
            // Diagnostic-only coordinator opt-in: retain devicectl's stdout
            // attachment through the first background/resume transition.
            XCTAssertNotEqual(app.state, .notRunning, "The coordinator must prelaunch the exact installed client")
            app.activate()
        } else {
            app.launch()
        }
    }

    @MainActor
    private func returnButton(_ app: XCUIElement) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
    }

    @MainActor
    private func fixtureStatus(_ app: XCUIElement, active: Bool = false) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@",
            "Peel Streaming Fixture", active ? "Stream status: Active." : "Stream status:"
        )).firstMatch
    }

    @MainActor
    private func foregroundFixtureWindow(_ app: XCUIApplication) throws -> XCUIElement {
        // iPad keeps a restored stream scene behind the newly opened one.
        // Its controls remain in AX, so never select a global duplicate toolbar.
        func candidates() -> [XCUIElement] {
            app.windows.allElementsBoundByIndex.filter {
                fixtureStatus($0).exists && returnButton($0).isHittable
            }
        }
        let unique = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            candidates().count == 1
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [unique], timeout: 10), .completed,
                       "Exactly one foreground owned-fixture scene must accept input")
        let windows = candidates()
        XCTAssertEqual(windows.count, 1)
        return try XCTUnwrap(windows.first)
    }

    @MainActor
    private func openFixture(_ fixture: Fixture, app: XCUIApplication) throws {
        if returnButton(app).waitForExistence(timeout: 3) { returnButton(app).tap() }
        let openMain = app.buttons.matching(identifier: "peel.restoredWindow.openMain")
        if openMain.firstMatch.exists {
            let recoveryMessage = "This window was restored without its connection to \(fixture.host). Open Peel Pro to reconnect and choose a desktop or app."
            XCTAssertTrue(app.staticTexts[recoveryMessage].exists,
                          "Only leave the restored scene for the exact expected Host")
            XCTAssertEqual(openMain.count, 1)
            XCTAssertTrue(openMain.element(boundBy: 0).isHittable)
            openMain.element(boundBy: 0).tap()
        }
        // The current browser presents Hosts as cells with a menu, not name buttons.
        // Include the connection status to distinguish the Host from its desktop row.
        let hostRows = app.cells.containing(.staticText, identifier: fixture.host)
            .containing(NSPredicate(format: "label IN %@", ["Paired", "Connecting…", "Connected"]))
        XCTAssertTrue(hostRows.firstMatch.waitForExistence(timeout: 20), "Expected already-paired Host missing")
        XCTAssertEqual(hostRows.count, 1, "Connect must be scoped to the exact already-paired Host")
        let hostRow = hostRows.element(boundBy: 0)
        if hostRow.staticTexts["Paired"].exists {
            // SwiftUI exposes an unlabeled button inside the labeled menu button.
            // Match the observed menu label instead of counting every descendant.
            let menus = hostRow.buttons.matching(NSPredicate(format: "label == %@", "More"))
            XCTAssertEqual(menus.count, 1, "Expected one More menu for the exact paired Host")
            XCTAssertFalse(hostRow.buttons["Pair again"].exists, "Pairing repair is not allowed")
            let menu = menus.element(boundBy: 0)
            XCTAssertTrue(menu.isHittable)
            menu.tap()
            let connect = app.buttons.matching(NSPredicate(format: "label == %@", "Connect"))
            XCTAssertTrue(connect.firstMatch.waitForExistence(timeout: 3), "The selected paired Host must offer Connect")
            XCTAssertEqual(connect.count, 1)
            connect.element(boundBy: 0).tap()
        }
        XCTAssertTrue(hostRow.staticTexts["Connected"].waitForExistence(timeout: 20), "Expected exact Host connection before opening its fixture")
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", fixture.title))
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        if !title.firstMatch.exists {
            let disclosure = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "App Windows")).firstMatch
            for _ in 0..<4 where !disclosure.exists || !disclosure.isHittable {
                XCTAssertTrue(list.exists, "The browser must expose its own scrollable list")
                list.swipeUp()
            }
            XCTAssertTrue(disclosure.exists && disclosure.isHittable, "Expected app-window disclosure missing")
            disclosure.tap()
        }
        for _ in 0..<8 where !title.firstMatch.exists {
            XCTAssertTrue(list.exists)
            list.swipeUp()
        }
        XCTAssertEqual(title.count, 1, "Only the exact fresh owned fixture may be selected")
        let rows = app.cells.containing(.staticText, identifier: fixture.title)
        XCTAssertEqual(rows.count, 1, "Open must be inside the exact fixture row")
        let row = rows.element(boundBy: 0)
        XCTAssertTrue(row.staticTexts["Peel Streaming Fixture"].exists, "Wrong owning application")
        let open = row.buttons["Open"]
        for _ in 0..<4 where !open.exists || !open.isHittable {
            XCTAssertTrue(list.exists, "Scroll only the Host window browser")
            list.swipeUp()
        }
        XCTAssertTrue(open.exists && open.isHittable)
        open.tap()
        XCTAssertTrue(returnButton(app).waitForExistence(timeout: 20))
        XCTAssertTrue(fixtureStatus(app).waitForExistence(timeout: 10), "Wrong streamed application")
    }

    @MainActor
    private func attachFailureDiagnostics(_ app: XCUIApplication, context: String) throws {
        let state = app.state.rawValue
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Owned fixture failure hierarchy; single snapshot"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        // Parse exposed stream fields from this one attachment offline. Separate
        // AX queries can each retry while the application is suspended.
        let values = ["context": context, "appStateRawValue": String(state),
                      "measurementScope": "Single accessibility snapshot; absent fields were not queried"]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Fixture failure context and application state"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func requireAdvancingFrames(_ app: XCUIApplication) throws {
        let window = try foregroundFixtureWindow(app)
        XCTAssertTrue(fixtureStatus(window).exists, "Inspect only the explicitly selected fixture stream")
        let expand = window.buttons["Expand toolbar"]
        if expand.exists { expand.tap() }
        let details = window.buttons["Stream Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        let receivedFields = app.descendants(matching: .any).matching(identifier: "peel.streamDetails.receivedFrames")
        let received = receivedFields.firstMatch
        if !received.exists {
            let immediate = XCTAttachment(string: "app.state.rawValue=\(app.state.rawValue)\n" + app.debugDescription)
            immediate.name = "Immediate Stream Details hierarchy; received-frame field absent"
            immediate.lifetime = .keepAlways
            add(immediate)
        }
        let receivedExposed = received.waitForExistence(timeout: 15)
        if !receivedExposed {
            try attachFailureDiagnostics(app, context: "Received-frame field absent after Stream Details tap")
        }
        XCTAssertTrue(receivedExposed, "Stream Details must expose the received-frame count before testing its progress")
        XCTAssertEqual(receivedFields.count, 1, "Only the selected foreground stream's diagnostics may be measured")
        func count() -> Int { Int(((received.value as? String) ?? "").filter(\.isNumber)) ?? 0 }
        let first = count()
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in count() > first }, object: received)
        let progress = XCTWaiter.wait(for: [advancing], timeout: 15)
        if progress != .completed { try attachFailureDiagnostics(app, context: "Received frames did not advance from \(first)") }
        XCTAssertEqual(progress, .completed,
                       "A restored scene must receive fresh frames, not just retain an old image")
        let attachment = XCTAttachment(string: "Owned fixture received frames advanced from \(first) to \(count()). This is not presentation FPS or latency.")
        attachment.name = "Owned fixture receiver progress"
        attachment.lifetime = .keepAlways
        add(attachment)
        let done = app.buttons.matching(identifier: "peel.streamDetails.done")
        XCTAssertEqual(done.count, 1, "Only one Stream Details sheet may be open")
        XCTAssertTrue(done.element(boundBy: 0).isHittable)
        done.element(boundBy: 0).tap()
        XCTAssertTrue(fixtureStatus(app).waitForExistence(timeout: 10))
    }

    /// Explicit setup only. The coordinator must keep this run's standard XCTest
    /// activity/screen artifacts transient because the normal PIN field is visible.
    @MainActor
    func testRepairExistingHostPairingWithPIN() throws {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { environment[key] ?? environment["TEST_RUNNER_" + key] }
        guard value("PEEL_UI_TEST_REPAIR_PAIRING") == "1",
              let host = value("PEEL_UI_TEST_HOST_NAME"), !host.isEmpty,
              let pin = value("PEEL_UI_TEST_PAIRING_PIN"), pin.count == 6,
              pin.allSatisfy({ "0123456789".contains($0) }) else {
            throw XCTSkip("Pairing repair requires explicit opt-in, exact existing Host, and ephemeral six-digit PIN")
        }

        let app = client()
        app.launch()
        if returnButton(app).waitForExistence(timeout: 3) { returnButton(app).tap() }
        let hostRows = app.cells.containing(.staticText, identifier: host)
            .containing(NSPredicate(format: "label IN %@", ["Paired", "Pair again", "Connecting…", "Connected"]))
        XCTAssertTrue(hostRows.firstMatch.waitForExistence(timeout: 20), "Expected existing paired Host missing")
        XCTAssertEqual(hostRows.count, 1, "Pairing repair must stay within the exact existing Host row")
        let row = hostRows.element(boundBy: 0)
        if row.staticTexts["Connected"].exists { return }

        if row.staticTexts["Paired"].exists {
            let menus = row.buttons.matching(NSPredicate(format: "label == %@", "More"))
            XCTAssertEqual(menus.count, 1)
            XCTAssertTrue(menus.element(boundBy: 0).isHittable)
            menus.element(boundBy: 0).tap()
            let connect = app.buttons.matching(NSPredicate(format: "label == %@", "Connect"))
            XCTAssertTrue(connect.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(connect.count, 1)
            connect.element(boundBy: 0).tap()
        }

        let resolved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.staticTexts["Connected"].exists || row.staticTexts["Pair again"].exists
        }, object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 20), .completed,
                       "Connection must either succeed or explicitly require pairing repair")
        if row.staticTexts["Connected"].exists { return }

        let repair = row.buttons.matching(NSPredicate(format: "label == %@", "Pair again"))
        XCTAssertEqual(repair.count, 1, "Only repair of this existing pairing is permitted")
        XCTAssertTrue(repair.element(boundBy: 0).isHittable)
        repair.element(boundBy: 0).tap()
        let heading = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Enter code from \(host). Use the 6-digit code shown in Peel Pro."
        ))
        XCTAssertTrue(heading.firstMatch.waitForExistence(timeout: 5), "Pairing sheet must name the exact Host")
        let fields = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "6-digit code"))
        XCTAssertEqual(fields.count, 1)
        let field = fields.element(boundBy: 0)
        XCTAssertTrue(field.isHittable)
        field.tap()
        field.typeText(pin)
        let enteredDigitCount = (field.value as? String)?.filter(\.isNumber).count ?? 0
        XCTAssertEqual(enteredDigitCount, 6, "The PIN field must contain six digits before submission")
        if app.keyboards.firstMatch.exists {
            let hideKeyboard = app.buttons.matching(NSPredicate(format: "label == %@", "Hide keyboard"))
            XCTAssertEqual(hideKeyboard.count, 1, "Use the keyboard's explicit dismissal control")
            XCTAssertTrue(hideKeyboard.element(boundBy: 0).isHittable)
            hideKeyboard.element(boundBy: 0).tap()
            let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !app.keyboards.firstMatch.exists
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed,
                           "The keyboard must stop covering the Pair button before submission")
        }
        let pair = app.buttons.matching(NSPredicate(format: "label == %@", "Pair"))
        XCTAssertEqual(pair.count, 1)
        XCTAssertTrue(pair.element(boundBy: 0).isEnabled)
        XCTAssertTrue(pair.element(boundBy: 0).isHittable)
        pair.element(boundBy: 0).tap()
        let connected = row.staticTexts["Connected"].waitForExistence(timeout: 30)
        // Emit only fixed category names and booleans. Never read/log the PIN field
        // value or copy an arbitrary UI label into the retained outcome receipt.
        var outcome = [
            "connected": connected,
            "pairingSheetVisible": fields.firstMatch.exists,
            "hostPaired": row.staticTexts["Paired"].exists,
            "hostConnecting": row.staticTexts["Connecting…"].exists,
            "hostRequiresPairingRepair": row.staticTexts["Pair again"].exists
        ]
        let knownStatuses = [
            "keyStorageFailed": "Could not save the pairing key on this device.",
            "pairingMaterialMissing": "host accepted but did not send pairing material",
            "wrongCodeOrAuthentication": "Wrong PIN/token.",
            "pairingTransportError": "Connection error while pairing",
            "pairingResponseTimeout": "Pairing timed out waiting for",
            "pairingResolveTimeout": "Could not reach",
            "pairingIdentityMissing": "Host didn’t advertise a stable pairing identity.",
            "pairingDataIncomplete": "Host pairing data is incomplete.",
            "pairingEndpointRefreshing": "The computer is refreshing pairing.",
            "waitingForPairing": "to accept pairing",
            "pairingSavedMessage": "Paired with"
        ]
        for (category, knownText) in knownStatuses {
            outcome[category] = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", knownText)
            ).firstMatch.exists
        }
        let outcomeData = try JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys])
        print("PEEL_PAIR_REPAIR_OUTCOME " + String(decoding: outcomeData, as: UTF8.self))
        if !connected {
            let redactedHierarchy = app.debugDescription
                .replacingOccurrences(of: pin, with: "[REDACTED]")
                .replacingOccurrences(of: #"(?<![0-9])[0-9]{6}(?![0-9])"#,
                                      with: "[REDACTED]", options: .regularExpression)
            let attachment = XCTAttachment(string: redactedHierarchy)
            attachment.name = "Pairing failure hierarchy with PIN redacted"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(connected,
                      "Repaired existing pairing must establish the exact Host connection")
    }

    @MainActor
    func testOwnedFixtureReceivesTextAndDrag() throws {
        let fixture = try Fixture.fromEnvironment()
        let app = client()
        launchClient(app)
        try openFixture(fixture, app: app)
        try requireAdvancingFrames(app)
        let window = try foregroundFixtureWindow(app)
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.48))
        center.tap() // Focus request until Host confirms input readiness.
        let inputReady = fixtureStatus(window, active: true).waitForExistence(timeout: 20)
        if !inputReady { try attachFailureDiagnostics(app, context: "Host did not confirm Active after focus tap") }
        XCTAssertTrue(inputReady)
        center.tap()
        let expand = window.buttons["Expand toolbar"]
        if expand.exists { expand.tap() }
        let showKeyboard = window.buttons["Show keyboard"]
        if showKeyboard.exists { showKeyboard.tap() }
        let bridge = window.textViews
        XCTAssertTrue(bridge.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(bridge.count, 1, "Only one remote keyboard bridge may receive the synthetic token")
        bridge.element(boundBy: 0).typeText("PEEL_STREAM_FIXTURE_42")
        let environment = ProcessInfo.processInfo.environment
        if (environment["PEEL_UI_TEST_INPUT_SETTLE_PROBE"]
            ?? environment["TEST_RUNNER_PEEL_UI_TEST_INPUT_SETTLE_PROBE"]) == "1" {
            // Diagnostic-only comparison: let Host delivery drain before a UI
            // transition. Independent fixture counters still decide acceptance.
            let settle = expectation(description: "Bounded Host text-delivery diagnostic")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { settle.fulfill() }
            XCTAssertEqual(XCTWaiter.wait(for: [settle], timeout: 7), .completed)
        }
        let hideKeyboard = window.buttons["Hide keyboard"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        XCTAssertTrue(fixtureStatus(window, active: true).exists)
        // iPad's native long-press drag begins after 0.12 seconds; the old
        // Vision-only input-mode controls are not part of this target.
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.48))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.56))
        from.press(forDuration: 0.30, thenDragTo: to)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "could not send that input")).firstMatch.exists)
        returnButton(window).tap()
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOwnedFixtureResumesAfterBackgroundAndRelaunch() throws {
        let fixture = try Fixture.fromEnvironment()
        let app = client()
        launchClient(app)
        try openFixture(fixture, app: app)
        try requireAdvancingFrames(app)
        // Activate only our installed empty harness. Hardware Home left Peel
        // foregrounded on this iPad; another owned app makes the lifecycle
        // transition explicit without opening any personal application.
        let harness = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.PeelUITestHarness")
        harness.activate()
        XCTAssertTrue(harness.wait(for: .runningForeground, timeout: 10))
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed,
                       "Client must leave the foreground before resume; state=\(app.state.rawValue)")
        let backgroundDwell = expectation(description: "Keep the owned client in the background for five seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { backgroundDwell.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [backgroundDwell], timeout: 7), .completed)
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended,
                      "Client must remain backgrounded for the dwell interval")
        app.activate()
        let foregrounded = app.wait(for: .runningForeground, timeout: 10)
        if !foregrounded {
            let attachment = XCTAttachment(string: "Peel foreground prerequisite failed; app.state.rawValue=\(app.state.rawValue)")
            attachment.name = "Owned client foreground prerequisite state"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(foregrounded, "Peel must return to the foreground before inspecting its resumed stream")
        XCTAssertTrue(fixtureStatus(app).waitForExistence(timeout: 20))
        try requireAdvancingFrames(app)
        app.terminate()
        app.launch()
        try openFixture(fixture, app: app)
        try requireAdvancingFrames(app)
        returnButton(try foregroundFixtureWindow(app)).tap()
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }
}
