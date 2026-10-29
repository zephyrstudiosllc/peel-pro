import ApplicationServices
import AppKit
import Foundation

private let maximumNodes = 2_000
private let maximumDepth = 20

private func containsToken(
    _ token: String,
    in element: AXUIElement,
    depth: Int,
    visitedNodes: inout Int
) -> Bool {
    guard depth <= maximumDepth, visitedNodes < maximumNodes else { return false }
    visitedNodes += 1

    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
       let stringValue = value as? String,
       stringValue.contains(token) {
        return true
    }

    var childrenValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        kAXChildrenAttribute as CFString,
        &childrenValue
    ) == .success,
    let children = childrenValue as? [AXUIElement] else {
        return false
    }

    return children.contains { child in
        containsToken(
            token,
            in: child,
            depth: depth + 1,
            visitedNodes: &visitedNodes
        )
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: AssertTextEditContains <token>\n", stderr)
    exit(64)
}

let token = CommandLine.arguments[1]
guard !token.isEmpty else {
    fputs("AssertTextEditContains: token must not be empty\n", stderr)
    exit(64)
}

guard AXIsProcessTrusted() else {
    fputs("AssertTextEditContains: this test process is not Accessibility-trusted\n", stderr)
    exit(77)
}

guard let textEdit = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.TextEdit"
).first else {
    fputs("AssertTextEditContains: TextEdit is not running\n", stderr)
    exit(69)
}

let application = AXUIElementCreateApplication(textEdit.processIdentifier)
AXUIElementSetMessagingTimeout(application, 1.0)

let deadline = Date().addingTimeInterval(10)
repeat {
    var visitedNodes = 0
    if containsToken(token, in: application, depth: 0, visitedNodes: &visitedNodes) {
        print("AssertTextEditContains: found token in TextEdit")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.25)
} while Date() < deadline

fputs("AssertTextEditContains: token did not reach TextEdit\n", stderr)
exit(1)
