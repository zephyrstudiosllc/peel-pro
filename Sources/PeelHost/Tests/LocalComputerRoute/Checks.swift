import Foundation
import AppKit
import Darwin

// The real InputSynthesizer, window controller, leases, local-access state,
// app catalog (scanning the real /System/Applications, with launch replaced)
// and the exact extracted Host local-route and paired host-command methods are
// compiled into this process. Only OS window lists, AX focus effects, capture
// output, permission reads and event posting are replaced. Nothing is
// captured, focused, closed, launched or posted.

enum FixturePermissions {
    static var masterGate = true
    static var accessibility = true
    static var screenCapture = true
}

/// Mirrors the real manager's gates: the paired predicate guards paired
/// paths and close/minimize; the local entry point runs only under the
/// caller-supplied authority, rechecked before every staged effect.
final class AccessibilityManager {
    var isRemoteControlAllowed: () -> Bool = { false }
    var sendInputRejected: ((UInt32, String) -> Void)?
    var focusedWindow: UInt32?
    var refuseFocus = false
    var holdFocus = false
    var ready = true
    var topmost = true
    var localFocusEntries: [Bool] = []
    var localStageEffects: [String] = []
    var closed: [UInt32] = []
    var minimized: [UInt32] = []
    // Staged mode runs the production local entry point and staged sequence
    // (extracted below); each raise/activation records the PID it resolved.
    var staged = false
    var stagedEffects: [String] = []
    var afterStagedEffect: ((String) -> Void)?

    func bringWindowToFront(windowId: UInt32, interactionPoint: CGPoint? = nil, force: Bool = false,
                            completion: (() -> Void)? = nil) {
        guard isRemoteControlAllowed() else { completion?(); return }
        focusedWindow = windowId
        completion?()
    }
    func bringWindowToFrontForLocalAgent(windowId: UInt32, authorized: @escaping () -> Bool,
                                         completion: @escaping (Bool) -> Void) {
        if staged {
            productionBringWindowToFrontForLocalAgent(windowId: windowId, authorized: authorized, completion: completion)
            return
        }
        let entry = authorized()
        localFocusEntries.append(entry)
        guard entry else { completion(false); return }
        localStageEffects.append("preselect+activate:\(windowId)")
        if holdFocus { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                guard authorized() else { completion(false); return }
                self.localStageEffects.append("raise:\(windowId)")
                if !self.refuseFocus { self.focusedWindow = windowId }
                completion(self.isExactWindowFocusedForAgentInput(windowId: windowId, authorized: authorized))
            }
        }
    }
    func isWindowReadyForInput(windowId: UInt32, interactionPoint: CGPoint? = nil) -> Bool {
        ready && isRemoteControlAllowed() && focusedWindow == windowId
    }
    func authoritativePointFallback(for windowId: UInt32) -> CGPoint? { CGPoint(x: 500, y: 400) }
    func isExactWindowFocusedForAgentInput(windowId: UInt32) -> Bool {
        isExactWindowFocusedForAgentInput(windowId: windowId, authorized: isRemoteControlAllowed)
    }
    func isExactWindowFocusedForAgentInput(windowId: UInt32, authorized: () -> Bool) -> Bool {
        authorized() && focusedWindow == windowId
    }
    func isExactWindowTopmostForAgentInput(windowId: UInt32, point: CGPoint) -> Bool { topmost }
    func isExactWindowHitForLocalAgentPointer(windowId: UInt32, point: CGPoint) -> Bool { topmost }
    func closeWindow(windowId: UInt32) {
        guard isRemoteControlAllowed() else { return }
        closed.append(windowId)
    }
    func minimizeWindow(windowId: UInt32) {
        guard isRemoteControlAllowed() else { return }
        minimized.append(windowId)
    }
    func isWindowActuallyFrontmost(windowId: UInt32, authorized: (() -> Bool)? = nil) -> Bool {
        (authorized ?? isRemoteControlAllowed)() && focusedWindow == windowId
    }
    func isTargetWindowTopmost(targetWindowId: UInt32, at point: CGPoint) -> Bool { false }
    /// Whether each activation carried a still-current local authority, which
    /// production requires before its AX frontmost request.
    var activationLocalAuthority: [Bool] = []
    func activateOwningRegularAppMacMechanicStyle(windowId: UInt32, diagnosticGeneration: UInt64? = nil,
                                                  localAuthority: (() -> Bool)? = nil) -> Bool {
        guard let pid = WindowEnumerator.ownerPID(for: windowId) else { return false }
        activationLocalAuthority.append(localAuthority?() ?? false)
        stagedEffects.append("activate:\(windowId):\(pid)")
        afterStagedEffect?("activate")
        return true
    }
    func recordStagedRaise(windowId: UInt32, pid: Int32, phase: String) {
        stagedEffects.append("\(phase):\(windowId):\(pid)")
        if phase != "preselect" && !refuseFocus { focusedWindow = windowId }
        afterStagedEffect?(phase)
    }

    /* PRODUCTION_LOCAL_FOCUS_SEQUENCE */
}

nonisolated struct FixtureMainWork: @unchecked Sendable {
    let body: @MainActor () -> Void
}

/// Keeps the production stage delays; only the main-queue hop is spelled for Swift 6.
enum FixtureMain {
    static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let work = FixtureMainWork(body: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work.body() } }
    }
}

