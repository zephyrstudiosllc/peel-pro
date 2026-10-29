// Compiled with the existing focus/window stubs and the real InputSynthesizer.
final class TextTestClock {
    var now: TimeInterval = 0
    var scheduledDelays: [TimeInterval] = []
    var pending: [(TimeInterval, DispatchWorkItem)] = []
    func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        scheduledDelays.append(delay)
        pending.append((now + delay, work))
    }
    func advance(_ delta: TimeInterval) {
        let target = now + delta
        while let next = pending.indices.filter({ pending[$0].0 <= target + 1e-9 })
            .min(by: { pending[$0].0 < pending[$1].0 }) {
            let (time, work) = pending.remove(at: next)
            now = max(now, time)
            if !work.isCancelled { work.perform() }
        }
        now = target
    }
    func fireActiveDeadline() {
        let index = pending.indices.first { pending[$0].0 - now > 1 && !pending[$0].1.isCancelled }!
        let (time, work) = pending.remove(at: index)
        now = time
        work.perform()
    }
}

@main struct TextPacingChecks {
    static func main() async throws {
        let focus = AccessibilityManager()
        let clock = TextTestClock()
        var events: [(CGEvent, TimeInterval)] = []
        var allowed = true
        var generation: UInt64 = 9
        var resetDuringDown = false
        var tapViolations = 0
        var input: InputSynthesizer!
        input = InputSynthesizer(accessibility: focus, eventSink: { event, tap in
            events.append((event, clock.now))
            let stateID = event.getIntegerValueField(.eventSourceStateID)
            let expectedTap: CGEventTapLocation = (stateID != 0 && stateID != 1) ? .cgSessionEventTap : .cghidEventTap
            if tap != expectedTap { tapViolations += 1 }
            if event.type == .keyDown && resetDuringDown {
                resetDuringDown = false
                input.resetSessionState()
            }
        }, scheduleInputWork: clock.schedule)
        input.isRemoteControlAllowed = { allowed }
        input.isControlGenerationCurrent = { $0 == generation }
        input.activeWindowProvider = { 111 }
        func text(_ value: String) {
            input.withReceivedControlGeneration(generation) {
                input.handleKeyboardText(.init(text: value, windowId: 111))
            }
        }
        func pump() async throws { try await Task.sleep(nanoseconds: 2_000_000) }
        func clear() {
            input.resetSessionState(); events.removeAll()
            clock.pending.removeAll(); clock.scheduledDelays.removeAll()
            clock.now = 0; allowed = true; focus.ready = true
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { print("CHECK FAILURE: \(message)"); exit(1) }
        }
        func source(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.eventSourceStateID) }

        text("A"); text("B")
        try await pump()
        require(events.count == 1 && events[0].0.type == .keyDown, "first down is immediate")
        let sourceID = source(events[0].0)
        require(sourceID != 0 && sourceID != 1, "private Unicode source")
        clock.advance(0.0005)
        require(events.count == 1, "no early key up")
        clock.advance(0.0005)
        require(events.count == 2 && events[1].0.type == .keyUp, "up at first edge")
        try await pump()
        require(events.count == 2, "final gap retains operation across messages")
        clock.advance(0.001); try await pump()
        require(events.count == 3 && events[2].1 >= 0.002 - 1e-9, "next message respects trailing gap")
        clock.advance(0.002); try await pump()
        require(events.count == 4 && events.allSatisfy { source($0.0) == sourceID }, "retained source across messages")
        require(tapViolations == 0, "ordinary Unicode halves use session tap")

        clear(); text("A\n\u{8}😀")
        try await pump(); clock.advance(0.008); try await pump()
        require(events.map { $0.0.getIntegerValueField(.keyboardEventKeycode) } == [0,0,36,36,51,51,0,0],
            "control characters retain scalar order")
        require(events.enumerated().allSatisfy { $0.element.0.type == ($0.offset.isMultiple(of: 2) ? .keyDown : .keyUp) },
            "paced halves alternate")
        require(zip(events, events.dropFirst()).allSatisfy { $0.1.1 - $0.0.1 >= 0.001 - 1e-9 },
            "every text edge has its interval")

        for cancelText in [false, true] {
            clear()
            input.withReceivedControlGeneration(generation) {
                input.handleKeyboardHardwareKey(.init(windowId: 111, keyCode: 4, modifiers: [], action: .down))
            }
            try await pump(); text("A"); try await pump()
            if cancelText { generation += 1 }
            clock.advance(0.002); try await pump(); input.resetSessionState()
            require(events.count == 4 && events.allSatisfy { $0.0.getIntegerValueField(.keyboardEventKeycode) == 0 }
                && source(events[0].0) == 1 && source(events[3].0) != sourceID
                && source(events[1].0) == sourceID && source(events[2].0) == sourceID,
                "hardware-zero and Unicode cleanup retain distinct sources")
        }

