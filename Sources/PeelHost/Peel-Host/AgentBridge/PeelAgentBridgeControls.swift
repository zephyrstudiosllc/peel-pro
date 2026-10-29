import AppKit
import SwiftUI

struct PeelAgentBridgeControls: View {
    @ObservedObject var host: PeelHost
    @State private var configurationCopied = false

    private var adapterURL: URL? {
        Bundle.main.url(forResource: "peel_mcp_server", withExtension: "py")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("Audio & Mac Status for Paired Devices") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Allow Mac audio on paired devices", isOn: Binding(
                        get: { host.systemAudioAllowed },
                        set: { host.setSystemAudioAllowed($0) }
                    ))
                    Text("On by default. Peel Pro plays Mac system sound, excluding Peel itself, while a paired device streams, until either device turns it off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(host.systemAudioStatus).font(.caption).foregroundStyle(.secondary)
                    if host.systemAudioStatus.contains("could not stop cleanly") {
                        Button("Stop Mac Audio Again") { host.setSystemAudioAllowed(false) }
                    }
                    Toggle("Allow remote microphone input", isOn: Binding(
                        get: { host.remoteVoiceAllowed },
                        set: { host.setRemoteVoiceAllowed($0) }
                    ))
                    Text("Voice also requires Mac audio above and the Peel Remote Microphone driver. Select it as the input in your Mac voice app, then start Voice from your paired device.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label(host.remoteVoiceStatus, systemImage: "mic")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Allow Mac Status on paired devices", isOn: Binding(
                        get: { host.remoteStatusAllowed },
                        set: { host.setRemoteStatusAllowed($0) }
                    ))
                    Text("Share system health, your top five apps and AI usage when you refresh Mac Status in Peel Pro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("AI Agents on This Mac", systemImage: "sparkles").font(.headline)
                Toggle("Allow local agents to connect", isOn: Binding(
                    get: { host.agentBridgeEnabled },
                    set: { host.setAgentBridgeEnabled($0) }
                ))
                Text("Connect a compatible agent app on this computer. Each kind of access below is a separate permission.")
                    .font(.caption).foregroundStyle(.secondary)
                if host.agentBridgeEnabled {
                    Text(host.agentBridgeStatus).font(.caption)
                    Button(configurationCopied ? "Configuration Copied" : "Copy MCP Configuration") { copyConfiguration() }
                        .disabled(adapterURL == nil)
                    Text(adapterURL == nil
                         ? "The agent adapter is missing from this build. Reinstall Peel Pro to restore it."
                         : "Use this configuration in a compatible agent app on this Mac. Python 3 is required.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                PeelLocalComputerAccessControls(host: host, access: host.localComputerAccess)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(host.agentControlStatus, systemImage: host.agentControlAllowed ? "cursorarrow.rays" : "hand.raised")
                            .font(.caption)
                        Spacer()
                        Button("Stop Agent Control", role: .destructive) { host.setAgentControlAllowed(false) }
                            .disabled(!host.agentControlAllowed)
                    }
                    Toggle("Allow agents to control a visible Peel window", isOn: Binding(
                        get: { host.agentControlAllowed }, set: { host.setAgentControlAllowed($0) }
                    ))
                    .disabled(!host.agentBridgeEnabled)
                    Text("For a window streamed to your paired iPhone or iPad. Off at every launch. Requires Accessibility, Screen Recording, an opted-in paired client and its active streamed window. Each action needs a fresh inspection. Your input or Stop cancels the agent. Spatial views currently lack required presentation telemetry.")
                        .font(.caption).foregroundStyle(.secondary)
                    if host.agentBridgeEnabled {
                        Text(host.agentAuthorizationStatus).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Receiving device setup") {
                            Text("On your iPhone or iPad, manually open and select the Mac window in Peel Pro, then enable “Allow agents to control my open stream” in Peel Pro Settings. Keep Peel Pro visible and connected. Automatic AI window opening is a separate paid permission; notifications have their own permission. Spatial views currently do not support agent control.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func copyConfiguration() {
        guard let script = adapterURL?.path else { return }
        let value = ["mcpServers": ["peel": [
            "command": "python3",
            "args": [script, "--socket", host.agentBridgeSocketPath]
        ]]] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        configurationCopied = NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The only control that can grant local-computer AI access. It is runtime-only
/// and starts off at every launch.
struct PeelLocalComputerAccessControls: View {
    @ObservedObject var host: PeelHost
    @ObservedObject var access: PeelLocalComputerAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(access.activity.map { "\(access.status) · \($0)" } ?? access.status,
                      systemImage: access.isAllowed ? "cursorarrow.rays" : "hand.raised")
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button("Stop AI Access", role: .destructive) { host.setLocalComputerAccessAllowed(false) }
                    .disabled(!access.isAllowed)
                    .help("Stop AI access to apps on this Mac immediately")
            }
            Toggle("Allow AI to use apps on this Mac", isOn: Binding(
                get: { access.isAllowed }, set: { host.setLocalComputerAccessAllowed($0) }
            ))
            .disabled(!host.agentBridgeEnabled && !access.isAllowed)
            .help("Lets a connected agent on this Mac list, open, focus, inspect and control app windows here, such as System Settings or Terminal.")
            Text("No second device needed. Off at every launch, and an agent cannot turn it on. A connected agent can list and open apps, bring one window forward, inspect it, then perform one bounded action per inspection. Peel's own windows, desktops and system password prompts are excluded. Inspection needs Screen Recording; control also needs “Allow Peel Pro to control this Mac” and Accessibility. Your keyboard or mouse interrupts the agent, and Stop ends access.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
