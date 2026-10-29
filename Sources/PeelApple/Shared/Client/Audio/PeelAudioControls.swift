import SwiftUI

struct PeelAudioControls: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @Environment(\.dismiss) private var dismiss

    private var clientProductName: String {
#if os(visionOS)
        return "Peel Pro"
#elseif os(iOS)
        return "Peel Pro"
#else
        return "Peel Pro"
#endif
    }


    var body: some View {
        NavigationStack {
            List {

                if PeelAudioPlatformCapabilities.supportsMacSystemAudio {
                    Section {
                        ForEach(browser.sessionsByHostKey.values.sorted { $0.host.name < $1.host.name }) { session in
                            PeelHostAudioRow(session: session)
                        }
                        if browser.sessionsByHostKey.isEmpty {
                            Text("Connect to a computer to hear its audio here.")
                        }
                    } header: {
                        Text("Computer Audio")
                    } footer: {
                        Text("System sound plays automatically while you stream from a computer that allows it, and stops when its last stream closes. Turning it off keeps it off for that computer until you turn it on again. Voice must be enabled in Peel Pro on that computer first. On a Mac, voice also requires the Peel Remote Microphone driver selected in your voice app and microphone permission. Playback ends when you disconnect or leave \(clientProductName); one computer can play at a time.")
                    }
                } else {
                    Text("Computer audio is unavailable on this device.")
                }
            }
            .navigationTitle("Audio")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct PeelHostAudioRow: View {
    @ObservedObject var session: PeelHostSession
    @State private var selectedMode: PeelClientAudioMode = .playback
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var voiceAvailable: Bool {
        session.hostCapabilities.contains(PeelCapability.remoteVoiceV1.rawValue)
    }

    private var selectedModeAvailable: Bool {
        session.hostCapabilities.contains(selectedMode.hostCapability)
    }


    private var audioToggleDisabled: Bool {
        // Stopping remains available if connection or source availability changes.
        guard !session.systemAudioRequested else { return false }
        return !session.isConnectionReady || !selectedModeAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if voiceAvailable {
                Group {
                    if horizontalSizeClass == .compact {
                        HStack(spacing: 8) {
                            Label(
                                selectedMode == .voice ? "Voice" : "Listen",
                                systemImage: selectedMode == .voice
                                    ? "mic.fill"
                                    : "speaker.wave.2.fill"
                            )
                            .font(.subheadline.weight(.medium))
                            Spacer(minLength: 4)
                            Picker("Audio mode", selection: $selectedMode) {
                                ForEach(PeelClientAudioMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityLabel("Audio mode")
                        }
                    } else {
                        Picker("Audio mode", selection: $selectedMode) {
                            ForEach(PeelClientAudioMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .disabled(session.systemAudioRequested)
            }
            Toggle(session.host.name, isOn: Binding(
                get: { session.systemAudioRequested },
                set: { enabled in
                    if enabled { session.audioController.startByUser(mode: selectedMode) }
                    else { session.audioController.stopByUser() }
                }
            ))
            .disabled(audioToggleDisabled)
            Text(session.systemAudioStatus).font(.caption).foregroundStyle(.secondary)
        }
    }
}
