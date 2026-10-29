// Adapted from OrcheSSHtra LiveTerminalView.swift at 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
import SwiftUI
import SwiftTerm
import PeelShellCore

extension TerminalThemeColor {
    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }
}

@MainActor
struct LiveTerminalView: View {
    let sessionID: UUID
    let session: any SSHShellSessionProtocol
    let onEnded: (Error?) -> Void
    var body: some View {
        TerminalRepresentable(session: session, onEnded: onEnded)
            .id(sessionID) // A replaced session never reuses a view bound to the previous machine.
    }
}

#if canImport(UIKit)
import UIKit
@MainActor
private struct TerminalRepresentable: UIViewRepresentable {
    let session: any SSHShellSessionProtocol
    let onEnded: (Error?) -> Void
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(session: session, onEnded: onEnded) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.backgroundColor = .black
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.installColors(TerminalTheme.defaultDark.ansi.map(\.swiftTermColor))
#if DEBUG
        // Explicit fixture-only observability: keep actual terminal rendering/input,
        // without an indefinitely repeating cursor animation blocking XCTest idle.
        if ProcessInfo.processInfo.environment["PEEL_SHELL_UI_FIXTURE"] == "1" {
            view.getTerminal().setCursorStyle(.steadyBlock)
            view.accessibilityIdentifier = "peel-shell-terminal"
            view.isAccessibilityElement = true
            view.accessibilityLabel = "Independent SSH terminal"
        }
#endif
        context.coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {}
    static func dismantleUIView(_ view: TerminalView, coordinator: TerminalCoordinator) { coordinator.stop() }
}
#else
import AppKit
@MainActor
private struct TerminalRepresentable: NSViewRepresentable {
    let session: any SSHShellSessionProtocol
    let onEnded: (Error?) -> Void
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(session: session, onEnded: onEnded) }
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.installColors(TerminalTheme.defaultDark.ansi.map(\.swiftTermColor))
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {}
    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalCoordinator) { coordinator.stop() }
}
#endif

@MainActor
private final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    private let session: any SSHShellSessionProtocol
    private let onEnded: (Error?) -> Void
    private weak var terminal: TerminalView?
    private var outputTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var pendingInput = Data()
    private var pendingSize: SSHTerminalSize?
    private var stopped = false
    init(session: any SSHShellSessionProtocol, onEnded: @escaping (Error?) -> Void) {
        self.session = session; self.onEnded = onEnded
    }
    func attach(_ view: TerminalView) {
        terminal = view; view.terminalDelegate = self
        outputTask = Task { [weak self, session] in
            do {
                for try await chunk in session.output {
                    guard !Task.isCancelled, let self, !self.stopped else { return }
                    let bytes = [UInt8](chunk)
                    self.terminal?.feed(byteArray: bytes[...])
                }
                self?.finish(nil)
            } catch { self?.finish(error) }
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        outputTask?.cancel(); inputTask?.cancel(); resizeTask?.cancel()
        outputTask = nil; inputTask = nil; resizeTask = nil
        pendingInput.removeAll(); pendingSize = nil; terminal?.terminalDelegate = nil
        Task { [session] in await session.close() }
    }
    private func finish(_ error: Error?) {
        guard !stopped else { return }
        stop(); onEnded(error)
    }
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // SwiftTerm's legacy delegate has no actor annotation. Its UIKit/AppKit callbacks
        // and this adapter's feed path run on the UI actor; enforce that at the boundary.
        MainActor.assumeIsolated { enqueueInput(data) }
    }
    private func enqueueInput(_ data: ArraySlice<UInt8>) {
        guard !stopped else { return }
        guard data.count <= 262_144 - pendingInput.count else { finish(SSHClientError.inputLimitExceeded); return }
        pendingInput.append(contentsOf: data)
        guard inputTask == nil else { return }
        // One writer preserves keystroke/paste order and bounds queued user input.
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inputTask = nil }
            do {
                while !self.pendingInput.isEmpty && !self.stopped {
                    let chunk = Data(self.pendingInput.prefix(65_536))
                    self.pendingInput.removeFirst(chunk.count)
                    try await self.session.send(chunk)
                }
            } catch { self.finish(error) }
        }
    }
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { enqueueResize(columns: newCols, rows: newRows) }
    }
    private func enqueueResize(columns: Int, rows: Int) {
        guard !stopped else { return }
        pendingSize = SSHTerminalSize(columns: columns, rows: rows)
        guard resizeTask == nil else { return }
        resizeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.resizeTask = nil }
            do {
                while let size = self.pendingSize, !self.stopped {
                    self.pendingSize = nil
                    try await self.session.resize(to: size)
                }
            } catch { self.finish(error) }
        }
    }
    // Remote terminal text is untrusted: it cannot open URLs, write clipboard, or establish cwd authority.
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
