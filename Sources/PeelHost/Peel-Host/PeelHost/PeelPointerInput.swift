import Foundation
import CoreGraphics

/// The same wire button names accepted by the Windows Host. Unknown names are
/// rejected instead of being converted into an unintended primary click.
nonisolated enum PeelMouseButton: String, CaseIterable, Sendable {
    case left, right, middle, x1, x2

    var nativeButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        // Quartz documents additional buttons in USB order, integers 3...31.
        // https://developer.apple.com/documentation/coregraphics/cgmousebutton
        case .x1: return CGMouseButton(rawValue: 3)!
        case .x2: return CGMouseButton(rawValue: 4)!
        }
    }

    enum Action: CaseIterable { case down, drag, up }

    func eventType(for action: Action) -> CGEventType {
        switch (self, action) {
        case (.left, .down): return .leftMouseDown
        case (.left, .drag): return .leftMouseDragged
        case (.left, .up): return .leftMouseUp
        case (.right, .down): return .rightMouseDown
        case (.right, .drag): return .rightMouseDragged
        case (.right, .up): return .rightMouseUp
        case (_, .down): return .otherMouseDown
        case (_, .drag): return .otherMouseDragged
        case (_, .up): return .otherMouseUp
        }
    }

    /// Creates, but never posts, the event so native serialization is testable.
    func makeEvent(_ action: Action, at point: CGPoint) -> CGEvent? {
        CGEvent(mouseEventSource: nil, mouseType: eventType(for: action),
            mouseCursorPosition: point, mouseButton: nativeButton)
    }
}

/// One active scroll target, so fractional movement cannot leak to another
/// window and a peer cannot grow an unbounded per-window state dictionary.
nonisolated struct PeelScrollAccumulator {
    private var windowId: UInt32?
    private var residualX = 0.0
    private var residualY = 0.0

    mutating func reset() { self = Self() }

    mutating func consume(windowId: UInt32, deltaX: Double, deltaY: Double) -> (x: Int32, y: Int32)? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        if self.windowId != windowId {
            reset(); self.windowId = windowId
        }
        // Preserve the existing sensitivity. Bound each event before converting
        // to Int32, including finite but arbitrarily large peer-supplied values.
        let scale = 0.5
        let maximum = 1200.0
        let x = min(max(deltaX * scale, -maximum), maximum) + residualX
        let y = min(max(deltaY * scale, -maximum), maximum) + residualY
        let wholeX = x.rounded(.towardZero)
        let wholeY = y.rounded(.towardZero)
        residualX = x - wholeX; residualY = y - wholeY
        return (Int32(wholeX), Int32(wholeY))
    }
}
