import AppKit
import SwiftUI

/// Visible Stop surface plus human-input interrupt while local AI access is on.
/// The panel never becomes key or main, so it cannot take focus from the
/// target window. It is Peel's own window, which the local route never lists,
/// and an overlap at an action point fails the existing topmost check.
@MainActor
final class PeelLocalComputerActivity {
    private var monitors: [Any] = []
    private var panel: NSPanel?
    var onExternalInput: () -> Void = {}

    func update(access: PeelLocalComputerAccess, stop: @escaping () -> Void) {
        access.isAllowed ? show(access: access, stop: stop) : hide()
    }

    private func show(access: PeelLocalComputerAccess, stop: @escaping () -> Void) {
        if monitors.isEmpty { installMonitors() }
        if panel == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 44),
                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.title = "Peel Pro AI access"
            panel.contentView = NSHostingView(rootView: PeelLocalComputerActivityView(access: access, stop: stop))
            self.panel = panel
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - panel.frame.height - 8))
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged,
                                           .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                           .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                           .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                           .scrollWheel]
        // Global: input delivered to other apps, where the agent's target lives.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }) { monitors.append(monitor) }
        // Local: input to Peel itself. Observed only; the event is returned unchanged.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }) { monitors.append(monitor) }
    }

    private func observe(_ event: NSEvent) {
        let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        guard PeelLocalComputerWindowPolicy.isExternalInput(sourceUserData: userData) else { return }
        onExternalInput()
    }
}

private struct PeelLocalComputerActivityView: View {
    @ObservedObject var access: PeelLocalComputerAccess
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI can use apps on this Mac").font(.caption.weight(.semibold))
                Text(access.activity ?? "Your keyboard or mouse interrupts it.")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Stop", role: .destructive, action: stop)
                .controlSize(.small)
                .help("Stop AI access to this Mac immediately")
                .accessibilityLabel("Stop AI access to this Mac")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 300, height: 44)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
