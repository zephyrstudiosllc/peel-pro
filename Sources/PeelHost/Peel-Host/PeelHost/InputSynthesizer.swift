//
//  InputSynthesizer.swift
//  Peel-Host
//
//  Created by Zach on 4/14/26.
//

import Foundation
import AppKit
import ApplicationServices

enum HostSpaceSwitchDirection: Equatable {
    case left
    case right
}

@MainActor
final class InputSynthesizer {
    enum ResetReason: String {
        case unspecified, hostLockedOrAsleep, permissionChanged, hostTermination
        case controlConnected, controlDisconnected, controlBlocked, clientHidden, clientTimedOut
        case queueOverflow, inputDeadline, inputGenerationChanged, windowPositionUnavailable, windowNotReady
    }

    private enum DiagnosticCounter: String {
        case decodedTextMessages, decodedTextScalars, admittedTextMessages, admittedTextScalars
        case enqueuedTextMessages, enqueuedTextScalars, postedUnicodeDown, postedUnicodeUp
        case cancelledQueuedOperations, cancelledActiveOperations
    }
    private let inputDiagnosticsEnabled = ProcessInfo.processInfo.environment["PEEL_INPUT_DIAGNOSTICS"] == "1"
    private var inputDiagnostics: [String: (windowId: UInt32?, control: UInt64?, counts: [String: Int])] = [:]
    private var inputDiagnosticsFlushPending = false
    private var inputDiagnosticResetCount = 0

    var isRemoteControlAllowed: () -> Bool = { false }
    /// Local-computer agent operations use a reserved control-generation
    /// namespace that network control generations never reach, and their own
    /// authority predicate. They never borrow a paired client's visibility.
    var isLocalControlAllowed: () -> Bool = { false }
    nonisolated static let localControlGenerationFlag: UInt64 = 1 << 63
    nonisolated static func isLocalControlGeneration(_ control: UInt64) -> Bool {
        control & localControlGenerationFlag != 0
    }
    /// Readiness for a local-computer operation, checked under that exact
    /// request's own authority. Local operations never use the paired-client
    /// accessibility gate or start the paired focus sequence.
    var isLocalWindowReadyForInput: (UInt32, CGPoint?) -> Bool = { _, _ in false }
    var activeWindowProvider: () -> UInt32? = { nil }
    var activeWindowSetter: (UInt32) -> Void = { _ in }
    var markInput: (UInt32?) -> Void = { _ in }
    var isControlGenerationCurrent: (UInt64) -> Bool = { _ in false }

    let accessibility: AccessibilityManager
    private let eventSink: (CGEvent, CGEventTapLocation) -> Void
    private let scheduleInputWork: (TimeInterval, DispatchWorkItem) -> Void
    // Empirical delivery pacing; Quartz does not specify a minimum interval.
    private static let textEventInterval: TimeInterval = 0.001
    private static let unicodeEventTap: CGEventTapLocation = .cgSessionEventTap
    // Keep remote text's private key state alive across its whole sequence.
    private let unicodeEventSource = CGEventSource(stateID: .privateState)
    private var sessionGeneration = UUID()
    private struct InputGeneration: Equatable {
        let local: UUID
        let control: UInt64
        let operation: UUID?
        init(local: UUID, control: UInt64, operation: UUID? = nil) {
            self.local = local; self.control = control; self.operation = operation
        }
    }
    private var executingGeneration: InputGeneration?
    private var admittedGeneration: InputGeneration?
    private var heldKeyCodes: Set<CGKeyCode> = []
    // Unicode uses virtual key zero, which can also be a held hardware A key.
    private var heldUnicodeKey = false
    private var heldMouseButtons: [PeelMouseButton: CGPoint] = [:]
    // Agent requests use the same event path, but retain a separate live consent
    // predicate through every deferred/post boundary and an honest post receipt.
    private final class AgentInputContext {
        let operationID: UUID
        var cancelled = false
        var isAllowed: Bool { !cancelled && allowed() }
        let allowed: () -> Bool
        let completion: (Int, Bool) -> Void
        let eventAllowed: (CGEvent) -> Bool
        let point: ((Double, Double) -> CGPoint?)?
        var posted = 0
        var enqueued = false
        var finished = false
        init(operationID: UUID, allowed: @escaping () -> Bool, eventAllowed: @escaping (CGEvent) -> Bool, point: ((Double, Double) -> CGPoint?)?, completion: @escaping (Int, Bool) -> Void) {
            self.operationID = operationID; self.allowed = allowed; self.eventAllowed = eventAllowed; self.point = point; self.completion = completion
        }
        func finish(_ completed: Bool) {
            guard !finished else { return }; finished = true
            completion(posted, completed)
        }
    }
    private var admittingAgentInput: AgentInputContext?
    private struct QueuedInput {
        let id: UUID
        let generation: InputGeneration
        let windowId: UInt32?
        let coalescingKey: String?
        let agentContext: AgentInputContext?
        let action: (InputGeneration, @escaping () -> Void) -> Void
    }
    private var pendingInputs: [QueuedInput] = []
    private var activeInput: QueuedInput?
    private var pendingPump: UUID?
    private var inputTimeout: DispatchWorkItem?
    private static let maximumQueuedInputs = 128
    private static let maximumTextBytes = 65_536
    private static let maximumMacroSteps = 128
    private static let maximumMacroDelayMilliseconds = 10_000

    private var lastInputPointByWindow: [UInt32: CGPoint] = [:]

    private var nextAllowedSpaceSwitchAt: CFAbsoluteTime = 0
    private let spaceSwitchCooldown: CFTimeInterval = 0.45

    private struct ClickTrackingState {
        var lastAt: CFAbsoluteTime = 0
        var lastPoint: CGPoint = .zero
        var lastWindowId: UInt32?
        var lastButton: String = "left"
        var clickCount: Int64 = 0
    }

    private var clickTrackingState = ClickTrackingState()
    private var scrollAccumulator = PeelScrollAccumulator()
    private var scrollControlGeneration: UInt64?

    init(accessibility: AccessibilityManager,
         eventSink: @escaping (CGEvent, CGEventTapLocation) -> Void = { event, tap in event.post(tap: tap) },
         scheduleInputWork: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.accessibility = accessibility
        self.eventSink = eventSink
        self.scheduleInputWork = scheduleInputWork
    }

    /// The transport's received identity must survive decoding/routing. Never
    /// replace it with whichever peer happens to be connected at admission time.
    /// This context is synchronous; deferred work captures its immutable value.
    func withReceivedControlGeneration(_ control: UInt64?, perform: () -> Void) {
        let previous = admittedGeneration
        admittedGeneration = control.map { InputGeneration(local: sessionGeneration, control: $0) }
        defer { admittedGeneration = previous }
        perform()
    }

    func resetSessionState(reason: ResetReason = .unspecified) {
        if inputDiagnosticsEnabled {
            for input in pendingInputs {
                recordInputDiagnostic(.cancelledQueuedOperations, windowId: input.windowId, control: input.generation.control)
            }
            if let input = activeInput {
                recordInputDiagnostic(.cancelledActiveOperations, windowId: input.windowId, control: input.generation.control)
            }
            inputDiagnosticResetCount += 1
            emitInputDiagnostic(["event": "reset", "reason": reason.rawValue,
                "resetCount": inputDiagnosticResetCount, "pendingOperations": pendingInputs.count,
                "activeOperations": activeInput == nil ? 0 : 1])
            flushInputDiagnostics()
        }
        let cancelledAgents = pendingInputs.compactMap(\.agentContext) + [activeInput?.agentContext].compactMap { $0 }
        sessionGeneration = UUID()
        inputTimeout?.cancel()
        inputTimeout = nil
        pendingInputs.removeAll()
        activeInput = nil
        pendingPump = nil
        releaseHeldInputState()
        scrollAccumulator.reset()
        scrollControlGeneration = nil
        resetClickTracking()
        lastInputPointByWindow.removeAll()
        for context in cancelledAgents { context.finish(false) }
    }

