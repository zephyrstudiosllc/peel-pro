import Foundation
import CoreGraphics

@main
struct LocalPointerHitTestChecks {
    static let display = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    static let point = CGPoint(x: 319.52, y: 834.352)
    static let targetID: UInt32 = 72199
    static let targetPID: pid_t = 30832
    static let dockPID: pid_t = 2568
    static let dockLayer = 20
    static let dockIdentity = PeelLocalPointerOwnerIdentity(bundleIdentifier: "com.apple.dock",
        executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")

    static func row(_ id: UInt32, pid: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha, kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }

    static let dockRow = row(57, pid: dockPID, layer: dockLayer, bounds: display)
    static let targetRow = row(targetID, pid: targetPID, layer: 0, bounds: CGRect(x: 180, y: 668, width: 640, height: 592))
    static let backgroundRow = row(9001, pid: 777, layer: 0, bounds: display)
    static let exactHit = PeelLocalPointerAXHit(ownerPID: targetPID, windowID: targetID)

    static func allows(_ rows: [[String: Any]], point: CGPoint = point, displays: [CGRect] = [display],
                       identity: PeelLocalPointerOwnerIdentity? = dockIdentity,
                       hit: PeelLocalPointerAXHit? = exactHit, axCalls: UnsafeMutablePointer<Int>? = nil) -> Bool {
        PeelLocalPointerHitTestPolicy.allows(rawRows: rows, targetWindowID: targetID, targetPID: targetPID, point: point,
            dockLayer: dockLayer, displayBounds: displays,
            ownerIdentity: { $0 == dockPID ? identity : PeelLocalPointerOwnerIdentity(bundleIdentifier: "com.example.other", executablePath: "/Applications/Other.app/Contents/MacOS/Other") },
            axHit: { axCalls?.pointee += 1; return hit })
    }

    static func main() {
        let axCalls = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { axCalls.deallocate() }

        // Genuine click-through Dock full-display row + exact AX target allows.
        axCalls.pointee = 0
        precondition(allows([dockRow, targetRow, backgroundRow], axCalls: axCalls), "Click-through Dock row with exact AX hit must allow")
        precondition(axCalls.pointee == 1, "Dock exception must consult the real AX hit-test")

        // Cheap CG path: exact target first never needs AX or Dock identity.
        axCalls.pointee = 0
        precondition(allows([targetRow, backgroundRow], hit: nil, axCalls: axCalls), "Exact CG topmost target must pass")
        precondition(axCalls.pointee == 0, "Exact CG topmost must not need AX")
        precondition(!allows([row(targetID, pid: 4242, layer: 0, bounds: display)]), "Target row with mismatched owner blocks")

        // AX hit must resolve the exact window and owner.
        precondition(!allows([dockRow, targetRow], hit: .init(ownerPID: dockPID, windowID: 57)), "Interactive Dock element blocks")
        precondition(!allows([dockRow, targetRow], hit: .init(ownerPID: dockPID, windowID: nil)), "Dock button/menu without window blocks")
        precondition(!allows([dockRow, targetRow], hit: .init(ownerPID: targetPID, windowID: 72200)), "Mismatched sibling window blocks")
        precondition(!allows([dockRow, targetRow], hit: .init(ownerPID: 555, windowID: targetID)), "Other app owner blocks")
        precondition(!allows([dockRow, targetRow], hit: .init(ownerPID: targetPID, windowID: nil)), "Missing AX window identity blocks")
        precondition(!allows([dockRow, targetRow], hit: nil), "AX nil blocks")

        // Dock identity and covering geometry must be verified.
        precondition(!allows([dockRow, targetRow], identity: nil), "Unknown Dock owner identity blocks")
        precondition(!allows([dockRow, targetRow], identity: .init(bundleIdentifier: "com.apple.dock", executablePath: "/Applications/Dock.app/Contents/MacOS/Dock")), "Impostor Dock path blocks")
        precondition(!allows([dockRow, targetRow], identity: .init(bundleIdentifier: "com.example.dock", executablePath: dockIdentity.executablePath)), "Wrong Dock bundle blocks")
        precondition(!allows([dockRow, targetRow], identity: .init(bundleIdentifier: "com.apple.dock", executablePath: nil)), "Missing Dock path blocks")
        precondition(!allows([row(57, pid: dockPID, layer: dockLayer, bounds: CGRect(x: 0, y: 700, width: 3440, height: 740)), targetRow]), "Partial Dock geometry blocks")
        precondition(!allows([dockRow, targetRow], displays: []), "Unknown display geometry blocks")
        precondition(!allows([dockRow, targetRow], displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]), "Mismatched display geometry blocks")
        precondition(!allows([row(57, pid: dockPID, layer: 25, bounds: display), targetRow]), "Dock row at another layer blocks")
        precondition(!allows([dockRow, dockRow, targetRow]), "Only one Dock covering row may be discounted")

        // Protected, unknown and own overlays still block, exact AX hit notwithstanding.
        let authModal = row(800, pid: 333, layer: 1000, bounds: CGRect(x: 100, y: 600, width: 800, height: 500))
        precondition(!allows([authModal, dockRow, targetRow]), "Auth/protected overlay above Dock blocks")
        precondition(!allows([dockRow, authModal, targetRow]), "Overlay between Dock and target blocks")
        precondition(!allows([row(801, pid: targetPID, layer: 0, bounds: display), targetRow]), "Sibling window of target app blocks")
        precondition(!allows([row(802, pid: 999, layer: 3, bounds: display), targetRow]), "Own/ineligible window blocks")
        precondition(!allows([dockRow]), "Dock with no target row behind blocks")
        precondition(!allows([dockRow, backgroundRow, targetRow]), "Other app behind Dock above target blocks")
        var noLayer = dockRow; noLayer.removeValue(forKey: kCGWindowLayer as String)
        precondition(!allows([noLayer, targetRow]), "Containing row without identity blocks")

        // Same containment filter as the paired gate.
        precondition(allows([row(803, pid: 999, layer: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)), targetRow], hit: nil),
            "Non-containing rows are skipped")
        precondition(allows([row(804, pid: 999, layer: 0, bounds: display, alpha: 0), targetRow], hit: nil), "Transparent rows are skipped")
        precondition(!allows([dockRow, targetRow], point: CGPoint(x: CGFloat.nan, y: 834)), "Non-finite point blocks")
        precondition(!allows([]), "Empty window list blocks")

        // Real CGWindowList values arrive as NSNumber.
        let bridged: [String: Any] = [kCGWindowNumber as String: NSNumber(value: targetID), kCGWindowOwnerPID as String: NSNumber(value: targetPID),
            kCGWindowLayer as String: NSNumber(value: 0), kCGWindowAlpha as String: NSNumber(value: 1.0),
            kCGWindowBounds as String: CGRect(x: 180, y: 668, width: 640, height: 592).dictionaryRepresentation]
        precondition(PeelLocalPointerWindowRow.parse(bridged) == .init(windowID: targetID, ownerPID: targetPID, layer: 0, alpha: 1,
            bounds: CGRect(x: 180, y: 668, width: 640, height: 592)), "NSNumber-backed rows must parse")

        print("Local pointer hit-test checks passed")
    }
}
