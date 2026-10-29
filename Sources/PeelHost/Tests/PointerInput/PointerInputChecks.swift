import Foundation
import CoreGraphics

@main
struct PointerInputChecks {
    static func main() {
        var accumulator = PeelScrollAccumulator()
        var x: Int32 = 0
        var y: Int32 = 0
        for _ in 0..<100 {
            let delta = accumulator.consume(windowId: 1, deltaX: 0.5, deltaY: -0.25)!
            x += delta.x; y += delta.y
        }
        precondition(x == 25 && y == -12, "Subpixel movement must accumulate with existing sensitivity")
        precondition(accumulator.consume(windowId: 1, deltaX: 0, deltaY: -1)!.y == -1)
        accumulator.reset()
        precondition(accumulator.consume(windowId: 1, deltaX: 1.5, deltaY: 0)!.x == 0)
        precondition(accumulator.consume(windowId: 2, deltaX: 0.5, deltaY: 0)!.x == 0,
            "A previous window's residual cannot scroll a new target")
        precondition(accumulator.consume(windowId: 2, deltaX: 1.5, deltaY: 0)!.x == 1)
        accumulator.reset()
        for _ in 0..<100 {
            precondition(accumulator.consume(windowId: 1, deltaX: 0.5, deltaY: -0.5)!.x == 0)
            let reverse = accumulator.consume(windowId: 1, deltaX: -0.5, deltaY: 0.5)!
            precondition(reverse.x == 0 && reverse.y == 0)
        }
        precondition(accumulator.consume(windowId: 1, deltaX: 1.5, deltaY: 0)!.x == 0)
        precondition(accumulator.consume(windowId: 2, deltaX: .nan, deltaY: 0) == nil)
        precondition(accumulator.consume(windowId: 1, deltaX: .infinity, deltaY: 0) == nil)
        precondition(accumulator.consume(windowId: 1, deltaX: 0.5, deltaY: 0)!.x == 1,
            "Rejected values must not alter valid pending movement")
        let large = accumulator.consume(windowId: 1, deltaX: .greatestFiniteMagnitude, deltaY: -.greatestFiniteMagnitude)!
        precondition(large.x == 1200 && large.y == -1200, "Huge finite peer input cannot trap or accumulate runaway movement")
        accumulator.reset()
        precondition(accumulator.consume(windowId: 1, deltaX: 1, deltaY: 1)!.x == 0)
        accumulator.reset()
        precondition(accumulator.consume(windowId: 1, deltaX: 1, deltaY: 1)!.x == 0)

        precondition(PeelMouseButton(rawValue: "unsupported") == nil)
        precondition(PeelMouseButton(rawValue: "") == nil)
        let point = CGPoint(x: 321, y: 456)
        let expected: [(PeelMouseButton, Int64, [CGEventType])] = [
            (.left, 0, [.leftMouseDown, .leftMouseDragged, .leftMouseUp]),
            (.right, 1, [.rightMouseDown, .rightMouseDragged, .rightMouseUp]),
            (.middle, 2, [.otherMouseDown, .otherMouseDragged, .otherMouseUp]),
            (.x1, 3, [.otherMouseDown, .otherMouseDragged, .otherMouseUp]),
            (.x2, 4, [.otherMouseDown, .otherMouseDragged, .otherMouseUp])
        ]
        for (button, number, types) in expected {
            for (index, action) in PeelMouseButton.Action.allCases.enumerated() {
                guard let event = button.makeEvent(action, at: point),
                      let data = event.data, let decoded = CGEvent(withDataAllocator: nil, data: data) else {
                    fatalError("Native event serialization failed")
                }
                precondition(decoded.type == types[index])
                precondition(decoded.getIntegerValueField(.mouseEventButtonNumber) == number)
                precondition(decoded.location == point)
            }
        }
        print("PointerInputChecks: PASS (fractional/target/reset/bounds, 15 native button event round trips; no events posted)")
    }
}