enum WindowEnumerator {
    static var windows: [PeelWindow] = []
    static var boundsByWindow: [UInt32: CGRect] = [:]
    static var pidByWindow: [UInt32: Int32] = [:]
    /// Counts the remote enumeration (global AX, pixel and icon passes).
    static var enumerations = 0
    struct Geometry {
        let bounds: CGRect
        func screenPoint(normX: Double, normY: Double) -> CGPoint {
            CGPoint(x: bounds.minX + normX * bounds.width, y: bounds.minY + normY * bounds.height)
        }
    }
    static func enumerateWindows() -> [PeelWindow] { enumerations += 1; return windows }
    static func bounds(for windowId: UInt32) -> CGRect? { boundsByWindow[windowId] }
    static func ownerPID(for windowId: UInt32) -> Int32? { pidByWindow[windowId] }
    static func isDisplayCaptureWindowId(_ windowId: UInt32) -> Bool { windowId >= 0xFFF0_0000 }
    static func inputGeometry(for windowId: UInt32) -> Geometry? { boundsByWindow[windowId].map(Geometry.init) }
}

nonisolated final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PeelLocalAgentHandlerResult?
    func set(_ value: PeelLocalAgentHandlerResult) { lock.lock(); if self.value == nil { self.value = value }; lock.unlock() }
    func get() -> PeelLocalAgentHandlerResult? { lock.lock(); defer { lock.unlock() }; return value }
}

nonisolated final class CaptureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(UInt32, CGRect)] = []
    func record(_ id: UInt32, _ bounds: CGRect) { lock.lock(); calls.append((id, bounds)); lock.unlock() }
    var last: (UInt32, CGRect)? { lock.lock(); defer { lock.unlock() }; return calls.last }
}

final class LocalRouteFixtureHost {
    final class Network {
        var generation: UInt64 = 7
        func isCurrentControlGeneration(_ candidate: UInt64) -> Bool { candidate == generation }
    }
    final class Activity {
        var visible: [Bool] = []
        var onExternalInput: () -> Void = {}
        var stop: (() -> Void)?
        func update(access: PeelLocalComputerAccess, stop: @escaping () -> Void) {
            visible.append(access.isAllowed); self.stop = stop
        }
    }

    var agentBridgeEnabled = true
    var agentBridgeStatus = "Ready"
    var hostIsLockedOrAsleep = false
    var localAgentEpoch = UUID()
    var remoteControlAllowed = false
    var applicationMatches = true
    var onScreen = true
    var fingerprints: [UInt32: PeelAgentWindowInstanceFingerprint] = [:]
    var refreshedAfterHostAction = 0
    let network = Network()
    let accessibility: AccessibilityManager
    let input: InputSynthesizer
    let localComputerAccess = PeelLocalComputerAccess()
    let localComputerActivity = Activity()
    let localWindowControl: PeelAgentWindowControl
    var localAgentWindowInventory = PeelAgentAdvertisedWindowInventory()
    let localAgentAppCatalog: PeelAgentAppCatalog
    var localComputerAccessConfigured = false
    var localControlOwner: (owner: UUID, authority: () -> Bool)?

    init(accessibility: AccessibilityManager, input: InputSynthesizer, control: PeelAgentWindowControl, catalog: PeelAgentAppCatalog) {
        self.accessibility = accessibility; self.input = input; localWindowControl = control; localAgentAppCatalog = catalog
    }

    func isRemoteControlAllowed() -> Bool { remoteControlAllowed }
    func agentWindowFingerprint(_ window: PeelWindow) -> PeelAgentWindowInstanceFingerprint { fingerprints[window.windowId]! }
    func agentControlWindowIsOnScreen(windowID: UInt32, bounds: CGRect) -> Bool { onScreen }
    func localApplicationMatches(_ fingerprint: PeelAgentWindowInstanceFingerprint) -> Bool { applicationMatches }
    func localFocusWindowRow(windowID: UInt32) -> PeelWindow? { WindowEnumerator.windows.first { $0.windowId == windowID } }
    /// Stands in for the on-screen metadata read; never the remote enumeration.
    func localWindowListing() -> [(PeelWindow, PeelAgentWindowInstanceFingerprint)] {
        WindowEnumerator.windows.map { ($0, agentWindowFingerprint($0)) }
    }
    var localComputerName: String { "Fixture Mac" }
    var agentSourceHostJSON: PeelLocalAgentJSONValue { .object(["hostId": .string("fixture-host")]) }
    func openLauncherFolder() { fatalError("not exercised") }
    func openPath(_ path: String) { fatalError("not exercised") }
    func refreshWindowListAfterHostWindowAction() { refreshedAfterHostAction += 1 }

    /* PRODUCTION_LOCAL_ROUTE */
}

