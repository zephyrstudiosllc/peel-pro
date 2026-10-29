import Foundation
import AppKit
import ApplicationServices

// The real InputSynthesizer and wire types are compiled into this process.
// Only window resolution/focus and the event destination are replaced. No event
// is posted and no application is activated by these checks.
final class AccessibilityManager {
    var sendInputRejected: ((UInt32, String) -> Void)?
    var holdFocus = false
    var ready = true
    var completions: [() -> Void] = []
    func bringWindowToFront(windowId: UInt32, interactionPoint: CGPoint? = nil, completion: @escaping () -> Void) {
        if holdFocus { completions.append(completion) } else { completion() }
    }
    func isWindowReadyForInput(windowId: UInt32, interactionPoint: CGPoint?) -> Bool { ready }
    func authoritativePointFallback(for windowId: UInt32) -> CGPoint? { CGPoint(x: 100, y: 100) }
    func completeFocus() {
        let pending = completions; completions.removeAll()
        for completion in pending { completion() }
    }
}

enum WindowEnumerator {
    static var geometryAvailable = true
    static var geometryLookups = 0
    struct Geometry {
        func screenPoint(normX: Double, normY: Double) -> CGPoint { CGPoint(x: normX * 1000, y: normY * 1000) }
    }
    static func inputGeometry(for windowId: UInt32) -> Geometry? {
        geometryLookups += 1
        return geometryAvailable ? Geometry() : nil
    }
    static func isDisplayCaptureWindowId(_ windowId: UInt32) -> Bool { false }
}

// Compile the exact production cancel method into a minimal owner fixture;
// capture/input lifetime are exercised against the real InputSynthesizer below.
final class AgentCancellationOwnerFixture {
    struct Leases { mutating func clear() {} }
    var operation: UUID?
    var inputOperation: UUID?
    var leases = Leases()
    var onStatus: (String) -> Void = { _ in }
    /* PRODUCTION_AGENT_CANCEL */
}

