import XCTest

/// Simulator UI checks of the already installed watchOS Peel Pro candidate.
///
/// The runner targets `com.zephyrstudiosllc.Peel.watchkitapp` by bundle identifier. It does not
/// link, build or install the production app, so a pass describes whatever candidate root
/// installed on the simulator (227.1 for the 2026-10-21 run), not a compiled dependency.
///
/// Selectors come from `Peel-Watch/PeelWatchHome.swift` and
/// `Shared/WatchCompanion/Sources/PeelWatchCore/CompanionProvider.swift`. Remote Desktop is
/// never tapped: `PeelWatchStreamView.onAppear` calls `model.startWatchViewing()` at once.
/// Provider rows are never tapped: every row writes `model.provider`, even the selected one.
/// Nothing here pairs, streams, sends a draft, contacts a provider, accepts consent or changes
/// a setting. No route uses a Back control (the source defines none); the chooser and
/// Connection details tests end by terminating the app, relaunching it and checking the
/// provider is unchanged. Teardown always terminates the app.
final class PeelWatchInstalledCandidateUITests: XCTestCase {
    private static let bundleID = "com.zephyrstudiosllc.Peel.watchkitapp"
    /// Retained QA watchOS simulator; screen captures are taken only inside it.
    private static let retainedQASimulatorUDID = "9DBF3FD1-7D46-478B-BF7E-58C001FE49C9"
    /// `CompanionProvider.displayName`, in `PeelWatchProviderPicker` order.
    private static let providerNames = ["OpenAI / dot", "Grok", "Claude"]
    /// Home controls: identifier and accessibility label, both from PeelWatchHome.swift.
    private static let homeHeaderControls: [(id: String, label: String)] = [
        ("watch.home.menu", "Peel Pro menu"),
        ("watch.home.more", "More options"),
    ]
    /// `PeelWatchConnection.detail` for each provider.
    private static let connectionDetail: [String: String] = [
        "OpenAI / dot": "Existing ChatGPT account and dot access are not connected. Drafts cannot start text or voice chats.",
        "Grok": "X account sign-in and Grok chats are not connected. No API key or paid API billing is enabled.",
        "Claude": "Claude chat and Claude Code on your computer are not connected. Peel Pro will not run remote session commands.",
    ]
    /// Every `transportStatus` value assigned in Shared/WatchUI/PeelCompanionModel.swift.
    private static let transportStatuses = [
        "Checking iPhone connection…",
        "Watch connection is unavailable on this device",
        "Open Peel Pro on your paired iPhone and watch first",
        "Install Peel Pro on your paired Apple Watch first",
        "Install Peel Pro on your paired iPhone first",
        "Open Peel Pro on both paired devices",
        "No Apple Watch paired with this iPhone",
        "Install Peel Pro on your Apple Watch",
        "Install Peel Pro on your iPhone",
        "Paired device reachable",
        "Paired device offline · drafts can queue",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let installedID = Self.bundleID
        addTeardownBlock { await MainActor.run { XCUIApplication(bundleIdentifier: installedID).terminate() } }
    }

    // MARK: - Routes

    /// Home header, provider selector, status caption, Remote Desktop and Cloud agents.
    /// Presence and hittability only; nothing is tapped. The Digital Crown is the only
    /// scrolling input, so no touch can land on Remote Desktop.
    @MainActor
    func testHomeAnchors() throws {
        let app = launchToHome()
        let provider = currentProvider(app)
        for control in Self.homeHeaderControls {
            let button = homeButton(app, control.id, label: control.label)
            require(button.isHittable, "\(control.id) must be hittable", app)
        }
        require(element(app, NSPredicate(format: "label == %@", "Connection needed")).exists,
                "Home must show its Connection needed status caption", app)

        let liveView = homeButton(app, "watch.home.liveView", label: "Remote Desktop")
        require(liveView.isHittable, "Remote Desktop (watch.home.liveView) must be hittable on Home", app)
        capture(app, "Home (top)")
        captureScreenEvidence(app, "Home (top)")

        let cloudAgents = homeButton(app, "watch.home.cloudAgents", label: "Cloud agents")
        let crownTurns = revealWithCrown(cloudAgents, "Cloud agents (watch.home.cloudAgents)", app)
        capture(app, "Home (Cloud agents revealed)")
        attachJSON(["provider": provider,
                    "crownTurnsToCloudAgents": "\(crownTurns)",
                    "tapped": "none"],
                   "Home observed state (Remote Desktop not tapped)")
    }

