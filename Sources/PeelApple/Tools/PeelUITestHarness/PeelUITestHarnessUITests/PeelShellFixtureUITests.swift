import XCTest
import UIKit
import Vision

/// Opt-in tests of the disposable loopback echo fixture, never an owner SSH server.
/// Requires an installed Debug client and an already-paired simulator at its home screen.
final class PeelShellFixtureUITests: XCTestCase {
    private enum FixtureAbort: Error { case unsafeOrUnexpectedUI }
    @MainActor private final class ClientLifetime {
        var app: XCUIApplication?
        nonisolated init() {}
        func terminate() { app?.terminate(); app = nil }
    }
    private let clientLifetime = ClientLifetime()

    override func tearDown() async throws {
        // XCTest assertion failures with continueAfterFailure=false can bypass Swift defer.
        // Terminate only the client this test launched, including during failed trust UI checks.
        await clientLifetime.terminate()
        try await super.tearDown()
    }
    private struct Fixture {
        let hostName: String
        let hostID: UUID?
        let address: String
        let port: UInt16
        let username: String
        let password: String
        let fingerprint: String

        static func fromRunnerEnvironment() throws -> Fixture {
            let environment = ProcessInfo.processInfo.environment
            func required(_ suffix: String) throws -> String {
                let key = "PEEL_SSH_UI_" + suffix
                // xcodebuild forwards TEST_RUNNER_* after removing the prefix.
                guard let value = environment[key] ?? environment["TEST_RUNNER_" + key], !value.isEmpty else {
                    throw XCTSkip("Supply TEST_RUNNER_\(key) for the explicitly reserved fixture run.")
                }
                return value
            }
            let hostName = try required("HOST_NAME")
            let address = try required("ADDRESS")
            let portString = try required("PORT")
            let username = try required("USERNAME")
            let password = try required("PASSWORD")
            let fingerprint = try required("FINGERPRINT")
            guard address == "127.0.0.1", let port = UInt16(portString), port > 1024,
                  username == "fixture", password == "fixture-only",
                  fingerprint.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil else {
                throw XCTSkip("Refusing anything except the configured loopback fixture, its fixed synthetic credentials, and exact public fingerprint.")
            }
            let rawID = environment["PEEL_SSH_UI_HOST_ID"] ?? environment["TEST_RUNNER_PEEL_SSH_UI_HOST_ID"]
            let hostID = rawID.flatMap(UUID.init(uuidString:))
            if let rawID, !rawID.isEmpty, hostID == nil {
                throw XCTSkip("The optional stable machine ID is not a UUID.")
            }
            return Fixture(hostName: hostName, hostID: hostID, address: address, port: port,
                           username: username, password: password, fingerprint: fingerprint)
        }
    }

    @MainActor
    func testFixtureFingerprintTrustOnceWelcomeAndDisconnect() throws {
        continueAfterFailure = false
        let fixture = try Fixture.fromRunnerEnvironment()
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        app.launchEnvironment["PEEL_SHELL_UI_FIXTURE"] = "1"
        clientLifetime.app = app
        app.launch()
        defer { disconnectAndTerminate(app) }
        let machineID = try openFixture(app, fixture: fixture)
        let terminal = try fixtureTerminal(app, fixture: fixture, machineID: machineID)
        try requireRendered("PEEL SSH ECHO FIXTURE - NO COMMANDS EXECUTED", in: terminal,
                            attachmentName: "Fixture welcome terminal only")
        try disconnect(app)
    }

