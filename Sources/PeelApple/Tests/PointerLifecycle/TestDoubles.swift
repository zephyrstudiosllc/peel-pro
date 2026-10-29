import Foundation
import CoreGraphics
import CoreFoundation

private var testClock: CFTimeInterval = 1
private func CACurrentMediaTime() -> CFTimeInterval { testClock }
private protocol UIGestureRecognizerDelegate {}
private class UIView: NSObject { var bounds = CGRect(x: 0, y: 0, width: 100, height: 100) }
private class UIGestureRecognizer: NSObject {
    enum State { case possible, began, changed, ended, cancelled, failed }
    var state: State = .possible
    var point = CGPoint(x: 50, y: 50)
    func location(in view: UIView) -> CGPoint { point }
}
private class UIPanGestureRecognizer: UIGestureRecognizer {
    var translationValue = CGPoint.zero
    var velocityValue = CGPoint.zero
    func translation(in view: UIView) -> CGPoint { translationValue }
    func setTranslation(_ value: CGPoint, in view: UIView) { translationValue = value }
    func velocity(in view: UIView) -> CGPoint { velocityValue }
}
private class UIHoverGestureRecognizer: UIGestureRecognizer {}
private class UITapGestureRecognizer: UIGestureRecognizer {}
private struct UIEvent {
    enum EventType { case touches, scroll, hover }
    struct ButtonMask: OptionSet {
        let rawValue: Int
        static let primary = ButtonMask(rawValue: 1)
        static let secondary = ButtonMask(rawValue: 2)
    }
    var type: EventType = .touches
    var buttonMask: ButtonMask = .primary
}
private struct UITouch { enum TouchType { case indirectPointer, direct }; var type: TouchType }
private enum UIScrollView {
    struct DecelerationRate { let rawValue: CGFloat; static let normal = DecelerationRate(rawValue: 0.998) }
}
private final class CADisplayLink {
    static var live: [CADisplayLink] = []
    private var target: NSObject?
    private let selector: Selector
    init(target: NSObject, selector: Selector) { self.target = target; self.selector = selector }
    func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) { Self.live.append(self) }
    func invalidate() {
        let previousTarget = target
        target = nil
        Self.live.removeAll { $0 === self }
        withExtendedLifetime(previousTarget) {}
    }
    static func tick() {
        testClock += 1.0 / 60
        autoreleasepool { for link in live { _ = link.target?.perform(link.selector) } }
    }
}
