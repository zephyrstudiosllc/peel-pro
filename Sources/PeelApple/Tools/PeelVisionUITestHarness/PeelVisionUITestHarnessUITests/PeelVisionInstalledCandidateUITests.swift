import XCTest
import UIKit

/// Simulator UI checks of the already installed visionOS Peel Pro candidate.
///
/// The runner targets `com.zephyrstudiosllc.Peel` by bundle identifier. It does not link,
/// build or install the production app, so a pass describes whatever candidate root
/// installed on the simulator (227.1 for the 2026-10-21 run), not a compiled dependency.
///
/// Each route starts from the Home window's ornament (`Peel/ContentView/ContentView.swift`),
/// opens one local sheet and leaves through that sheet's own Done. Nothing here pairs,
/// connects, streams, opens a peeled window, trackpad or immersive space, sends input,
/// purchases, restores, signs in, selects a provider, requests a permission or changes a
/// setting. Settings is scrolled only by gestures that start on standalone text rows or plain
/// source footnotes clear of every control (see Read-only scrolling). Every observation of a switch or slider must equal the first value
/// seen for it, and every one seen on the way down must be seen again on the way back up.
/// About's Info ScrollView is scrolled only upward, by at most six gestures that start on
/// whitelisted noninteractive Info texts (see About read-only scrolling).
///
/// App screenshots are the top-level scene image. On the xrOS simulator XCUIScreen returned 1x1
/// black stubs ("Manual screenshots are not supported."), so such captures are recorded as
/// invalid metadata and are never presented as visual evidence.
final class PeelVisionInstalledCandidateUITests: XCTestCase {
    private static let bundleID = "com.zephyrstudiosllc.Peel"
    /// Retained QA visionOS simulator; screen captures are taken only inside it.
    private static let retainedQASimulatorUDID = "335101C7-A63E-46DF-ADB7-F18D62E30B6C"
    /// Vision Home ornament: identifier and accessibility label, both from ContentView.swift.
    private static let ornamentControls: [(id: String, label: String)] = [
        ("peel.home.audio", "Audio"),
        ("peel.home.status", "Computer Status"),
        ("peel.home.settings", "Settings"),
        ("peel.home.about", "About Peel Pro"),
    ]
    /// Vision Home TabView items: label and systemImage from ContentView.swift `.tabItem`.
    /// On visionOS 27 each item is an outer Button whose identifier is the systemImage name.
    private static let homeTabs: [(label: String, id: String)] = [
        ("Computers", "desktopcomputer"),
        ("Apps", "sharedwithyou"),
        ("Desktops", "display"),
    ]
    private static var doneLabel: NSPredicate { NSPredicate(format: "label == %@", "Done") }
    /// Vision Controls rows, title then instruction (`#else` branch of `quickControls` in
    /// Shared/Client/InfoView.swift), followed there by `aboutExternalInputNote`.
    private static let aboutControls: [(title: String, message: String)] = [
        ("Left Click", "Pinch"),
        ("Right Click", "Pinch and hold"),
        ("Scroll", "Pinch and drag"),
        ("Drag", "Pinch, hold, and drag"),
        ("Zoom", "Pinch in/out with both hands"),
    ]
    private static let aboutExternalInputNote = "Peel Pro also supports external input devices"
    /// Texts that must be fully visible together: the Controls heading, five rows and the note.
    private static let aboutTargetLabels: [String] =
        ["Controls"] + aboutControls.flatMap { [$0.title, $0.message] } + [aboutExternalInputNote]
    /// The only labels an About gesture may start on: the Controls card texts and the Pair and
    /// Connect steps, which have no accessory. Each step row is `.accessibilityElement(children:
    /// .combine)` with its number hidden, so it is accepted as its title, its message, or both
    /// joined by ", ". The Download step (Copy and the download link) is never an anchor.
    private static let aboutAnchorLabels: Set<String> = {
        let steps = [("Pair", "Tap pair, then enter the pairing code from Peel Pro."),
                     ("Connect", "Tap connect, and you're all set.")]
        return Set(aboutTargetLabels).union(steps.flatMap { [$0.0, $0.1, "\($0.0), \($0.1)"] })
    }()
    /// Every held drag and every swipeUp fallback counts against this total.
    private static let aboutMaxGestureAttempts = 6

    // MARK: - Routes