    /// The provider chooser opened from the Home selector. Rows are read, never tapped.
    @MainActor
    func testProviderChooserReadOnly() throws {
        let app = launchToHome()
        let provider = currentProvider(app)
        let selector = homeButton(app, "watch.provider.selector", label: "Provider, \(provider)")
        require(selector.isHittable, "watch.provider.selector must be hittable", app)
        selector.tap() // Presents PeelWatchProviderPicker only.
        require(waitForHeader(app, "Provider") != nil, "watch.provider.selector must open the Provider chooser", app)

        var rows: [String: String] = [:]
        for name in Self.providerNames {
            let expected = "\(name), \(name == provider ? "selected" : "not selected")"
            let row = app.buttons.matching(NSPredicate(format: "label == %@", expected)).firstMatch
            require(row.waitForExistence(timeout: 10), "Provider chooser must list \"\(expected)\"", app)
            let opposite = "\(name), \(name == provider ? "not selected" : "selected")"
            require(!app.buttons.matching(NSPredicate(format: "label == %@", opposite)).firstMatch.exists,
                    "Provider chooser must not also list \"\(opposite)\"", app)
            rows[name] = expected
        }
        let selectedRows = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", selected")).count
        require(selectedRows == 1, "Provider chooser must mark exactly one row selected, found \(selectedRows)", app)
        let firstRow = app.buttons.matching(NSPredicate(format: "label == %@", rows[Self.providerNames[0]] ?? "")).firstMatch
        require(firstRow.isHittable, "Provider chooser's first row must be on screen", app)
        capture(app, "Provider chooser")
        captureScreenEvidence(app, "Provider chooser")
        attachJSON(rows.merging(["homeProvider": provider, "rowsTapped": "none"]) { $1 },
                   "Provider chooser rows (no row tapped)")

        relaunchAndRequireProvider(app, provider, "after Provider chooser")
    }

    /// More options → Connection details, observed read-only. No add, pair, reconnect or switch.
    @MainActor
    func testConnectionDetailsReadOnly() throws {
        let app = launchToHome()
        let provider = currentProvider(app)
        let more = homeButton(app, "watch.home.more", label: "More options")
        require(more.isHittable, "watch.home.more must be hittable", app)
        more.tap() // Presents the Peel Pro options dialog only.

        let entries = app.buttons.matching(NSPredicate(format: "label == %@", "Connection details"))
        require(entries.firstMatch.waitForExistence(timeout: 10), "More options must offer Connection details", app)
        let entryCount = entries.count
        require(entryCount == 1, "More options must offer exactly one Connection details, found \(entryCount)", app)
        let entry = entries.firstMatch
        require(entry.isHittable, "Connection details must be hittable", app)
        let dialogTitleShown = element(app, NSPredicate(format: "label == %@", "Peel Pro options")).exists
        capture(app, "Peel Pro options")
        entry.tap() // Pushes PeelWatchConnection, whose body is text only.

        let details = app.descendants(matching: .any).matching(identifier: "watch.connection.details").firstMatch
        require(details.waitForExistence(timeout: 10), "Connection details must show watch.connection.details", app)
        require(waitForHeader(app, "Connections") != nil, "Connection details must be titled Connections", app)
        require(element(app, NSPredicate(format: "label == %@", "Connection unavailable")).exists,
                "Connection details must state Connection unavailable", app)
        require(element(app, NSPredicate(format: "label == %@", provider)).exists,
                "Connection details must name the current provider \(provider)", app)
        let detail = Self.connectionDetail[provider] ?? ""
        require(element(app, NSPredicate(format: "label == %@", detail)).exists,
                "Connection details must show the \(provider) limit: \(detail)", app)
        let transport = Self.transportStatuses.first {
            element(app, NSPredicate(format: "label == %@", $0)).exists
        }
        require(transport != nil, "Connection details must show a source-defined transport status", app)
        capture(app, "Connection details")
        captureScreenEvidence(app, "Connection details")
        attachJSON(["provider": provider,
                    "transportStatus": transport ?? "none",
                    "optionsDialogTitleShown": "\(dialogTitleShown)",
                    "route": "watch.home.more → Connection details",
                    "back": "not attempted; app terminated and relaunched"],
                   "Connection details observed state")

        relaunchAndRequireProvider(app, provider, "after Connection details")
    }

    // MARK: - Home

    @MainActor
    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.bundleID)
        app.launch()
        require(app.wait(for: .runningForeground, timeout: 30),
                "Precondition: installed \(Self.bundleID) must launch to the foreground", app)
        require(app.buttons["watch.provider.selector"].waitForExistence(timeout: 30),
                "Precondition: installed Peel Pro Watch must reach Home (watch.provider.selector)", app)
        let alert = app.alerts.firstMatch
        require(!alert.exists, "An unexpected alert blocks Home: \(alert.exists ? alert.label : "")", app)
        return app
    }

    /// The single Home button with the exact source identifier and accessibility label.
    @MainActor
    private func homeButton(_ app: XCUIApplication, _ id: String, label: String) -> XCUIElement {
        let query = app.buttons.matching(identifier: id)
        let button = query.firstMatch
        require(button.waitForExistence(timeout: 10), "Home must expose \(id)", app)
        let count = query.count
        require(count == 1, "Home must expose exactly one \(id), found \(count)", app)
        require(button.label == label, "\(id) must be labelled \"\(label)\", found \"\(button.label)\"", app)
        return button
    }

    /// Provider display name from the Home selector label `Provider, <displayName>`.
    @MainActor
    private func currentProvider(_ app: XCUIApplication) -> String {
        let label = app.buttons["watch.provider.selector"].label
        let prefix = "Provider, "
        let name = label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : ""
        require(Self.providerNames.contains(name),
                "watch.provider.selector must read \"Provider, <OpenAI / dot|Grok|Claude>\", found \"\(label)\"", app)
        return name
    }

    @MainActor
    private func relaunchAndRequireProvider(_ app: XCUIApplication, _ expected: String, _ context: String) {
        app.terminate()
        require(app.wait(for: .notRunning, timeout: 15), "Peel Pro Watch must terminate \(context)", app)
        let relaunched = launchToHome()
        let provider = currentProvider(relaunched)
        require(provider == expected, "Provider changed \(context): \(expected) → \(provider)", relaunched)
        capture(relaunched, "Home relaunched \(context)")
    }

    /// Scrolls with the Digital Crown only, first toward later content, then back.
    @MainActor
    private func revealWithCrown(_ target: XCUIElement, _ what: String, _ app: XCUIApplication) -> Int {
        let deltas = [CGFloat](repeating: 0.1, count: 5) + [CGFloat](repeating: -0.1, count: 10)
        var turns = 0
        for delta in deltas {
            if target.exists && target.isHittable { break }
            XCUIDevice.shared.rotateDigitalCrown(delta: delta)
            turns += 1
        }
        require(target.exists && target.isHittable, "Home must show \(what) (\(turns) crown turns)", app)
        return turns
    }

    // MARK: - Queries

    /// The navigation bar titled `title`, or its exact title text if the bar is not exposed.
    @MainActor
    private func waitForHeader(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let bar = app.navigationBars[title]
            if bar.exists { return bar }
            let text = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
            if text.waitForExistence(timeout: 0.5) { return text }
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ predicate: NSPredicate) -> XCUIElement {
        app.descendants(matching: .any).matching(predicate).firstMatch
    }

    // MARK: - Evidence

    /// Fails with the installed app's own AX hierarchy and screenshot attached.
    @MainActor
    @discardableResult
    private func require(_ condition: Bool, _ message: String, _ app: XCUIApplication,
                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if !condition {
            attachFailureEvidence(app, message)
            XCTFail(message, file: file, line: line)
        }
        return condition
    }

    @MainActor
    private func attachFailureEvidence(_ app: XCUIApplication, _ message: String) {
        let state = app.state
        guard state == .runningForeground || state == .runningBackground else {
            attachJSON(["failure": message, "appState": "\(state.rawValue)"], "Failure: app not running")
            return
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Failure AX hierarchy: \(message)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        if state == .runningForeground {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Failure app screenshot: \(message)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    /// App screenshot, taken only while Peel Pro owns the foreground; otherwise the route fails
    /// with no image (the failure helper captures only a foreground app).
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        guard require(app.state == .runningForeground,
                      "Precondition: Peel Pro must own the foreground for the \(name) app screenshot", app) else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "App: \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Independent screen pixels beside the app screenshot. Taken only while Peel Pro owns the
    /// foreground of the retained QA simulator (TEST_RUNNER_PEEL_WATCH_QA_SIMULATOR_UDID
    /// overrides the default); otherwise withheld with the reason attached.
    @MainActor
    private func captureScreenEvidence(_ app: XCUIApplication, _ name: String) {
        guard require(app.state == .runningForeground,
                      "Precondition: Peel Pro must own the foreground for \(name) evidence", app) else { return }
        let environment = ProcessInfo.processInfo.environment
        let expectedUDID = environment["PEEL_WATCH_QA_SIMULATOR_UDID"]
            ?? environment["TEST_RUNNER_PEEL_WATCH_QA_SIMULATOR_UDID"]
            ?? Self.retainedQASimulatorUDID
        let actualUDID = environment["SIMULATOR_UDID"] ?? "unavailable"
        guard actualUDID == expectedUDID else {
            attachJSON(["screenCapture": "withheld: simulator context is not the declared QA simulator",
                        "simulatorUDID": actualUDID, "expectedQASimulatorUDID": expectedUDID],
                       "Screen (XCUIScreen.main) \(name) withheld")
            return
        }
        let screenShot = XCUIScreen.main.screenshot()
        let screen = XCTAttachment(screenshot: screenShot)
        screen.name = "Screen (XCUIScreen.main) \(name)"
        screen.lifetime = .keepAlways
        add(screen)
        attachJSON(["screenPNGBytes": "\(screenShot.pngRepresentation.count)",
                    "appWindowFrame": "\(app.windows.firstMatch.frame)",
                    "simulatorUDID": actualUDID],
                   "Screen (XCUIScreen.main) \(name) metrics")
    }

    @MainActor
    private func attachJSON(_ value: [String: String], _ name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
