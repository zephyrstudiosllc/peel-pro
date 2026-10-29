import CoreGraphics

@main
struct KeyboardUnicodeChecks {
    static func read(_ event: CGEvent) -> [UniChar] {
        var count = 0
        var units = [UniChar](repeating: 0, count: 4)
        units.withUnsafeMutableBufferPointer { buffer in
            event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                actualStringLength: &count, unicodeString: buffer.baseAddress)
        }
        precondition(count <= units.count)
        return Array(units.prefix(count))
    }

    static func main() {
        // Expected UTF-16 is explicit, independent of the conversion under test.
        let cases: [(UInt32, [UniChar])] = [
            (0x41, [0x0041]), (0xe9, [0x00e9]), (0x301, [0x0301]),
            (0x4e2d, [0x4e2d]), (0xffff, [0xffff]),
            (0x10000, [0xd800, 0xdc00]), (0x1f600, [0xd83d, 0xde00]),
            (0x1f3fd, [0xd83c, 0xdffd]), (0x10ffff, [0xdbff, 0xdfff])]
        for (value, expected) in cases {
            guard let scalar = UnicodeScalar(value),
                  let events = PeelKeyboardEventFactory.unicodeEvents(for: scalar) else {
                fatalError("Could not create Unicode events for \(value)")
            }
            precondition(events.down.type == .keyDown && events.up.type == .keyUp)
            let sourceID = events.down.getIntegerValueField(.eventSourceStateID)
            precondition(sourceID != Int64(CGEventSourceStateID.hidSystemState.rawValue) &&
                sourceID != Int64(CGEventSourceStateID.combinedSessionState.rawValue),
                "Default Unicode events must use private state")
            precondition(events.up.getIntegerValueField(.eventSourceStateID) == sourceID)
            precondition(read(events.down) == expected, "Key-down Unicode mismatch: \(value)")
            precondition(read(events.up) == expected, "Key-up Unicode mismatch: \(value)")
        }
        let source = CGEventSource(stateID: .privateState)!
        source.userData = 217
        for value: UInt32 in [0x41, 0x1f600] {
            let events = PeelKeyboardEventFactory.unicodeEvents(for: UnicodeScalar(value)!, source: source)!
            for event in [events.down, events.up] {
                precondition(event.getIntegerValueField(.eventSourceStateID) == Int64(source.sourceStateID.rawValue),
                    "Explicit source identity must survive both halves and successive scalars")
                precondition(event.getIntegerValueField(.eventSourceUserData) == 217)
            }
        }
        print("KeyboardUnicodeChecks: PASS (9 native CGEvent round trips, private default and retained explicit source; no events posted)")
    }
}
