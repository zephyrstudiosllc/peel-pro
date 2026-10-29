import SwiftUI

/// Stream-window toolbar group: Listen (receiver playback of the source's
/// audio), source media keys and source volume. Source controls act on the
/// streamed computer through the paired control connection only; nothing
/// here touches this Mac's output volume or media keys.
@MainActor
struct PeelRemoteMacSourceMediaControls: View {
    @ObservedObject var controller: PeelRemoteMacViewerController
    @ObservedObject var audio: PeelRemoteMacAudioController
    @ObservedObject var media: PeelRemoteMacSourceMediaController
    @AppStorage(PeelRemoteMacSourceMediaPreferences.showVolumeKey) private var showVolume = true
    @AppStorage(PeelRemoteMacSourceMediaPreferences.showMediaControlsKey) private var showMediaControls = true

    var body: some View {
        // Wide windows show buttons inline; narrow ones fold media into a menu.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                PeelRemoteMacListenButton(controller: controller, audio: audio)
                if showMediaControls { mediaButtons }
                if showVolume { PeelRemoteMacSourceVolumeButton(controller: controller, media: media) }
                messageIndicator
            }
            .fixedSize()
            HStack(spacing: 6) {
                PeelRemoteMacListenButton(controller: controller, audio: audio)
                if showMediaControls { mediaMenu }
                if showVolume { PeelRemoteMacSourceVolumeButton(controller: controller, media: media) }
            }
            .fixedSize()
            PeelRemoteMacListenButton(controller: controller, audio: audio).fixedSize()
            // Narrower than Listen alone (e.g. tall portrait windows): add nothing
            // rather than clip the existing Control/Info toolbar.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var sourceName: String { controller.connectedDisplayName ?? "the source computer" }

    private var mediaHelp: String {
        switch media.mediaAvailability {
        case .available: return "Controls media on \(sourceName)"
        case .needsControl: return "Turn on Control to use media controls on \(sourceName)"
        case .unsupported: return "\(sourceName) does not offer media controls"
        case .noStream: return "No active stream"
        }
    }

    private var mediaButtons: some View {
        HStack(spacing: 2) {
            mediaButton(.previousTrack, symbol: "backward.fill", label: "Previous")
            mediaButton(.playPause, symbol: "playpause.fill", label: "Play or Pause")
            mediaButton(.nextTrack, symbol: "forward.fill", label: "Next")
        }
    }

    private func mediaButton(_ action: PeelSourceMediaAction, symbol: String, label: String) -> some View {
        Button { media.send(action) } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(media.mediaAvailability != .available)
            .help("\(label) — \(mediaHelp)")
            .accessibilityLabel("\(label) on \(sourceName)")
    }

    private var mediaMenu: some View {
        Menu {
            Button("Previous") { media.send(.previousTrack) }
            Button("Play or Pause") { media.send(.playPause) }
            Button("Next") { media.send(.nextTrack) }
            if let message = media.lastMessage { Divider(); Text(message) }
        } label: { Image(systemName: "playpause") }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(media.mediaAvailability != .available)
        .help(mediaHelp)
        .accessibilityLabel("Media controls for \(sourceName)")
    }

    @ViewBuilder private var messageIndicator: some View {
        if let message = media.lastMessage {
            Button(action: media.clearMessage) { Image(systemName: "exclamationmark.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help(message)
                .accessibilityLabel(message)
        }
    }
}

/// Listen indicator and explicit On/Off. Blue only while PCM is actually
/// rendering; a pending request pulses in the secondary color.
@MainActor
private struct PeelRemoteMacListenButton: View {
    @ObservedObject var controller: PeelRemoteMacViewerController
    @ObservedObject var audio: PeelRemoteMacAudioController
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: audio.isRequested ? "headphones.circle.fill" : "headphones")
                .foregroundStyle(audio.isPlayingPCM ? Color.blue : Color.secondary)
                .symbolEffect(.pulse, isActive: audio.isRequested && !audio.isPlayingPCM)
        }
        .buttonStyle(.borderless)
        .help("Listen: \(audio.status)")
        .accessibilityLabel(audio.isPlayingPCM ? "Listening to computer audio" : "Listen: \(audio.status)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Listen on this Mac", isOn: Binding(
                    get: { audio.isRequested },
                    set: { on in on ? audio.startByUser() : audio.stopByUser() }))
                    .toggleStyle(.switch)
                    .disabled(!controller.isConnected)
                Text(audio.status).font(.caption).foregroundStyle(.secondary)
                if let pairingID = controller.connectedPairingID, audio.isDefaultPlaybackOff(for: pairingID),
                   !audio.isRequested {
                    Text("Listening stays off for this computer until you turn it on.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Plays \(controller.connectedDisplayName ?? "the source computer")'s audio here. No microphone is used.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 260)
        }
    }
}

/// Source volume/mute. Values shown come only from validated source replies;
/// the slider position while dragging is the user's request, not a result.
@MainActor
private struct PeelRemoteMacSourceVolumeButton: View {
    @ObservedObject var controller: PeelRemoteMacViewerController
    @ObservedObject var media: PeelRemoteMacSourceMediaController
    @State private var showing = false
    @State private var draft = 0.0
    @State private var dragging = false

    var body: some View {
        let current = media.currentVolume
        Button { showing.toggle() } label: {
            Image(systemName: current?.muted == true ? "speaker.slash" : "speaker.wave.2")
        }
        .buttonStyle(.borderless)
        .disabled(media.volumeAvailability != .available)
        .help(media.volumeAvailability == .available
              ? "Source volume on \(controller.connectedDisplayName ?? "the source computer")"
              : "Source volume control isn't available for this computer yet")
        .accessibilityLabel("Source volume on \(controller.connectedDisplayName ?? "the source computer")")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Source volume · \(controller.connectedDisplayName ?? "Source computer")").font(.headline)
                Text("Changes the source computer's system output, not this Mac. Listen controls playback here.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let current, current.supported {
                    HStack {
                        Button {
                            if let muted = current.muted { media.setMuted(!muted) }
                        } label: { Image(systemName: current.muted == true ? "speaker.slash.fill" : "speaker.fill") }
                        .buttonStyle(.borderless)
                        .disabled(!current.canSetMute || current.muted == nil || !controller.inputEnabled)
                        .help(current.muted == true ? "Unmute source" : "Mute source")
                        .accessibilityLabel(current.muted == true ? "Unmute source" : "Mute source")
                        Slider(value: $draft, in: 0...1) { editing in
                            dragging = editing
                            if !editing { media.setVolume(draft) }
                        }
                        .disabled(!current.canSetVolume || current.volume == nil || !controller.inputEnabled)
                    }
                    Text(current.volume.map { "Source reports \(Int(($0 * 100).rounded()))%" } ?? "Level unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let current {
                    Text(current.reason.map { PeelRemoteMacSourceMediaController.describe(.unsupported, $0) }
                         ?? "The source computer doesn't support volume control.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(media.pendingCount > 0 ? "Asking the source computer…" : "No volume reported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !controller.inputEnabled {
                    Text("Turn on Control to change it.").font(.caption2).foregroundStyle(.secondary)
                }
                if let message = media.lastMessage {
                    Text(message).font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(width: 260)
            .onAppear {
                draft = media.currentVolume?.volume ?? 0
                media.refreshVolume()
            }
            .onChange(of: media.currentVolume?.volume) { _, value in
                if !dragging, let value { draft = value }
            }
        }
    }
}