        // Cancellation needs no separate reset callback to release its down.
        for losePermission in [false, true] {
            clear(); text("AB"); try await pump()
            if losePermission { allowed = false } else { generation += 1 }
            clock.advance(0.010); try await pump()
            require(events.count == 2 && events[1].0.type == .keyUp && source(events[1].0) == sourceID,
                "invalid delayed half cleans exact source once")
            input.resetSessionState()
            require(events.count == 2, "invalid-half cleanup idempotent")
        }

        clear(); text("AB"); try await pump()
        clock.advance(0.001); focus.ready = false; clock.advance(0.010); try await pump()
        require(events.count == 2, "focus loss prohibits later down")

        clear(); resetDuringDown = true; text("AB"); try await pump()
        require(events.count == 2 && events[1].0.type == .keyUp && source(events[1].0) == sourceID,
            "reentrant reset sees admitted held down")
        clock.advance(0.010); try await pump()
        require(events.count == 2, "reentrant reset cannot replay delayed up")

        clear(); text("OLD"); try await pump(); input.resetSessionState()
        clock.advance(0.0005); text("N"); try await pump()
        require(events.count == 3, "replacement starts after old cleanup")
        clock.advance(0.0005); try await pump()
        require(events.count == 3, "old callback cannot reset replacement")
        clock.advance(0.002); try await pump()
        require(events.count == 4 && events[3].0.type == .keyUp, "replacement completes independently")

        clear()
        input.withReceivedControlGeneration(generation) {
            input.handleKeyboardMacro(.init(windowId: 111, steps: [.text("AB"), .key(.init(command: .enter))]))
            input.handleKeyboardCommand(.init(command: .tab, windowId: 111))
        }
        try await pump(); clock.advance(0.003); try await pump()
        require(events.count == 4, "macro owns final text gap")
        clock.advance(0.001); try await pump(); try await pump()
        require(events.map { $0.0.getIntegerValueField(.keyboardEventKeycode) } == [0,0,0,0,36,36,48,48],
            "macro text and later commands remain serialized")
        require(events[4].1 == events[5].1 && events[6].1 == events[7].1,
            "direct command timing is unchanged")

        clear(); text("AB"); text("DEPENDENT"); try await pump()
        clock.fireActiveDeadline()
        require(events.count == 2 && events[1].0.type == .keyUp && source(events[1].0) == sourceID,
            "deadline releases held Unicode through exact source")
        text("N"); try await pump()
        require(events.count == 3, "new text starts after deadline cancellation")
        clock.advance(0.002); try await pump()
        require(events.count == 4 && events[3].0.type == .keyUp,
            "expired callbacks and dependent queue cannot disturb replacement")

        clear(); text(String(repeating: "x", count: 65_536)); try await pump()
        require(clock.scheduledDelays.contains { abs($0 - 141.072) < 1e-9 }, "full admitted ASCII has bounded pacing budget")
        input.resetSessionState(); clock.advance(142); try await pump()
        require(events.count == 2, "full admitted text cancellation stops pending work")
        clear()
        input.withReceivedControlGeneration(generation) {
            input.handleKeyboardMacro(.init(windowId: 111, steps: [.text(String(repeating: "x", count: 65_536)),
                .delayMilliseconds(10_000)]))
        }
        try await pump()
        require(clock.scheduledDelays.contains { abs($0 - 151.072) < 1e-9 }, "macro budget includes declared delays")

        clear(); text(String(repeating: "x", count: 65_536))
        input.withReceivedControlGeneration(generation) {
            input.handleKeyboardCommand(.init(command: .tab, windowId: 111))
        }
        try await pump(); clock.advance(131.0711); try await pump()
        require(events.count == 131_072 && events.enumerated().allSatisfy {
            $0.element.0.type == ($0.offset.isMultiple(of: 2) ? .keyDown : .keyUp)
                && source($0.element.0) == sourceID
        }, "full admitted ASCII completes every half before final gap")
        clock.advance(0.0009); try await pump()
        require(events.count == 131_074 && events.suffix(2).allSatisfy {
            $0.0.getIntegerValueField(.keyboardEventKeycode) == 48
        }, "full admitted text completes before queued command")
        clear(); text(String(repeating: "x", count: 65_537)); try await pump()
        require(events.isEmpty && clock.scheduledDelays.isEmpty, "oversize remains rejected before partial effect")
        require(InputSynthesizer.textExecutionDeadline(scalarCount: 16_384) == 42.768,
            "supplementary scalars count once in budget")
        require(tapViolations == 0, "all Unicode cleanup uses session tap and controls retain HID tap")

