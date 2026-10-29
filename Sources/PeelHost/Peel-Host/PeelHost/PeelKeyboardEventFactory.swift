import CoreGraphics

/// Creates events without posting them, so Unicode serialization can be checked
/// without sending input to the user's active application.
nonisolated enum PeelKeyboardEventFactory {
    /// Conservative per-event UTF-16 bound for CGEventKeyboardSetUnicodeString.
    static let maximumUnicodeStringLength = 20

    static func unicodeEvents(for scalar: UnicodeScalar,
                              source: CGEventSource? = nil) -> (down: CGEvent, up: CGEvent)? {
        unicodeEvents(for: [scalar][...], source: source)
    }

    /// One down/up pair carrying whole scalars, at most `maximumUnicodeStringLength` UTF-16 units.
    static func unicodeEvents(for scalars: ArraySlice<UnicodeScalar>,
                              source: CGEventSource? = nil) -> (down: CGEvent, up: CGEvent)? {
        // CoreGraphics consumes UTF-16 code units, not a truncated scalar value.
        // Supplementary characters (including emoji) require a surrogate pair.
        let units = Array(String(String.UnicodeScalarView(scalars)).utf16)
        guard !units.isEmpty, units.count <= maximumUnicodeStringLength,
              let source = source ?? CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        return (down, up)
    }

    /// End of the run starting at `start`: whole non-control scalars within the
    /// UTF-16 limit. A control scalar always forms its own single-scalar run.
    static func unicodeRunEnd(in scalars: [UnicodeScalar], from start: Int) -> Int {
        var end = start, units = 0
        while end < scalars.count, scalars[end].properties.generalCategory != .control || end == start {
            let width = UTF16.width(scalars[end])
            guard units + width <= maximumUnicodeStringLength else { break }
            units += width
            end += 1
            if scalars[end - 1].properties.generalCategory == .control { break }
        }
        return end
    }

    static func unicodeRunCount(_ text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        var index = 0, runs = 0
        while index < scalars.count { index = unicodeRunEnd(in: scalars, from: index); runs += 1 }
        return runs
    }
}