    /// Home with its Computers tab. Empty, searching, nearby and saved states are all valid;
    /// no host is required and no host row, Pair, Connect or window action is touched.
    @MainActor
    func testHomeShowsComputersAndOrnamentControls() throws {
        continueAfterFailure = false
        let app = launchToHome()
        let computers = tabItem(app, "Computers")
        let wasSelected = computers.isSelected
        if !wasSelected {
            computers.tap() // Tab selection only.
        }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: computers)
        require(XCTWaiter.wait(for: [selected], timeout: 10) == .completed && computers.isSelected,
                "Computers tab must be selected", app)
        var summary = assertComputersContent(app)
        summary["computersTabSelectedAtLaunch"] = "\(wasSelected)"
        assertHome(app, "Computers selected")
        capture(app, "Home → Computers")
        captureScreenEvidence(app, "Home → Computers")
        attachJSON(summary, "Home observed state (no pairing or connection attempted)")
    }

    /// Settings opened from the ornament, observed read-only and closed with its own Done.
    /// The installed marketing version is declared with
    /// TEST_RUNNER_PEEL_VISION_EXPECTED_VERSION (default 2.0); Vision Settings renders only
    /// `Version <CFBundleShortVersionString>`, never the build number.
    @MainActor
    func testSettingsOpensReadOnlyAndReturnsHome() throws {
        continueAfterFailure = false
        let expectedVersion = environmentValue("PEEL_VISION_EXPECTED_VERSION") ?? "2.0"
        let app = launchToHome()
        let header = openSheet(app, from: "peel.home.settings", header: "Settings")
        let accountEntry = element(app, labelContaining: "Apple Account & Device Sync")
        require(accountEntry.waitForExistence(timeout: 10), "Settings must list Apple Account & Device Sync first", app)
        let list = settingsList(app, header: header)
        capture(app, "Settings (top)")

        // Retained visionOS Settings entries, in list order (Shared/Client/SettingsView.swift).
        let entries: [(what: String, predicate: NSPredicate)] = [
            ("Windows → Window Layout", NSPredicate(format: "label CONTAINS %@", "Window Layout")),
            ("Windows → Quick Open Limit", NSPredicate(format: "label CONTAINS %@", "Quick Open Limit")),
            ("Windows → Computer Window Placement", NSPredicate(format: "label CONTAINS %@", "Computer Window Placement")),
            ("Input → Keyboard Controls", NSPredicate(format: "label CONTAINS %@", "Keyboard Controls")),
            ("Advanced → Show HUD Tab", NSPredicate(format: "label CONTAINS %@", "Show HUD Tab")),
            ("About → Version \(expectedVersion)", NSPredicate(format: "label == %@", "Version \(expectedVersion)")),
            ("About → ©2026 Zephyr Studios", NSPredicate(format: "label CONTAINS %@", "©2026 Zephyr Studios")),
        ]
        var session = ScrollSession()
        var values = ValueGuard()
        for entry in entries {
            let target = list.descendants(matching: .any).matching(entry.predicate).firstMatch
            reveal(target, in: list, header: header, entry.what, app, startTowardEnd: true,
                   values: &values, session: &session)
        }
        capture(app, "Settings (About, version \(expectedVersion))")
        captureScreenEvidence(app, "Settings (About)")

        // Back to the top, re-reading every switch and slider passed on the way down.
        values.returning = true
        reveal(accountEntry, in: list, header: header, "top → Apple Account & Device Sync", app, startTowardEnd: false,
               values: &values, session: &session)
        attachJSON(["steps": session.log.joined(separator: "\n"),
                    "strategyOrder": session.order.map { $0.rawValue }.joined(separator: ",")],
                   "Settings scroll progress")
        let notReobserved = values.downward.subtracting(values.upward).sorted()
        attachJSON(["baseline": describe(values.baseline),
                    "downward": values.downward.sorted().joined(separator: ", "),
                    "upward": values.upward.sorted().joined(separator: ", "),
                    "notReobservedOnReturn": notReobserved.joined(separator: ", "),
                    "observations": "\(values.observations)",
                    "discrepancies": values.discrepancies.joined(separator: "\n"),
                    "expectedVersion": expectedVersion],
                   "Settings switch/slider values observed without changing them")
        require(!values.downward.isEmpty, "Read-only guard must observe Settings switches or sliders on the way down", app)
        require(values.discrepancies.isEmpty,
                "Settings switch/slider values changed during a read-only pass: \(values.discrepancies.joined(separator: "; "))", app)
        require(notReobserved.isEmpty,
                "Every switch and slider seen on the way down must be re-observed on the way back up; not re-observed: \(notReobserved.joined(separator: ", "))", app)

        dismissWithToolbarDone(app, header: header, title: "Settings")
        assertHome(app, "after Settings Done")
        capture(app, "Home after Settings Done")
    }

    /// About opened directly from the Vision ornament. The Settings → Help → About Peel Pro
    /// row is iOS-only (`#if os(iOS)` in SettingsView.swift), so the phone route is not used.
    /// The compiled Vision About (`Shared/Client/InfoView.swift`) shows the Info title, the
    /// three setup steps, Controls and a bottom Done; it renders no version or build. Its rows are
    /// in the AX tree even when scrolled away, so the lower Controls card is proven by geometry
    /// inside the visible band and a fresh app screenshot, not by existence.
    @MainActor
    func testAboutOpensDirectlyFromOrnamentAndReturnsHome() throws {
        continueAfterFailure = false
        let app = launchToHome()
        let header = openSheet(app, from: "peel.home.about", header: "Info")
        let steps = [
            ("Download", "Install Peel Pro and leave it running."),
            ("Pair", "Tap pair, then enter the pairing code from Peel Pro."),
            ("Connect", "Tap connect, and you're all set."),
        ]
        for (title, message) in steps {
            require(element(app, labelContaining: message).waitForExistence(timeout: 10),
                    "About must show setup step \(title): \(message)", app)
        }
        require(app.staticTexts.matching(NSPredicate(format: "label == %@", "Controls")).firstMatch.exists,
                "About must show its Controls heading", app)
        require(element(app, labelContaining: "Left Click").exists, "About must list the Left Click control", app)
        capture(app, "About (Info)")
        captureScreenEvidence(app, "About (Info)")
        attachJSON(["route": "Home ornament peel.home.about (direct)",
                    "aboutSource": "Shared/Client/InfoView.swift (Vision target)",
                    "versionOrBuildInAbout": "not rendered by the compiled Vision About"],
                   "About route")

        // About's Done is its bottom button, below the Info header.
        let dones = app.buttons.matching(Self.doneLabel)
        var aboutDone: XCUIElement?
        for index in 0..<dones.count {
            let candidate = dones.element(boundBy: index)
            if candidate.exists && candidate.isHittable && candidate.frame.minY > header.frame.maxY {
                aboutDone = candidate
            }
        }
        require(aboutDone != nil, "About must offer its own reachable Done below the Info header", app)
        guard let done = aboutDone else { return }

        // Lower Controls card: bounded upward scrolling of the Info ScrollView only.
        let scroll = aboutScrollView(app, header: header, done: done)
        let doneCount = app.buttons.matching(Self.doneLabel).count
        requireAboutUntouched(app, header: header, doneCount: doneCount, "before scrolling")
        let initialBand = aboutBand(scroll, header: header, done: done)
        let initialScan = scanAbout(scroll, header: header, done: done)
        require(initialScan != nil, "About's ScrollView snapshot must be available before scrolling", app)
        guard let initial = initialScan else { return }
        let initialOutside = aboutTargetsOutside(initial, band: initialBand, listFrame: scroll.frame)
        let progress = revealAboutControls(scroll, header: header, done: done, doneCount: doneCount, app)
        let band = aboutBand(scroll, header: header, done: done)
        let revealedScan = scanAbout(scroll, header: header, done: done)
        require(revealedScan != nil, "About's ScrollView snapshot must be available after scrolling", app)
        guard let revealed = revealedScan else { return }
        var geometry = requireAboutControlsGeometry(revealed, band: band, listFrame: scroll.frame, app)
        let startY = initial.texts["Controls"]?.first?.minY
        let endY = revealed.texts["Controls"]?.first?.minY
        if !initialOutside.isEmpty {
            require(progress.moving >= 1 && startY != nil && endY != nil && (startY ?? 0) - (endY ?? 0) >= 4,
                    "About's Controls card started outside the visible band, so the Controls heading must move up by at least 4 pt (\(progress.moving) moving gestures)", app)
        }
        capture(app, "About (Info) Controls – five rows and external input note")
        let afterImage = scanAbout(scroll, header: header, done: done)
        for label in Self.aboutTargetLabels {
            let before = revealed.texts[label]?.first ?? .null
            let after = afterImage?.texts[label] ?? []
            require(after.count == 1 && after.first.map { sameFrame($0, before) } == true,
                    "\"\(label)\" must keep its checked frame across the Controls app screenshot", app)
        }
        requireAboutUntouched(app, header: header, doneCount: doneCount, "after the Controls screenshot")
        func text(_ rect: CGRect) -> String {
            "x \(Int(rect.minX)) y \(Int(rect.minY)) w \(Int(rect.width)) h \(Int(rect.height))"
        }
        geometry["band"] = "y \(Int(band.lowerBound))…\(Int(band.upperBound))"
        geometry["scrollViewFrame"] = text(scroll.frame)
        geometry["headerFrame"] = text(header.frame)
        geometry["doneFrame"] = text(done.frame)
        geometry["appFirstWindowFrame"] = text(app.windows.firstMatch.frame)
        geometry["initiallyOutsideBand"] = initialOutside.joined(separator: ", ")
        geometry["initiallyVisible"] = "\(initialOutside.isEmpty)"
        geometry["initialAnchors"] = initial.list.anchors.map { "\($0.label): \(text($0.frame))" }.joined(separator: "\n")
        geometry["controlsHeadingMinY"] = "\(startY.map { "\(Int($0))" } ?? "nil") → \(endY.map { "\(Int($0))" } ?? "nil")"
        geometry["gestureAttempts"] = "\(progress.attempts) of \(Self.aboutMaxGestureAttempts)"
        geometry["movingGestures"] = "\(progress.moving)"
        geometry["steps"] = progress.log.joined(separator: "\n")
        attachJSON(geometry, "About Controls geometry (whitelisted Info texts only)")

        require(done.exists && done.isHittable && done.frame.minY >= scroll.frame.maxY - 1,
                "About's own Done must still be reachable below its ScrollView after scrolling", app)
        aboutDone?.tap()
        require(header.waitForNonExistence(timeout: 10), "About did not dismiss after Done", app)
        assertHome(app, "after About Done")
        capture(app, "Home after About Done")
    }

    // MARK: - Home

    @MainActor
    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.bundleID)
        let installedID = Self.bundleID
        addTeardownBlock { await MainActor.run { XCUIApplication(bundleIdentifier: installedID).terminate() } }
        app.launch()
        require(app.wait(for: .runningForeground, timeout: 30),
                "Precondition: installed \(Self.bundleID) must launch to the foreground", app)
        require(app.buttons["peel.home.settings"].waitForExistence(timeout: 30),
                "Precondition: installed Peel Pro must reach Home (peel.home.settings)", app)
        let alert = app.alerts.firstMatch
        require(!alert.exists, "An unexpected alert blocks Home: \(alert.exists ? alert.label : "")", app)
        assertHome(app, "launch")
        return app
    }

    /// Home title, the four ornament controls and the tab items, all from actual source.
    @MainActor
    private func assertHome(_ app: XCUIApplication, _ context: String) {
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", "Peel Pro")).firstMatch
        require(title.waitForExistence(timeout: 10), "Home must show its Peel Pro title (\(context))", app)
        for control in Self.ornamentControls {
            let button = app.buttons[control.id]
            require(button.waitForExistence(timeout: 10), "\(control.id) must exist in the Home ornament (\(context))", app)
            require(button.isHittable, "\(control.id) must be hittable (\(context))", app)
            require(button.label == control.label,
                    "\(control.id) must be labelled \"\(control.label)\", found \"\(button.label)\" (\(context))", app)
        }
        for tab in Self.homeTabs {
            let item = tabItem(app, tab.label)
            require(item.isHittable, "\(tab.label) tab must be hittable (\(context))", app)
        }
    }

    /// The outer sidebar tab Button with the exact source identifier and label. Its nested
    /// icon and title buttons carry no identifier, so exactly one element may match.
    @MainActor
    private func tabItem(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 10) -> XCUIElement {
        guard let id = Self.homeTabs.first(where: { $0.label == label })?.id else {
            require(false, "No source tab named \(label)", app)
            return app.buttons[label]
        }
        let query = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", id, label))
        let item = query.firstMatch
        require(item.waitForExistence(timeout: timeout), "Home must expose the \(label) tab (button \(id))", app)
        let count = query.count
        require(count == 1, "Home must expose exactly one \(label) tab button (\(id)), found \(count)", app)
        return item
    }

    /// MacsTabView always shows its nearby count, plus searching, nearby or saved content.
    @MainActor
    private func assertComputersContent(_ app: XCUIApplication) -> [String: String] {
        let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ computers? nearby")).firstMatch
        require(count.waitForExistence(timeout: 10), "Computers must show its nearby-computer count", app)
        let states: [(name: String, element: XCUIElement)] = [
            ("searching", element(app, NSPredicate(format: "label BEGINSWITH[c] %@", "Looking for Computers"))),
            ("nearby", element(app, NSPredicate(format: "label ==[c] %@", "Nearby Computers"))),
            ("saved", element(app, NSPredicate(format: "label ==[c] %@", "Saved Computers"))),
        ]
        var observed: [String] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            observed = states.filter { $0.element.exists }.map { $0.name }
        } while observed.isEmpty && !states[0].element.waitForExistence(timeout: 1) && Date() < deadline
        observed = states.filter { $0.element.exists }.map { $0.name }
        require(!observed.isEmpty, "Computers must show searching, nearby or saved computers", app)
        return ["nearbyCount": count.label, "computersContent": observed.joined(separator: ",")]
    }

    // MARK: - Sheets

    @MainActor
    private func openSheet(_ app: XCUIApplication, from id: String, header title: String) -> XCUIElement {
        require(headerElement(app, title) == nil, "Precondition: \(title) must not be on screen before \(id)", app)
        let button = app.buttons[id]
        require(button.waitForExistence(timeout: 10) && button.isHittable, "\(id) must be hittable", app)
        button.tap()
        var header: XCUIElement?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            header = headerElement(app, title)
        } while header == nil && !app.navigationBars[title].waitForExistence(timeout: 0.5) && Date() < deadline
        header = header ?? headerElement(app, title)
        require(header != nil, "\(id) must open \(title)", app)
        return header ?? app.navigationBars[title]
    }

    /// The navigation bar titled `title`, or its exact title text if the bar is not exposed.
    @MainActor
    private func headerElement(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
        let bar = app.navigationBars[title]
        if bar.exists { return bar }
        let text = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        return text.exists ? text : nil
    }

    @MainActor
    private func dismissWithToolbarDone(_ app: XCUIApplication, header: XCUIElement, title: String) {
        var done = header.buttons.matching(Self.doneLabel).firstMatch
        if !(done.exists && done.isHittable) {
            done = hittable(app.buttons.matching(Self.doneLabel)) ?? done
        }
        require(done.exists && done.isHittable, "\(title) must offer its own Done", app)
        done.tap()
        require(header.waitForNonExistence(timeout: 10), "\(title) did not dismiss after Done", app)
    }

    // MARK: - Read-only scrolling
    //
    // visionOS 27 XCUIAutomation offers no scroll-wheel or pointer API (scroll(byDeltaX:deltaY:),
    // hover and click are TARGET_OS_IOS-only and TARGET_OS_IOS is 0 on xros), and Digital Crown
    // rotation is a system control on Vision, so it is not used. Repair 1 showed that drags in the
    // list's leading margin (x 17 pt, outside the 24…556 pt cells) move nothing. Gestures now start
    // only on a standalone text row: a cell with no interactive descendant whose single static
    // text spans the whole cell (section headers and footnotes, e.g. "Peel Pro" or
    // "Connect by Address" in the actual 227.1 hierarchy). Toggle rows never qualify because their
    // Switch spans the cell. Repair 3 showed the Input section has no such row: each cell is a
    // Switch plus a sibling `settingFootnote` text (e.g. Scroll at y 153.5…185.5, "Show vertical
    // scroll arrows" at y 189.5…205.5). Those source footnotes are also anchors when no ancestor is
    // interactive, their frame stays clear of every interactive frame and their centre stays well
    // clear of it. Every gesture is checked against before/after AX snapshots.

    private enum ScrollStrategy: String {
        /// Press, drag within the visible list, hold before release: bounded distance, no fling.
        case heldDrag
        /// XCUIElement.swipeUp()/swipeDown() at the anchor's hittable point.
        case swipe
    }

    private struct ScrollSession {
        /// The first strategy that demonstrably moves the list is kept first.
        var order: [ScrollStrategy] = [.heldDrag, .swipe]
        var log: [String] = []
    }

    /// Read-only guard across the whole Settings route: one baseline per switch or slider,
    /// against which every later snapshot is compared before anything else is recorded.
    private struct ValueGuard {
        /// First value seen for each control key, in either direction.
        var baseline: [String: String] = [:]
        /// Keys seen before and after `returning` is set.
        var downward: Set<String> = []
        var upward: Set<String> = []
        var returning = false
        var observations = 0
        var discrepancies: [String] = []
    }

    /// One AX snapshot of the Settings list.
    private struct ListScan {
        var anchors: [(label: String, frame: CGRect, kind: AnchorKind)] = []
        var textMinY: [String: CGFloat] = [:]
        var controls: [String: String] = [:]
        /// Frames of every interactive element in the snapshot.
        var interactiveFrames: [CGRect] = []
    }

    private enum AnchorKind: String {
        /// A cell with no interactive descendant whose static text spans the whole cell.
        case row
        /// A whitelisted source footnote with no interactive ancestor.
        case footnote
    }

    /// `settingFootnote` texts of the visionOS Input and Advanced sections
    /// (Shared/Client/SettingsView.swift). Each renders as a plain static text beside, not inside,
    /// its Toggle.
    private static let footnoteAnchors: Set<String> = [
        "Show vertical scroll arrows",
        "Show esc, tab, shift, etc.",
        "Show directional arrow keys",
        "Show zoom buttons",
        "Show right click and drag buttons",
        "Keep right click mode on until turned off",
        "Show experimental immersive HUD controls",
    ]
    /// A gesture's start point must lie outside every interactive frame grown by this margin.
    private static let startClearance: CGFloat = 8
    /// A footnote's frame must not overlap any interactive frame grown by this margin. It is below
    /// the source's 4 pt VStack spacing between a Toggle and its footnote.
    private static let footnoteClearance: CGFloat = 2
    /// Largest held drag, as a share of the visible band, so consecutive snapshots overlap by at
    /// least 40% of the band (two dense 96 pt rows) and no row passes between them unobserved.
    private static let maxStepFraction: CGFloat = 0.6

    private static let interactiveTypes: Set<XCUIElement.ElementType> = [
        .button, .`switch`, .toggle, .slider, .stepper, .link, .textField, .secureTextField, .textView,
        .searchField, .popUpButton, .menuButton, .menu, .menuItem, .segmentedControl, .picker, .pickerWheel,
        .datePicker, .comboBox, .checkBox, .radioButton, .disclosureTriangle, .incrementArrow,
        .decrementArrow, .colorWell, .toolbarButton, .tab, .key,
    ]

    /// The Settings sheet's own collection view, scoped by its window's navigation bar so it
    /// stays resolvable after the account row scrolls away.
    @MainActor
    private func settingsList(_ app: XCUIApplication, header: XCUIElement) -> XCUIElement {
        if header.elementType == .navigationBar {
            let list = app.windows.containing(.navigationBar, identifier: "Settings").firstMatch
                .collectionViews.firstMatch
            if list.waitForExistence(timeout: 5) { return list }
        }
        let predicate = NSPredicate(format: "label CONTAINS %@", "Apple Account & Device Sync")
        for query in [app.collectionViews, app.tables, app.scrollViews] {
            let match = query.containing(predicate).firstMatch
            if match.waitForExistence(timeout: 3) { return match }
        }
        require(false, "No Settings list was found", app)
        return app.collectionViews.firstMatch
    }

    /// Scrolls until `target` is hittable. The direction follows the target's frame when it is
    /// in the AX tree (so an overshoot reverses), and reverses once when no gesture moves the list.
    @MainActor
    private func reveal(_ target: XCUIElement, in list: XCUIElement, header: XCUIElement, _ what: String,
                        _ app: XCUIApplication, startTowardEnd: Bool,
                        values: inout ValueGuard, session: inout ScrollSession) {
        var towardEnd = startTowardEnd
        var reversed = false
        var gestures = 0
        if let scan = scanList(list) { observe(scan.controls, &values, "\(what) start", app) }
        while !(target.exists && target.isHittable) && gestures < 16 {
            let band = visibleBand(list, header: header)
            if target.exists {
                if target.frame.maxY <= band.lowerBound { towardEnd = false }
                if target.frame.minY >= band.upperBound { towardEnd = true }
            }
            let moved = scrollStep(list, band: band, towardEnd: towardEnd, toward: what, app,
                                   values: &values, session: &session)
            gestures += 1
            if !moved {
                guard !reversed else { break }
                reversed = true
                towardEnd.toggle()
            }
        }
        if !(target.exists && target.isHittable) {
            attachJSON(["target": what, "gestures": "\(gestures)",
                        "steps": session.log.joined(separator: "\n")],
                       "Settings scroll progress before failure")
        }
        require(target.exists && target.isHittable,
                "Settings must show \(what) (\(gestures) read-only scroll gestures; see scroll progress)", app)
    }

    /// Area of the list that is on screen and below the navigation bar.
    @MainActor
    private func visibleBand(_ list: XCUIElement, header: XCUIElement) -> ClosedRange<CGFloat> {
        let frame = list.frame
        let top = max(frame.minY, header.frame.maxY) + 8
        let bottom = max(top + 1, frame.maxY - 8)
        return top...bottom
    }

    /// One gesture on a safe anchor (standalone text row or clear source footnote); true only if
    /// the AX snapshot shows the content moved.
    @MainActor
    private func scrollStep(_ list: XCUIElement, band: ClosedRange<CGFloat>, towardEnd: Bool, toward what: String,
                            _ app: XCUIApplication,
                            values: inout ValueGuard, session: inout ScrollSession) -> Bool {
        let direction = towardEnd ? "down" : "up"
        guard let before = scanList(list) else {
            session.log.append("\(what) \(direction): list snapshot unavailable")
            return false
        }
        observe(before.controls, &values, "\(what) \(direction), before gesture", app)
        let listFrame = list.frame
        let candidates = before.anchors.filter { isSafeAnchor($0, before, band: band, listFrame: listFrame) }
            .sorted { towardEnd ? $0.frame.midY > $1.frame.midY : $0.frame.midY < $1.frame.midY }
        guard !candidates.isEmpty else {
            session.log.append("\(what) \(direction): no standalone text row or clear footnote visible in \(band)")
            return false
        }
        // The lowest (or highest) safe anchor that a fresh query finds with the same label and
        // frame and that is hittable now.
        var resolved: (anchor: (label: String, frame: CGRect, kind: AnchorKind), element: XCUIElement)?
        for anchor in candidates.prefix(3) where resolved == nil {
            let matches = list.staticTexts.matching(NSPredicate(format: "label == %@", anchor.label))
            for index in 0..<min(matches.count, 8) {
                let candidate = matches.element(boundBy: index)
                let frame = candidate.frame
                if abs(frame.minX - anchor.frame.minX) < 1 && abs(frame.minY - anchor.frame.minY) < 1
                    && abs(frame.width - anchor.frame.width) < 1 && abs(frame.height - anchor.frame.height) < 1
                    && candidate.isHittable {
                    resolved = (anchor, candidate)
                    break
                }
            }
            if resolved == nil {
                session.log.append("\(what) \(direction): \(anchor.kind.rawValue) '\(anchor.label)' not resolvable with the same frame and hittable")
            }
        }
        guard let match = resolved else { return false }
        let anchor = match.anchor
        let element = match.element
        for strategy in session.order {
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            switch strategy {
            case .heldDrag:
                let maxStep = (band.upperBound - band.lowerBound) * Self.maxStepFraction
                let endY = towardEnd ? band.lowerBound + 4 : band.upperBound - 4
                let distance = max(-maxStep, min(maxStep, endY - anchor.frame.midY))
                guard abs(distance) >= 40 else {
                    session.log.append("\(what) \(direction): heldDrag skipped, '\(anchor.label)' only \(Int(distance)) pt from edge")
                    continue
                }
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                            withVelocity: .slow, thenHoldForDuration: 0.3)
            case .swipe:
                if towardEnd { element.swipeUp() } else { element.swipeDown() }
            }
            guard let after = scanList(list) else {
                session.log.append("\(what) \(direction): \(strategy.rawValue) on '\(anchor.label)', snapshot unavailable after")
                return false
            }
            observe(after.controls, &values, "\(what) \(direction), after \(strategy.rawValue)", app)
            let shift = contentShift(before, after)
            session.log.append("\(what) \(direction): \(strategy.rawValue) on \(anchor.kind.rawValue) '\(anchor.label)' at y \(Int(anchor.frame.midY)) → \(shift)")
            if shift != "unchanged" {
                session.order = [strategy] + session.order.filter { $0 != strategy }
                return true
            }
        }
        return false
    }

    /// An anchor whose snapshot frame lies fully inside the visible band and list, whose centre (the
    /// gesture's start point) is clear of every grown interactive frame and, for a footnote, whose
    /// whole frame is too.
    private func isSafeAnchor(_ anchor: (label: String, frame: CGRect, kind: AnchorKind), _ scan: ListScan,
                              band: ClosedRange<CGFloat>, listFrame: CGRect) -> Bool {
        let frame = anchor.frame
        guard !frame.isEmpty, band.contains(frame.minY), band.contains(frame.maxY),
              frame.minX >= listFrame.minX, frame.maxX <= listFrame.maxX else { return false }
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
        }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        return !scan.interactiveFrames.contains { control in
            control.insetBy(dx: -Self.startClearance, dy: -Self.startClearance).contains(start)
                || (anchor.kind == .footnote
                    && overlaps(control.insetBy(dx: -Self.footnoteClearance, dy: -Self.footnoteClearance), frame))
        }
    }

    /// Describes how far shared static texts moved, or whether the visible text set changed.
    private func contentShift(_ before: ListScan, _ after: ListScan) -> String {
        let shared = before.textMinY.keys.filter { after.textMinY[$0] != nil }
        let deltas = shared.compactMap { key -> CGFloat? in
            guard let old = before.textMinY[key], let new = after.textMinY[key] else { return nil }
            return new - old
        }
        if let largest = deltas.max(by: { abs($0) < abs($1) }), abs(largest) >= 4 {
            return "moved \(Int(largest)) pt"
        }
        if Set(before.textMinY.keys) != Set(after.textMinY.keys) { return "text set changed" }
        return "unchanged"
    }

    /// One AX snapshot of the list: standalone text rows, source footnotes, static-text positions,
    /// interactive frames and the values of every switch and slider.
    @MainActor
    private func scanList(_ list: XCUIElement) -> ListScan? {
        guard let root = try? list.snapshot() else { return nil }
        var scan = ListScan()
        func descendants(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
            node.children + node.children.flatMap { descendants($0) }
        }
        func visit(_ node: XCUIElementSnapshot, insideInteractive: Bool) {
            let interactive = Self.interactiveTypes.contains(node.elementType)
            if interactive { scan.interactiveFrames.append(node.frame) }
            switch node.elementType {
            case .`switch`, .slider:
                let key = "\(node.elementType == .slider ? "slider" : "switch"):\(node.label)"
                if scan.controls[key] == nil { scan.controls[key] = node.value.map { "\($0)" } ?? "nil" }
            case .staticText:
                if !node.label.isEmpty && scan.textMinY[node.label] == nil { scan.textMinY[node.label] = node.frame.minY }
                // Never a switch or button label: a footnote counts only with no interactive ancestor.
                if !insideInteractive && Self.footnoteAnchors.contains(node.label) {
                    scan.anchors.append((node.label, node.frame, .footnote))
                }
            case .cell:
                let inner = descendants(node)
                let spanning = inner.first {
                    $0.elementType == .staticText && !$0.label.isEmpty
                        && abs($0.frame.minX - node.frame.minX) < 1 && abs($0.frame.minY - node.frame.minY) < 1
                        && abs($0.frame.width - node.frame.width) < 1 && abs($0.frame.height - node.frame.height) < 1
                }
                let hasInteractive = inner.contains { Self.interactiveTypes.contains($0.elementType) }
                if !insideInteractive && !hasInteractive, let spanning {
                    scan.anchors.append((spanning.label, spanning.frame, .row))
                }
            default:
                break
            }
            node.children.forEach { visit($0, insideInteractive: insideInteractive || interactive) }
        }
        visit(root, insideInteractive: false)
        return scan
    }

    /// Compares every observed control with its baseline before recording it; a key seen for the
    /// first time becomes its baseline. Any difference fails at once and is kept for the summary.
    @MainActor
    private func observe(_ controls: [String: String], _ values: inout ValueGuard, _ context: String,
                         _ app: XCUIApplication) {
        values.observations += 1
        for key in controls.keys.sorted() {
            let value = controls[key] ?? "nil"
            if let baseline = values.baseline[key], baseline != value {
                let discrepancy = "\(key): \(baseline) → \(value) (\(context))"
                values.discrepancies.append(discrepancy)
                require(false, "\(key) changed during a read-only Settings pass: \(discrepancy)", app)
            } else if values.baseline[key] == nil {
                values.baseline[key] = value
            }
            if values.returning { values.upward.insert(key) } else { values.downward.insert(key) }
        }
    }

    private func describe(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "nil")" }.joined(separator: "; ")
    }

    // MARK: - About read-only scrolling
    //
    // About (Shared/Client/InfoView.swift) is a ScrollView holding the three steps and the Controls
    // card, with its Done fixed below the ScrollView. Gestures start only on an `aboutAnchorLabels`
    // text that is a static text (or a combined step row) with no interactive ancestor or
    // descendant and a label unique in the ScrollView, and that passes `isSafeAnchor` in its
    // strict footnote form against every interactive frame plus the Info header and Done frames.
    // A fresh snapshot and query revalidate the anchor right before each gesture. Each held drag
    // moves the content up by at most 60% of the visible band and ends inside the band, clear of
    // every interactive frame. A held drag that moves nothing gets one swipeUp on the same
    // revalidated anchor; if that also moves nothing the route fails. Six attempts in total, no
    // sleeps, and only whitelisted Info labels and frames are logged.

    /// Whitelisted Info texts in one snapshot of the About ScrollView.
    private struct AboutScan {
        /// Anchors (always `.footnote`, the strict form), whitelisted static-text positions and
        /// every interactive frame, including the Info header and About's Done.
        var list = ListScan()
        /// Frames of every static text with a whitelisted label.
        var texts: [String: [CGRect]] = [:]
        var anchorTypes: [String: XCUIElement.ElementType] = [:]
    }

    /// About's own ScrollView: it must hold exactly one Controls heading and no Done, and end
    /// above About's fixed Done.
    @MainActor
    private func aboutScrollView(_ app: XCUIApplication, header: XCUIElement, done: XCUIElement) -> XCUIElement {
        let controls = NSPredicate(format: "label == %@", "Controls")
        var queries = [app.scrollViews]
        if header.elementType == .navigationBar {
            queries.insert(app.windows.containing(.navigationBar, identifier: "Info").firstMatch.scrollViews, at: 0)
        }
        var scroll = app.scrollViews.firstMatch
        for query in queries {
            let match = query.containing(controls).firstMatch
            if match.waitForExistence(timeout: 5) {
                scroll = match
                break
            }
        }
        require(scroll.exists && scroll.staticTexts.matching(controls).count == 1,
                "About must expose one Info ScrollView holding exactly one Controls heading", app)
        require(scroll.buttons.matching(Self.doneLabel).count == 0 && scroll.frame.maxY <= done.frame.minY + 1,
                "About's Done must sit outside and below its ScrollView", app)
        return scroll
    }

    /// Area of the ScrollView that is on screen, below the Info header and above About's Done.
    @MainActor
    private func aboutBand(_ scroll: XCUIElement, header: XCUIElement, done: XCUIElement) -> ClosedRange<CGFloat> {
        let frame = scroll.frame
        let top = max(frame.minY, header.frame.maxY) + 8
        let bottom = max(top + 1, min(frame.maxY, done.frame.minY) - 8)
        return top...bottom
    }

    @MainActor
    private func scanAbout(_ scroll: XCUIElement, header: XCUIElement, done: XCUIElement) -> AboutScan? {
        guard let root = try? scroll.snapshot() else { return nil }
        var scan = AboutScan()
        scan.list.interactiveFrames = [header.frame, done.frame]
        var counts: [String: Int] = [:]
        func descendants(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
            node.children + node.children.flatMap { descendants($0) }
        }
        func visit(_ node: XCUIElementSnapshot, insideInteractive: Bool) {
            let interactive = Self.interactiveTypes.contains(node.elementType)
            if interactive { scan.list.interactiveFrames.append(node.frame) }
            if Self.aboutAnchorLabels.contains(node.label) {
                counts[node.label, default: 0] += 1
                if node.elementType == .staticText { scan.texts[node.label, default: []].append(node.frame) }
                if scan.list.textMinY[node.label] == nil { scan.list.textMinY[node.label] = node.frame.minY }
                if !interactive && !insideInteractive
                    && (node.elementType == .staticText || node.elementType == .other)
                    && !descendants(node).contains(where: { Self.interactiveTypes.contains($0.elementType) }) {
                    scan.list.anchors.append((node.label, node.frame, .footnote))
                    scan.anchorTypes[node.label] = node.elementType
                }
            }
            node.children.forEach { visit($0, insideInteractive: insideInteractive || interactive) }
        }
        visit(root, insideInteractive: false)
        scan.list.anchors.removeAll { counts[$0.label] != 1 }
        return scan
    }

    /// Target labels that are missing, duplicated or not fully inside the band and ScrollView.
    private func aboutTargetsOutside(_ scan: AboutScan, band: ClosedRange<CGFloat>, listFrame: CGRect) -> [String] {
        Self.aboutTargetLabels.filter { label in
            guard let frames = scan.texts[label], frames.count == 1, let frame = frames.first, !frame.isEmpty else { return true }
            return !(band.contains(frame.minY) && band.contains(frame.maxY)
                     && frame.minX >= listFrame.minX && frame.maxX <= listFrame.maxX)
        }
    }

    private func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// Fresh snapshot and query right before a gesture: the anchor must still be a safe, unique,
    /// fully visible whitelisted text with the same frame, and one hittable element of that type,
    /// label and frame.
    @MainActor
    private func resolveAboutAnchor(_ anchor: (label: String, frame: CGRect, kind: AnchorKind), in scroll: XCUIElement,
                                    header: XCUIElement, done: XCUIElement) -> XCUIElement? {
        let band = aboutBand(scroll, header: header, done: done)
        guard let scan = scanAbout(scroll, header: header, done: done),
              let type = scan.anchorTypes[anchor.label],
              let current = scan.list.anchors.first(where: { $0.label == anchor.label }),
              sameFrame(current.frame, anchor.frame),
              isSafeAnchor(current, scan.list, band: band, listFrame: scroll.frame) else { return nil }
        let matches = scroll.descendants(matching: type).matching(NSPredicate(format: "label == %@", anchor.label))
        guard matches.count == 1 else { return nil }
        let element = matches.element(boundBy: 0)
        return sameFrame(element.frame, anchor.frame) && element.isHittable ? element : nil
    }

    /// Nothing on About may have been triggered: foreground, header, no alert, no Copy feedback and
    /// the same Done buttons.
    @MainActor
    private func requireAboutUntouched(_ app: XCUIApplication, header: XCUIElement, doneCount: Int, _ context: String) {
        require(app.state == .runningForeground, "Peel Pro must stay in the foreground on About (\(context))", app)
        require(header.exists, "About's Info header must stay on screen (\(context))", app)
        require(!app.alerts.firstMatch.exists, "No alert may appear on About (\(context))", app)
        require(!element(app, labelContaining: "Copied").exists, "About's Copy must not have been triggered (\(context))", app)
        require(app.buttons.matching(Self.doneLabel).count == doneCount, "About's Done buttons must not change (\(context))", app)
    }

    /// Scrolls About's ScrollView up until every target text is fully inside the visible band.
    @MainActor
    private func revealAboutControls(_ scroll: XCUIElement, header: XCUIElement, done: XCUIElement, doneCount: Int,
                                     _ app: XCUIApplication) -> (attempts: Int, moving: Int, log: [String]) {
        var attempts = 0
        var moving = 0
        var log: [String] = []
        func fail(_ message: String) -> (attempts: Int, moving: Int, log: [String]) {
            attachJSON(["attempts": "\(attempts) of \(Self.aboutMaxGestureAttempts)", "steps": log.joined(separator: "\n")],
                       "About scroll progress before failure")
            require(false, "\(message) (\(attempts) gesture attempts; see About scroll progress)", app)
            return (attempts, moving, log)
        }
        while true {
            let band = aboutBand(scroll, header: header, done: done)
            guard let before = scanAbout(scroll, header: header, done: done) else {
                return fail("About's ScrollView snapshot was unavailable")
            }
            let outside = aboutTargetsOutside(before, band: band, listFrame: scroll.frame)
            if outside.isEmpty { return (attempts, moving, log) }
            if let heading = before.texts["Controls"]?.first, heading.minY < band.lowerBound {
                return fail("The Controls card does not fit the visible band \(Int(band.lowerBound))…\(Int(band.upperBound)); outside: \(outside.joined(separator: ", "))")
            }
            guard attempts < Self.aboutMaxGestureAttempts else {
                return fail("The Controls card is not fully visible within the six-attempt budget; outside: \(outside.joined(separator: ", "))")
            }
            log.append("outside band \(Int(band.lowerBound))…\(Int(band.upperBound)): \(outside.joined(separator: ", "))")

            // The lowest safe anchor with a drag of at least 40 pt that ends in the band, clear of
            // every interactive frame.
            let maxStep = (band.upperBound - band.lowerBound) * Self.maxStepFraction
            func clear(_ point: CGPoint) -> Bool {
                band.contains(point.y) && !before.list.interactiveFrames.contains {
                    $0.insetBy(dx: -Self.startClearance, dy: -Self.startClearance).contains(point)
                }
            }
            var choice: (anchor: (label: String, frame: CGRect, kind: AnchorKind), distance: CGFloat)?
            let candidates = before.list.anchors.filter { isSafeAnchor($0, before.list, band: band, listFrame: scroll.frame) }
                .sorted { $0.frame.midY > $1.frame.midY }
            for anchor in candidates.prefix(3) where choice == nil {
                var distance = max(-maxStep, band.lowerBound + 4 - anchor.frame.midY)
                while distance <= -40 && !clear(CGPoint(x: anchor.frame.midX, y: anchor.frame.midY + distance)) {
                    distance += 8
                }
                if distance <= -40 {
                    choice = (anchor, distance)
                } else {
                    log.append("'\(anchor.label)' at y \(Int(anchor.frame.midY)): no clear upward drag of at least 40 pt")
                }
            }
            guard let chosen = choice else {
                return fail("No safe noninteractive Info text with a clear upward drag is visible in the band")
            }
            let anchor = chosen.anchor
            guard let element = resolveAboutAnchor(anchor, in: scroll, header: header, done: done) else {
                return fail("'\(anchor.label)' was not revalidated as safe, unique, unmoved and hittable before its held drag")
            }
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: chosen.distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
            attempts += 1
            requireAboutUntouched(app, header: header, doneCount: doneCount, "after attempt \(attempts)")
            guard let afterDrag = scanAbout(scroll, header: header, done: done) else {
                return fail("About's ScrollView snapshot was unavailable after attempt \(attempts)")
            }
            var shift = contentShift(before.list, afterDrag.list)
            log.append("attempt \(attempts): heldDrag \(Int(chosen.distance)) pt on '\(anchor.label)' at y \(Int(anchor.frame.midY)) → \(shift)")
            if shift == "unchanged" {
                guard attempts < Self.aboutMaxGestureAttempts else {
                    return fail("The held drag did not move About's ScrollView and no attempt is left for its swipeUp fallback")
                }
                guard let same = resolveAboutAnchor(anchor, in: scroll, header: header, done: done) else {
                    return fail("'\(anchor.label)' was not revalidated before its swipeUp fallback")
                }
                same.swipeUp()
                attempts += 1
                requireAboutUntouched(app, header: header, doneCount: doneCount, "after attempt \(attempts)")
                guard let afterSwipe = scanAbout(scroll, header: header, done: done) else {
                    return fail("About's ScrollView snapshot was unavailable after attempt \(attempts)")
                }
                shift = contentShift(before.list, afterSwipe.list)
                log.append("attempt \(attempts): swipeUp fallback on '\(anchor.label)' → \(shift)")
                if shift == "unchanged" {
                    return fail("Neither the held drag nor its swipeUp fallback on '\(anchor.label)' moved About's ScrollView")
                }
            }
            moving += 1
        }
    }

    /// Every target is one static text fully inside the band; each title shares its row with its
    /// instruction, title first; heading, rows and note are in source order. Returns their frames.
    @MainActor
    private func requireAboutControlsGeometry(_ scan: AboutScan, band: ClosedRange<CGFloat>, listFrame: CGRect,
                                              _ app: XCUIApplication) -> [String: String] {
        var frames: [String: CGRect] = [:]
        for label in Self.aboutTargetLabels {
            let found = scan.texts[label] ?? []
            require(found.count == 1, "About must expose exactly one \"\(label)\" text in its ScrollView, found \(found.count)", app)
            frames[label] = found.first
        }
        let outside = aboutTargetsOutside(scan, band: band, listFrame: listFrame)
        require(outside.isEmpty, "About's Controls card must be fully visible; outside the band: \(outside.joined(separator: ", "))", app)
        for row in Self.aboutControls {
            guard let title = frames[row.title], let message = frames[row.message] else { continue }
            require(abs(title.midY - message.midY) <= 4 && title.maxX <= message.minX,
                    "\"\(row.title)\" and \"\(row.message)\" must share one row, title first", app)
        }
        let order = ["Controls"] + Self.aboutControls.map { $0.title } + [Self.aboutExternalInputNote]
        for (upper, lower) in zip(order, order.dropFirst()) {
            require((frames[upper]?.maxY ?? .infinity) <= (frames[lower]?.minY ?? -.infinity),
                    "\"\(upper)\" must sit above \"\(lower)\" as in InfoView.swift", app)
        }
        var values: [String: String] = [:]
        for (label, rect) in frames {
            values["frame: " + label] = "x \(Int(rect.minX)) y \(Int(rect.minY)) w \(Int(rect.width)) h \(Int(rect.height))"
        }
        return values
    }

    // MARK: - Queries

    @MainActor
    private func element(_ app: XCUIApplication, labelContaining value: String) -> XCUIElement {
        element(app, NSPredicate(format: "label CONTAINS %@", value))
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ predicate: NSPredicate) -> XCUIElement {
        app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func hittable(_ query: XCUIElementQuery) -> XCUIElement? {
        for index in 0..<query.count {
            let candidate = query.element(boundBy: index)
            if candidate.exists && candidate.isHittable { return candidate }
        }
        return nil
    }

    private func environmentValue(_ key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment[key] ?? environment["TEST_RUNNER_" + key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
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

    /// Attempted independent screen pixels beside the app screenshot. Taken only while Peel Pro
    /// owns the foreground of the retained QA simulator (TEST_RUNNER_PEEL_VISION_QA_SIMULATOR_UDID
    /// overrides the default); otherwise withheld. On the xrOS simulator XCUIScreen returned 1x1
    /// black stubs, so a capture smaller than 64x64 pixels is recorded as invalid metadata only:
    /// it is not attached as an image, is not visual evidence, and does not fail the route.
    @MainActor
    private func captureScreenEvidence(_ app: XCUIApplication, _ name: String) {
        guard require(app.state == .runningForeground,
                      "Precondition: Peel Pro must own the foreground for \(name) evidence", app) else { return }
        let expectedUDID = environmentValue("PEEL_VISION_QA_SIMULATOR_UDID") ?? Self.retainedQASimulatorUDID
        let actualUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unavailable"
        guard actualUDID == expectedUDID else {
            attachJSON(["screenCapture": "withheld: simulator context is not the declared QA simulator",
                        "simulatorUDID": actualUDID, "expectedQASimulatorUDID": expectedUDID],
                       "Screen (XCUIScreen.main) \(name) withheld")
            return
        }
        let screenShot = XCUIScreen.main.screenshot()
        let pixels = screenShot.image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        guard pixels.width >= 64 && pixels.height >= 64 else {
            attachJSON(["screenCapture": "invalid: XCUIScreen returned a \(Int(pixels.width))x\(Int(pixels.height)) pixel stub; not visual evidence",
                        "simulatorUDID": actualUDID,
                        "note": "Use the app screenshot (top-level scene image) and root's native simulator viewport capture instead"],
                       "Screen (XCUIScreen.main) \(name) invalid")
            return
        }
        let screen = XCTAttachment(screenshot: screenShot)
        screen.name = "Screen (XCUIScreen.main) \(name)"
        screen.lifetime = .keepAlways
        add(screen)
        guard require(app.state == .runningForeground,
                      "Precondition: Peel Pro must still own the foreground for the \(name) metrics app screenshot", app)
        else { return }
        let appImage = app.screenshot().image // Metrics only; capture() attaches the app image.
        func metrics(_ prefix: String, _ image: UIImage) -> [String: String] {
            [prefix + "Points": "\(image.size.width)x\(image.size.height)",
             prefix + "Scale": "\(image.scale)",
             prefix + "ImageOrientationRaw": "\(image.imageOrientation.rawValue)",
             prefix + "CGImagePixels": image.cgImage.map { "\($0.width)x\($0.height)" } ?? "unavailable"]
        }
        var values = metrics("screen", screenShot.image).merging(metrics("appSeparateCapture", appImage)) { $1 }
        values["appWindowFrame"] = "\(app.windows.firstMatch.frame)"
        values["simulatorUDID"] = actualUDID
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
