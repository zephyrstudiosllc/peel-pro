import AppKit

/// A harmless real window for parent-owned end-to-end acceptance. No files,
/// network, shell, Messages, AppleEvents or preferences are accessed.
@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let counter = NSTextField(labelWithString: "Clicks: 0")
    var clicks = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Peel MCP Acceptance Fixture"
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))
        let title = NSTextField(labelWithString: "Peel MCP — harmless visible-window acceptance")
        title.frame = NSRect(x: 24, y: 515, width: 590, height: 24); root.addSubview(title)
        let text = NSTextField(string: "")
        text.placeholderString = "Type only the synthetic acceptance token here"
        text.identifier = NSUserInterfaceItemIdentifier("fixtureText")
        text.frame = NSRect(x: 24, y: 460, width: 590, height: 32); root.addSubview(text)
        let button = NSButton(title: "Increment fixture counter", target: self, action: #selector(increment))
        button.frame = NSRect(x: 24, y: 410, width: 230, height: 32); root.addSubview(button)
        counter.frame = NSRect(x: 280, y: 415, width: 220, height: 24); root.addSubview(counter)
        let drag = FixtureDragView(frame: NSRect(x: 24, y: 230, width: 590, height: 160)); root.addSubview(drag)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: 590, height: 180))
        scroll.hasVerticalScroller = true
        let rows = NSTextView(frame: NSRect(x: 0, y: 0, width: 570, height: 2400))
        rows.isEditable = false; rows.string = (1...100).map { "Synthetic fixture row \($0)" }.joined(separator: "\n")
        scroll.documentView = rows; root.addSubview(scroll)
        window.contentView = root; window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc func increment() { clicks += 1; counter.stringValue = "Clicks: \(clicks)" }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@MainActor final class FixtureDragView: NSView {
    var center = CGPoint(x: 100, y: 70)
    var dragging = false
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        ("Drag the blue circle inside this fixture" as NSString).draw(at: CGPoint(x: 12, y: 130), withAttributes: [.foregroundColor: NSColor.labelColor])
        NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)).fill()
    }
    override func mouseDown(with event: NSEvent) { dragging = true; move(event) }
    override func mouseDragged(with event: NSEvent) { if dragging { move(event) } }
    override func mouseUp(with event: NSEvent) { if dragging { move(event) }; dragging = false }
    func move(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        center = CGPoint(x: min(max(20, p.x), bounds.width - 20), y: min(max(20, p.y), bounds.height - 35))
        needsDisplay = true
    }
}
@main struct VisibleFixture {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = FixtureDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
    }
}
