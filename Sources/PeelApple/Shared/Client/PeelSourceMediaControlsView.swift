//
//  PeelSourceMediaControlsView.swift
//  Peel
//
//  Streamed-window controls for the source computer's media keys and volume.
//  Each instance is bound to its window's exact owning session and stream
//  window. Without an owner nothing is drawn and nothing is sent.
//

import SwiftUI

#if os(iOS) || os(visionOS)

enum PeelSourceMediaControlsStyle {
    /// Icon buttons inside the iPad floating toolbar.
    case toolbar
    /// Circle buttons inside a visionOS ornament.
    case ornament
    /// Wrapping labeled tiles inside the iPhone controls panel.
    case panel
    /// One menu button where the chrome is too narrow for separate buttons.
    case menu
}

struct PeelSourceMediaControls: View {
    /// The window's owning session; never the browser's selected session.
    let session: PeelHostSession?
    let windowId: UInt32
    let computerName: String
    var style: PeelSourceMediaControlsStyle = .toolbar
    /// The window's existing input gate, checked again at tap time.
    var canInteract: () -> Bool = { true }

    @AppStorage(PeelSourceControlsVisibility.showVolumeKey) private var showVolume = true
    @AppStorage(PeelSourceControlsVisibility.showMediaControlsKey) private var showMediaControls = true

    var body: some View {
        if let session, showVolume || showMediaControls {
            PeelSourceMediaControlsContent(
                session: session,
                controller: session.sourceMediaController,
                windowId: windowId,
                computerName: computerName,
                style: style,
                showVolume: showVolume,
                showMediaControls: showMediaControls,
                canInteract: canInteract
            )
        }
    }
}

nonisolated private enum PeelSourceMediaItem: CaseIterable, Hashable {
    case previous
    case playPause
    case next

    var action: PeelSourceMediaAction {
        switch self {
        case .previous: return .previousTrack
        case .playPause: return .playPause
        case .next: return .nextTrack
        }
    }

    var systemImage: String {
        switch self {
        case .previous: return "backward.fill"
        case .playPause: return "playpause.fill"
        case .next: return "forward.fill"
        }
    }

    var title: String {
        switch self {
        case .previous: return "Previous"
        case .playPause: return "Play/Pause"
        case .next: return "Next"
        }
    }

    func accessibilityLabel(computerName: String) -> String {
        switch self {
        case .previous: return "Previous track on \(computerName)"
        case .playPause: return "Play or pause on \(computerName)"
        case .next: return "Next track on \(computerName)"
        }
    }
}

private struct PeelSourceMediaControlsContent: View {
    @ObservedObject var session: PeelHostSession
    @ObservedObject var controller: PeelSourceMediaController
    let windowId: UInt32
    let computerName: String
    let style: PeelSourceMediaControlsStyle
    let showVolume: Bool
    let showMediaControls: Bool
    let canInteract: () -> Bool

    @State private var showingVolume = false

    /// A source that does not offer media keys gets no media buttons.
    private var showsMedia: Bool { showMediaControls && controller.sourceOffersMediaKeys }
    private var mediaEnabled: Bool { controller.canSendMedia(windowId: windowId) }
    private var volumeEnabled: Bool { controller.canUseVolume(windowId: windowId) }
    private var windowState: PeelSourceMediaWindowState { controller.state(for: windowId) }

