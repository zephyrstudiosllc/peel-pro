//
//  MacsTabView.swift
//  Peel
//
//  Created by Zach on 6/1/26.
//


import SwiftUI

struct MacsTabView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    
    let hostDisplayName: (PeelHostInfo) -> String
    let savedMacDisplayName: (PeelSavedPairedMac) -> String
    let hostSymbolName: (PeelHostInfo) -> String
    let hostStatusText: (PeelHostInfo) -> String
    let hostStatusSymbolName: (PeelHostInfo) -> String
    let hostStatusColor: (PeelHostInfo) -> Color
    let hostPrimaryActionButton: (PeelHostInfo) -> AnyView
    let primaryHostAction: (PeelHostInfo) -> Void
    let isDisconnectOnCooldown: Bool
    let beginDisconnectCooldown: () -> Void
    let presentAppearanceEditor: (PeelHostInfo) -> Void
    private let peelHostDownloadURL = URL(string: "https://peelpro.app")!
    
    
    @Binding var forgetPairingHost: PeelHostInfo?
    @Binding var forgetSavedPairingMac: PeelSavedPairedMac?
    
    var body: some View {
        VStack{
            HStack {
                Spacer()
                if browser.hosts.count == 1{
                    Text("1 computer nearby")
                        .foregroundStyle(.secondary)
                }else {
                    Text("\(browser.hosts.count) computers nearby")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            
            
            
            List {
                if browser.hosts.isEmpty && browser.hiddenSavedPairedMacs.isEmpty {
                    Section(header: Text("Computers")) {
                        VStack(spacing: 24) {
                            PeelLoadingView(
                                header: "Looking for Computers",
                                subhead: "Your computer must be awake and unlocked.\nPeel Pro needs to be running on that computer.\nBoth devices need the same Wi-Fi and Local Network access.",
                                variant: .searching,
                                showsLogo: false
                            )
                        
                            VStack(spacing: 10) {
                                Text("Need Peel Pro?")
                                    .font(.headline)
                                
                                VStack(spacing: 3) {
                                    Text("Open the download page on the computer you want to connect.")
                                        .foregroundStyle(.secondary)
                                    
                                    Button {
                                        copyPeelHostDownloadLink()
                                    } label: {
                                        Label("Copy Link", systemImage: "doc.on.doc")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    
                                    Button {
                                        openURL(peelHostDownloadURL)
                                    } label: {
                                        Text("peelpro.app")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.blue)
                                            .underline()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open the Peel Pro download page")
                                    
                                    
                                }
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                
                                
                            }
                            .padding(20)
                            .frame(maxWidth: 420)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 330)
                        .listRowInsets(EdgeInsets(top: 18, leading: 0, bottom: 26, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
                
                if !browser.hosts.isEmpty {
                    Section(header: Text("Nearby Computers")) {
                        ForEach(browser.hosts, id: \.id) { host in
                            let updateMessage = updateRequiredMessage(for: host)
                            HStack(spacing: 12) {
                                Image(systemName: hostSymbolName(host))
                                    .font(.title3)
                                    .frame(width: 28)
                                    .foregroundStyle(.secondary)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hostDisplayName(host))
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    
                                    Label(updateMessage ?? hostStatusText(host), systemImage: updateMessage == nil ? hostStatusSymbolName(host) : "exclamationmark.triangle.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(updateMessage == nil ? hostStatusColor(host) : .orange)
                                        .lineLimit(1)
                                }
                                
                                Spacer(minLength: 12)
                                
                                if updateMessage == nil {
                                    hostPrimaryActionButton(host)
                                } else {
                                    Button("Needs Update") { }
                                        .disabled(true)
                                }
                                
                                Menu {
                                    if updateMessage == nil && browser.needsPairingRepair(host) && !browser.isConnected(to: host) && !browser.isConnecting(host) && !browser.isPairing(host) {
                                        Button {
                                            primaryHostAction(host)
                                        } label: {
                                            Text("Pair again")
                                                .foregroundStyle(.orange)
                                        }
                                    }

                                    if updateMessage == nil && browser.isPaired(host) && !browser.needsPairingRepair(host) && !browser.isConnected(to: host) && !browser.isConnecting(host) && !browser.isPairing(host) {
                                        Button {
                                            primaryHostAction(host)
                                        } label: {
                                            Text("Connect")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    
                                    if browser.isConnected(to: host) {
                                        Button("Disconnect") {
                                            guard !isDisconnectOnCooldown else { return }
                                            beginDisconnectCooldown()
                                            browser.disconnect(from: host)
                                        }
                                        .disabled(isDisconnectOnCooldown)
                                    }
                                    
                                    if browser.isPaired(host) || browser.isConnected(to: host) || browser.isConnecting(host) {
                                        if browser.isConnecting(host) {
                                            Button("Cancel Connection", role: .destructive) {
                                                browser.disconnect(from: host, reason: "Connection cancelled")
                                            }
                                        }
                                    }
                                    
                                    Button("Set icon") {
                                        presentAppearanceEditor(host)
                                    }
                                    
                                    if browser.isPaired(host) || browser.isConnected(to: host) || browser.isConnecting(host) {
                                        Button("Forget pairing", role: .destructive) {
                                            forgetPairingHost = host
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3)
                                        .padding(6)
                                }
                                .disabled(browser.isPairing(host))
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                
                
                if !browser.hiddenSavedPairedMacs.isEmpty {
                    Section(header: Text("Saved Computers")) {
                        ForEach(browser.hiddenSavedPairedMacs) { savedMac in
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .font(.title3)
                                
                                    .foregroundStyle(.secondary)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(savedMacDisplayName(savedMac))
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    
                                    Label("Paired, not available", systemImage: "link.circle.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                
                                Spacer(minLength: 12)
                                
                                Menu {
                                    Button("Forget pairing", role: .destructive) {
                                        forgetSavedPairingMac = savedMac
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3)
                                        .padding(6)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                

            }
            .verticallyCentersUnderfilledList()
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.black : Color.white)
            
            Text("If the computer doesn't appear, make sure all required permissions are enabled and restart Peel Pro on that computer.")
                .font(.footnote)
                .tint(.secondary)
                .opacity(0.3)
                .padding(.horizontal, 40)
        }
    }
    
    
    private func updateRequiredMessage(for host: PeelHostInfo) -> String? {
        let sessionStatus = browser.sessionsByHostKey[host.hostKey]?.status.trimmingCharacters(in: .whitespacesAndNewlines)

        let status: String
        if let sessionStatus, !sessionStatus.isEmpty {
            status = sessionStatus
        } else if browser.selectedHostKey == host.hostKey {
            status = browser.status.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }

        let lowercasedStatus = status.lowercased()
        
        guard lowercasedStatus.contains("not compatible") ||
                lowercasedStatus.contains("needs update") ||
                lowercasedStatus.contains("update peel") ||
                lowercasedStatus.contains("protocol mismatch") else {
            return nil
        }
        
        if lowercasedStatus.contains("update peel host") {
            return "Update Peel Pro"
        }
        
        if lowercasedStatus.contains("update peel pro") {
            return "Update Peel Pro"
        }
        
        return "Needs Update"
    }
    private func copyPeelHostDownloadLink() {
#if canImport(UIKit)
        UIPasteboard.general.string = peelHostDownloadURL.absoluteString
#endif
    }
}