    @MainActor
    func testFixtureEchoRoundTripAndDisconnect() throws {
        continueAfterFailure = false
        let fixture = try Fixture.fromRunnerEnvironment()
        let app = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        app.launchEnvironment["PEEL_SHELL_UI_FIXTURE"] = "1"
        clientLifetime.app = app
        app.launch()
        defer { disconnectAndTerminate(app) }
        let machineID = try openFixture(app, fixture: fixture)
        let terminal = try fixtureTerminal(app, fixture: fixture, machineID: machineID)
        try requireRendered("PEEL SSH ECHO FIXTURE - NO COMMANDS EXECUTED", in: terminal,
                            attachmentName: "Fixture welcome before echo")
        // The pinned SwiftTerm TerminalView is a UIScrollView conforming to UITextInput.
        // This is its observed element, not an application coordinate or remote stream.
        terminal.tap()
        guard terminal.isHittable else {
            throw XCTSkip("Connected and welcome rendered; terminal input element is unavailable. Echo acceptance remains incomplete.")
        }
        terminal.typeText("PEEL ECHO CHECK\n")
        try requireRendered("PEEL ECHO CHECK", in: terminal,
                            attachmentName: "Fixture echoed marker terminal only")
        try disconnect(app)
    }

    @MainActor
    private func openFixture(_ app: XCUIApplication, fixture: Fixture) throws -> UUID {
        let returnToPeel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if returnToPeel.waitForExistence(timeout: 2) {
            // Authorized client chrome navigation only; never tap, type into, or capture the restored stream.
            XCTAssertTrue(returnToPeel.isHittable)
            returnToPeel.tap()
        }
        let settings = app.buttons["peel.home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Expected the installed iPad/iPhone client home screen.")
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let entry = app.buttons["shell-preview-entry"]
        try reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Shell Preview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Choose a machine"].waitForExistence(timeout: 5))

        let selection = try observedMachineRow(app, fixture: fixture)
        let selectionRecord = XCTAttachment(string: "Selected paired UI record: \(fixture.hostName)\nStable machine UUID: \(selection.id.uuidString)")
        selectionRecord.name = "Observed paired machine identity"
        selectionRecord.lifetime = .keepAlways
        add(selectionRecord)
        selection.row.tap()
        guard app.staticTexts["Machine: \(selection.id.uuidString)"].waitForExistence(timeout: 10) else {
            XCTFail("Target view must retain the exact stable UUID observed in the selected row.")
            throw FixtureAbort.unsafeOrUnexpectedUI
        }

        let address = app.textFields["Host or private-network address"]
        let port = app.textFields["Port"]
        let username = app.textFields["Username"]
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        // Fresh preview form only: no saved credential is loaded or reused.
        guard isEmpty(address, placeholder: "Host or private-network address"),
              isEmpty(username, placeholder: "Username"), isEmpty(password, placeholder: "Password") else {
            XCTFail("Expected a fresh connection form without retained endpoint or credential input.")
            throw FixtureAbort.unsafeOrUnexpectedUI
        }
        try fill(address, with: fixture.address, in: app)
        try fill(port, with: String(fixture.port), in: app)
        try fill(username, with: fixture.username, in: app)
        try reveal(password, in: app)
        password.tap()
        password.typeText(fixture.password)

        let save = app.switches["Save credential in this device's Keychain"]
        try reveal(save, in: app)
        guard save.value as? String == "0" else {
            XCTFail("Saving credentials must remain off; this test never changes that toggle.")
            throw FixtureAbort.unsafeOrUnexpectedUI
        }
        let connect = app.buttons["Open independent shell"]
        try reveal(connect, in: app)
        connect.tap()
        let trustOnce = app.buttons["Trust for this connection only"]
        XCTAssertTrue(trustOnce.waitForExistence(timeout: 25), "A fresh disposable fixture must present a fingerprint decision.")
        // iOS Password AutoFill can cover this panel after the synthetic login.
        // Decline only the observed save prompt; never persist the fixture secret.
        let passwordPrompt = app.alerts["Save Password?"]
        if passwordPrompt.waitForExistence(timeout: 2) {
            let notNow = passwordPrompt.buttons["Not Now"]
            XCTAssertTrue(notNow.isHittable)
            notNow.tap()
            XCTAssertFalse(passwordPrompt.exists)
        }
        let endpoint = app.staticTexts.matching(NSPredicate(format: "label == %@", "\(fixture.username)@\(fixture.address):\(fixture.port)"))
        guard endpoint.firstMatch.exists, app.staticTexts[fixture.fingerprint].exists,
              app.staticTexts["Machine: \(selection.id.uuidString)"].exists else {
            XCTFail("Exact fixture endpoint, public fingerprint, and selected machine UUID must all be visible before trust once.")
            throw FixtureAbort.unsafeOrUnexpectedUI
        }
        try revealTrustOnce(trustOnce, in: app, fingerprint: fixture.fingerprint,
                            machineID: selection.id,
                            endpoint: "\(fixture.username)@\(fixture.address):\(fixture.port)")
        // Never save trust, replace an association, or tap credential load/save controls.
        trustOnce.tap()
        XCTAssertTrue(app.staticTexts["Connected · interactive PTY accepted"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts[fixture.fingerprint].exists)
        return selection.id
    }

    @MainActor
    private func revealTrustOnce(_ button: XCUIElement, in app: XCUIApplication, fingerprint: String,
                                 machineID: UUID, endpoint: String) throws {
        if button.isHittable { return }
        func containsTrustContents(_ panel: XCUIElement) -> Bool {
            panel.staticTexts.matching(NSPredicate(format: "label == %@", fingerprint)).count > 0 &&
            panel.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "Verify this SSH host", "SSH host key changed")).count > 0 &&
            panel.buttons.matching(NSPredicate(format: "label == %@", "Trust for this connection only")).count > 0
        }
        let candidates = app.scrollViews.allElementsBoundByIndex.filter(containsTrustContents)
        // Ancestor scroll containers can expose the same descendants. Select an actual
        // innermost candidate by AX containment, not by a guessed coordinate or smallest area.
        let innermost = candidates.filter { panel in
            !panel.descendants(matching: .scrollView).allElementsBoundByIndex.contains(where: containsTrustContents)
        }
        guard innermost.count == 1, let panel = innermost.first else {
            recordTrustPanelFailure(app, button: button, fingerprint: fingerprint,
                                    machineID: machineID, endpoint: endpoint,
                                    reason: "Candidate panels: \(candidates.count); innermost candidates: \(innermost.count)")
            XCTFail("Cannot identify one innermost trust scroll view containing the exact fixture fingerprint, title, and trust-once button.")
            throw FixtureAbort.unsafeOrUnexpectedUI
        }
        for _ in 0..<6 {
            if button.isHittable { return }
            guard panel.isHittable else { break }
            panel.swipeUp()
        }
        if button.isHittable { return }
        recordTrustPanelFailure(app, button: button, fingerprint: fingerprint,
                                machineID: machineID, endpoint: endpoint,
                                reason: "Trust once remains unreachable after bounded scrolling in the unique innermost panel.")
        XCTFail("Trust once remains unreachable after bounded scrolling in its verified panel; layout acceptance is incomplete.")
        throw FixtureAbort.unsafeOrUnexpectedUI
    }

    @MainActor
    private func recordTrustPanelFailure(_ app: XCUIApplication, button: XCUIElement,
                                         fingerprint: String, machineID: UUID, endpoint: String, reason: String) {
        let guarded = app.staticTexts["Machine: \(machineID.uuidString)"].exists &&
            app.staticTexts.matching(NSPredicate(format: "label == %@", endpoint)).firstMatch.exists &&
            app.staticTexts.matching(NSPredicate(format: "label == %@", fingerprint)).firstMatch.exists &&
            app.navigationBars["Shell Preview"].exists
        guard guarded else {
            let evidence = XCTAttachment(string: "\(reason)\nCurrent machine/endpoint/fingerprint/Shell Preview guards no longer hold; screenshot and geometry withheld.")
            evidence.name = "Trust panel identity guard changed"
            evidence.lifetime = .keepAlways
            add(evidence)
            return
        }
        let observations = app.scrollViews.allElementsBoundByIndex.prefix(12).enumerated().map { index, scroll in
            let fingerprints = scroll.staticTexts.matching(NSPredicate(format: "label == %@", fingerprint)).count
            let titles = scroll.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "Verify this SSH host", "SSH host key changed")).count
            let trustButtons = scroll.buttons.matching(NSPredicate(format: "label == %@", "Trust for this connection only")).count
            return "scroll[\(index)] frame=\(scroll.frame), hittable=\(scroll.isHittable), exactFingerprintCount=\(fingerprints), trustTitleCount=\(titles), trustOnceButtonCount=\(trustButtons)"
        }.joined(separator: "\n")
        let geometry = XCTAttachment(string: "\(reason)\nObserved trust-once button frame=\(button.frame), hittable=\(button.isHittable)\nOwn Shell UI scroll observations only (maximum 12):\n\(observations)")
        geometry.name = "Verified Shell trust panel geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        // Parent authorized this diagnostic only after exact own-Shell identity guards.
        // Never capture an app-wide image during launch, stream restoration, or credential entry.
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Verified own Shell fingerprint UI — layout failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func observedMachineRow(_ app: XCUIApplication, fixture: Fixture) throws -> (row: XCUIElement, id: UUID) {
        let prefix = "shell-preview-machine-"
        if let id = fixture.hostID {
            let rows = app.buttons.matching(identifier: prefix + id.uuidString)
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(rows.count, 1, "Exact machine identifier must be unique.")
            let row = rows.element(boundBy: 0)
            try reveal(row, in: app)
            let exactCombinedLabels = [fixture.hostName, "\(fixture.hostName), \(id.uuidString)", "\(fixture.hostName)\n\(id.uuidString)"]
            guard exactNameTexts(in: row, name: fixture.hostName).count == 1 || exactCombinedLabels.contains(row.label) else {
                XCTFail("The exact UUID row must also identify the exact configured paired Host name.")
                throw FixtureAbort.unsafeOrUnexpectedUI
            }
            return (row, id)
        }
        // Discover only from a real exact-name child and the exposed stable identifier.
        // A similarly named host or an inferred/default UUID is never substituted.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        let matches = rows.filter { exactNameTexts(in: $0, name: fixture.hostName).count == 1 }
        guard matches.count == 1, let row = matches.first,
              let id = UUID(uuidString: String(row.identifier.dropFirst(prefix.count))) else {
            let observedRows = rows.prefix(16).map { observed in
                let rawID = String(observed.identifier.dropFirst(prefix.count))
                let publicID = UUID(uuidString: rawID)?.uuidString ?? "unavailable"
                return "Label: \(String(observed.label.prefix(240)))\nIdentifier: \(prefix)\(publicID)"
            }.joined(separator: "\n\n")
            let evidence = XCTAttachment(string: "Expected exact paired Host name: \(fixture.hostName)\nMatching named machine rows: \(matches.count)\nNo target selected. Supply its observed stable UUID through TEST_RUNNER_PEEL_SSH_UI_HOST_ID if this OS merges child text in accessibility.\n\nObserved Shell Preview machine rows only (maximum 16):\n\(observedRows)")
            evidence.name = "Shell machine selection incomplete"
            evidence.lifetime = .keepAlways
            add(evidence)
            throw XCTSkip("No unique exact-name row with a valid exposed stable UUID. No SSH endpoint was entered or contacted.")
        }
        try reveal(row, in: app)
        return (row, id)
    }

    @MainActor
    private func exactNameTexts(in row: XCUIElement, name: String) -> XCUIElementQuery {
        row.staticTexts.matching(NSPredicate(format: "label == %@", name))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            let tables = app.tables.allElementsBoundByIndex.filter(\.isHittable)
            let collections = app.collectionViews.allElementsBoundByIndex.filter(\.isHittable)
            let containers = tables.isEmpty ? collections : tables
            guard containers.count == 1, let container = containers.first else {
                throw XCTSkip("Cannot identify a unique active settings/form list; no blind scroll was attempted.")
            }
            container.swipeUp()
        }
        XCTFail("Expected Shell Preview control did not become visible after bounded list scrolling.")
        throw FixtureAbort.unsafeOrUnexpectedUI
    }

    @MainActor
    private func fill(_ element: XCUIElement, with value: String, in app: XCUIApplication) throws {
        try reveal(element, in: app)
        let existing = element.value as? String ?? ""
        let placeholder = element.placeholderValue ?? ""
        let deleteCount = existing == placeholder ? 0 : existing.count
        XCTAssertLessThanOrEqual(deleteCount, 128)
        element.tap()
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount) + value)
        guard element.value as? String == value else {
            XCTFail("Refusing to connect unless the entered fixture endpoint is exact.")
            throw FixtureAbort.unsafeOrUnexpectedUI
        }
    }

    @MainActor
    private func isEmpty(_ element: XCUIElement, placeholder: String) -> Bool {
        let value = element.value as? String ?? ""
        return value.isEmpty || value == placeholder
    }

    @MainActor
    private func fixtureTerminal(_ app: XCUIApplication, fixture: Fixture, machineID: UUID) throws -> XCUIElement {
        let status = app.staticTexts["Connected · interactive PTY accepted"]
        let bar = app.navigationBars["Shell Preview"]
        XCTAssertTrue(status.exists && bar.exists)
        XCTAssertTrue(app.staticTexts[fixture.fingerprint].exists)
        XCTAssertTrue(app.staticTexts["Machine: \(machineID.uuidString)"].exists)
        XCTAssertTrue(app.staticTexts["\(fixture.username)@\(fixture.address):\(fixture.port)"].exists)
        let terminals = app.descendants(matching: .any)
            .matching(identifier: "peel-shell-terminal").allElementsBoundByIndex
        guard terminals.count == 1, let terminal = terminals.first else {
            throw XCTSkip("Fingerprint and connected PTY verified, but no unique fixture terminal identifier is exposed. Rendering/echo acceptance remains incomplete; no guessed coordinate used.")
        }
        XCTAssertTrue(terminal.isHittable && terminal.frame.height > 80)
        XCTAssertGreaterThanOrEqual(terminal.frame.minY, status.frame.maxY)
        XCTAssertGreaterThanOrEqual(terminal.frame.midX, bar.frame.minX)
        XCTAssertLessThanOrEqual(terminal.frame.midX, bar.frame.maxX)
        return terminal
    }

    @MainActor
    private func requireRendered(_ marker: String, in terminal: XCUIElement, attachmentName: String) throws {
        let normalize: (String) -> String = { String($0.uppercased().filter { $0.isLetter || $0.isNumber }) }
        var lastText = ""
        for attempt in 0..<8 {
            let screenshot = terminal.screenshot() // Only the verified fixture terminal, not the app/background.
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            lastText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if normalize(lastText).contains(normalize(marker)) {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = attachmentName
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            if attempt == 7 {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = attachmentName + " — OCR incomplete"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        let evidence = XCTAttachment(string: "Requested fixture marker: \(marker)\nFixture-terminal OCR: \(lastText)")
        evidence.name = "Fixture rendering check incomplete"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTFail("OCR did not identify the expected fixture marker; connected transport alone is not render/echo acceptance.")
    }

    @MainActor
    private func disconnect(_ app: XCUIApplication) throws {
        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.exists && disconnect.isHittable)
        disconnect.tap()
        XCTAssertTrue(app.staticTexts["Disconnected · reconnect opens a new shell"].waitForExistence(timeout: 10))
        let open = app.buttons["Open independent shell"]
        try reveal(open, in: app)
        XCTAssertTrue(open.isHittable)
    }

    @MainActor
    private func disconnectAndTerminate(_ app: XCUIApplication) {
        // Success explicitly verifies Disconnect. Failure cleanup must not add an
        // animation-dependent UI action before terminating this owned client.
        app.terminate()
    }
}