        // Local-computer agent text: bounded runs per down/up, reconstructed from the sink.
        let localGeneration = InputSynthesizer.localControlGenerationFlag | 5
        var localAllowed = true, localReady = true, eventGate = true, gatedEvents = 0
        var receipt: (posted: Int, finished: Bool)?
        input.isLocalControlAllowed = { localAllowed }
        input.isLocalWindowReadyForInput = { _, _ in localReady }
        input.isControlGenerationCurrent = { $0 == generation || $0 == localGeneration }
        func unicode(_ event: CGEvent) -> [UniChar] {
            var count = 0
            var units = [UniChar](repeating: 0, count: 64)
            units.withUnsafeMutableBufferPointer { buffer in
                event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                    actualStringLength: &count, unicodeString: buffer.baseAddress)
            }
            return Array(units.prefix(count))
        }
        // Each key down as typed text; control keys by their key code.
        func typed() -> [String] {
            events.filter { $0.0.type == .keyDown }.map { event in
                switch event.0.getIntegerValueField(.keyboardEventKeycode) {
                case 36: return "<enter>"
                case 51: return "<delete>"
                default: return String(utf16CodeUnits: unicode(event.0), count: unicode(event.0).count)
                }
            }
        }
        func agentText(_ value: String) async throws {
            clear(); localAllowed = true; localReady = true; eventGate = true; gatedEvents = 0; receipt = nil
            require(input.performAgentOperation(controlGeneration: localGeneration, operationID: UUID(),
                allowed: { localAllowed }, eventAllowed: { _ in gatedEvents += 1; return eventGate },
                completion: { receipt = ($0, $1) }, perform: { $0.handleKeyboardText(.init(text: value, windowId: 111)) }),
                "local agent text admitted")
            try await pump()
        }
        func settle() async throws { for _ in 0..<64 { clock.advance(0.001); try await pump() } }

        let crossing = "ABCDEFGHIJKLMNOPQRS😀Z"
        try await agentText(crossing); try await settle()
        require(typed() == ["ABCDEFGHIJKLMNOPQRS", "😀Z"], "runs end before a surrogate pair would exceed 20 units: \(typed())")
        require(events.count == 4 && gatedEvents == 4, "each posted half passes the event authority gate")
        require(stride(from: 0, to: events.count, by: 2).allSatisfy {
            events[$0].0.type == .keyDown && events[$0 + 1].0.type == .keyUp && unicode(events[$0].0) == unicode(events[$0 + 1].0)
        }, "each run is one matching down/up pair")
        require(receipt?.finished == true && receipt?.posted == 4
            && PeelKeyboardEventFactory.unicodeRunCount(crossing) * 2 == 4, "local receipt minimum matches posted runs")

        let mixed = "PEEL-MCP-232-OK é中👍🏽\tab\ncd\u{8}" + String(repeating: "x", count: 25)
        try await agentText(mixed); try await settle()
        // Whole scalars only: a modifier scalar may begin the next run, a surrogate pair never splits.
        require(typed() == ["PEEL-MCP-232-OK é中👍", "🏽", "\t", "ab", "<enter>", "cd", "<delete>",
                            String(repeating: "x", count: 20), "xxxxx"], "Unicode and control semantics retained: \(typed())")
        require(events.allSatisfy { unicode($0.0).count <= 20 } && receipt?.finished == true, "all runs bounded and complete")

        // Authority, focus or event-gate loss between runs releases nothing extra and posts no later payload.
        for loss in ["authority", "focus", "event"] {
            try await agentText(String(repeating: "a", count: 60))
            clock.advance(0.001); try await pump()
            require(events.count == 2 && typed() == [String(repeating: "a", count: 20)], "first run posted (\(loss))")
            switch loss { case "authority": localAllowed = false; case "focus": localReady = false; default: eventGate = false }
            try await settle()
            // posted 2 < the receipt minimum of 6, so the operation reports interrupted.
            require(events.count == 2 && receipt?.posted == 2 && (loss == "event" || receipt?.finished == false),
                "no later run after \(loss) loss: \(typed())")
        }
        // Loss while a run is held releases only that held key.
        try await agentText(String(repeating: "a", count: 60))
        localAllowed = false; try await settle()
        require(events.count == 2 && events[1].0.type == .keyUp && unicode(events[1].0) != unicode(events[0].0)
            && source(events[1].0) == source(events[0].0) && receipt?.finished == false, "held run released once, no payload")

        // Paired-stream text keeps one scalar per down/up.
        clear(); text(crossing); try await pump(); try await settle()
        require(typed() == crossing.unicodeScalars.map { String($0) }, "paired text unchanged: \(typed())")
        print("TextPacingChecks: PASS (virtual clock, delayed halves, focus, cancellation, source, ordering, admitted bounds, local agent Unicode runs; no events posted)")
    }
}