@main
struct InputLifetimeChecks {
    static func main() async throws {
        let focus = AccessibilityManager()
        var events: [CGEvent] = []
        var allowed = true
        var controlGeneration: UInt64? = 7
        var replaceAfterNextEvent = false
        var replaceAfterNextValidation = false
        let input = InputSynthesizer(accessibility: focus, eventSink: { event, _ in
            events.append(event)
            if replaceAfterNextEvent {
                controlGeneration = (controlGeneration ?? 0) + 1; replaceAfterNextEvent = false
            }
        })
        input.isRemoteControlAllowed = { allowed }
        input.isControlGenerationCurrent = { requested in
            let current = requested == controlGeneration
            if replaceAfterNextValidation {
                controlGeneration = (controlGeneration ?? 0) + 1; replaceAfterNextValidation = false
            }
            return current
        }
        input.activeWindowProvider = { 1 }
        var markedInputs = 0
        input.markInput = { _ in markedInputs += 1 }
        func admit(_ body: () -> Void) {
            input.withReceivedControlGeneration(controlGeneration, perform: body)
        }
        func settle(_ milliseconds: UInt64 = 20) async throws {
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }
        func waitForEventCount(_ expected: Int) async throws {
            for _ in 0..<100 {
                if events.count >= expected { return }
                try await settle(10)
            }
        }

        // The old line passed its initial network check, then the connection
        // advanced during synchronous decoding before input admission.
        let receivedGeneration = controlGeneration!
        precondition(input.isControlGenerationCurrent(receivedGeneration))
        controlGeneration = receivedGeneration + 1
        input.withReceivedControlGeneration(receivedGeneration) {
            input.performMouseMove(windowId: 1, normX: 0.1, normY: 0.2)
            input.performScroll(windowId: 1, deltaX: 1.5, deltaY: 0)
            input.handleKeyboardCommand(.init(command: .enter, windowId: 1))
        }
        try await settle()
        precondition(events.isEmpty && markedInputs == 0 && focus.completions.isEmpty,
            "Received generation cannot be replaced with the live generation during admission")
        input.performMouseMove(windowId: 1, normX: 0.1, normY: 0.2)
        try await settle()
        precondition(events.isEmpty && markedInputs == 0, "Input outside a received-session context must fail closed")
        input.withReceivedControlGeneration(controlGeneration) {
            input.resetSessionState()
            input.performMouseMove(windowId: 1, normX: 0.1, normY: 0.2)
        }
        try await settle()
        precondition(events.isEmpty && markedInputs == 0, "Routing context retains the local generation too")

        admit { input.performMouseMove(windowId: 1, normX: 0.1, normY: 0.2) }
        input.resetSessionState()
        try await settle()
        precondition(events.isEmpty, "Already queued events must be cancelled by session replacement")

        admit { input.performScroll(windowId: 1, deltaX: 1.5, deltaY: 0) }
        input.resetSessionState()
        admit { input.performScroll(windowId: 1, deltaX: 0.5, deltaY: 0) }
        try await settle()
        precondition(events.isEmpty, "Old queued fractional scroll cannot seed the new session")
        input.resetSessionState()

        admit { input.performMouseMove(windowId: 1, normX: 0.1, normY: 0.2) }
        admit { input.performScroll(windowId: 1, deltaX: 1.5, deltaY: 0) }
        controlGeneration = (controlGeneration ?? 0) + 1 // Network advances before the main reset callback.
        try await settle()
        admit { input.performScroll(windowId: 1, deltaX: 0.5, deltaY: 0) }
        try await settle()
        precondition(events.isEmpty, "Actual control identity must reject old input before the main reset runs")
        input.resetSessionState()
        admit { input.performScroll(windowId: 1, deltaX: 1.5, deltaY: 0) }
        replaceAfterNextValidation = true
        try await settle()
        admit { input.performScroll(windowId: 1, deltaX: 0.5, deltaY: 0) }
        try await settle()
        precondition(events.isEmpty, "Residuals must belong to their actual control generation even across a concurrent transition")
        input.resetSessionState()

        focus.holdFocus = true; focus.ready = false
        admit { input.performClick(windowId: 1, normX: 0.1, normY: 0.2) }
        admit { input.handleKeyboardText(.init(text: "fixture", windowId: 1)) }
        admit { input.handleKeyboardCommand(.init(command: .enter, windowId: 1)) }
        admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 40, modifiers: [])) }
        admit { input.handleKeyboardChord(.init(windowId: 1, chord: .init(keys: [.command, .f1]))) }
        try await settle()
        precondition(focus.completions.count == 1, "Only the receive-order head may request focus")
        input.resetSessionState()
        focus.completeFocus()
        try await settle(60)
        precondition(events.isEmpty, "Late focus completions cannot inject into a replacement session")

        admit { input.performMouseDown(windowId: 1, normX: 0.1, normY: 0.2) }
        admit { input.handleKeyboardCommand(.init(command: .enter, windowId: 1)) }
        try await settle()
        precondition(focus.completions.count == 1)
        controlGeneration = (controlGeneration ?? 0) + 1
        focus.completeFocus()
        try await settle(60)
        precondition(events.isEmpty, "Old focus callbacks must check network identity without relying on main reset")

        focus.holdFocus = false; focus.ready = true
        replaceAfterNextEvent = true
        admit { input.performClick(windowId: 1, normX: 0.1, normY: 0.2) }
        try await settle(60)
        precondition(events.count == 1 && events[0].type == .leftMouseDown,
            "Each emitted event must revalidate identity, including the second half of a click")
        input.resetSessionState()
        precondition(events.count == 2 && events[1].type == .leftMouseUp,
            "Cleanup must release the admitted first half after session invalidation")
        events.removeAll()

        replaceAfterNextEvent = true
        admit { input.handleKeyboardText(.init(text: "AB", windowId: 1)) }
        try await waitForEventCount(2)
        precondition(events.count == 2 && events[0].type == .keyDown && events[1].type == .keyUp,
            "Text bursts must stop and release their admitted down when network identity changes")
        let unicodeSourceID = events[0].getIntegerValueField(.eventSourceStateID)
        precondition(unicodeSourceID != Int64(CGEventSourceStateID.hidSystemState.rawValue) &&
            unicodeSourceID != Int64(CGEventSourceStateID.combinedSessionState.rawValue),
            "Unicode must use an independent private source")
        allowed = false
        input.resetSessionState()
        precondition(events.count == 2 && events[1].type == .keyUp &&
            events[1].getIntegerValueField(.eventSourceStateID) == unicodeSourceID,
            "Disabled-session cleanup must release interrupted text using its exact private source")
        input.resetSessionState()
        precondition(events.count == 2, "Private-source cleanup is idempotent")
        events.removeAll(); allowed = true

        admit { input.handleKeyboardText(.init(text: "AB", windowId: 1)) }
        try await waitForEventCount(4)
        precondition(events.count == 4 && events.allSatisfy {
            $0.getIntegerValueField(.eventSourceStateID) == unicodeSourceID
        }, "Successive scalars and a new control generation retain one private source")
        input.resetSessionState()
        precondition(events.count == 4, "Complete Unicode pairs leave no held state")

        // A hardware A and a Unicode scalar share virtual key zero but not state.
        for cancelText in [false, true] {
            events.removeAll()
            admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
                modifiers: [], action: .down)) }
            try await settle()
            precondition(events.count == 1 && events[0].type == .keyDown &&
                events[0].getIntegerValueField(.keyboardEventKeycode) == 0)
            replaceAfterNextEvent = cancelText
            admit { input.handleKeyboardText(.init(text: "A", windowId: 1)) }
            try await waitForEventCount(cancelText ? 4 : 3)
            precondition(events.count == (cancelText ? 4 : 3),
                "Unicode completion or cancellation must not erase hardware key-zero cleanup")
            input.resetSessionState()
            precondition(events.count == 4 && events.last!.type == .keyUp &&
                events.last!.getIntegerValueField(.keyboardEventKeycode) == 0 &&
                events.last!.getIntegerValueField(.eventSourceStateID) != unicodeSourceID,
                "Unicode completion or cancellation must not erase hardware key-zero cleanup")
            precondition(events[2].type == .keyUp &&
                events[2].getIntegerValueField(.eventSourceStateID) == unicodeSourceID,
                "Canceled and completed text must each release their private key state")
            input.resetSessionState()
            precondition(events.count == 4, "Mixed-source cleanup is idempotent")
        }
        events.removeAll()

        focus.holdFocus = false
        admit { input.performMouseDown(windowId: 1, normX: 0.1, normY: 0.2, button: "middle") }
        try await settle(60)
        precondition(events.count == 1 && events[0].type == .otherMouseDown)
        admit { input.performMouseDragged(windowId: 1, normX: 0.2, normY: 0.3, button: "middle") }
        try await settle()
        precondition(events.count == 2 && events[1].type == .otherMouseDragged)
        allowed = false
        input.resetSessionState()
        precondition(events.count == 3 && events[2].type == .otherMouseUp &&
            events[2].getIntegerValueField(.mouseEventButtonNumber) == 2,
            "Disabling input still releases the session's actually posted button")
        input.resetSessionState()
        precondition(events.count == 3, "Cleanup is idempotent")

        events.removeAll(); allowed = true
        admit { input.handleKeyboardCommand(.init(command: .command, windowId: 1, action: .down)) }
        admit { input.handleKeyboardCommand(.init(command: .enter, windowId: 1, action: .down)) }
        try await settle()
        precondition(events.count == 2 && events[0].type == .flagsChanged && events[1].type == .keyDown)
        precondition(events.allSatisfy { $0.flags.contains(.maskCommand) }, "Held modifiers must remain present on subsequent keys")
        allowed = false
        input.resetSessionState()
        precondition(events.count == 4 && events[2].type == .keyUp && events[3].type == .flagsChanged)
        precondition(events[2].getIntegerValueField(.keyboardEventKeycode) == 36 &&
            events[3].getIntegerValueField(.keyboardEventKeycode) == 55,
            "Release ordinary keys before modifiers")
        precondition(events[2].flags.contains(.maskCommand) && events[3].flags.isEmpty)

        events.removeAll(); allowed = true
        admit { input.handleKeyboardCommand(.init(command: .command, windowId: 1, action: .down)) }
        try await settle()
        admit { input.handleKeyboardChord(.init(windowId: 1, chord: .init(keys: [.command, .shift, .f1]))) }
        admit { input.handleKeyboardCommand(.init(command: .f2, windowId: 1, modifiers: [.command])) }
        try await settle()
        precondition(events.count == 7 && events.allSatisfy { $0.flags.contains(.maskCommand) },
            "Temporary chords/modified presses must preserve an already held Command key")
        admit { input.handleKeyboardCommand(.init(command: .command, windowId: 1, modifiers: [.command], action: .up)) }
        try await settle()
        precondition(events.count == 8 && events.last!.flags.isEmpty,
            "A released modifier cannot survive through stale modifier flags on its up message")
        input.resetSessionState()
        precondition(events.count == 8, "A normally released modifier needs no extra cleanup event")

        events.removeAll(); allowed = true; focus.ready = false
        admit { input.handleKeyboardCommand(.init(command: .enter, windowId: 1)) }
        try await settle()
        input.resetSessionState(); focus.ready = true
        try await settle(80)
        precondition(events.isEmpty, "Readiness retries must retain the original generation")
        admit { input.performMouseMove(windowId: 1, normX: 0.2, normY: 0.3) }
        try await settle()
        precondition(events.count == 1 && events[0].type == .mouseMoved, "Fresh input remains usable after cancellation")
        events.removeAll(); input.resetSessionState()
        focus.holdFocus = true; focus.ready = false
        admit {
            input.performMouseDown(windowId: 1, normX: 0.1, normY: 0.1)
            input.performMouseDragged(windowId: 1, normX: 0.2, normY: 0.2)
            input.performMouseUp(windowId: 1, normX: 0.3, normY: 0.3)
        }
        try await settle()
        precondition(events.isEmpty && focus.completions.count == 1,
            "Drag and release cannot overtake a down waiting for focus")
        focus.ready = true; focus.completeFocus()
        try await settle()
        precondition(events.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        input.resetSessionState()
        precondition(events.count == 3, "Normal down/drag/up must leave no held button")

        events.removeAll(); focus.ready = false
        admit {
            input.handleKeyboardCommand(.init(command: .enter, windowId: 1, action: .down))
            input.handleKeyboardCommand(.init(command: .enter, windowId: 1, action: .up))
        }
        try await settle()
        precondition(events.isEmpty && focus.completions.count == 1)
        let oldCompletion = focus.completions[0]
        focus.ready = true; focus.completeFocus()
        try await settle()
        oldCompletion() // A duplicated late completion cannot replay or finish new input.
        try await settle()
        precondition(events.map(\.type) == [.keyDown, .keyUp])
        input.resetSessionState()
        precondition(events.count == 2)

        // Motion is latest-adjacent-only; no button boundary may be crossed.
        events.removeAll(); focus.ready = false
        admit { input.performMouseDown(windowId: 1, normX: 0.1, normY: 0.1) }
        try await settle()
        for n in 1...3 {
            admit { input.performMouseDragged(windowId: 1, normX: Double(n) / 10, normY: 0.2) }
        }
        admit { input.performMouseUp(windowId: 1, normX: 0.6, normY: 0.2) }
        for n in 1...500 {
            admit { input.performMouseMove(windowId: 1, normX: Double(n) / 1000, normY: 0.2) }
        }
        focus.ready = true; focus.completeFocus()
        try await settle()
        precondition(events.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseDragged, .leftMouseUp, .mouseMoved])
        precondition(events.map(\.location.x) == [100, 100, 200, 300, 600, 500], "Drag paths stay intact; only adjacent hover collapses")

        // Atomic macro delays hold the input sequence while allowing the main
        // actor to run and release its held modifier immediately on cancellation.
        events.removeAll(); focus.holdFocus = false
        var heartbeatBeforeDelayFinished = false
        admit { input.handleKeyboardMacro(.init(windowId: 1, steps: [
            .key(.init(command: .command, action: .down)), .delayMilliseconds(200),
            .key(.init(command: .enter)), .key(.init(command: .command, action: .up))], executeAtomically: true)) }
        admit { input.handleKeyboardCommand(.init(command: .tab, windowId: 1)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            heartbeatBeforeDelayFinished = events.count == 1
        }
        try await settle(60)
        precondition(heartbeatBeforeDelayFinished && events.count == 1 && events[0].type == .flagsChanged,
            "A macro delay must not block the main actor or interleave queued Tab")
        input.resetSessionState()
        precondition(events.count == 2 && events[1].type == .flagsChanged && events[1].flags.isEmpty)
        try await settle(180)
        precondition(events.count == 2, "Cancelled macro and queued input cannot resume after their delay")

        events.removeAll()
        admit { input.handleKeyboardMacro(.init(windowId: 1, steps: [
            .key(.init(command: .enter)), .delayMilliseconds(50), .key(.init(command: .f1))], executeAtomically: true)) }
        admit { input.handleKeyboardCommand(.init(command: .tab, windowId: 1)) }
        try await settle(100)
        precondition(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [36, 36, 122, 122, 48, 48],
            "Queued keys follow the whole macro in receive order")

        // Focus timeout invalidates old continuations without letting their
        // completion release a newer active operation.
        events.removeAll(); focus.holdFocus = true; focus.ready = false
        var rejections = 0
        focus.sendInputRejected = { _, _ in rejections += 1 }
        admit { input.performMouseDown(windowId: 1, normX: 0.1, normY: 0.1) }
        try await settle()
        let timedOutCompletion = focus.completions.removeFirst()
        try await settle(1050)
        precondition(events.isEmpty && rejections == 1)
        admit { input.handleKeyboardCommand(.init(command: .enter, windowId: 1)) }
        try await settle()
        timedOutCompletion()
        try await settle()
        precondition(events.isEmpty && focus.completions.count == 1)
        focus.ready = true; focus.completeFocus()
        try await settle()
        precondition(events.map(\.type) == [.keyDown, .keyUp], "New operation survives an old completion")
        input.resetSessionState()

        events.removeAll(); focus.ready = true; focus.holdFocus = true
        admit { input.performClick(windowId: 1, normX: 0.2, normY: 0.2) }
        try await settle()
        precondition(events.map(\.type) == [.leftMouseDown, .leftMouseUp] && focus.completions.isEmpty,
            "An already ready window skips activation and fixed focus settling")

        // Explicit bounded overflow releases held state instead of dropping an
        // arbitrary key-up while retaining a key-down.
        events.removeAll(); focus.holdFocus = false
        admit { input.handleKeyboardCommand(.init(command: .command, windowId: 1, action: .down)) }
        try await settle()
        focus.ready = false; focus.holdFocus = true
        admit { input.performMouseDown(windowId: 1, normX: 0.1, normY: 0.1) }
        try await settle()
        let rejectedBeforeOverflow = rejections
        for _ in 0..<129 { admit { input.handleKeyboardCommand(.init(command: .enter, windowId: 1)) } }
        precondition(rejections == rejectedBeforeOverflow + 1)
        precondition(events.map(\.type) == [.flagsChanged, .flagsChanged] && events.last!.flags.isEmpty)
        focus.ready = true; focus.completeFocus()
        try await settle()
        precondition(events.count == 2, "Overflow cancels the in-flight focus callback and queued commands")

        // A real readiness failure also cancels dependent input and releases
        // previously held state, without waiting for a disconnect.
        events.removeAll(); focus.holdFocus = false
        admit { input.handleKeyboardCommand(.init(command: .command, windowId: 1, action: .down)) }
        try await settle()
        focus.ready = false
        let rejectedBeforeFocus = rejections
        admit {
            input.handleKeyboardCommand(.init(command: .enter, windowId: 1, action: .down))
            input.handleKeyboardCommand(.init(command: .enter, windowId: 1, action: .up))
        }
        try await settle(400)
        precondition(rejections == rejectedBeforeFocus + 1)
        precondition(events.map(\.type) == [.flagsChanged, .flagsChanged] && events.last!.flags.isEmpty)

        events.removeAll(); focus.ready = true
        admit { input.handleKeyboardCommand(.init(command: .command, windowId: 1, action: .down)) }
        try await settle()
        let rejectedBeforeGeometry = rejections
        WindowEnumerator.geometryAvailable = false
        admit {
            input.performMouseDown(windowId: 1, normX: 0.1, normY: 0.1)
            input.performMouseDragged(windowId: 1, normX: 0.2, normY: 0.2)
            input.performMouseUp(windowId: 1, normX: 0.3, normY: 0.3)
            input.handleKeyboardCommand(.init(command: .enter, windowId: 1))
        }
        DispatchQueue.main.async { WindowEnumerator.geometryAvailable = true }
        try await settle()
        precondition(rejections == rejectedBeforeGeometry + 1, "Missing required geometry must reject and cancel pending input")
        precondition(events.map(\.type) == [.flagsChanged, .flagsChanged] && events.last!.flags.isEmpty,
            "Missing geometry cancels dependent drag/up/key even when geometry recovers before their pump, and releases held input")
        events.removeAll()
        let rejectedBeforeLimits = rejections
        admit { input.handleKeyboardText(.init(text: String(repeating: "x", count: 65_537), windowId: 1)) }
        admit { input.handleKeyboardMacro(.init(windowId: 1, steps: [.delayMilliseconds(Int.max)])) }
        admit { input.handleKeyboardMacro(.init(windowId: 1, steps: [.delayMilliseconds(-1)])) }
        admit { input.handleKeyboardMacro(.init(windowId: 1, steps: Array(repeating: .delayMilliseconds(0), count: 129))) }
        admit { input.handleKeyboardChord(.init(windowId: 1, chord: .init(keys: Array(repeating: .command, count: 33)))) }
        precondition(rejections == rejectedBeforeLimits + 5 && events.isEmpty,
            "Oversized text/chords/macros are explicitly rejected before any partial effect")

        var eventsAtMainTurn = -1
        admit { input.handleKeyboardText(.init(text: String(repeating: "😀", count: 200), windowId: 1)) }
        admit { input.handleKeyboardCommand(.init(command: .tab, windowId: 1)) }
        DispatchQueue.main.async { eventsAtMainTurn = events.count }
        for _ in 0..<100 {
            if events.count == 402 { break }
            try await settle(10)
        }
        precondition(eventsAtMainTurn > 0 && eventsAtMainTurn < 400, "Long text yields the main actor between chunks")
        precondition(events.count == 402 && events.suffix(2).allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 48 },
            "Text chunks preserve all characters and complete before later input")
        input.resetSessionState()
        events.removeAll(); focus.ready = true; focus.holdFocus = false
        let rejectedBeforeHardware = rejections
        let markedBeforeHardware = markedInputs
        for usage in [-1, 0, 70, 100, 102, 65_535, Int.max] {
            admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: usage, modifiers: [.command])) }
        }
        // A hardware message is one key. Never turn a composed/long character
        // payload into only its first scalar, especially with shortcut modifiers.
        for characters in ["ab", "a\u{0301}", "\r\n", "İ"] {
            admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 100,
                characters: characters, charactersIgnoringModifiers: characters, modifiers: [.command])) }
        }
        try await settle()
        precondition(rejections == rejectedBeforeHardware + 11 && events.isEmpty &&
            markedInputs == markedBeforeHardware && focus.completions.isEmpty,
            "Unmapped HID and multi-scalar payloads must explicitly reject without focus or unrelated shortcut events")

        let keypad: [(Int, String, Int64)] = [
            (83, "", 71), (84, "/", 75), (85, "*", 67), (86, "-", 78), (87, "+", 69),
            (88, "\r", 76), (89, "1", 83), (90, "2", 84), (91, "3", 85), (92, "4", 86),
            (93, "5", 87), (94, "6", 88), (95, "7", 89), (96, "8", 91), (97, "9", 92),
            (98, "0", 82), (99, ".", 65), (103, "=", 81)
        ]
        for (usage, characters, _) in keypad {
            admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: usage,
                characters: characters, charactersIgnoringModifiers: characters, modifiers: [])) }
        }
        try await settle()
        precondition(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } ==
            keypad.flatMap { [$0.2, $0.2] }, "Keypad HID identity must win over ordinary character mapping")
        precondition(events.enumerated().allSatisfy { $0.element.type == ($0.offset.isMultiple(of: 2) ? .keyDown : .keyUp) })
        input.resetSessionState()
        precondition(events.count == keypad.count * 2, "Normal hardware presses leave no held keys")

        events.removeAll()
        admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
            characters: "Q", charactersIgnoringModifiers: "q", modifiers: [])) }
        admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 80,
            characters: "<", charactersIgnoringModifiers: "<", modifiers: [])) }
        admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 100,
            characters: "\\", charactersIgnoringModifiers: "\\", modifiers: [])) }
        admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
            characters: "a\u{0301}", charactersIgnoringModifiers: "a\u{0301}", modifiers: [])) }
        try await settle()
        precondition(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [12,12,123,123,42,42,0,0],
            "Layout-aware single-character fallback, navigation priority and known physical-HID fallback remain supported")
        input.resetSessionState()
        // Inspection owns no input context. Cancelling it must leave an
        // ordinary free held key and its later Up entirely intact.
        events.removeAll()
        admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
            characters: "a", charactersIgnoringModifiers: "a", modifiers: [], action: .down)) }
        try await settle()
        precondition(events.count == 1 && events[0].type == .keyDown)
        let inspectionOwner = AgentCancellationOwnerFixture()
        inspectionOwner.operation = UUID()
        inspectionOwner.cancel(input: input, reason: "Pro withdrawn during inspection")
        precondition(events.count == 1, "Inspection cancellation must not release free held keys")
        admit { input.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
            characters: "a", charactersIgnoringModifiers: "a", modifiers: [], action: .up)) }
        try await settle()
        precondition(events.count == 2 && events[1].type == .keyUp)
        input.resetSessionState(); events.removeAll()

        // Queued agent work is removed by exact owner; subsequent ordinary
        // input remains in order and retains its current session generation.
        let queuedOwner = UUID(); var queuedCompletions = 0
        precondition(input.performAgentOperation(controlGeneration: controlGeneration!, operationID: queuedOwner,
            allowed: { true }, completion: { _, complete in queuedCompletions += 1; precondition(!complete) }) { synth in
                synth.handleKeyboardCommand(.init(command: .enter, windowId: 1))
            })
        admit { input.handleKeyboardCommand(.init(command: .tab, windowId: 1)) }
        input.cancelAgentOperation(operationID: queuedOwner)
        try await settle()
        precondition(queuedCompletions == 1 && events.count == 2 &&
            events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 48 },
            "Agent cancellation preserves ordinary queued Tab and completes once")
        input.cancelAgentOperation(operationID: queuedOwner)
        precondition(queuedCompletions == 1, "Repeated cancellation is exact and idempotent")
        input.resetSessionState(); events.removeAll()

        // A deterministic delayed drag owns the posted down. Cancel releases
        // only that down, preserves queued free input, and retires every late
        // drag/deadline callback before a normal held key is admitted.
        var ownedEvents: [CGEvent] = [], scheduled: [DispatchWorkItem] = []
        let ownedInput = InputSynthesizer(accessibility: focus, eventSink: { event, _ in ownedEvents.append(event) },
            scheduleInputWork: { _, work in scheduled.append(work) })
        ownedInput.isRemoteControlAllowed = { true }
        ownedInput.isControlGenerationCurrent = { $0 == 77 }
        ownedInput.activeWindowProvider = { 1 }
        let owner = UUID(); var ownedCompletions = 0
        precondition(ownedInput.performAgentOperation(controlGeneration: 77, operationID: owner,
            allowed: { true }, completion: { _, complete in ownedCompletions += 1; precondition(!complete) }) { synth in
                synth.performAgentDrag(windowId: 1, fromX: 0.1, fromY: 0.1, toX: 0.8, toY: 0.8)
            })
        try await settle()
        precondition(ownedEvents.count == 1 && ownedEvents[0].type == .leftMouseDown)
        ownedInput.withReceivedControlGeneration(77) {
            ownedInput.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
                characters: "a", charactersIgnoringModifiers: "a", modifiers: [], action: .down))
        }
        let inputOwner = AgentCancellationOwnerFixture(); inputOwner.operation = owner; inputOwner.inputOperation = owner
        inputOwner.cancel(input: ownedInput, reason: "Pro withdrawn during paid input")
        precondition(ownedEvents.count == 2 && ownedEvents[1].type == .leftMouseUp && ownedCompletions == 1)
        try await settle()
        precondition(ownedEvents.count == 3 && ownedEvents[2].type == .keyDown,
            "Ordinary free key remains queued after the paid drag")
        for work in scheduled { work.perform() }
        try await settle()
        precondition(ownedEvents.count == 3, "Late paid drag/deadline cannot release or modify the new free held key")
        ownedInput.cancelAgentOperation(operationID: UUID())
        precondition(ownedEvents.count == 3, "Unrelated owner cannot release free held state")
        ownedInput.withReceivedControlGeneration(77) {
            ownedInput.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
                characters: "a", charactersIgnoringModifiers: "a", modifiers: [], action: .up))
        }
        try await settle()
        precondition(ownedEvents.count == 4 && ownedEvents[3].type == .keyUp && ownedCompletions == 1)
        ownedInput.resetSessionState()
        // Expiry/failure can reach the agent callback before the Host's
        // explicit cancellation timer. The callback must retire only its owner.
        for mode in ["type-expiry", "drag-expiry", "agent-timeout", "drag-window-failure"] {
            var posted: [CGEvent] = [], delayed: [(TimeInterval, DispatchWorkItem)] = []
            var paidAllowed = true, completions = 0
            let scoped = InputSynthesizer(accessibility: focus, eventSink: { event, _ in posted.append(event) },
                scheduleInputWork: { delay, work in delayed.append((delay, work)) })
            scoped.isRemoteControlAllowed = { true }; scoped.isControlGenerationCurrent = { $0 == 88 }
            scoped.activeWindowProvider = { 1 }
            precondition(scoped.performAgentOperation(controlGeneration: 88, operationID: UUID(),
                allowed: { paidAllowed }, completion: { _, complete in completions += 1; precondition(!complete) }) { synth in
                    if mode == "type-expiry" { synth.handleKeyboardText(.init(text: "AB", windowId: 1)) }
                    else { synth.performAgentDrag(windowId: 1, fromX: 0.1, fromY: 0.1, toX: 0.8, toY: 0.8) }
                })
            try await settle()
            precondition(posted.count == 1, "Fixture must retain exactly the agent's owned down")
            scoped.withReceivedControlGeneration(88) {
                scoped.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
                    characters: "a", charactersIgnoringModifiers: "a", modifiers: [], action: .down))
            }
            if mode.hasSuffix("expiry") { paidAllowed = false }
            if mode == "drag-window-failure" { focus.ready = false }
            let boundary = delayed.first { mode == "agent-timeout" ? $0.0 >= 1 && !$0.1.isCancelled : $0.0 < 0.1 }
            precondition(boundary != nil); boundary!.1.perform()
            focus.ready = true
            try await settle()
            precondition(posted.count == 3 && posted[2].type == .keyDown && completions == 1,
                "\(mode) must release only the agent down and preserve queued free input without a timer-order assumption")
            for (_, work) in delayed { work.perform() }
            try await settle()
            precondition(posted.count == 3, "Late paid work must not release the now-held free key")
            scoped.withReceivedControlGeneration(88) {
                scoped.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4,
                    characters: "a", charactersIgnoringModifiers: "a", modifiers: [], action: .up))
            }
            try await settle()
            precondition(posted.count == 4 && posted[3].type == .keyUp && completions == 1)
            scoped.resetSessionState()
        }
        // Owned-input boundary regressions: the destination is only this array.
        // New isolated synthesizers keep these cases independent of prior fixtures.
        do {
            let ownershipFocus = AccessibilityManager()
            var posted: [CGEvent] = []
            var effects = 0
            let owned = InputSynthesizer(accessibility: ownershipFocus, eventSink: { event, _ in posted.append(event) })
            owned.isRemoteControlAllowed = { true }
            owned.isControlGenerationCurrent = { $0 == 99 }
            owned.activeWindowProvider = { 1 }
            owned.markInput = { _ in effects += 1 }
            owned.activeWindowSetter = { _ in effects += 1 }
            func receive(_ body: () -> Void) { owned.withReceivedControlGeneration(99, perform: body) }

            let lookupsBeforeOrphans = WindowEnumerator.geometryLookups
            for button in ["left", "right", "middle", "x1", "x2"] {
                receive {
                    owned.performMouseDragged(windowId: 1, normX: 0.2, normY: 0.3, button: button)
                    owned.performMouseUp(windowId: 1, normX: 0.2, normY: 0.3, button: button)
                }
            }
            try await settle(60)
            precondition(posted.isEmpty && effects == 0 && ownershipFocus.completions.isEmpty &&
                WindowEnumerator.geometryLookups == lookupsBeforeOrphans,
                "Unowned drag/up cannot resolve geometry, focus, mark input, or post any button")

            // All three messages arrive before the input pump runs: ownership
            // must be evaluated at execution, after the queued down really posts.
            receive {
                owned.performMouseDown(windowId: 1, normX: 0.1, normY: 0.2)
                owned.performMouseDragged(windowId: 1, normX: 0.2, normY: 0.3)
                owned.performMouseUp(windowId: 1, normX: 0.3, normY: 0.4)
                owned.performMouseUp(windowId: 1, normX: 0.4, normY: 0.5)
            }
            try await settle(60)
            precondition(posted.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp] && effects == 6,
                "Queued owned stroke remains ordered; duplicate up has no effect")
            owned.resetSessionState()
            precondition(posted.count == 3, "Completed stroke leaves no cleanup state")

            posted.removeAll(); effects = 0
            receive { owned.performMouseDown(windowId: 1, normX: 0.1, normY: 0.2, button: "right") }
            try await settle()
            let afterRightDown = effects
            receive {
                owned.performMouseDragged(windowId: 1, normX: 0.2, normY: 0.3, button: "left")
                owned.performMouseUp(windowId: 1, normX: 0.2, normY: 0.3, button: "left")
            }
            try await settle()
            precondition(posted.map(\.type) == [.rightMouseDown] && effects == afterRightDown,
                "Ownership of one button cannot authorize another button's drag/up")
            WindowEnumerator.geometryAvailable = false
            receive { owned.performMouseUp(windowId: 1, normX: 0.3, normY: 0.4, button: "right") }
            try await settle()
            precondition(posted.map(\.type) == [.rightMouseDown, .rightMouseUp] &&
                posted[1].location == posted[0].location,
                "An owned release retains its last-point fallback if geometry vanishes")
            WindowEnumerator.geometryAvailable = true
            owned.resetSessionState()

            posted.removeAll(); effects = 0
            ownershipFocus.ready = false; ownershipFocus.holdFocus = true
            for usage in [4, 40, 227, 231] {
                receive { owned.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: usage, modifiers: [], action: .up)) }
            }
            try await settle(60)
            precondition(posted.isEmpty && effects == 0 && ownershipFocus.completions.isEmpty,
                "Unowned hardware releases are ignored before focus/readiness side effects")
            ownershipFocus.ready = true; ownershipFocus.holdFocus = false
            receive {
                owned.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4, modifiers: [], action: .down))
                owned.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4, modifiers: [], action: .up))
                owned.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4, modifiers: [], action: .up))
            }
            try await settle(60)
            precondition(posted.map(\.type) == [.keyDown, .keyUp] && effects == 4,
                "A queued hardware down/up works once; duplicate hardware up is inert")
            owned.resetSessionState()
            precondition(posted.count == 2, "Completed hardware pair leaves no cleanup state")

            posted.removeAll(); effects = 0
            receive {
                owned.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4, modifiers: [], action: .up))
                owned.handleKeyboardHardwareKey(.init(windowId: 1, keyCode: 4, modifiers: [], action: .down))
            }
            try await settle(60)
            precondition(posted.map(\.type) == [.keyDown] && effects == 2,
                "An earlier orphan up cannot be authorized by a later queued down")
            owned.resetSessionState()
            precondition(posted.map(\.type) == [.keyDown, .keyUp],
                "Actually posted hardware state still releases during session cleanup")
        }

        print("InputLifetimeChecks: PASS (real synthesizer, received/operation generations, ordering, hardware mapping/rejection, nonblocking macros, cleanup; no events posted)")
    }
}
