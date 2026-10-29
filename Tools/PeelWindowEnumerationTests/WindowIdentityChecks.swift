import Foundation

// The four exact production methods are appended by the runner. Only AX replies
// are controlled; no running app, screen pixels or permissions are accessed.
typealias AXUIElement = FixtureAXElement
typealias CGWindowID = UInt32
enum AXError { case success, failure }
let kAXWindowsAttribute = "AXWindows"
let kAXMinimizedAttribute = "AXMinimized"
let kAXWindowNumberAttribute = "AXWindowNumber" as CFString
final class FixtureAXElement: NSObject {
    var children: [FixtureAXElement]?
    var number: NSNumber?
    var minimized: Bool?
    var primaryID: UInt32?
    init(number: UInt64? = nil, minimized: Bool? = false, children: [FixtureAXElement]? = nil, primaryID: UInt32? = nil) {
        self.number = number.map(NSNumber.init(value:))
        self.minimized = minimized
        self.children = children
        self.primaryID = primaryID
    }
}
enum FixtureAX { static var applications: [pid_t: FixtureAXElement] = [:] }
func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { FixtureAX.applications[pid]! }
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError {
    guard let primaryID = element.primaryID else { return .failure }
    id = primaryID
    return .success
}
func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString,
                                  _ output: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    switch attribute as String {
    case kAXWindowsAttribute:
        guard let children = element.children else { return .failure }
        output.pointee = children as NSArray
    case kAXMinimizedAttribute:
        guard let minimized = element.minimized else { return .failure }
        output.pointee = NSNumber(value: minimized)
    case "AXWindowNumber":
        guard let number = element.number else { return .failure }
        output.pointee = number
    default: return .failure
    }
    return .success
}

extension WindowEnumerator {
    static func verifyIdentityMapping() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        FixtureAX.applications = [
            1: FixtureAXElement(children: [FixtureAXElement()]),
            2: FixtureAXElement(children: [FixtureAXElement(number: 10), FixtureAXElement()]),
            3: FixtureAXElement(children: [FixtureAXElement(number: 10), FixtureAXElement(number: 11)]),
            4: FixtureAXElement(children: []),
            5: FixtureAXElement(children: [FixtureAXElement(minimized: true)]),
            6: FixtureAXElement(children: [FixtureAXElement(number: 12), FixtureAXElement(number: 13, minimized: true)]),
            7: FixtureAXElement(children: nil),
            8: FixtureAXElement(children: [FixtureAXElement(number: UInt64(UInt32.max) + 1)]),
            9: FixtureAXElement(children: [FixtureAXElement(number: 15), FixtureAXElement(number: 15)]),
            10: FixtureAXElement(children: [FixtureAXElement(number: UInt64(UInt32.max))]),
            11: FixtureAXElement(children: [FixtureAXElement(primaryID: 20)]),
            12: FixtureAXElement(children: [FixtureAXElement(number: 21, primaryID: 0)]),
            13: FixtureAXElement(children: [FixtureAXElement(number: 22)]),
            14: FixtureAXElement(children: [FixtureAXElement(number: 31, primaryID: 30)]),
            15: FixtureAXElement(children: [FixtureAXElement(primaryID: 0)]),
            16: FixtureAXElement(children: [FixtureAXElement(number: 0)]),
            17: FixtureAXElement(children: [FixtureAXElement(number: 0, primaryID: 0)])
        ]
        let mapping = accessibilityWindowIdsByPID(for: Set(FixtureAX.applications.keys))
        func permits(_ id: UInt32, _ pid: pid_t) -> Bool {
            passesAccessibilityWindowFilter(windowId: id, pid: pid, axWindowIdsByPID: mapping)
        }
        check(mapping[1] == nil && permits(20, 1), "Unresolvable AX IDs are unknown, not a known-empty allowlist")
        check(mapping[2] == nil && permits(10, 2) && permits(20, 2), "Partial AX mapping cannot reject unresolved CG windows")
        check(mapping[3] == Set([10, 11]) && permits(10, 3) && permits(11, 3) && !permits(20, 3),
              "Complete mapping still enforces known window IDs")
        check(mapping[4] == Set<UInt32>() && !permits(20, 4), "Known empty AX list still rejects")
        check(mapping[5] == Set<UInt32>() && !permits(20, 5), "Minimized-only list remains known empty even without IDs")
        check(mapping[6] == Set([12]) && permits(12, 6) && !permits(13, 6), "Complete eligible map still excludes minimized IDs")
        check(mapping[7] == nil && permits(20, 7), "AX window-list read failure retains prior unknown-map behavior")
        check(mapping[8] == nil && permits(20, 8), "Out-of-range AX IDs cannot create false complete mapping")
        check(mapping[9] == Set([15]) && permits(15, 9) && !permits(20, 9), "Duplicate IDs retain set semantics")
        check(mapping[10] == Set([UInt32.max]) && permits(UInt32.max, 10), "Maximum UInt32 ID remains valid")
        check(mapping[11] == Set([20]) && permits(20, 11) && !permits(21, 11),
              "Existing primary resolver keeps exact filtering when AXWindowNumber is unavailable")
        check(mapping[12] == Set([21]) && permits(21, 12) && !permits(0, 12), "Zero primary ID falls back to valid attribute")
        check(mapping[13] == Set([22]) && permits(22, 13), "Failed primary resolver falls back to valid attribute")
        check(mapping[14] == Set([30]) && !permits(31, 14), "Actual CG identity takes precedence over attribute")
        check(mapping[15] == nil && permits(20, 15), "Both resolvers unavailable retains unknown-map fallback")
        check(mapping[16] == nil && permits(20, 16), "Failed primary and zero attribute cannot create a complete mapping")
        check(mapping[17] == nil && permits(20, 17), "Zero primary and zero attribute retain unknown-map fallback")
        check(permits(20, 999), "Absent application map retains prior fallback")
        return failures
    }
}

@main struct WindowIdentityChecks {
    static func main() {
        let failures = WindowEnumerator.verifyIdentityMapping()
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: exact AX identity collection/filter methods; unknown/partial/complete/empty/minimized/failed/out-of-range mappings; controlled AX, no UI")
    }
}