    private var volumeSystemImage: String {
        controller.volumeSnapshot(windowId: windowId)?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    private var mediaFeedbackMessage: String? {
        windowState.mediaFeedback.flatMap {
            PeelSourceMediaCopy.message(for: $0.outcome, computerName: computerName)
        }
    }

    var body: some View {
        Group {
            if showsMedia || showVolume {
                switch style {
                case .toolbar: toolbarBody
                case .ornament: ornamentBody
                case .panel: panelBody
                case .menu: menuBody
                }
            }
        }
        .popover(isPresented: $showingVolume) {
            PeelSourceVolumePanel(
                session: session,
                controller: controller,
                windowId: windowId,
                computerName: computerName,
                canInteract: canInteract
            )
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: volumeEnabled) { _, enabled in
            if !enabled { showingVolume = false }
        }
        // One read of actual source state when the controls appear or become
        // usable; never a repeating poll.
        .task(id: showVolume && volumeEnabled) {
            if showVolume && volumeEnabled {
                controller.refreshVolume(windowId: windowId)
            }
        }
        .task(id: windowState.mediaFeedback?.id) {
            guard let id = windowState.mediaFeedback?.id else { return }
            try? await Task.sleep(for: .seconds(3))
            controller.clearFeedback(windowId: windowId, id: id)
        }
    }

    private func perform(_ item: PeelSourceMediaItem) {
        guard canInteract() else { return }
        controller.perform(item.action, windowId: windowId)
    }

    private func openVolume() {
        guard canInteract(), volumeEnabled else { return }
        showingVolume = true
    }

    // MARK: Toolbar (iPad)

    /// Leads with its own divider so a hidden group leaves none behind.
    private var toolbarBody: some View {
        HStack(spacing: 2) {
            toolbarDivider
            if showsMedia {
                ForEach(PeelSourceMediaItem.allCases, id: \.self) { item in
                    toolbarButton(systemImage: item.systemImage,
                                  label: item.accessibilityLabel(computerName: computerName),
                                  enabled: mediaEnabled) { perform(item) }
                }
            }
            if showsMedia && showVolume {
                toolbarDivider
            }
            if showVolume {
                toolbarButton(systemImage: volumeSystemImage,
                              label: "Volume of \(computerName)",
                              enabled: volumeEnabled) { openVolume() }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .popover(isPresented: mediaFeedbackPresented) { mediaFeedbackPopover }
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 26)
            .padding(.horizontal, 4)
    }

    private func toolbarButton(systemImage: String, label: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 42, height: 42)
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Ornament (visionOS)

    private var ornamentBody: some View {
        HStack(spacing: 10) {
            if showsMedia {
                ForEach(PeelSourceMediaItem.allCases, id: \.self) { item in
                    ornamentButton(systemImage: item.systemImage,
                                   label: item.accessibilityLabel(computerName: computerName),
                                   enabled: mediaEnabled) { perform(item) }
                }
            }
            if showVolume {
                ornamentButton(systemImage: volumeSystemImage,
                               label: "Volume of \(computerName)",
                               enabled: volumeEnabled) { openVolume() }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .popover(isPresented: mediaFeedbackPresented) { mediaFeedbackPopover }
    }

    private func ornamentButton(systemImage: String, label: String, enabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(PeelSourceMediaCircleBackground())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Panel (iPhone)

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Controls for \(computerName)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Adaptive columns wrap instead of shrinking labels.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                if showsMedia {
                    ForEach(PeelSourceMediaItem.allCases, id: \.self) { item in
                        panelTile(title: item.title, systemImage: item.systemImage,
                                  label: item.accessibilityLabel(computerName: computerName),
                                  enabled: mediaEnabled) { perform(item) }
                    }
                }
                if showVolume {
                    panelTile(title: "Volume", systemImage: volumeSystemImage,
                              label: "Volume of \(computerName)",
                              enabled: volumeEnabled) { openVolume() }
                }
            }

            if let mediaFeedbackMessage {
                Text(mediaFeedbackMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func panelTile(title: String, systemImage: String, label: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Menu (narrow chrome)

    private var menuBody: some View {
        Menu {
            if showsMedia {
                ForEach(PeelSourceMediaItem.allCases, id: \.self) { item in
                    Button {
                        perform(item)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                    .disabled(!mediaEnabled)
                    .accessibilityLabel(item.accessibilityLabel(computerName: computerName))
                }
            }
            if showVolume {
                Button {
                    openVolume()
                } label: {
                    Label("Computer Volume…", systemImage: volumeSystemImage)
                }
                .disabled(!volumeEnabled)
                .accessibilityLabel("Volume of \(computerName)")
            }
        } label: {
            Image(systemName: "music.note")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(PeelSourceMediaCircleBackground())
        .accessibilityLabel("Media and volume controls for \(computerName)")
        .popover(isPresented: mediaFeedbackPresented) { mediaFeedbackPopover }
    }

    // MARK: Feedback

    /// Refusals show in a popover anchored to the controls. The system places
    /// it on whichever side has room, so a toolbar snapped to the bottom edge
    /// or a narrow ornament never pushes it off-screen, clips it or grows.
    private var mediaFeedbackPresented: Binding<Bool> {
        Binding(
            get: { mediaFeedbackMessage != nil },
            set: { presented in
                guard !presented, let id = windowState.mediaFeedback?.id else { return }
                controller.clearFeedback(windowId: windowId, id: id)
            }
        )
    }

    private var mediaFeedbackPopover: some View {
        Text(mediaFeedbackMessage ?? "")
            .font(.callout)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .presentationCompactAdaptation(.popover)
    }
}

private struct PeelSourceMediaCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
#if os(visionOS)
        content.glassBackgroundEffect(in: Circle())
#else
        content.background(.regularMaterial, in: Circle())
#endif
    }
}

/// Mute and volume for the source computer. Values shown are only what the
/// source last reported; a released slider waits for the source's new state.
private struct PeelSourceVolumePanel: View {
    @ObservedObject var session: PeelHostSession
    @ObservedObject var controller: PeelSourceMediaController
    let windowId: UInt32
    let computerName: String
    let canInteract: () -> Bool

    @State private var draftVolume: Double?

    private var windowState: PeelSourceMediaWindowState { controller.state(for: windowId) }

    var body: some View {
        let snapshot = controller.volumeSnapshot(windowId: windowId)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Volume of \(computerName)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if windowState.isCheckingVolume {
                    ProgressView()
                        .accessibilityLabel("Checking \(computerName)")
                }
            }

            note(PeelSourceMediaCopy.volumeScopeNote(computerName: computerName))

            if !controller.canUseVolume(windowId: windowId) {
                note(PeelSourceMediaCopy.volumeUnavailable(computerName: computerName,
                                                           offered: controller.volumeScope != nil))
            } else if let snapshot, snapshot.supported {
                controls(for: snapshot)
            } else if let snapshot {
                note(PeelSourceMediaCopy.message(for: snapshot.reason ?? .scopeUnsupported,
                                                 computerName: computerName))
            } else if windowState.isCheckingVolume {
                note("Checking \(computerName)…")
            } else {
                note("The volume on \(computerName) is unknown.")
                Button("Check Again") {
                    controller.refreshVolume(windowId: windowId)
                }
            }

            if let feedback = windowState.volumeFeedback,
               let message = PeelSourceMediaCopy.message(for: feedback.outcome, computerName: computerName) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        .onAppear {
            controller.refreshVolume(windowId: windowId)
        }
    }

    @ViewBuilder
    private func controls(for snapshot: PeelSourceVolumeSnapshot) -> some View {
        let isMuted = snapshot.muted == true

        HStack(spacing: 12) {
            Button {
                guard canInteract(), let muted = snapshot.muted else { return }
                controller.setMuted(!muted, windowId: windowId)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!snapshot.canToggleMute)
            .accessibilityLabel(isMuted ? "Unmute \(computerName)" : "Mute \(computerName)")

            Slider(
                value: Binding(
                    get: { draftVolume ?? snapshot.volume ?? 0 },
                    set: { draftVolume = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    let value = draftVolume
                    draftVolume = nil
                    guard let value, canInteract() else { return }
                    controller.setVolume(value, windowId: windowId)
                }
            )
            .disabled(!snapshot.canAdjustVolume)
            .accessibilityLabel("Volume of \(computerName)")

            Text(percentText(draftVolume ?? snapshot.volume))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }

        if snapshot.muted == nil {
            note("\(computerName) didn't report whether it's muted.")
        }
        if snapshot.volume == nil {
            note("\(computerName) didn't report its volume.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }
}

/// Plain-language text for source replies. Names the source computer so it is
/// never confused with this device.
enum PeelSourceMediaCopy {
    /// Volume and mute act on the source computer itself, never this device.
    static func volumeScopeNote(computerName: String) -> String {
        "Changes the sound output of \(computerName) itself. Listening on this device is set separately."
    }

    static func volumeUnavailable(computerName: String, offered: Bool) -> String {
        offered
            ? "Volume control for \(computerName) is available while this window is streaming."
            : "\(computerName) doesn't offer volume control."
    }

    static func message(for outcome: PeelSourceMediaOutcome, computerName: String) -> String? {
        switch outcome {
        case .sent:
            return nil
        case .busy:
            return "Still waiting for \(computerName). Try again in a moment."
        case .noResponse:
            return "\(computerName) didn't respond."
        case .refused(let status, let reason):
            if let reason {
                return message(for: reason, computerName: computerName)
            }
            switch status {
            case .applied: return nil
            case .unsupported: return "\(computerName) doesn't support this control."
            case .denied: return "\(computerName) didn't allow this control."
            case .failed: return "\(computerName) couldn't complete this control."
            case .stale: return "This window is no longer streaming."
            case .invalid: return "\(computerName) couldn't read this request."
            }
        }
    }

    static func message(for reason: PeelSourceMediaReason, computerName: String) -> String {
        switch reason {
        case .controlOff: return "Control is turned off on \(computerName)."
        case .notVisible: return "Keep Peel Pro open to control \(computerName)."
        case .locked: return "\(computerName) is locked or asleep."
        case .accessibilityMissing: return "Allow Accessibility for Peel on \(computerName)."
        case .scopeUnsupported: return "\(computerName) doesn't offer volume control."
        case .fixedVolume: return "The sound output on \(computerName) has a fixed volume."
        case .noOutputDevice: return "\(computerName) has no sound output."
        case .staleStream: return "This window is no longer streaming."
        case .rateLimited: return "Too many presses. Try again in a moment."
        case .osRefused: return "\(computerName) didn't accept the control."
        }
    }
}

#endif
