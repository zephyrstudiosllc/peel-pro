import XCTest
import UIKit

/// Simulator reachability of retained Apple-client screens on the installed client.
/// Each test opens a local screen and leaves it through its own Done or back
/// control. Nothing here pairs, connects, purchases, restores, signs in, sends a
/// draft or message, opens an external URL, selects a provider, or toggles a consent.
/// Rotation coverage is interface orientation only, not a fold-posture claim.
final class PeelRetainedFeatureReachabilityTests: XCTestCase {
    private let bundleID = "com.zephyrstudiosllc.Peel"

    // MARK: - More Options sheets

    @MainActor
    func testMoreConnectByAddressSheetOpensAndDismisses() throws {
        continueAfterFailure = false
        let app = launchToHome()
        openMore(app)
        menuItem(app, id: "peel.home.connectByAddress", label: "Connect by Address…").tap()
        let bar = app.navigationBars["Connect by Address"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Connect by Address must open from More Options")
        XCTAssertTrue(text(app, containing: "private network or VPN").waitForExistence(timeout: 5),
                      "Connect by Address must explain its private-network scope")
        // Either the unpaired guidance or a per-pairing address row; never typed into here.
        let unpaired = text(app, containing: "Pair a computer first")
        let addressField = app.textFields["Host name or IP address"]
        XCTAssertTrue(unpaired.exists || addressField.exists,
                      "Connect by Address must show its unpaired guidance or a saved-pairing address row")
        capture(app, "More → Connect by Address")
        dismiss(app, bar: bar)
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAboutOpensAndDismissesFromMoreAndSettingsHelp() throws {
        continueAfterFailure = false
        let app = launchToHome()
        openMore(app)
        menuItem(app, id: "peel.home.about", label: "About Peel Pro").tap()
        assertAboutSheetThenDone(app, screenshot: "More → About")
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))

        let settingsBar = openSettings(app)
        let about = button(app, labelContaining: "About Peel Pro")
        reveal(about, below: settingsBar, "Settings → Help → About Peel Pro")
        about.tap()
        assertAboutSheetThenDone(app, screenshot: "Settings → Help → About")
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10), "About must return to Settings")
        dismiss(app, bar: settingsBar)
    }

    // MARK: - Settings screens

    @MainActor
    func testSettingsAccountAndDeviceSyncOpensAndReturns() throws {
        continueAfterFailure = false
        let app = launchToHome()
        let settingsBar = openSettings(app)
        let entry = button(app, labelContaining: "Apple Account & Device Sync")
        reveal(entry, below: settingsBar, "Settings → Apple Account & Device Sync")
        entry.tap()
        let bar = app.navigationBars["Apple Account & iCloud"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Account & Device Sync must open from Settings")
        XCTAssertTrue(text(app, containing: "Use Peel Pro without an account").waitForExistence(timeout: 5),
                      "Account screen must keep the no-account path visible")
        let sync = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Sync device and agent status")).firstMatch
        XCTAssertTrue(sync.exists, "Account screen must expose the iCloud sync control (observed, not toggled)")
        capture(app, "Settings → Apple Account & iCloud")
        back(app, from: bar, to: "Settings")
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10), "Account screen must return to Settings")
        dismiss(app, bar: settingsBar)
    }

    @MainActor
    func testSettingsConnectionOptionsExposeAudioAIAgentAndNotificationsWithoutToggling() throws {
        continueAfterFailure = false
        let app = launchToHome()
        let settingsBar = openSettings(app)
        let entry = button(app, labelContaining: "Connection Options")
        reveal(entry, below: settingsBar, "Settings → Connection Options")
        entry.tap()
        let bar = app.navigationBars["Connection Options"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Connection Options must open from Settings")

        // Audio & Voice opens its own sheet and closes with Done.
        let audioVoice = button(app, labelContaining: "Audio & Voice")
        reveal(audioVoice, below: bar, "Connection Options → Audio & Voice")
        audioVoice.tap()
        let audioBar = app.navigationBars["Audio"]
        XCTAssertTrue(audioBar.waitForExistence(timeout: 10), "Audio & Voice must open Audio")
        capture(app, "Settings → Connection Options → Audio")
        dismiss(app, bar: audioBar)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Audio must return to Connection Options")

        XCTAssertTrue(text(app, containing: "private network or VPN").exists,
                      "Connection Options must include Connect by Address")

        // Observe consents only. Values are recorded and must be unchanged when leaving.
        let consents = [
            ("manualAgentControl", "Allow agents to control my open stream"),
            ("aiWindowOpening", "Allow AI window opening"),
            ("aiNotifications", "Allow AI notifications"),
        ]
        var observed: [String: String] = [:]
        for (key, label) in consents {
            let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            reveal(toggle, below: bar, "Connection Options → \(label)")
            observed[key] = toggle.value as? String ?? "unreadable"
        }
        XCTAssertTrue(button(app, labelContaining: "View notification history").exists,
                      "Notification history must stay reachable beside the AI notifications consent")
        let proEntry = app.buttons["peel.pro.settingsEntry"]
        reveal(proEntry, below: bar, "Connection Options → Peel Pro")
        capture(app, "Settings → Connection Options (consents observed, not toggled)")

        for (key, label) in consents {
            let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            reveal(toggle, below: bar, "Connection Options → \(label) (recheck)")
            XCTAssertEqual(toggle.value as? String ?? "unreadable", observed[key], "\(label) changed during a read-only check")
        }
        attachJSON(observed, "Connection Options consent values observed without toggling")
        back(app, from: bar, to: "Settings")
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10), "Connection Options must return to Settings")
        dismiss(app, bar: settingsBar)
    }

    @MainActor
    func testSettingsHelpKeepsPurchaseRecoveryVisibleWithoutPurchasing() throws {
        continueAfterFailure = false
        let app = launchToHome()
        let settingsBar = openSettings(app)
        let entry = button(app, labelContaining: "Peel Pro & Restore Purchases")
        reveal(entry, below: settingsBar, "Settings → Help → Peel Pro & Restore Purchases")
        // Contact Us is a SwiftUI Link; Write a Review is a Button. Revealed, never tapped.
        reveal(buttonOrLink(app, labelContaining: "Contact Us"), below: settingsBar, "Settings → Help → Contact Us (not opened)")
        reveal(buttonOrLink(app, labelContaining: "Write a Review"), below: settingsBar, "Settings → Help → Write a Review (not opened)")
        reveal(entry, below: settingsBar, "Settings → Help → Peel Pro & Restore Purchases (again)")
        entry.tap()
        let bar = app.navigationBars["Peel Pro"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Peel Pro & Restore Purchases must open")
        let restore = app.buttons["peel.pro.restore"]
        reveal(restore, below: bar, "Peel Pro → Restore Purchases")
        XCTAssertTrue(app.buttons["peel.pro.manageSubscriptions"].exists, "Manage Subscriptions must stay visible (not opened)")
        capture(app, "Settings → Help → Peel Pro (restore visible, not tapped)")
        back(app, from: bar, to: "Settings")
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10), "Peel Pro must return to Settings")
        dismiss(app, bar: settingsBar)
    }

    /// Shell Preview is compiled only into Debug. Declare the installed configuration with
    /// TEST_RUNNER_PEEL_UI_TEST_CLIENT_CONFIGURATION=Debug|Release; Release asserts absence.
    @MainActor
    func testSettingsShellPreviewOpensAndReturnsWithoutStartingSSH() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let key = "PEEL_UI_TEST_CLIENT_CONFIGURATION"
        guard let configuration = environment[key] ?? environment["TEST_RUNNER_" + key],
              configuration == "Debug" || configuration == "Release" else {
            throw XCTSkip("Declare TEST_RUNNER_\(key)=Debug or Release for the installed client; Shell Preview is Debug-only by design")
        }
        let app = launchToHome()
        let settingsBar = openSettings(app)
        let entry = app.buttons["shell-preview-entry"]
        if configuration == "Release" {
            let notices = button(app, labelContaining: "Open-source notices")
            reveal(notices, below: settingsBar, "Settings → Legal")
            XCTAssertFalse(entry.exists, "Release must not expose Shell Preview")
            dismiss(app, bar: settingsBar)
            return
        }
        reveal(entry, below: settingsBar, "Settings → Development → Shell Preview")
        entry.tap()
        let bar = app.navigationBars["Shell Preview"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Shell Preview must open from Settings")
        XCTAssertTrue(text(app, containing: "Development preview").waitForExistence(timeout: 5))
        // Machine rows are observed only; selecting one is what prepares an SSH session.
        let machines = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shell-preview-machine-"))
        XCTAssertTrue(machines.count > 0 || text(app, containing: "Pair a computer in Peel Pro before opening Shell Preview").exists,
                      "Shell Preview must list paired machines or explain that pairing is required")
        XCTAssertFalse(text(app, containing: "Preparing Shell Preview").exists, "Opening the list must not start a shell session")
        attachJSON(["pairedMachineRows": "\(machines.count)"], "Shell Preview machine rows observed, none selected")
        capture(app, "Settings → Development → Shell Preview (no machine selected)")
        back(app, from: bar, to: "Settings")
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10), "Shell Preview must return to Settings")
        dismiss(app, bar: settingsBar)
    }

    // MARK: - Watch & Cloud Agents

    @MainActor
    func testWatchCloudAgentsPanelShowsSetupOptionsAndDisconnectedState() throws {
        continueAfterFailure = false
        let app = launchToHome()
        openMore(app)
        menuItem(app, id: "peel.watch.open", label: "Apple Watch & Cloud Agents").tap()
        let watchBar = app.navigationBars["Watch & Cloud Agents"]
        XCTAssertTrue(watchBar.waitForExistence(timeout: 10), "Watch & Cloud Agents must open from More Options")
        XCTAssertTrue(text(app, containing: "Remote Desktop on Watch").waitForExistence(timeout: 5),
                      "Watch panel must keep its Remote Desktop section")
        XCTAssertFalse(app.buttons["peel.watch.stopSharing"].exists, "No Watch live view may be sharing at launch")
        XCTAssertFalse(app.buttons["peel.watch.revokeControl"].exists, "Watch control must not be granted at launch")
        capture(app, "More → Watch & Cloud Agents")

        // Cloud agent setup: reachable with a truthful disconnected state; no sign-in started.
        let signIn = button(app, labelContaining: "Sign in to your cloud agent")
        reveal(signIn, below: watchBar, "Watch → Sign in to your cloud agent")
        XCTAssertTrue(app.descendants(matching: .any)["peel.watch.provider"].exists,
                      "Provider choice must stay visible (observed, not changed)")
        signIn.tap()
        let agentsBar = app.navigationBars["Cloud agents"]
        XCTAssertTrue(agentsBar.waitForExistence(timeout: 10), "Cloud agent setup must open from the Watch panel")
        for name in ["Dot", "Grok Bot"] {
            let connect = app.buttons["Connect \(name)"]
            reveal(connect, below: agentsBar, "Cloud agents → Connect \(name)")
            XCTAssertFalse(app.buttons["Reconnect \(name)"].exists, "\(name) must not claim a usable session on a clean simulator")
        }
        XCTAssertFalse(text(app, containing: "Dot connected").exists, "Dot must report disconnected")
        XCTAssertFalse(text(app, containing: "Grok Bot connected").exists, "Grok Bot must report disconnected")
        XCTAssertFalse(app.buttons["Disconnect on this iPhone"].exists, "No signed-in agent may be present")
        XCTAssertFalse(app.buttons["Cancel connection"].exists, "Opening setup must not start a sign-in")
        let restore = app.buttons.matching(NSPredicate(format: "label == %@", "Restore Purchases")).firstMatch
        reveal(restore, below: agentsBar, "Cloud agents → Restore Purchases")
        capture(app, "Watch → Cloud agents (disconnected, nothing started)")
        back(app, from: agentsBar, to: "Watch & Cloud Agents")
        XCTAssertTrue(watchBar.waitForExistence(timeout: 10), "Cloud agents must return to the Watch panel")

        // The currently selected provider's connection options, without changing the selection.
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Connection not available")).firstMatch
        reveal(provider, below: watchBar, "Watch → provider connection options")
        provider.tap()
        let notConnected = text(app, containing: "Not connected")
        XCTAssertTrue(notConnected.waitForExistence(timeout: 10), "Provider options must state Not connected")
        XCTAssertTrue(text(app, containing: "Live provider voice is unavailable").exists,
                      "Provider options must state voice limits truthfully")
        let providerBar = app.navigationBars.matching(NSPredicate(
            format: "identifier IN %@", ["OpenAI / dot", "Grok", "Claude"])).firstMatch
        XCTAssertTrue(providerBar.exists, "Provider options must be titled with the selected provider")
        capture(app, "Watch → provider connection options (not connected)")
        back(app, from: providerBar, to: "Watch & Cloud Agents")
        XCTAssertTrue(watchBar.waitForExistence(timeout: 10), "Provider options must return to the Watch panel")
        dismiss(app, bar: watchBar)
        XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
    }

    // MARK: - Rotation

    @MainActor
    func testRotationKeepsHomeControlsReachableInLandscapeAndPortrait() throws {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        addTeardownBlock { await MainActor.run { XCUIDevice.shared.orientation = .portrait } }
        device.orientation = .portrait
        let app = launchToHome()
        var observations: [String: String] = [:]

        let passes: [(String, UIDeviceOrientation)] = [("landscape", .landscapeLeft), ("portrait", .portrait)]
        for (name, orientation) in passes {
            let windowBefore = app.windows.firstMatch.frame
            let screenBefore = XCUIScreen.main.screenshot().image.size
            device.orientation = orientation
            // Duo 227.1 evidence: the app ran windowed (466x678 window inside a ~669x951 pt screen)
            // and the window did not flip within 10 s. Interface rotation is accepted only from a
            // measured aspect change of the full-screen app window or of the system screen; an
            // unchanged frame never counts for both orientations.
            func matches(_ size: CGSize) -> Bool {
                orientation.isLandscape ? size.width > size.height : size.height > size.width
            }
            var window = windowBefore, screen = screenBefore
            // A flip is a measured change into the requested aspect, never a frame that already matched.
            var windowFlipped: Bool { matches(window.size) && !matches(windowBefore.size) }
            var screenFlipped: Bool { matches(screen) && !matches(screenBefore) }
            let deadline = Date().addingTimeInterval(10)
            repeat {
                window = app.windows.firstMatch.frame
                screen = XCUIScreen.main.screenshot().image.size
            } while !(windowFlipped || screenFlipped) && Date() < deadline
            // Settle Home geometry, then capture app-only image, metrics and AX before any assertion.
            let settled = settledHomeGeometry(app)
            let screenImage = XCUIScreen.main.screenshot().image
            screen = screenImage.size
            window = settled.frames["window"] ?? window
            let bounds = interfaceBounds(window: window, screen: screen)
            let appImage = app.screenshot().image
            func rectText(_ rect: CGRect) -> String {
                "{\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))}"
            }
            var evidence: [String: String] = [
                "requested": name,
                "deviceOrientationReadback": "\(XCUIDevice.shared.orientation.rawValue)",
                "windowBefore": "\(Int(windowBefore.width))x\(Int(windowBefore.height))",
                "windowAfter": "\(Int(window.width))x\(Int(window.height))",
                "screenBeforePoints": "\(Int(screenBefore.width))x\(Int(screenBefore.height))",
                "screenAfterPoints": "\(Int(screen.width))x\(Int(screen.height))",
                "screenScale": "\(screenImage.scale)",
                "screenPixels": "\(Int(screen.width * screenImage.scale))x\(Int(screen.height * screenImage.scale))",
                "appScreenshotPoints": "\(Int(appImage.size.width))x\(Int(appImage.size.height))",
                "appScreenshotScale": "\(appImage.scale)",
                // System interface flip (screen) and AX app-window flip are reported separately.
                "systemInterfaceFlipped": "\(screenFlipped)",
                "appWindowFrameFlipped": "\(windowFlipped)",
                "geometryBounds": "\(bounds.source) \(rectText(bounds.rect))",
                "appPresentation": bounds.fullScreen ? "fullScreen" : "windowed",
                "geometrySettled": "\(settled.settled) after \(settled.samples) AX samples",
            ]
            for (key, rect) in settled.frames { evidence["frame." + key] = rectText(rect) }
            capture(app, "Home \(name) (settled, captured before geometry assertions)")
            captureScreenEvidence(app, "Home \(name)")
            attachJSON(evidence, "Rotation \(name) interface evidence (orientation only, not fold posture)")
            attachHierarchy(app, "Home \(name) settled, before geometry assertions")

            XCTAssertTrue(windowFlipped || screenFlipped,
                          "Neither the app window nor the screen changed into the \(name) aspect within 10 s: \(evidence)")
            XCTAssertTrue(settled.settled, "Home geometry did not settle within 5 s after rotating to \(name)")
            observations[name] = assertHomeControlsUsable(app, orientation: name, frames: settled.frames, bounds: bounds)

            let settingsBar = openSettings(app)
            capture(app, "Settings \(name)")
            captureScreenEvidence(app, "Settings \(name)")
            dismiss(app, bar: settingsBar) // Asserts a hittable Done and that Settings closes in this orientation.

            openAudio(app)
            let audioBar = app.navigationBars["Audio"]
            XCTAssertTrue(audioBar.waitForExistence(timeout: 10), "Audio must open in \(name)")
            dismiss(app, bar: audioBar)

            openMore(app)
            for (id, label) in [("peel.watch.open", "Apple Watch & Cloud Agents"),
                                ("peel.home.connectByAddress", "Connect by Address…")] {
                XCTAssertTrue(menuItem(app, id: id, label: label).isHittable, "\(label) must be hittable in \(name)")
            }
            menuItem(app, id: "peel.home.about", label: "About Peel Pro").tap()
            assertAboutSheetThenDone(app, screenshot: "More → About \(name)", screenEvidence: "About \(name)")
            XCTAssertTrue(app.buttons["peel.home.settings"].waitForExistence(timeout: 10))
        }
        attachJSON(observations, "Rotation home observations (orientation only, not fold posture)")
    }

    // MARK: - Helpers

    @MainActor
    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let installedID = self.bundleID
        addTeardownBlock { await MainActor.run { XCUIApplication(bundleIdentifier: installedID).terminate() } }
        app.launch()
        let returnButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Return to Peel")).firstMatch
        if returnButton.waitForExistence(timeout: 3) { returnButton.tap() }
        let settings = app.buttons["peel.home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "Precondition: installed client must reach its home screen")
        XCTAssertTrue(settings.isHittable, "Precondition: a startup overlay blocks the home toolbar")
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        let settings = app.buttons["peel.home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10) && settings.isHittable, "Settings must be hittable")
        settings.tap()
        let bar = app.navigationBars["Settings"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Settings must open")
        return bar
    }

    @MainActor
    private func openMore(_ app: XCUIApplication) {
        let more = app.buttons["peel.home.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10) && more.isHittable, "More Options must be hittable")
        more.tap()
    }

    /// Regular width shows Audio in the toolbar; compact width keeps it under More.
    @MainActor
    private func openAudio(_ app: XCUIApplication) {
        let toolbarAudio = app.buttons["peel.home.audio"]
        if toolbarAudio.exists {
            XCTAssertTrue(toolbarAudio.isHittable, "Toolbar Audio must be hittable")
            toolbarAudio.tap()
            return
        }
        openMore(app)
        menuItem(app, id: "peel.home.audio", label: "Audio").tap()
    }

    /// SwiftUI menu actions may expose either the identifier or only the label; both are exact.
    @MainActor
    private func menuItem(_ app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let byID = app.buttons[id]
        if byID.waitForExistence(timeout: 3) { return byID }
        let byLabel = app.buttons[label]
        if !byLabel.waitForExistence(timeout: 2) { attachHierarchy(app, "More Options lacks \(label)") }
        XCTAssertTrue(byLabel.exists, "More Options must offer \(label) (\(id))")
        return byLabel
    }

    @MainActor
    private func button(_ app: XCUIApplication, labelContaining label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    /// SwiftUI `Link` rows (Contact Us, Terms, Privacy) are links, not buttons, in the AX tree.
    @MainActor
    private func buttonOrLink(_ app: XCUIApplication, labelContaining label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND label CONTAINS %@",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.link.rawValue, label)).firstMatch
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    /// Scrolls the frontmost list by dragging at its horizontal centre just below the
    /// navigation bar, so the gesture never lands on an iPad form-sheet dimming view or
    /// a trailing switch. Searches downward first, then back upward.
    @MainActor
    private func reveal(_ element: XCUIElement, below bar: XCUIElement, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        var step = 0
        while !(element.exists && element.isHittable) && step < 24 {
            let edge = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0))
            let (from, to): (CGFloat, CGFloat) = step < 8 ? (240, 60) : (60, 240)
            edge.withOffset(CGVector(dx: 0, dy: from))
                .press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: to)))
            step += 1
        }
        if !(element.exists && element.isHittable) { attachHierarchy(XCUIApplication(bundleIdentifier: bundleID), "Unreachable: \(what)") }
        XCTAssertTrue(element.exists && element.isHittable, "\(what) must be reachable", file: file, line: line)
    }

    /// Done may sit in the navigation bar or, on iOS 26 floating toolbars, in a sibling Toolbar.
    /// Either way the screen's own bar must disappear afterwards.
    @MainActor
    private func dismiss(_ app: XCUIApplication, bar: XCUIElement) {
        var done = bar.buttons["Done"]
        if !done.waitForExistence(timeout: 3) {
            done = hittable(app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "Done"))) ?? done
        }
        if !(done.exists && done.isHittable) { attachHierarchy(app, "No Done for \(bar.identifier)") }
        XCTAssertTrue(done.exists && done.isHittable, "\(bar.identifier) must offer Done")
        done.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "\(bar.identifier) did not dismiss")
    }

    /// Observed on iOS 26 (Duo 227.1): the pushed screen's NavigationBar holds only its title;
    /// the system back control is a sibling Toolbar Button with identifier `BackButton` and no
    /// label. A label match on the parent title is only accepted inside the bar itself, never
    /// app-wide, so a covered Home `Settings` button can't be tapped by mistake.
    @MainActor
    private func back(_ app: XCUIApplication, from bar: XCUIElement, to parent: String) {
        let inBar = bar.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", parent, "Back"))
        let system = app.buttons.matching(identifier: "BackButton")
        var backButton: XCUIElement?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            backButton = hittable(system) ?? hittable(inBar)
        } while backButton == nil && Date() < deadline
        guard let backButton else {
            attachHierarchy(app, "No back control from \(bar.identifier) to \(parent)")
            return XCTFail("\(bar.identifier) must offer a back control to \(parent)")
        }
        backButton.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "\(bar.identifier) did not pop back to \(parent)")
    }

    @MainActor
    private func hittable(_ query: XCUIElementQuery) -> XCUIElement? {
        for index in 0..<query.count {
            let candidate = query.element(boundBy: index)
            if candidate.exists && candidate.isHittable { return candidate }
        }
        return nil
    }

    /// Runtime AX tree for selector triage; the app hierarchy only, never another app's screen.
    @MainActor
    private func attachHierarchy(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "AX hierarchy: \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertAboutSheetThenDone(_ app: XCUIApplication, screenshot: String, screenEvidence: String? = nil) {
        let infoBar = app.navigationBars["Info"]
        XCTAssertTrue(infoBar.waitForExistence(timeout: 10), "About must open")
        XCTAssertTrue(text(app, containing: "Download").exists && text(app, containing: "Tap pair").exists,
                      "About must show its setup steps")
        capture(app, screenshot)
        if let screenEvidence { captureScreenEvidence(app, screenEvidence) }
        // About's Done is a bottom button, distinct from any Settings toolbar Done behind it.
        let dones = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        var aboutDone: XCUIElement?
        for index in 0..<dones.count {
            let candidate = dones.element(boundBy: index)
            if candidate.isHittable && candidate.frame.minY > infoBar.frame.maxY { aboutDone = candidate }
        }
        guard let aboutDone else { return XCTFail("About must offer a reachable Done button") }
        aboutDone.tap()
        XCTAssertTrue(infoBar.waitForNonExistence(timeout: 10), "About did not dismiss")
    }

    private static let homeControlIDs = ["peel.home.status", "peel.home.audio", "peel.home.settings", "peel.home.more"]

    @MainActor
    private func homeGeometrySample(_ app: XCUIApplication) -> [String: CGRect] {
        var frames: [String: CGRect] = ["window": app.windows.firstMatch.frame]
        for id in Self.homeControlIDs where app.buttons[id].exists { frames[id] = app.buttons[id].frame }
        let title = app.staticTexts["Remote Desktop"]
        if title.exists { frames["title"] = title.frame }
        return frames
    }

    /// Polls until two consecutive AX samples of Home's controls, title and window are
    /// identical after rotation (each sample is several AX queries; no fixed sleep). Bounded.
    @MainActor
    private func settledHomeGeometry(_ app: XCUIApplication, timeout: TimeInterval = 5) -> (frames: [String: CGRect], settled: Bool, samples: Int) {
        var previous = homeGeometrySample(app)
        var samples = 1
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = homeGeometrySample(app)
            samples += 1
            if current == previous && current["peel.home.more"] != nil { return (current, true, samples) }
            previous = current
        }
        return (previous, false, samples)
    }

    /// iPad 227.1 runtime evidence (rotation to landscape): the screen measured 820x1180 → 1180x820 pt
    /// and the video shows the app relaid out full-screen in landscape, yet the AX main-window frame
    /// stayed 820x1180. The window frame is then stale (not rotated with the interface), so
    /// on-screen bounds come from the measured interface-oriented screen. The window frame is used
    /// only when its aspect agrees with the screen's.
    private struct InterfaceBounds {
        let rect: CGRect
        let source: String
        let fullScreen: Bool
    }

    private func interfaceBounds(window: CGRect, screen: CGSize) -> InterfaceBounds {
        let agrees = (window.width > window.height) == (screen.width > screen.height)
        let sameSize = abs(window.width - screen.width) < 1 && abs(window.height - screen.height) < 1
        let transposed = abs(window.width - screen.height) < 1 && abs(window.height - screen.width) < 1
        if agrees {
            return InterfaceBounds(rect: window, source: "appWindow", fullScreen: sameSize)
        }
        return InterfaceBounds(rect: CGRect(origin: .zero, size: screen),
                               source: "screen (AX window \(Int(window.width))x\(Int(window.height)) did not rotate; treated as stale)",
                               fullScreen: transposed)
    }

    /// Home toolbar controls must be hittable, inside the measured interface bounds and not overlapping.
    /// Full-screen apps must also lay out to the rotated bounds: the trailing More control hugs the
    /// trailing edge (a stale portrait layout inside landscape bounds leaves it hundreds of points short).
    @MainActor
    private func assertHomeControlsUsable(_ app: XCUIApplication, orientation: String,
                                          frames sampled: [String: CGRect], bounds: InterfaceBounds) -> String {
        let window = bounds.rect
        var controls = ["peel.home.status", "peel.home.settings", "peel.home.more"]
        if sampled["peel.home.audio"] != nil { controls.insert("peel.home.audio", at: 1) }
        var frames: [(String, CGRect)] = []
        for id in controls {
            let element = app.buttons[id]
            XCTAssertTrue(element.waitForExistence(timeout: 10) && element.isHittable, "\(id) must be hittable in \(orientation)")
            XCTAssertTrue(window.contains(element.frame),
                          "\(id) \(element.frame) must lie inside the \(bounds.source) bounds \(window) in \(orientation)")
            frames.append((id, element.frame))
        }
        if bounds.fullScreen, let more = frames.first(where: { $0.0 == "peel.home.more" })?.1 {
            let trailingGap = window.maxX - more.maxX
            XCTAssertTrue(trailingGap <= 120,
                          "Full-screen Home must lay out to the \(orientation) bounds; More ends \(Int(trailingGap)) pt before the trailing edge of \(window)")
        }
        for (i, a) in frames.enumerated() {
            for b in frames.dropFirst(i + 1) {
                XCTAssertFalse(a.1.intersects(b.1), "\(a.0) overlaps \(b.0) in \(orientation)")
            }
        }
        let title = app.staticTexts["Remote Desktop"]
        XCTAssertTrue(title.exists && title.isHittable, "Remote Desktop title must stay visible in \(orientation)")
        XCTAssertTrue(window.contains(title.frame), "Remote Desktop title \(title.frame) is clipped by \(window) in \(orientation)")
        for (id, frame) in frames {
            XCTAssertFalse(title.frame.intersects(frame), "Remote Desktop title overlaps \(id) in \(orientation)")
        }
        let content = ["Looking for Computers", "Connected Computer", "Saved Computers", "Computers", "Connection Options"]
            .first { text(app, containing: $0).exists } ?? "none"
        XCTAssertNotEqual(content, "none", "Home content must show a computer list or the searching state in \(orientation)")
        return "bounds=\(Int(window.width))x\(Int(window.height)) source=\(bounds.source) fullScreen=\(bounds.fullScreen) controls=\(controls.joined(separator: ",")) content=\(content)"
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Independent full-screen pixels beside the app screenshot. iPad 227.1 landscape app
    /// screenshots exported as 2360x1640 PNGs with EXIF Orientation 8, partly black, while AX
    /// geometry was correct; the screen capture separates XCTest app-capture effects from layout.
    /// Captured only while Peel owns the foreground of the isolated QA simulator.
    @MainActor
    private func captureScreenEvidence(_ app: XCUIApplication, _ name: String) {
        XCTAssertEqual(app.state, .runningForeground, "Precondition: Peel must own the foreground before a screen capture (\(name))")
        guard app.state == .runningForeground else { return }
        let screenShot = XCUIScreen.main.screenshot()
        let appImage = app.screenshot().image // Metrics only; the app image itself is attached by capture().
        let screen = XCTAttachment(screenshot: screenShot)
        screen.name = "Screen (XCUIScreen.main) \(name)"
        screen.lifetime = .keepAlways
        add(screen)
        func metrics(_ prefix: String, _ image: UIImage) -> [String: String] {
            [prefix + "Points": "\(image.size.width)x\(image.size.height)",
             prefix + "Scale": "\(image.scale)",
             prefix + "ImageOrientationRaw": "\(image.imageOrientation.rawValue)",
             prefix + "CGImagePixels": image.cgImage.map { "\($0.width)x\($0.height)" } ?? "unavailable"]
        }
        var values = metrics("screen", screenShot.image).merging(metrics("appSeparateCapture", appImage)) { $1 }
        values["deviceOrientationReadback"] = "\(XCUIDevice.shared.orientation.rawValue)"
        values["appWindowFrame"] = "\(app.windows.firstMatch.frame)"
        values["note"] = "UIImage.Orientation raw: 0 up, 1 down, 2 left, 3 right, 4-7 mirrored"
        attachJSON(values, "Screen (XCUIScreen.main) \(name) metrics")
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