    /// Releases only the held state owned by the current active operation.
    /// Agent admission requires an idle queue with no prior held state; ordinary
    /// input arriving afterward remains queued until that operation is retired.
    private func releaseHeldInputState() {
        // Release only input actually posted by this session. Releases remain
        // necessary after control has been disabled; no new down is admitted.
        if heldUnicodeKey {
            heldUnicodeKey = false
            if let source = unicodeEventSource,
               let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                eventSink(event, Self.unicodeEventTap)
            }
        }
        let keys = heldKeyCodes.sorted { lhs, rhs in
            if isModifierKeyCode(lhs) != isModifierKeyCode(rhs) { return !isModifierKeyCode(lhs) }
            return lhs < rhs
        }
        var remainingKeys = heldKeyCodes
        heldKeyCodes.removeAll()
        for key in keys {
            remainingKeys.remove(key)
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) {
                event.flags = eventFlags(forKeyCodes: Array(remainingKeys))
                eventSink(event, .cghidEventTap)
            }
        }
        let buttons = heldMouseButtons
        heldMouseButtons.removeAll()
        for button in PeelMouseButton.allCases {
            if let point = buttons[button], let event = button.makeEvent(.up, at: point) {
                eventSink(event, .cghidEventTap)
            }
        }
    }

    /// Cancels only this exact agent owner. It never rotates the normal session
    /// generation, removes ordinary queue entries or releases another operation.
    func cancelAgentOperation(operationID: UUID) {
        retireAgentOperation(operationID: operationID, completed: false)
    }

    private func retireAgentOperation(operationID: UUID, completed: Bool) {
        let queued = pendingInputs.compactMap(\.agentContext).filter { $0.operationID == operationID }
        let active = (activeInput?.agentContext).flatMap { $0.operationID == operationID ? $0 : nil }
        guard active != nil || !queued.isEmpty else { return }
        let contexts = queued + [active].compactMap { $0 }
        for context in contexts { context.cancelled = true }
        pendingInputs.removeAll { $0.agentContext?.operationID == operationID }
        if active != nil {
            inputTimeout?.cancel(); inputTimeout = nil
            activeInput = nil // Retires the operation ID before release/callbacks.
            releaseHeldInputState()
        }
        for context in contexts { context.finish(completed && context === active) }
        scheduleInputPump()
    }

    /// Failure of a paid operation retires only that exact active owner. Normal
    /// input retains the existing full-session failure/reset policy.
    private func retireFailedInput(generation: InputGeneration, reason: ResetReason) {
        guard let id = generation.operation, activeInput?.id == id else { return }
        if let agent = activeInput?.agentContext {
            retireAgentOperation(operationID: agent.operationID, completed: false)
        } else {
            resetSessionState(reason: reason)
        }
    }

    /// Exactly one bounded operation, no held state crossing requests. A return
    /// value only means queued; completion counts events posted to Quartz, never
    /// delivery to an application or remote presentation.
    @discardableResult
    func performAgentOperation(controlGeneration: UInt64, operationID: UUID, allowed: @escaping () -> Bool,
                               eventAllowed: @escaping (CGEvent) -> Bool = { _ in true },
                               point: ((Double, Double) -> CGPoint?)? = nil,
                               completion: @escaping (Int, Bool) -> Void,
                               perform: (InputSynthesizer) -> Void) -> Bool {
        guard activeInput == nil, pendingInputs.isEmpty, heldKeyCodes.isEmpty,
              !heldUnicodeKey, heldMouseButtons.isEmpty, allowed() else { return false }
        let context = AgentInputContext(operationID: operationID, allowed: allowed, eventAllowed: eventAllowed, point: point, completion: completion)
        admittingAgentInput = context
        defer { admittingAgentInput = nil }
        withReceivedControlGeneration(controlGeneration) { perform(self) }
        return context.enqueued
    }

    /// A drag is one queue operation. Cancellation releases its down through the
    /// same reset path used for transport/permission loss; no raw down/up API is
    /// exposed over MCP.
    func performAgentDrag(windowId: UInt32, fromX: Double, fromY: Double, toX: Double, toY: Double) {
        guard let generation = captureInputGeneration() else { return }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "agentDrag",
            point: { self.clickPoint(windowId: windowId, normX: fromX, normY: fromY) }, requiresPoint: true) { generation, point, finish in
            guard let point, let down = PeelMouseButton.left.makeEvent(.down, at: point),
                  self.postPointerEvent(down, button: .left, action: .down, generation: generation) else { finish(); return }
            @MainActor func step(_ index: Int) {
                guard self.validateTextGeneration(generation) else { finish(); return }
                let fraction = Double(index) / 12
                guard let target = self.clickPoint(windowId: windowId,
                    normX: fromX + (toX - fromX) * fraction, normY: fromY + (toY - fromY) * fraction),
                      self.windowReadyForInput(windowId, interactionPoint: target, generation: generation),
                      let event = PeelMouseButton.left.makeEvent(index == 12 ? .up : .drag, at: target),
                      self.postPointerEvent(event, button: .left, action: index == 12 ? .up : .drag, generation: generation) else {
                    self.retireFailedInput(generation: generation, reason: .windowNotReady); finish(); return
                }
                self.noteInputPoint(target, for: windowId)
                if index == 12 { finish() }
                else { self.scheduleInputWork(0.016, DispatchWorkItem { step(index + 1) }) }
            }
            self.scheduleInputWork(0.016, DispatchWorkItem { step(1) })
        }
    }

    /// Opt-in, content-free boundary counts. Never retain text, scalars, or key names.
    func noteDecodedKeyboardText(_ message: KeyboardTextMessage) {
        guard inputDiagnosticsEnabled else { return }
        let windowId = message.windowId ?? activeWindowProvider()
        recordInputDiagnostic(.decodedTextMessages, windowId: windowId, control: admittedGeneration?.control)
        recordInputDiagnostic(.decodedTextScalars, windowId: windowId, control: admittedGeneration?.control,
                              amount: message.text.unicodeScalars.count)
    }

    private func recordInputDiagnostic(_ counter: DiagnosticCounter, windowId: UInt32?, control: UInt64?, amount: Int = 1) {
        guard inputDiagnosticsEnabled else { return }
        let key = "\(control.map(String.init) ?? "nil"):\(windowId.map(String.init) ?? "nil")"
        guard inputDiagnostics[key] != nil || inputDiagnostics.count < 64 else { return }
        var row = inputDiagnostics[key] ?? (windowId, control, [:])
        row.counts[counter.rawValue, default: 0] += amount
        inputDiagnostics[key] = row
        guard !inputDiagnosticsFlushPending else { return }
        inputDiagnosticsFlushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.inputDiagnosticsFlushPending = false
            self?.flushInputDiagnostics()
        }
    }

    private func flushInputDiagnostics() {
        guard inputDiagnosticsEnabled else { return }
        for key in inputDiagnostics.keys.sorted() {
            guard let row = inputDiagnostics[key] else { continue }
            emitInputDiagnostic(["event": "counts", "windowId": row.windowId.map(String.init) ?? "nil",
                "controlGeneration": row.control.map(String.init) ?? "nil", "counts": row.counts])
        }
    }

    private func emitInputDiagnostic(_ values: [String: Any]) {
        var payload = values
        payload["timestamp"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        print("PeelInputDiag " + String(decoding: data, as: UTF8.self))
    }

    func switchSpace(_ direction: HostSpaceSwitchDirection) {
        guard let generation = captureInputGeneration() else { return }
        enqueueSynchronousInput(generation: generation, windowId: nil) { generation in
            let now = CFAbsoluteTimeGetCurrent()
            guard now >= self.nextAllowedSpaceSwitchAt else { return }
            self.nextAllowedSpaceSwitchAt = now + self.spaceSwitchCooldown
            self.postSpaceSwipeGesture(direction)
        }
    }

    func performClick(windowId: UInt32, normX: Double, normY: Double, button: String = "left") {
        guard let generation = captureInputGeneration(),
              let mapping = resolveMouseButton(button, windowId: windowId) else { return }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "click",
            point: { self.clickPoint(windowId: windowId, normX: normX, normY: normY) }, requiresPoint: true) { generation, point, finish in
            defer { finish() }
            guard let point else { return }
            self.noteInputPoint(point, for: windowId)
            self.postClick(windowId: windowId, point: point, button: mapping, generation: generation)
        }
    }

    func performMouseMove(windowId: UInt32, normX: Double, normY: Double) {
        guard let generation = captureInputGeneration() else { return }
        enqueueSynchronousInput(generation: generation, windowId: windowId, coalescingKey: "move:\(windowId)") { generation in
            guard let point = self.clickPoint(windowId: windowId, normX: normX, normY: normY) else { return }
            self.markInput(windowId)
            self.noteInputPoint(point, for: windowId)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left) else { return }
            self.postEvent(event, generation: generation)
        }
    }

    func performMouseDown(windowId: UInt32, normX: Double, normY: Double, button: String = "left") {
        guard let generation = captureInputGeneration(),
              let mapping = resolveMouseButton(button, windowId: windowId) else { return }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "mouseDown",
            point: { self.clickPoint(windowId: windowId, normX: normX, normY: normY) }, requiresPoint: true) { generation, point, finish in
            defer { finish() }
            guard let point,
                  let event = mapping.makeEvent(.down, at: point) else { return }
            self.noteInputPoint(point, for: windowId)
            self.postPointerEvent(event, button: mapping, action: .down, generation: generation)
        }
    }

    func performMouseDragged(windowId: UInt32, normX: Double, normY: Double, button: String = "left") {
        guard let generation = captureInputGeneration() else { return }
        // Preserve stroke geometry; only hover motion may be coalesced.
        enqueueSynchronousInput(generation: generation, windowId: windowId) { generation in
            guard let mapping = self.resolveMouseButton(button, windowId: windowId),
                  self.heldMouseButtons[mapping] != nil,
                  let point = self.clickPoint(windowId: windowId, normX: normX, normY: normY),
                  let event = mapping.makeEvent(.drag, at: point) else { return }
            self.markInput(windowId)
            self.activeWindowSetter(windowId)
            self.noteInputPoint(point, for: windowId)
            self.postPointerEvent(event, button: mapping, action: .drag, generation: generation)
        }
    }

    func performMouseUp(windowId: UInt32, normX: Double, normY: Double, button: String = "left") {
        guard let generation = captureInputGeneration() else { return }
        enqueueSynchronousInput(generation: generation, windowId: windowId) { generation in
            guard let mapping = self.resolveMouseButton(button, windowId: windowId),
                  self.heldMouseButtons[mapping] != nil,
                  let point = self.clickPoint(windowId: windowId, normX: normX, normY: normY) ?? self.heldMouseButtons[mapping],
                  let event = mapping.makeEvent(.up, at: point) else { return }
            self.markInput(windowId)
            self.activeWindowSetter(windowId)
            self.noteInputPoint(point, for: windowId)
            self.postPointerEvent(event, button: mapping, action: .up, generation: generation)
        }
    }

    func performScroll(windowId: UInt32?, deltaX: Double, deltaY: Double) {
        guard let generation = captureInputGeneration(),
              let windowId = windowId ?? activeWindowProvider() else { return }
        enqueueSynchronousInput(generation: generation, windowId: windowId) { generation in
            self.noteRemoteInputTarget(windowId, generation: generation)
            guard let point = self.authoritativeInputPoint(for: windowId) else { return }
            if self.scrollControlGeneration != generation.control {
                self.scrollAccumulator.reset()
                self.scrollControlGeneration = generation.control
            }
            guard let scroll = self.scrollAccumulator.consume(windowId: windowId, deltaX: deltaX, deltaY: deltaY),
                  scroll.x != 0 || scroll.y != 0 else { return }
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: scroll.y, wheel2: scroll.x, wheel3: 0) {
                event.location = point
                self.postEvent(event, generation: generation)
            }
        }
    }

    func handleKeyboardText(_ message: KeyboardTextMessage) {
        guard let generation = captureInputGeneration(), !message.text.isEmpty,
              let windowId = message.windowId ?? activeWindowProvider() else { return }
        guard message.text.utf8.count <= Self.maximumTextBytes else {
            rejectInput(windowId: windowId, reason: "The text input is too large; send smaller chunks")
            return
        }
        let diagnosticScalars = inputDiagnosticsEnabled ? message.text.unicodeScalars.count : nil
        if let diagnosticScalars {
            recordInputDiagnostic(.admittedTextMessages, windowId: windowId, control: generation.control)
            recordInputDiagnostic(.admittedTextScalars, windowId: windowId, control: generation.control, amount: diagnosticScalars)
        }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "keyboardText",
            point: { self.authoritativeInputPoint(for: windowId) }, diagnosticTextScalars: diagnosticScalars) { generation, _, finish in
            self.setInputDeadline(generation: generation,
                seconds: Self.textExecutionDeadline(scalarCount: message.text.unicodeScalars.count))
            self.postTextInChunks(message.text, interpretControlCharacters: true, generation: generation, completion: finish)
        }
    }

    func handleKeyboardCommand(_ message: KeyboardCommandMessage) {
        guard let generation = captureInputGeneration(),
              let windowId = message.windowId ?? activeWindowProvider(),
              let keyCode = keyCode(for: message.command) else { return }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "keyboardCommand",
            point: { self.authoritativeInputPoint(for: windowId) }) { _, _, finish in
            defer { finish() }
            self.postKeyboardCommand(message, resolvedWindowId: windowId, resolvedKeyCode: keyCode)
        }
    }

    func handleKeyboardHardwareKey(_ message: KeyboardHardwareKeyMessage) {
        guard let generation = captureInputGeneration(),
              let windowId = message.windowId ?? activeWindowProvider() else { return }
        guard let keyCode = cgKeyCode(forHardwareMessage: message) else {
            rejectInput(windowId: windowId, reason: "This hardware key is not supported on this Mac")
            return
        }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "keyboardHardwareKey",
            point: { self.authoritativeInputPoint(for: windowId) },
            admission: { message.action != .up || self.heldKeyCodes.contains(keyCode) }) { _, _, finish in
            defer { finish() }
            self.postKeyboardHardwareKey(message, resolvedKeyCode: keyCode)
        }
    }

    func handleKeyboardChord(_ message: KeyboardChordMessage) {
        guard let generation = captureInputGeneration(),
              let windowId = message.windowId ?? activeWindowProvider() else { return }
        guard message.chord.keys.count <= 32 else {
            rejectInput(windowId: windowId, reason: "The keyboard chord has too many keys")
            return
        }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "keyboardChord",
            point: { self.authoritativeInputPoint(for: windowId) }) { _, _, finish in
            defer { finish() }
            self.postKeyboardChord(message.chord)
        }
    }

    func handleKeyboardMacro(_ message: KeyboardMacroMessage) {
        guard let generation = captureInputGeneration(),
              let windowId = message.windowId ?? activeWindowProvider() else { return }
        guard let delayMilliseconds = validatedMacroDelay(message) else {
            rejectInput(windowId: windowId, reason: "The keyboard macro exceeds the step, text or delay limit")
            return
        }
        enqueueFocusedInput(generation: generation, windowId: windowId, inputType: "keyboardMacro",
            point: { self.authoritativeInputPoint(for: windowId) }) { generation, _, finish in
            let textScalars = message.steps.reduce(0) { count, step in
                if case .text(let text) = step { return count + text.unicodeScalars.count }
                return count
            }
            self.setInputDeadline(generation: generation,
                seconds: Self.textExecutionDeadline(scalarCount: textScalars) + Double(delayMilliseconds) / 1000)
            self.postKeyboardMacro(message, generation: generation, completion: finish)
        }
    }

    private func enqueueInput(generation: InputGeneration, windowId: UInt32?, coalescingKey: String? = nil,
                              diagnosticTextScalars: Int? = nil,
                              action: @escaping (InputGeneration, @escaping () -> Void) -> Void) {
        guard isCurrentInputGeneration(generation) else { return }
        if let context = admittingAgentInput {
            guard !context.enqueued, context.isAllowed else { return }
            context.enqueued = true
        }
        let id = UUID()
        let queuedGeneration = InputGeneration(local: generation.local, control: generation.control, operation: id)
        let input = QueuedInput(id: id, generation: queuedGeneration, windowId: windowId,
            coalescingKey: coalescingKey, agentContext: admittingAgentInput, action: action)
        // Only adjacent motion for the same target/session can collapse. Never
        // cross a button/key/scroll boundary or replace the operation in flight.
        if let coalescingKey, let last = pendingInputs.last,
           last.coalescingKey == coalescingKey, last.generation.local == generation.local,
           last.generation.control == generation.control {
            pendingInputs[pendingInputs.count - 1] = input
        } else {
            guard pendingInputs.count < Self.maximumQueuedInputs else {
                resetSessionState(reason: .queueOverflow)
                if let windowId { rejectInput(windowId: windowId, reason: "Input queue overflow; pending input was cancelled. Try again") }
                return
            }
            pendingInputs.append(input)
        }
        if let diagnosticTextScalars {
            recordInputDiagnostic(.enqueuedTextMessages, windowId: windowId, control: generation.control)
            recordInputDiagnostic(.enqueuedTextScalars, windowId: windowId, control: generation.control, amount: diagnosticTextScalars)
        }
        scheduleInputPump()
    }

    private func scheduleInputPump() {
        guard activeInput == nil, pendingPump == nil, !pendingInputs.isEmpty else { return }
        let token = UUID()
        pendingPump = token
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingPump == token else { return }
            self.pendingPump = nil
            guard self.activeInput == nil, !self.pendingInputs.isEmpty else { return }
            let input = self.pendingInputs.removeFirst()
            self.activeInput = input
            guard self.isCurrentInputGeneration(input.generation) else {
                self.finishInput(id: input.id)
                return
            }
            self.setInputDeadline(generation: input.generation, seconds: 1)
            input.action(input.generation) { [weak self] in self?.finishInput(id: input.id) }
        }
    }

    private func finishInput(id: UUID) {
        guard activeInput?.id == id else { return }
        let agent = activeInput?.agentContext
        let completed = agent.map { $0.posted > 0 && $0.isAllowed } ?? false
        if let agent {
            retireAgentOperation(operationID: agent.operationID, completed: completed)
        } else {
            inputTimeout?.cancel(); inputTimeout = nil; activeInput = nil
            scheduleInputPump()
        }
    }

    private func setInputDeadline(generation: InputGeneration, seconds: TimeInterval) {
        guard let id = generation.operation, activeInput?.id == id else { return }
        inputTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.activeInput?.id == id else { return }
            let windowId = self.activeInput?.windowId
            self.retireFailedInput(generation: generation, reason: .inputDeadline)
            if let windowId { self.rejectInput(windowId: windowId, reason: "Input timed out; pending input was cancelled. Try again", generation: generation) }
        }
        inputTimeout = timeout
        scheduleInputWork(seconds, timeout)
    }

    private func rejectInput(windowId: UInt32, reason: String, generation: InputGeneration? = nil) {
        // Local-computer failures are reported in the agent receipt, never to a paired client.
        if let generation, Self.isLocalControlGeneration(generation.control) { return }
        accessibility.sendInputRejected?(windowId, "Peel could not send input. \(reason)")
    }

    private func windowReadyForInput(_ windowId: UInt32, interactionPoint: CGPoint?, generation: InputGeneration) -> Bool {
        if Self.isLocalControlGeneration(generation.control) {
            return isLocalWindowReadyForInput(windowId, interactionPoint)
        }
        return accessibility.isWindowReadyForInput(windowId: windowId, interactionPoint: interactionPoint)
    }

    private func enqueueSynchronousInput(generation: InputGeneration, windowId: UInt32?, coalescingKey: String? = nil,
                                         action: @escaping (InputGeneration) -> Void) {
        enqueueInput(generation: generation, windowId: windowId, coalescingKey: coalescingKey) { generation, finish in
            defer { finish() }
            self.performInGeneration(generation) { action(generation) }
        }
    }

    private func enqueueFocusedInput(generation: InputGeneration, windowId: UInt32, inputType: String,
                                      point: @escaping () -> CGPoint?, requiresPoint: Bool = false,
                                      diagnosticTextScalars: Int? = nil,
                                      admission: @escaping () -> Bool = { true },
                                      action: @escaping (InputGeneration, CGPoint?, @escaping () -> Void) -> Void) {
        enqueueInput(generation: generation, windowId: windowId, diagnosticTextScalars: diagnosticTextScalars) { generation, finish in
            guard self.isCurrentInputGeneration(generation), admission() else { finish(); return }
            let point = point()
            guard !requiresPoint || point != nil else {
                self.retireFailedInput(generation: generation, reason: .windowPositionUnavailable)
                self.rejectInput(windowId: windowId, reason: "The requested Mac window's position is unavailable; pending input was cancelled", generation: generation)
                finish()
                return
            }
            self.noteRemoteInputTarget(windowId, generation: generation)
            let afterFocus = {
                self.runWhenWindowReadyForInput(windowId: windowId, interactionPoint: point,
                    inputType: inputType, generation: generation) { ready in
                    guard ready else { finish(); return }
                    if !self.performInGeneration(generation, action: { action(generation, point, finish) }) { finish() }
                }
            }
            if WindowEnumerator.isDisplayCaptureWindowId(windowId)
                || self.windowReadyForInput(windowId, interactionPoint: point, generation: generation) {
                afterFocus()
            } else if Self.isLocalControlGeneration(generation.control) {
                // The local route focuses only through its explicit presentWindow request.
                self.retireFailedInput(generation: generation, reason: .windowNotReady)
                finish()
            } else {
                self.accessibility.bringWindowToFront(windowId: windowId, interactionPoint: point, completion: afterFocus)
            }
        }
    }

    private func runWhenWindowReadyForInput(windowId: UInt32, interactionPoint: CGPoint?, inputType: String,
                                             generation: InputGeneration, attempt: Int = 0,
                                             completion: @escaping (Bool) -> Void) {
        guard isCurrentInputGeneration(generation) else { completion(false); return }
        if WindowEnumerator.isDisplayCaptureWindowId(windowId)
            || windowReadyForInput(windowId, interactionPoint: interactionPoint, generation: generation) {
            completion(true)
            return
        }
        guard attempt < 3 else {
            // A rejected down must not be followed by dependent drags/keys.
            // Also release any key/button held before this target disappeared.
            retireFailedInput(generation: generation, reason: .windowNotReady)
            if !Self.isLocalControlGeneration(generation.control) {
                accessibility.sendInputRejected?(windowId, "Peel could not send \(inputType) because the requested Mac window was not ready for input")
            }
            completion(false)
            return
        }
        let delays: [TimeInterval] = [0.05, 0.10, 0.18]
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            self?.runWhenWindowReadyForInput(windowId: windowId, interactionPoint: interactionPoint,
                inputType: inputType, generation: generation, attempt: attempt + 1, completion: completion)
        }
    }

    /// Paired-stream focus/capture hints belong to the remote session only. A
    /// local-computer agent operation must not move the paired client's
    /// active-window state or mark its stream as receiving input.
    private func noteRemoteInputTarget(_ windowId: UInt32, generation: InputGeneration) {
        guard !Self.isLocalControlGeneration(generation.control) else { return }
        markInput(windowId)
        activeWindowSetter(windowId)
    }

    private func captureInputGeneration() -> InputGeneration? {
        guard let generation = admittedGeneration, isCurrentInputGeneration(generation) else { return nil }
        return generation
    }

    private func isCurrentInputGeneration(_ generation: InputGeneration) -> Bool {
        let authorized = Self.isLocalControlGeneration(generation.control)
            ? isLocalControlAllowed() : isRemoteControlAllowed()
        return sessionGeneration == generation.local && authorized
            && isControlGenerationCurrent(generation.control)
            && (generation.operation == nil || generation.operation == activeInput?.id)
            && (generation.operation == nil || activeInput?.agentContext?.isAllowed != false)
    }

    @discardableResult
    private func performInGeneration(_ generation: InputGeneration, action: () -> Void) -> Bool {
        guard isCurrentInputGeneration(generation) else { return false }
        let previous = executingGeneration
        executingGeneration = generation
        defer { executingGeneration = previous }
        action()
        return true
    }

    @discardableResult
    private func postEvent(_ event: CGEvent, tap: CGEventTapLocation = .cghidEventTap,
                           generation: InputGeneration? = nil, beforePost: (() -> Void)? = nil) -> Bool {
        guard let generation = generation ?? executingGeneration,
              isCurrentInputGeneration(generation), activeInput?.agentContext?.eventAllowed(event) != false else { return false }
        beforePost?()
        activeInput?.agentContext?.posted += 1
        eventSink(event, tap)
        return true
    }

    @discardableResult
    private func postPointerEvent(_ event: CGEvent, button: PeelMouseButton, action: PeelMouseButton.Action,
                                  generation: InputGeneration) -> Bool {
        // A drag/release may only continue a button down actually posted by this session.
        guard action == .down || heldMouseButtons[button] != nil else { return false }
        return postEvent(event, generation: generation, beforePost: {
            // Track before the sink: a Stop/session reset can run reentrantly
            // while a posted down is delivered, and must release it exactly once.
            switch action {
            case .down: self.heldMouseButtons[button] = event.location
            case .drag: if self.heldMouseButtons[button] != nil { self.heldMouseButtons[button] = event.location }
            case .up: self.heldMouseButtons.removeValue(forKey: button)
            }
        })
    }

    private func resolveMouseButton(_ value: String, windowId: UInt32) -> PeelMouseButton? {
        guard let button = PeelMouseButton(rawValue: value) else {
            accessibility.sendInputRejected?(windowId, "Peel Pro does not support the requested mouse button")
            return nil
        }
        return button
    }

    private func clickPoint(windowId: UInt32, normX: Double, normY: Double) -> CGPoint? {
        if let point = activeInput?.agentContext?.point { return point(normX, normY) }
        return WindowEnumerator.inputGeometry(for: windowId)?.screenPoint(normX: normX, normY: normY)
    }

    private func noteInputPoint(_ point: CGPoint, for windowId: UInt32) {
        lastInputPointByWindow[windowId] = point
    }

    private func authoritativeInputPoint(for windowId: UInt32) -> CGPoint? {
        if let point = activeInput?.agentContext?.point { return point(0.5, 0.5) }
        if let point = lastInputPointByWindow[windowId] {
            return point
        }

        return accessibility.authoritativePointFallback(for: windowId)
    }

    private func postClick(windowId: UInt32, point: CGPoint, button: PeelMouseButton, generation: InputGeneration) {
        let clickState = nextClickState(windowId: windowId, at: point, button: button.rawValue)
        guard let down = button.makeEvent(.down, at: point), let up = button.makeEvent(.up, at: point) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: clickState)
        up.setIntegerValueField(.mouseEventClickState, value: clickState)
        guard postPointerEvent(down, button: button, action: .down, generation: generation) else { return }
        postPointerEvent(up, button: button, action: .up, generation: generation)
    }

    private func nextClickState(windowId: UInt32, at point: CGPoint, button: String) -> Int64 {
        let now = CFAbsoluteTimeGetCurrent()
        let baseInterval = NSEvent.doubleClickInterval
        let maxInterval = max(baseInterval, 0.50) + 0.15
        let maxDistance: CGFloat = 18

        let sameTarget = (clickTrackingState.lastWindowId == windowId) && (clickTrackingState.lastButton == button)
        let dt = now - clickTrackingState.lastAt
        let dx = point.x - clickTrackingState.lastPoint.x
        let dy = point.y - clickTrackingState.lastPoint.y
        let dist = (dx * dx + dy * dy).squareRoot()

        if sameTarget && dt > 0 && dt <= maxInterval && dist <= maxDistance {
            clickTrackingState.clickCount = min(clickTrackingState.clickCount + 1, 3)
        } else {
            clickTrackingState.clickCount = 1
        }

        clickTrackingState.lastAt = now
        clickTrackingState.lastPoint = point
        clickTrackingState.lastWindowId = windowId
        clickTrackingState.lastButton = button

        return clickTrackingState.clickCount
    }

    private func resetClickTracking() {
        clickTrackingState = ClickTrackingState()
    }

    private func validatedMacroDelay(_ message: KeyboardMacroMessage) -> Int? {
        guard message.steps.count <= Self.maximumMacroSteps else { return nil }
        var delay = 0
        var bytes = 0
        for step in message.steps {
            switch step {
            case .delayMilliseconds(let milliseconds):
                guard milliseconds >= 0, milliseconds <= Self.maximumMacroDelayMilliseconds - delay else { return nil }
                delay += milliseconds
            case .text(let text):
                let count = text.utf8.count
                guard count <= Self.maximumTextBytes - bytes else { return nil }
                bytes += count
            case .chord(let chord):
                guard chord.keys.count <= 32 else { return nil }
            case .key: break
            }
        }
        return delay
    }

    // Admission caps total text at 65,536 UTF-8 bytes, hence at most that many
    // scalars: 141.072s including 10s headroom, or 151.072s for a maximal macro.
    static func textExecutionDeadline(scalarCount: Int) -> TimeInterval {
        10 + Double(scalarCount) * 2 * textEventInterval
    }

    private func validateTextGeneration(_ generation: InputGeneration) -> Bool {
        guard isCurrentInputGeneration(generation) else {
            // A transport/permission transition may precede its main-actor reset.
            // Only this operation may release its held input; an old callback
            // must never reset a replacement operation.
            if activeInput?.id == generation.operation {
                retireFailedInput(generation: generation, reason: .inputGenerationChanged)
            }
            return false
        }
        return true
    }

    private func postTextInChunks(_ text: String, interpretControlCharacters: Bool, generation: InputGeneration,
                                   completion: @escaping () -> Void) {
        let scalars = Array(text.unicodeScalars)
        // Only a local-computer agent operation posts bounded runs of printable
        // scalars per down/up; every run keeps the full per-post guards below.
        // Paired-stream text remains one scalar per down/up.
        let postsUnicodeRuns = Self.isLocalControlGeneration(generation.control) && activeInput?.agentContext != nil
        func later(_ action: @escaping () -> Void) {
            self.scheduleInputWork(Self.textEventInterval, DispatchWorkItem(block: action))
        }
        func emit(from first: Int) {
            guard self.validateTextGeneration(generation) else { completion(); return }
            guard first < scalars.count else { completion(); return }
            guard let windowId = self.activeInput?.windowId,
                  WindowEnumerator.isDisplayCaptureWindowId(windowId)
                    || (Self.isLocalControlGeneration(generation.control)
                        ? self.isLocalWindowReadyForInput(windowId, self.authoritativeInputPoint(for: windowId))
                        : self.accessibility.isWindowReadyForInput(windowId: windowId,
                        interactionPoint: self.authoritativeInputPoint(for: windowId))) else {
                let windowId = self.activeInput?.windowId
                self.retireFailedInput(generation: generation, reason: .windowNotReady)
                if let windowId { self.rejectInput(windowId: windowId, reason: "The requested Mac window was no longer ready; pending text was cancelled", generation: generation) }
                completion()
                return
            }
            let scalar = scalars[first]
            let controlKey: CGKeyCode?
            if interpretControlCharacters, scalar.value == 8 || scalar.value == 127 { controlKey = 51 }
            else if interpretControlCharacters, scalar.value == 10 || scalar.value == 13 { controlKey = 36 }
            else { controlKey = nil }
            // Last scalar posted by this step.
            let index = postsUnicodeRuns && controlKey == nil
                ? PeelKeyboardEventFactory.unicodeRunEnd(in: scalars, from: first) - 1 : first

            let postUp: () -> Bool
            if let controlKey {
                var posted = false
                self.performInGeneration(generation) { posted = self.postKeyCode(controlKey, keyDown: true) }
                guard posted else { _ = self.validateTextGeneration(generation); completion(); return }
                postUp = {
                    var posted = false
                    self.performInGeneration(generation) { posted = self.postKeyCode(controlKey, keyDown: false) }
                    return posted
                }
            } else {
                guard let source = self.unicodeEventSource,
                      let events = index == first
                        ? PeelKeyboardEventFactory.unicodeEvents(for: scalar, source: source)
                        : PeelKeyboardEventFactory.unicodeEvents(for: scalars[first...index], source: source) else {
                    completion(); return
                }
                guard self.postEvent(events.down, tap: Self.unicodeEventTap, generation: generation, beforePost: { self.heldUnicodeKey = true }) else {
                    _ = self.validateTextGeneration(generation); completion(); return
                }
                self.recordInputDiagnostic(.postedUnicodeDown, windowId: windowId, control: generation.control)
                postUp = {
                    guard self.postEvent(events.up, tap: Self.unicodeEventTap, generation: generation, beforePost: { self.heldUnicodeKey = false }) else { return false }
                    self.recordInputDiagnostic(.postedUnicodeUp, windowId: windowId, control: generation.control)
                    return true
                }
            }
            later {
                guard self.validateTextGeneration(generation), postUp() else {
                    _ = self.validateTextGeneration(generation); completion(); return
                }
                // Retain operation ownership through this gap even for the last
                // scalar, so separate one-character messages cannot bypass it.
                later { emit(from: index + 1) }
            }
        }
        emit(from: 0)
    }

    private func postKeyboardMacro(_ message: KeyboardMacroMessage, generation: InputGeneration,
                                    completion: @escaping () -> Void) {
        // Preserve receive ordering for the whole burst, including atomic macros,
        // while yielding the main actor for delays/text and lifecycle cancellation.
        func emit(step index: Int) {
            guard self.isCurrentInputGeneration(generation), index < message.steps.count else { completion(); return }
            let next = { DispatchQueue.main.async { emit(step: index + 1) } }
            switch message.steps[index] {
            case .chord(let chord):
                self.performInGeneration(generation) { self.postKeyboardChord(chord) }
                next()
            case .key(let keyMessage):
                self.performInGeneration(generation) {
                    if let keyCode = self.keyCode(for: keyMessage.command) {
                        self.postKeyboardCommand(keyMessage, resolvedWindowId: message.windowId, resolvedKeyCode: keyCode)
                    }
                }
                next()
            case .text(let text):
                self.postTextInChunks(text, interpretControlCharacters: false, generation: generation, completion: next)
            case .delayMilliseconds(let milliseconds):
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(milliseconds) / 1000) { emit(step: index + 1) }
            }
        }
        emit(step: 0)
    }

    private func postKeyboardCommand(
        _ message: KeyboardCommandMessage,
        resolvedWindowId: UInt32?,
        resolvedKeyCode: CGKeyCode
    ) {
        let modifierCommands = normalizedModifierCommands(message.modifiers ?? [])
        let modifierKeyCodes = modifierCommands
            .compactMap { keyCode(for: $0) }
            .filter { $0 != resolvedKeyCode }
        let modifierFlags = eventFlags(for: modifierCommands)

        switch message.action ?? .press {
        case .press:
            postModifiedKeyPress(
                keyCode: resolvedKeyCode,
                modifierKeyCodes: modifierKeyCodes,
                flags: modifierFlags
            )
        case .down:
            postKeyCode(resolvedKeyCode, keyDown: true, flags: modifierFlags)
        case .up:
            postKeyCode(resolvedKeyCode, keyDown: false, flags: modifierFlags)
        }
    }

    private func postKeyboardHardwareKey(
        _ message: KeyboardHardwareKeyMessage,
        resolvedKeyCode: CGKeyCode
    ) {
        let modifierCommands = normalizedModifierCommands(message.modifiers)
        let modifierKeyCodes = modifierCommands
            .compactMap { keyCode(for: $0) }
            .filter { $0 != resolvedKeyCode }
        let modifierFlags = eventFlags(for: modifierCommands)

        switch message.action ?? .press {
        case .press:
            postModifiedKeyPress(
                keyCode: resolvedKeyCode,
                modifierKeyCodes: modifierKeyCodes,
                flags: modifierFlags
            )
        case .down:
            postKeyCode(resolvedKeyCode, keyDown: true, flags: modifierFlags)
        case .up:
            postKeyCode(resolvedKeyCode, keyDown: false, flags: modifierFlags)
        }
    }

    private func cgKeyCode(forHardwareMessage message: KeyboardHardwareKeyMessage) -> CGKeyCode? {
        // For navigation/function/modifier hardware keys, prefer the HID usage.
        // UIKey.characters / charactersIgnoringModifiers can contain shortcut text
        // such as "<" for Option+Left, which resolves to comma on macOS and can
        // accidentally trigger Xcode menu shortcuts like Edit Scheme instead of
        // sending a real Left Arrow key event.
        if shouldPreferKeyboardHIDUsage(message.keyCode),
           let keyCode = cgKeyCode(forKeyboardHIDUsage: message.keyCode) {
            return keyCode
        }

        if let keyCode = cgKeyCode(forCharacters: message.charactersIgnoringModifiers) {
            return keyCode
        }

        if let keyCode = cgKeyCode(forCharacters: message.characters) {
            return keyCode
        }

        if let keyCode = cgKeyCode(forKeyboardHIDUsage: message.keyCode) {
            return keyCode
        }

        // The wire value is a USB keyboard HID usage, not a macOS virtual key.
        // Casting an unknown usage can trigger an unrelated key (for example,
        // Non-US backslash usage 100 becomes Mac F8).
        return nil
    }

    private func shouldPreferKeyboardHIDUsage(_ usage: Int) -> Bool {
        switch usage {
        case 40...44,       // return, escape, backspace, tab, space
             57...69,       // caps lock, F1...F12
             73...82,       // insert/home/page/nav arrows
             83...99, 103,  // keypad keys retain keypad identity
             224...231:     // modifier keys
            return true
        default:
            return false
        }
    }

    private func cgKeyCode(forCharacters characters: String?) -> CGKeyCode? {
        guard let characters, characters.unicodeScalars.count == 1 else { return nil }

        if characters == "\r" || characters == "\n" {
            return 36
        }

        if characters == "\t" {
            return 48
        }

        if characters == " " {
            return 49
        }

        let lowered = characters.lowercased().unicodeScalars
        guard lowered.count == 1, let firstScalar = lowered.first else {
            return nil
        }

        switch String(firstScalar) {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1", "!": return 18
        case "2", "@": return 19
        case "3", "#": return 20
        case "4", "$": return 21
        case "6", "^": return 22
        case "5", "%": return 23
        case "=", "+": return 24
        case "9", "(": return 25
        case "7", "&": return 26
        case "-", "_": return 27
        case "8", "*": return 28
        case "0", ")": return 29
        case "]", "}": return 30
        case "o": return 31
        case "u": return 32
        case "[", "{": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'", "\"": return 39
        case "k": return 40
        case ";", ":": return 41
        case "\\", "|": return 42
        case ",", "<": return 43
        case "/", "?": return 44
        case "n": return 45
        case "m": return 46
        case ".", ">": return 47
        case "`", "~": return 50
        default:
            return nil
        }
    }

    private func cgKeyCode(forKeyboardHIDUsage usage: Int) -> CGKeyCode? {
        switch usage {
        case 4: return 0      // A
        case 5: return 11     // B
        case 6: return 8      // C
        case 7: return 2      // D
        case 8: return 14     // E
        case 9: return 3      // F
        case 10: return 5     // G
        case 11: return 4     // H
        case 12: return 34    // I
        case 13: return 38    // J
        case 14: return 40    // K
        case 15: return 37    // L
        case 16: return 46    // M
        case 17: return 45    // N
        case 18: return 31    // O
        case 19: return 35    // P
        case 20: return 12    // Q
        case 21: return 15    // R
        case 22: return 1     // S
        case 23: return 17    // T
        case 24: return 32    // U
        case 25: return 9     // V
        case 26: return 13    // W
        case 27: return 7     // X
        case 28: return 16    // Y
        case 29: return 6     // Z

        case 30: return 18    // 1
        case 31: return 19    // 2
        case 32: return 20    // 3
        case 33: return 21    // 4
        case 34: return 23    // 5
        case 35: return 22    // 6
        case 36: return 26    // 7
        case 37: return 28    // 8
        case 38: return 25    // 9
        case 39: return 29    // 0

        case 40: return 36    // Return / Enter
        case 41: return 53    // Escape
        case 42: return 51    // Delete / Backspace
        case 43: return 48    // Tab
        case 44: return 49    // Space
        case 45: return 27    // -
        case 46: return 24    // =
        case 47: return 33    // [
        case 48: return 30    // ]
        case 49: return 42    // backslash
        case 50: return 42    // Non-US # / ~, closest Mac key
        case 51: return 41    // ;
        case 52: return 39    // '
        case 53: return 50    // `
        case 54: return 43    // ,
        case 55: return 47    // .
        case 56: return 44    // /
        case 57: return 57    // Caps Lock

        case 58: return 122   // F1
        case 59: return 120   // F2
        case 60: return 99    // F3
        case 61: return 118   // F4
        case 62: return 96    // F5
        case 63: return 97    // F6
        case 64: return 98    // F7
        case 65: return 100   // F8
        case 66: return 101   // F9
        case 67: return 109   // F10
        case 68: return 103   // F11
        case 69: return 111   // F12

        case 73: return 114   // Insert / Help
        case 74: return 115   // Home
        case 75: return 116   // Page Up
        case 76: return 117   // Forward Delete
        case 77: return 119   // End
        case 78: return 121   // Page Down
        case 79: return 124   // Right Arrow
        case 80: return 123   // Left Arrow
        case 81: return 125   // Down Arrow
        case 82: return 126   // Up Arrow

        case 83: return 71    // Keypad Clear / Num Lock
        case 84: return 75    // Keypad /
        case 85: return 67    // Keypad *
        case 86: return 78    // Keypad -
        case 87: return 69    // Keypad +
        case 88: return 76    // Keypad Enter
        case 89: return 83    // Keypad 1
        case 90: return 84    // Keypad 2
        case 91: return 85    // Keypad 3
        case 92: return 86    // Keypad 4
        case 93: return 87    // Keypad 5
        case 94: return 88    // Keypad 6
        case 95: return 89    // Keypad 7
        case 96: return 91    // Keypad 8
        case 97: return 92    // Keypad 9
        case 98: return 82    // Keypad 0
        case 99: return 65    // Keypad .
        case 103: return 81   // Keypad =

        case 224: return 59   // Left Control
        case 225: return 56   // Left Shift
        case 226: return 58   // Left Option
        case 227: return 55   // Left Command
        case 228: return 62   // Right Control
        case 229: return 60   // Right Shift
        case 230: return 61   // Right Option
        case 231: return 54   // Right Command

        default:
            return nil
        }
    }

    private func postKeyboardChord(_ chord: KeyboardChord) {
        let keyCodes = chord.keys.compactMap { keyCode(for: $0) }
        postChordKeyCodes(keyCodes)
    }

    private func postChordKeyCodes(_ keyCodes: [CGKeyCode]) {
        let uniqueKeyCodes = deduplicatedKeyCodes(keyCodes)
        guard !uniqueKeyCodes.isEmpty else { return }

        let modifierKeyCodes = uniqueKeyCodes.filter { isModifierKeyCode($0) && !heldKeyCodes.contains($0) }
        let nonModifierKeyCodes = uniqueKeyCodes.filter { !isModifierKeyCode($0) }
        var activeModifierFlags = eventFlags(forKeyCodes: Array(heldKeyCodes))

        for modifierKeyCode in modifierKeyCodes {
            if let flag = eventFlag(forModifierKeyCode: modifierKeyCode) {
                activeModifierFlags.insert(flag)
            }
            postKeyCode(modifierKeyCode, keyDown: true, flags: activeModifierFlags)
        }

        if nonModifierKeyCodes.isEmpty {
            releaseModifierKeyCodes(modifierKeyCodes, activeFlags: activeModifierFlags)
            return
        }

        for keyCode in nonModifierKeyCodes {
            postKeyCode(keyCode, keyDown: true, flags: activeModifierFlags)
            postKeyCode(keyCode, keyDown: false, flags: activeModifierFlags)
        }

        releaseModifierKeyCodes(modifierKeyCodes, activeFlags: activeModifierFlags)
    }

    private func postModifiedKeyPress(
        keyCode: CGKeyCode,
        modifierKeyCodes: [CGKeyCode],
        flags: CGEventFlags
    ) {
        let modifierKeyCodes = deduplicatedKeyCodes(modifierKeyCodes)

        if flags == .maskControl,
           modifierKeyCodes.count == 1,
           modifierKeyCodes[0] == 59 || modifierKeyCodes[0] == 62,
           let direction = spaceSwitchDirection(forArrowKeyCode: keyCode) {
            postSpaceSwipeGesture(direction)
            return
        }

        let temporaryModifierKeyCodes = modifierKeyCodes.filter { !heldKeyCodes.contains($0) }
        var activeModifierFlags = eventFlags(forKeyCodes: Array(heldKeyCodes))

        for modifierKeyCode in temporaryModifierKeyCodes {
            if let flag = eventFlag(forModifierKeyCode: modifierKeyCode) {
                activeModifierFlags.insert(flag)
            }
            postKeyCode(modifierKeyCode, keyDown: true, flags: activeModifierFlags)
        }

        let keyFlags = activeModifierFlags.isEmpty ? flags : activeModifierFlags
        postKeyCode(keyCode, keyDown: true, flags: keyFlags)
        postKeyCode(keyCode, keyDown: false, flags: keyFlags)

        releaseModifierKeyCodes(temporaryModifierKeyCodes, activeFlags: activeModifierFlags)
    }

    private func spaceSwitchDirection(forArrowKeyCode keyCode: CGKeyCode) -> HostSpaceSwitchDirection? {
        switch keyCode {
        case 123:
            return .left
        case 124:
            return .right
        default:
            return nil
        }
    }

    /// Mission Control does not treat synthesized Control-Arrow key events like the
    /// corresponding physical shortcut. A three-phase Dock swipe reaches the same
    /// system path as a fast trackpad gesture and avoids sending the rejected chord
    /// to the foreground app. Event recipe independently adapted from WhichSpace's
    /// MIT-licensed SpaceSwitcher implementation: https://github.com/gechr/WhichSpace
    private func postSpaceSwipeGesture(_ direction: HostSpaceSwitchDirection) {
        guard
            let eventTypeField = CGEventField(rawValue: 55),
            let gestureHIDTypeField = CGEventField(rawValue: 110),
            let gestureSwipeMotionField = CGEventField(rawValue: 123),
            let gestureSwipeProgressField = CGEventField(rawValue: 124),
            let gestureSwipeVelocityXField = CGEventField(rawValue: 129),
            let gestureSwipeVelocityYField = CGEventField(rawValue: 130),
            let gesturePhaseField = CGEventField(rawValue: 132)
        else {
            return
        }

        let movesRight = direction == .right
        let progress = movesRight ? Double(Float.leastNonzeroMagnitude) : -Double(Float.leastNonzeroMagnitude)
        let velocity = movesRight ? 2_000.0 : -2_000.0

        for phase: Int64 in [1, 2, 4] {
            guard let event = CGEvent(source: nil) else { return }
            event.setIntegerValueField(eventTypeField, value: 30)
            event.setIntegerValueField(gestureHIDTypeField, value: 23)
            event.setIntegerValueField(gesturePhaseField, value: phase)
            event.setDoubleValueField(gestureSwipeProgressField, value: progress)
            event.setIntegerValueField(gestureSwipeMotionField, value: 1)
            event.setDoubleValueField(gestureSwipeVelocityXField, value: velocity)
            event.setDoubleValueField(gestureSwipeVelocityYField, value: velocity)
            postEvent(event, tap: .cgSessionEventTap)
        }
    }

    private func releaseModifierKeyCodes(_ modifierKeyCodes: [CGKeyCode], activeFlags: CGEventFlags) {
        var activeFlags = activeFlags

        for modifierKeyCode in modifierKeyCodes.reversed() {
            if let flag = eventFlag(forModifierKeyCode: modifierKeyCode) {
                activeFlags.remove(flag)
            }
            postKeyCode(modifierKeyCode, keyDown: false, flags: activeFlags)
        }
    }

    private func deduplicatedKeyCodes(_ keyCodes: [CGKeyCode]) -> [CGKeyCode] {
        keyCodes.reduce(into: [CGKeyCode]()) { partialResult, keyCode in
            if !partialResult.contains(keyCode) {
                partialResult.append(keyCode)
            }
        }
    }

    private func normalizedModifierCommands(_ commands: [KeyboardCommand]) -> [KeyboardCommand] {
        commands.reduce(into: [KeyboardCommand]()) { partialResult, command in
            guard isModifierCommand(command), !partialResult.contains(command) else { return }
            partialResult.append(command)
        }
    }

    private func isModifierCommand(_ command: KeyboardCommand) -> Bool {
        switch command {
        case .command, .option, .control, .shift, .function:
            return true
        default:
            return false
        }
    }

    private func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
        switch keyCode {
        case 54, 55, 56, 60, 58, 61, 59, 62, 63:
            return true
        default:
            return false
        }
    }

    private func eventFlags(for commands: [KeyboardCommand]) -> CGEventFlags {
        var flags: CGEventFlags = []

        if commands.contains(.command) {
            flags.insert(.maskCommand)
        }

        if commands.contains(.shift) {
            flags.insert(.maskShift)
        }

        if commands.contains(.option) {
            flags.insert(.maskAlternate)
        }

        if commands.contains(.control) {
            flags.insert(.maskControl)
        }

        return flags
    }

    private func eventFlags(forKeyCodes keyCodes: [CGKeyCode]) -> CGEventFlags {
        keyCodes.reduce(into: CGEventFlags()) { flags, keyCode in
            if let flag = eventFlag(forModifierKeyCode: keyCode) {
                flags.insert(flag)
            }
        }
    }

    private func eventFlag(forModifierKeyCode keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 54, 55:
            return .maskCommand
        case 56, 60:
            return .maskShift
        case 58, 61:
            return .maskAlternate
        case 59, 62:
            return .maskControl
        default:
            return nil
        }
    }

    private func keyCode(for command: KeyboardCommand) -> CGKeyCode? {
        switch command {
        case .backspace:
            return 51
        case .delete:
            return 51
        case .forwardDelete:
            return 117
        case .enter:
            return 36
        case .returnKey:
            return 36
        case .space:
            return 49
        case .tab:
            return 48
        case .escape:
            return 53
        case .leftArrow:
            return 123
        case .rightArrow:
            return 124
        case .upArrow:
            return 126
        case .downArrow:
            return 125
        case .home:
            return 115
        case .end:
            return 119
        case .pageUp:
            return 116
        case .pageDown:
            return 121
        case .command:
            return 55
        case .option:
            return 58
        case .control:
            return 59
        case .shift:
            return 56
        case .function:
            return 63
        case .f1:
            return 122
        case .f2:
            return 120
        case .f3:
            return 99
        case .f4:
            return 118
        case .f5:
            return 96
        case .f6:
            return 97
        case .f7:
            return 98
        case .f8:
            return 100
        case .f9:
            return 101
        case .f10:
            return 109
        case .f11:
            return 103
        case .f12:
            return 111
        }
    }

    private func postKeyCode(_ keyCode: CGKeyCode) {
        postKeyCode(keyCode, keyDown: true)
        postKeyCode(keyCode, keyDown: false)
    }

    @discardableResult
    private func postKeyCode(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags = []) -> Bool {
        // Never release a local key that this session did not successfully post.
        // Unicode has its own private source and is deliberately tracked separately.
        guard keyDown || heldKeyCodes.contains(keyCode) else { return false }
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else { return false }
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown) else { return false }
        var nextHeldKeys = heldKeyCodes
        if keyDown { nextHeldKeys.insert(keyCode) } else { nextHeldKeys.remove(keyCode) }
        let heldFlags = eventFlags(forKeyCodes: Array(nextHeldKeys))
        var effectiveFlags = flags.union(heldFlags)
        if !keyDown, let releasedFlag = eventFlag(forModifierKeyCode: keyCode), !heldFlags.contains(releasedFlag) {
            effectiveFlags.remove(releasedFlag)
        }
        event.flags = effectiveFlags
        return postEvent(event, beforePost: { self.heldKeyCodes = nextHeldKeys })
    }
}