@main struct LocalComputerRouteChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    /// Text carried by posted key downs, independent of how it was split.
    static func typedText(_ events: [CGEvent]) -> String {
        events.filter { $0.type == .keyDown }.map { event in
            var count = 0
            var units = [UniChar](repeating: 0, count: 64)
            units.withUnsafeMutableBufferPointer { buffer in
                event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: buffer.baseAddress)
            }
            return String(utf16CodeUnits: units, count: count)
        }.joined()
    }

    static func main() async throws {
        final class OpenedApps { var urls: [URL] = [] }
        let openedApps = OpenedApps()
        let catalog = PeelAgentAppCatalog(dependencies: .init(
            fileManager: .default,
            inventoryRoots: [URL(fileURLWithPath: "/System/Applications", isDirectory: true)],
            runningApplications: { [] },
            openApplication: { url, done in openedApps.urls.append(url); done(4242, nil) },
            makeOpaqueIdentifier: { UUID().uuidString.lowercased() },
            monotonicNow: { DispatchTime.now().uptimeNanoseconds },
            scheduleDeadline: { _, _ in }))

        let captures = CaptureLog()
        var clock = 100.0
        let control = PeelAgentWindowControl(capture: { id, bounds in
            captures.record(id, bounds)
            return .init(data: Data([255, 216, 255, 0]), width: 400, height: 300)
        }, uptime: { clock })

        var events: [CGEvent] = []
        var afterFirstEvent: (() -> Void)?
        let focus = AccessibilityManager()
        // While parked, scheduled input work is held so a fixture can prove an
        // operation is still active; releasing re-schedules it with its delay.
        var parkInputWork = false
        var parkedInputWork: [(TimeInterval, DispatchWorkItem)] = []
        let input = InputSynthesizer(accessibility: focus, eventSink: { event, _ in
            events.append(event)
            if let callback = afterFirstEvent { afterFirstEvent = nil; callback() }
        }, scheduleInputWork: { delay, work in
            if parkInputWork { parkedInputWork.append((delay, work)); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        })
        func releaseParkedInputWork() {
            parkInputWork = false
            let parked = parkedInputWork; parkedInputWork.removeAll()
            for (delay, work) in parked { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        }
        let host = LocalRouteFixtureHost(accessibility: focus, input: input, control: control, catalog: catalog)

        // Production wiring shape: the paired AX predicate is the paired
        // predicate only; local readiness is the Host's exact-owner method.
        var checkedGenerations: [UInt64] = []
        var markedInputs = 0, activeWindowNotes: [UInt32] = []
        input.isRemoteControlAllowed = { host.isRemoteControlAllowed() }
        input.isLocalControlAllowed = { host.isLocalControlAllowed() }
        input.isLocalWindowReadyForInput = { windowId, _ in host.localControlWindowIsReady(windowId) }
        input.isControlGenerationCurrent = { generation in
            checkedGenerations.append(generation)
            return host.inputControlGenerationIsCurrent(generation)
        }
        input.markInput = { _ in markedInputs += 1 }
        input.activeWindowSetter = { activeWindowNotes.append($0) }
        focus.isRemoteControlAllowed = { host.isRemoteControlAllowed() }
        host.configureLocalComputerAccess()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        func window(_ id: UInt32, _ app: String, _ title: String) -> PeelWindow {
            .init(windowId: id, appName: app, title: title, width: 800, height: 600, statusSummary: nil,
                  appIconPNGBase64: nil, appLaunchTimeIntervalSince1970: 1000)
        }
        func fingerprint(_ id: UInt32, pid: Int32?, bundle: String?, app: String, title: String, display: Bool = false) -> PeelAgentWindowInstanceFingerprint {
            .init(windowID: id, ownerProcessID: pid, appBundleIdentifier: bundle, appName: app, title: title,
                  width: 800, height: 600, appLaunchTimeIntervalSince1970: display ? nil : 1000,
                  isDisplay: display, displayID: display ? 1 : nil)
        }
        let desktopID: UInt32 = 0xFFF0_0001
        WindowEnumerator.windows = [window(10, "Peel Pro", "Remote Desktop"), window(desktopID, "Display", "Desktop"),
            window(12, "SecurityAgent", "Password"), window(21, "Terminal", "zsh"), window(22, "System Settings", "Wi-Fi")]
        host.fingerprints = [
            10: fingerprint(10, pid: ownPID, bundle: "org.peel.fixture.self", app: "Peel Pro", title: "Remote Desktop"),
            desktopID: fingerprint(desktopID, pid: nil, bundle: nil, app: "Display", title: "Desktop", display: true),
            12: fingerprint(12, pid: 600, bundle: "com.apple.SecurityAgent", app: "SecurityAgent", title: "Password"),
            21: fingerprint(21, pid: 501, bundle: "com.apple.Terminal", app: "Terminal", title: "zsh"),
            22: fingerprint(22, pid: 502, bundle: "com.apple.systempreferences", app: "System Settings", title: "Wi-Fi")]
        let terminalBounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        WindowEnumerator.boundsByWindow = [10: terminalBounds, desktopID: terminalBounds, 12: terminalBounds,
                                           21: terminalBounds, 22: CGRect(x: 950, y: 100, width: 800, height: 600)]
        WindowEnumerator.pidByWindow = [10: ownPID, 12: 600, 21: 501, 22: 502]

        func request(_ method: PeelLocalAgentMethod, _ params: [String: PeelLocalAgentJSONValue],
                     deadline: UInt64 = 4_000_000_000, lifetime: PeelLocalAgentRequestLifetime = .init()) -> PeelLocalAgentRequest {
            .init(version: 1, id: UUID(), method: method, params: params,
                  deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + deadline, lifetime: lifetime)
        }
        func start(_ method: PeelLocalAgentMethod, _ params: [String: PeelLocalAgentJSONValue] = [:],
                   deadline: UInt64 = 4_000_000_000, epoch: UUID? = nil,
                   lifetime: PeelLocalAgentRequestLifetime = .init()) -> ResultBox {
            var merged = params; merged["targetPairingId"] = merged["targetPairingId"] ?? .string("local")
            let box = ResultBox()
            host.handleLocalComputerRequest(request(method, merged, deadline: deadline, lifetime: lifetime),
                                            epoch: epoch ?? host.localAgentEpoch, completion: { box.set($0) })
            return box
        }
        func wait(_ box: ResultBox, _ label: String) async throws -> PeelLocalAgentHandlerResult {
            for _ in 0..<1500 { if let value = box.get() { return value }; try await Task.sleep(nanoseconds: 2_000_000) }
            fatalError("local request did not finish: \(label)")
        }
        func call(_ method: PeelLocalAgentMethod, _ params: [String: PeelLocalAgentJSONValue] = [:],
                  deadline: UInt64 = 4_000_000_000, epoch: UUID? = nil,
                  lifetime: PeelLocalAgentRequestLifetime = .init()) async throws -> PeelLocalAgentHandlerResult {
            try await wait(start(method, params, deadline: deadline, epoch: epoch, lifetime: lifetime), "\(method)")
        }
        func code(_ result: PeelLocalAgentHandlerResult) -> String? {
            if case .failure(let error) = result { return error.code }; return nil
        }
        func object(_ result: PeelLocalAgentHandlerResult) -> [String: PeelLocalAgentJSONValue] {
            guard case .success(.object(let value)) = result else { fatalError("expected success, got \(result)") }
            return value
        }
        func string(_ value: PeelLocalAgentJSONValue?) -> String? { if case .string(let s) = value { return s }; return nil }
        func array(_ value: PeelLocalAgentJSONValue?) -> [PeelLocalAgentJSONValue] { if case .array(let a) = value { return a }; return [] }
        func listedIDs(_ result: [String: PeelLocalAgentJSONValue]) -> [Int64] {
            array(result["windows"]).compactMap { entry in
                if case .object(let o) = entry, case .integer(let id) = o["windowId"] { return id }; return nil
            }
        }
        func expectCode(_ expected: String, _ message: String, _ result: PeelLocalAgentHandlerResult) {
            require(code(result) == expected, "\(message): \(result)")
        }
        func token(_ id: UInt32) -> PeelLocalAgentJSONValue { .string(host.localWindowControl.token(windowID: id)!) }
        func inspect(_ id: UInt32) async throws -> String {
            clock += 0.3
            let result = object(try await call(.inspectWindow, ["windowId": .integer(Int64(id)), "windowToken": token(id)]))
            require(result["status"] == .string("captured") && result["visibilityEvidence"] == .string("local_on_screen_window"), "local capture receipt")
            guard let inspection = string(result["inspectionId"]) else { fatalError("inspectionId") }
            return inspection
        }
        func controlArgs(_ id: UInt32, _ inspection: String, text: String) -> [String: PeelLocalAgentJSONValue] {
            ["windowId": .integer(Int64(id)), "windowToken": token(id), "inspectionId": .string(inspection),
             "action": .string("type"), "text": .string(text)]
        }
        func prepare(_ id: UInt32) async throws -> String {
            _ = object(try await call(.listWindows))
            _ = object(try await call(.presentWindow, ["windowId": .integer(Int64(id))]))
            return try await inspect(id)
        }
        let longText = String(repeating: "a", count: 40)

        // 1. Consent is off at launch; every target-bound method is refused.
        require(!host.localComputerAccess.isAllowed, "local access is off at launch")
        for method: PeelLocalAgentMethod in [.listWindows, .listApps, .launchApp, .presentWindow, .inspectWindow, .controlWindow, .notify] {
            expectCode("consent_required", "consent required: \(method)", try await call(method, ["windowId": .integer(21)]))
        }
        guard case .object(let offDevice) = host.localComputerDeviceJSON else { fatalError("device JSON") }
        require(offDevice["accessReady"] == .bool(false) && offDevice["controlReady"] == .bool(false), "readiness is off")
        require(array(offDevice["missing"]).contains(.string("localAccessConsent")), "missing consent reported")
        require(array(offDevice["supportedMethods"]).count == 6 && offDevice["targetPairingId"] == .string("local"), "capabilities listed")
        host.agentBridgeEnabled = false
        host.setLocalComputerAccessAllowed(true)
        require(!host.localComputerAccess.isAllowed, "requires local agents to be enabled")
        host.agentBridgeEnabled = true
        host.setLocalComputerAccessAllowed(true)
        require(host.localComputerAccess.isAllowed && host.localComputerActivity.visible.last == true, "UI grant shows Stop surface")
        guard case .object(let onDevice) = host.localComputerDeviceJSON else { fatalError("device JSON") }
        require(onDevice["accessReady"] == .bool(true) && onDevice["controlReady"] == .bool(true), "readiness from real gates")
        FixturePermissions.screenCapture = false
        guard case .object(let noCapture) = host.localComputerDeviceJSON else { fatalError("device JSON") }
        require(noCapture["inspectReady"] == .bool(false) && array(noCapture["missing"]).contains(.string("screenRecording")), "missing Screen Recording reported")
        expectCode("permission_required", "capture permission enforced",
                   try await call(.inspectWindow, ["windowId": .integer(21), "windowToken": .string(UUID().uuidString)]))
        FixturePermissions.screenCapture = true

        // 2. Only eligible app windows are listed.
        let enumerationsBeforeList = WindowEnumerator.enumerations
        let listed = object(try await call(.listWindows))
        require(WindowEnumerator.enumerations == enumerationsBeforeList, "local listing skips the remote AX/pixel/icon enumeration")
        require(listedIDs(listed) == [21, 22], "own/desktop/auth windows excluded: \(listedIDs(listed))")
        require(!PeelLocalComputerWindowPolicy.isEligible(host.fingerprints[21]!, ownProcessID: ownPID, ownBundleIdentifier: "com.apple.Terminal"),
                "own bundle identifier excluded")
        for excluded: UInt32 in [10, desktopID, 12] {
            expectCode("window_unavailable", "excluded window cannot be inspected: \(excluded)",
                       try await call(.inspectWindow, ["windowId": .integer(Int64(excluded)), "windowToken": .string(UUID().uuidString)]))
        }

        // 3. Present focuses only through the dedicated local path under its own authority.
        expectCode("window_not_listed", "unlisted window refused", try await call(.presentWindow, ["windowId": .integer(99)]))
        let focused = object(try await call(.presentWindow, ["windowId": .integer(21), "context": .string("Open a shell")]))
        require(focused["status"] == .string("focused") && focus.localFocusEntries.last == true, "focus under its own authority")
        require(!host.localComputerAccess.hasActiveAuthority && !focus.isRemoteControlAllowed(), "no standing authority after present")
        focus.refuseFocus = true
        expectCode("focus_refused", "refused focus reported honestly", try await call(.presentWindow, ["windowId": .integer(22)]))
        focus.refuseFocus = false
        focus.holdFocus = true
        expectCode("timeout", "superseded focus times out", try await call(.presentWindow, ["windowId": .integer(22)], deadline: 80_000_000))
        require(!host.localComputerAccess.hasActiveAuthority, "timeout releases its own authority")
        focus.holdFocus = false

        // 4. Window-only capture; one bounded action in the local generation, no paired side effects.
        let firstInspection = try await inspect(21)
        require(captures.last?.0 == 21 && captures.last?.1 == terminalBounds, "window-only capture of exact window")
        events.removeAll(); checkedGenerations.removeAll(); markedInputs = 0; activeWindowNotes.removeAll()
        clock += 0.3
        let typed = object(try await call(.controlWindow, controlArgs(21, firstInspection, text: "ls")))
        require(typed["status"] == .string("events_posted") && typed["postedEvents"] == .integer(2) && typedText(events) == "ls",
                "real bounded typing as one Unicode run")
        require(!checkedGenerations.isEmpty && checkedGenerations.allSatisfy { $0 == host.localComputerAccess.inputGeneration && InputSynthesizer.isLocalControlGeneration($0) },
                "local operation owned by exact local generation")
        require(markedInputs == 0 && activeWindowNotes.isEmpty, "local input never moves paired stream focus state")
        require(host.localControlOwner == nil && !host.localComputerAccess.hasActiveAuthority, "control owner released")
        clock += 0.3
        var replay = controlArgs(21, firstInspection, text: "x")
        replay["action"] = .string("key"); replay["key"] = .string("enter"); replay["text"] = nil
        expectCode("inspection_required", "inspection is single use", try await call(.controlWindow, replay))

        // 5. P1: a person's input invalidates a completed (idle) inspection.
        let idleInspection = try await inspect(21)
        let idleToken = token(21)
        require(!host.localWindowControl.isBusy, "inspection completed and controller is idle")
        host.localComputerActivity.onExternalInput()
        require(host.localComputerAccess.isAllowed, "person input keeps consent")
        clock += 0.3
        let reused = try await call(.controlWindow, ["windowId": .integer(21), "windowToken": idleToken,
            "inspectionId": .string(idleInspection), "action": .string("type"), "text": .string("x")])
        require(code(reused) == "window_changed" || code(reused) == "inspection_required", "old inspection rejected after person input: \(reused)")
        require(host.localWindowControl.token(windowID: 21) == nil, "person input drops listed tokens")

        // 6. P1: a person's input during staged focus stops every later stage.
        _ = object(try await call(.listWindows))
        focus.focusedWindow = nil
        focus.localStageEffects.removeAll()
        let pending = start(.presentWindow, ["windowId": .integer(22)])
        require(focus.localStageEffects == ["preselect+activate:22"], "first stage ran")
        host.localComputerActivity.onExternalInput()
        let interruptedFocus = try await wait(pending, "interrupted focus")
        require(code(interruptedFocus) == "target_unavailable", "interrupted focus reported: \(interruptedFocus)")
        try await Task.sleep(nanoseconds: 120_000_000)
        require(focus.localStageEffects == ["preselect+activate:22"] && focus.focusedWindow == nil, "no later raise/activation after person input")

        // 6b. P2: the production staged sequence is bound to the exact listed
        // window and app instance at every stage, not only to the request.
        focus.staged = true
        let listedWindows = WindowEnumerator.windows, listedPIDs = WindowEnumerator.pidByWindow
        let listedFingerprints = host.fingerprints
        func stagedPresent(_ id: UInt32, after phase: String? = nil,
                           mutate: @escaping () -> Void = {}) async throws -> PeelLocalAgentHandlerResult {
            _ = object(try await call(.listWindows))
            focus.focusedWindow = nil
            focus.stagedEffects.removeAll()
            focus.afterStagedEffect = { stage in
                guard stage == phase else { return }
                focus.afterStagedEffect = nil
                mutate()
            }
            let result = try await call(.presentWindow, ["windowId": .integer(Int64(id))])
            try await Task.sleep(nanoseconds: 120_000_000)
            focus.afterStagedEffect = nil
            WindowEnumerator.windows = listedWindows; WindowEnumerator.pidByWindow = listedPIDs
            host.fingerprints = listedFingerprints; host.applicationMatches = true
            return result
        }
        let stagedFocus = object(try await stagedPresent(21))
        require(stagedFocus["status"] == .string("focused") &&
                focus.stagedEffects == ["preselect:21:501", "activate:21:501", "afterActivation:21:501"],
                "production staged focus of the exact window: \(focus.stagedEffects)")
        require(focus.activationLocalAuthority.last == true,
                "local activation carries the request's own authority for the AX frontmost request")
        let recycledOwner = try await stagedPresent(22, after: "preselect") {
            WindowEnumerator.pidByWindow[22] = 777
            host.fingerprints[22] = fingerprint(22, pid: 777, bundle: "com.example.replacement", app: "Replacement", title: "Wi-Fi")
        }
        expectCode("target_unavailable", "owner change after preselect reported", recycledOwner)
        require(focus.stagedEffects == ["preselect:22:502"] && focus.focusedWindow == nil,
                "no activation or raise of a replacement owner: \(focus.stagedEffects)")
        let recycledWindow = try await stagedPresent(22, after: "activate") {
            host.fingerprints[22] = fingerprint(22, pid: 502, bundle: "com.apple.systempreferences", app: "System Settings", title: "Passwords")
        }
        expectCode("target_unavailable", "recycled window after activation reported", recycledWindow)
        require(focus.stagedEffects == ["preselect:22:502", "activate:22:502"] && focus.focusedWindow == nil,
                "no raise of a recycled window: \(focus.stagedEffects)")
        let vanished = try await stagedPresent(22, after: "activate") {
            WindowEnumerator.windows.removeAll { $0.windowId == 22 }
        }
        expectCode("target_unavailable", "vanished window reported", vanished)
        require(focus.stagedEffects == ["preselect:22:502", "activate:22:502"] && focus.focusedWindow == nil,
                "no raise after the listed window disappeared: \(focus.stagedEffects)")
        let relaunched = try await stagedPresent(22, after: "activate") { host.applicationMatches = false }
        expectCode("target_unavailable", "relaunched app reported", relaunched)
        require(focus.stagedEffects == ["preselect:22:502", "activate:22:502"] && focus.focusedWindow == nil,
                "no raise after the app's launch identity changed: \(focus.stagedEffects)")
        let stagedPerson = try await stagedPresent(22, after: "activate") { host.localComputerActivity.onExternalInput() }
        expectCode("target_unavailable", "person input during production stages reported", stagedPerson)
        require(focus.stagedEffects == ["preselect:22:502", "activate:22:502"] && focus.focusedWindow == nil,
                "no raise after person input: \(focus.stagedEffects)")
        require(!host.localComputerAccess.hasActiveAuthority && !focus.isRemoteControlAllowed(), "staged focus leaves no authority")
        focus.staged = false

        // 7. P1: paired host commands never borrow local authority and bind to their session.
        _ = object(try await call(.listWindows))
        focus.holdFocus = true
        let held = start(.presentWindow, ["windowId": .integer(21)], deadline: 400_000_000)
        require(host.localComputerAccess.hasActiveAuthority && !host.remoteControlAllowed, "local authority active, paired client hidden")
        host.handleHostCommand(.init(command: .closeWindow, windowId: 21), generation: host.network.generation)
        host.handleHostCommand(.init(command: .minimizeWindow, windowId: 21), generation: host.network.generation)
        try await Task.sleep(nanoseconds: 30_000_000)
        require(focus.closed.isEmpty && focus.minimized.isEmpty && host.refreshedAfterHostAction == 0, "hidden paired client cannot close/minimize via local authority")
        host.remoteControlAllowed = true
        host.handleHostCommand(.init(command: .closeWindow, windowId: 21), generation: host.network.generation - 1)
        host.handleHostCommand(.init(command: .minimizeWindow, windowId: 21), generation: nil)
        host.handleHostCommand(.init(command: .closeWindow, windowId: 22), generation: host.network.generation)
        host.network.generation += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        require(focus.closed.isEmpty && focus.minimized.isEmpty, "stale or replaced session commands denied at the effect")
        host.handleHostCommand(.init(command: .closeWindow, windowId: 22), generation: host.network.generation)
        try await Task.sleep(nanoseconds: 30_000_000)
        require(focus.closed == [22] && host.refreshedAfterHostAction == 1, "current visible paired session keeps close")
        host.remoteControlAllowed = false
        expectCode("timeout", "held focus times out", try await wait(held, "held focus"))
        focus.holdFocus = false

        // 8. P2: caller lifetime gates every effect; SHUT_WR half-close stays usable.
        func lifetimePair() -> (PeelLocalAgentRequestLifetime, Int32, Int32) {
            var descriptors: [Int32] = [0, 0]
            require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0, "socketpair")
            var enabled: Int32 = 1
            require(setsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0, "nosigpipe")
            return (PeelLocalAgentRequestLifetime(descriptor: descriptors[0]), descriptors[0], descriptors[1])
        }
        let terminalApps = array(object(try await call(.listApps, ["query": .string("com.apple.Terminal")]))["apps"])
        guard terminalApps.count == 1, case .object(let terminalEntry) = terminalApps[0],
              let terminalID = string(terminalEntry["appId"]) else {
            fatalError("Terminal not discovered in /System/Applications: \(terminalApps)")
        }
        let (closedLifetime, closedLocal, closedPeer) = lifetimePair()
        close(closedPeer)
        let openedBefore = openedApps.urls.count
        expectCode("target_unavailable", "closed caller cannot launch",
                   try await call(.launchApp, ["appId": .string(terminalID)], lifetime: closedLifetime))
        require(openedApps.urls.count == openedBefore, "no launch after full close")
        _ = object(try await call(.listWindows))
        let entriesBefore = focus.localFocusEntries.count
        expectCode("target_unavailable", "closed caller cannot focus",
                   try await call(.presentWindow, ["windowId": .integer(21)], lifetime: closedLifetime))
        require(focus.localFocusEntries.count == entriesBefore, "no AX entry after full close")
        closedLifetime.invalidate(); close(closedLocal)
        let (halfLifetime, halfLocal, halfPeer) = lifetimePair()
        shutdown(halfPeer, SHUT_WR)
        let halfLaunch = object(try await call(.launchApp, ["appId": .string(terminalID)], lifetime: halfLifetime))
        require(halfLaunch["status"] == .string("launched") && openedApps.urls.last?.path.hasSuffix("Utilities/Terminal.app") == true,
                "half-closed caller still launches the exact listed app")
        halfLifetime.invalidate(); close(halfLocal); close(halfPeer)

        // 9. P2: a superseded focus A timing out never cancels a later control B.
        let bInspection = try await prepare(21)
        focus.holdFocus = true
        let requestA = start(.presentWindow, ["windowId": .integer(22)], deadline: 150_000_000)
        focus.holdFocus = false
        clock += 0.3
        events.removeAll()
        // B's first run posts, then its remaining input work is parked so B is
        // provably the active owner when A's 150 ms deadline fires.
        afterFirstEvent = { parkInputWork = true }
        let requestB = start(.controlWindow, controlArgs(21, bInspection, text: String(repeating: "b", count: 300)))
        expectCode("timeout", "focus A timed out", try await wait(requestA, "request A"))
        require(requestB.get() == nil && host.localControlOwner != nil && !parkedInputWork.isEmpty && events.count < 30,
                "B was active and incomplete when A's deadline fired: \(events.count) events")
        releaseParkedInputWork()
        let b = object(try await wait(requestB, "request B"))
        require(b["status"] == .string("events_posted") && events.count == 30 && typedText(events) == String(repeating: "b", count: 300),
                "B completed although A's deadline fired during it: \(b)")

        // 10. Paired and local agent operations never interleave in the shared input owner.
        let remoteScope = PeelAgentPresentationScope(pairingID: "paired-fixture", generation: host.network.generation)
        let remoteSession = PeelControlSession(pairingID: "paired-fixture", generation: host.network.generation)
        let remoteControl = PeelAgentWindowControl(capture: { _, _ in .init(data: Data([1]), width: 2, height: 2) }, uptime: { clock })
        let remoteContext = PeelAgentControlContext(session: remoteSession, fingerprint: host.fingerprints[21]!, bounds: terminalBounds,
            renderer: UUID(), validate: { true }, validateEvent: { _ in true })
        require(remoteContext.inputGeneration == remoteSession.generation && remoteContext.scope == remoteScope &&
                remoteContext.visibilityEvidence == "paired_peer_reported_active_display_layer", "paired context unchanged")
        remoteControl.replace(scope: remoteScope, instances: [host.fingerprints[21]!])
        func remoteRequest(_ method: PeelLocalAgentMethod, _ extra: [String: PeelLocalAgentJSONValue]) -> PeelLocalAgentRequest {
            var params: [String: PeelLocalAgentJSONValue] = ["targetPairingId": .string("paired-fixture"), "windowId": .integer(21),
                                                             "windowToken": .string(remoteControl.token(windowID: 21)!)]
            params.merge(extra, uniquingKeysWith: { _, new in new })
            return request(method, params)
        }
        let remoteInspectBox = ResultBox()
        remoteControl.handle(remoteRequest(.inspectWindow, [:]), context: remoteContext, input: input, completion: { remoteInspectBox.set($0) })
        guard let remoteInspection = string(object(try await wait(remoteInspectBox, "remote inspect"))["inspectionId"]) else {
            fatalError("remote inspection")
        }
        let localInspection = try await prepare(21)
        require(remoteControl.token(windowID: 21) != nil, "local listing does not replace paired tokens")
        var remoteWhileLocal: PeelLocalAgentHandlerResult?
        afterFirstEvent = {
            clock += 0.3
            let box = ResultBox()
            remoteControl.handle(remoteRequest(.controlWindow, ["inspectionId": .string(remoteInspection),
                "action": .string("click"), "x": .number(0.5), "y": .number(0.5)]), context: remoteContext, input: input,
                completion: { box.set($0) })
            remoteWhileLocal = box.get()
        }
        clock += 0.3
        let local = object(try await call(.controlWindow, controlArgs(21, localInspection, text: longText)))
        require(remoteWhileLocal.flatMap(code) == "busy", "paired agent cannot interleave with a local operation")
        require(local["status"] == .string("events_posted"), "local operation completes despite paired attempt")
        require(!input.performAgentOperation(controlGeneration: host.network.generation, operationID: UUID(),
            allowed: { true }, completion: { _, _ in }, perform: { $0.handleKeyboardText(.init(text: "x", windowId: 21)) }),
            "paired generation is not admitted by local consent")

        // 11. Person input mid-operation interrupts only the agent and releases held input.
        require(PeelLocalComputerWindowPolicy.isExternalInput(sourceUserData: 0), "untagged input is a person")
        require(!PeelLocalComputerWindowPolicy.isExternalInput(sourceUserData: PeelLocalComputerWindowPolicy.postedEventMarker),
                "tagged posts are Peel's own")
        let midInspection = try await prepare(21)
        events.removeAll()
        afterFirstEvent = { host.localComputerActivity.onExternalInput() }
        clock += 0.3
        let interrupted = object(try await call(.controlWindow, controlArgs(21, midInspection, text: longText)))
        require(interrupted["status"] == .string("interrupted") && events.filter({ $0.type == .keyDown }).count == 1 && events.last?.type == .keyUp,
                "person input interrupts and releases the held key")
        require(host.localComputerAccess.isAllowed && host.localControlOwner == nil, "consent kept, owner cleared")

        // 12. Stop mid-operation revokes consent and cancels with release.
        let stopInspection = try await prepare(21)
        events.removeAll()
        afterFirstEvent = { host.localComputerActivity.stop?() }
        clock += 0.3
        _ = try await call(.controlWindow, controlArgs(21, stopInspection, text: longText))
        require(!host.localComputerAccess.isAllowed && events.last?.type == .keyUp, "Stop revokes and releases")
        let staleLocal = InputSynthesizer.localControlGenerationFlag | 2
        host.remoteControlAllowed = true
        require(!input.performAgentOperation(controlGeneration: staleLocal, operationID: UUID(),
            allowed: { true }, completion: { _, _ in }, perform: { $0.handleKeyboardText(.init(text: "x", windowId: 21)) }),
            "local generation is not admitted by paired consent")
        host.remoteControlAllowed = false
        expectCode("consent_required", "revoked consent refuses requests", try await call(.listWindows))
        host.setLocalComputerAccessAllowed(true)
        expectCode("window_not_listed", "new grant invalidates old inventory", try await call(.presentWindow, ["windowId": .integer(21)]))

        // 13. Lock, stale bridge epoch and local notify.
        host.hostIsLockedOrAsleep = true
        expectCode("target_unavailable", "locked Mac refuses local requests", try await call(.listWindows))
        host.revokeLocalComputerAccess(reason: "Mac locked or asleep")
        require(!host.localComputerAccess.isAllowed, "lock revokes")
        host.hostIsLockedOrAsleep = false
        host.setLocalComputerAccessAllowed(true)
        let staleEpoch = host.localAgentEpoch
        host.localAgentEpoch = UUID()
        expectCode("target_unavailable", "old bridge epoch refused", try await call(.listWindows, epoch: staleEpoch))
        expectCode("unsupported", "no local notify method", try await call(.notify, ["title": .string("t"), "message": .string("m")]))

        // 14. Real app catalog: System Settings and Terminal; only returned IDs launch.
        let settingsApps = object(try await call(.listApps, ["query": .string("com.apple.systempreferences")]))
        guard case .object(let settings)? = array(settingsApps["apps"]).first, let settingsID = string(settings["appId"]),
              string(settings["bundleIdentifier"]) == "com.apple.systempreferences" else {
            fatalError("System Settings not discovered: \(settingsApps)")
        }
        expectCode("app_not_listed", "superseded inventory ID cannot launch", try await call(.launchApp, ["appId": .string(terminalID)]))
        let launched = object(try await call(.launchApp, ["appId": .string(settingsID)]))
        require(launched["status"] == .string("launched") && openedApps.urls.last?.lastPathComponent == "System Settings.app", "exact listed app launched")
        expectCode("app_not_listed", "paths are never app IDs",
                   try await call(.launchApp, ["appId": .string("/System/Applications/Utilities/Terminal.app")]))
        host.setLocalComputerAccessAllowed(false)
        expectCode("consent_required", "launch needs consent", try await call(.launchApp, ["appId": .string(settingsID)]))
        require(WindowEnumerator.enumerations == 0,
                "local list, present, inspect and control never run the remote AX/pixel/icon enumeration")

        print("Local computer route: consent, eligibility, exact-owner focus authority, person-input invalidation, paired command isolation, caller lifetime, owner-scoped deadlines, local generation, paired isolation, Stop/lock revocation and real app discovery checks passed")
    }
}
