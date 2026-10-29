//
//  DisplaysTabView.swift
//  Peel
//
//  Created by Zach on 6/1/26.
//


import SwiftUI

struct DisplaysTabView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @Environment(\.colorScheme) private var colorScheme

    let connectedMacDisplayName: String
    let displayCaptureWindows: [HostedPeelWindow]
    let displayWindowTitle: (HostedPeelWindow) -> String
    let displayCaptureSubtitle: (HostedPeelWindow) -> String
    let handleWindowOpenButtonTapped: (HostedPeelWindow) -> Void
    let closeSelectedWindow: (HostedPeelWindow) -> Void
    let showMacsTab: () -> Void

    
    private var hasConnectedHosts: Bool {
        browser.isConnectionReady ||
        browser.sessionsByHostKey.values.contains { $0.isConnectionReady || $0.connection != nil }
    }
    
    private var connectedDisplayHostCount: Int {
        Set(displayCaptureWindows.map { $0.hostKey }).count
    }
    
    private var displayHeaderTitle: String {
        guard hasConnectedHosts else { return "No connected computer" }
        guard !displayCaptureWindows.isEmpty else { return connectedMacDisplayName }
        guard connectedDisplayHostCount != 1 else {
            return displayCaptureWindows.first?.hostName ?? connectedMacDisplayName
        }
        return "\(connectedDisplayHostCount) Computers"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Text("\(displayHeaderTitle) • \(displayCaptureWindows.count) \(displayCaptureWindows.count == 1 ? "Desktop" : "Desktops")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            List {
                Section(displayCaptureWindows.count == 0 ? "Desktops" : "Virtual Display") {
                    if hasConnectedHosts && !displayCaptureWindows.isEmpty {
                        ForEach(displayCaptureWindows) { displayWindow in
                            let isOpen = scenes.isPeeledWindowOpen(displayWindow)

                            HStack(spacing: 12) {
                                displayStatusIndicator(for: displayWindow)

                                Button {
                                    handleWindowOpenButtonTapped(displayWindow)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: displaySymbolName(for: displayWindow))
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32, height: 32)

                                        Text(displayWindow.hostName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Spacer(minLength: 12)

                                if isOpen {
                                    Button {
                                        if !scenes.closePeeledWindowScene(for: displayWindow) {
                                            closeSelectedWindow(displayWindow)
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                            .padding(6)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Close")
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.clear)
                        }
                    } else if hasConnectedHosts {
                        PeelLoadingView(
                            header: "No desktops available",
                            subhead: "Your computer may be locked, asleep, closed, or not currently available for display mirroring.",
                            variant: .minimal,
                            showsLogo: false
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 220)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    } else {
                        VStack(spacing: 16) {
                            PeelLoadingView(
                                header: "Select a Computer",
                                subhead: "Connect to a paired computer to use its desktops.",
                                variant: .minimal,
                                showsLogo: true
                            )

                            Button {
                                showMacsTab()
                            } label: {
                                Text("Computers")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 220)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .verticallyCentersUnderfilledList(upwardBias: 72)
            .frame(minHeight: 260, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.black : Color.white)
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
    }

    private func cleanDisplayName(for displayWindow: HostedPeelWindow) -> String {
        let title = displayWindowTitle(displayWindow)
        let separators = [" • ", " - ", " – ", " — "]

        for separator in separators {
            if let range = title.range(of: separator) {
                return String(title[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displaySymbolName(for displayWindow: HostedPeelWindow) -> String {
        guard let aspectRatio = displayAspectRatio(for: displayWindow) else {
            return "display"
        }

        // Common MacBook/internal displays are usually around 16:10.
        // Standard external displays are usually 16:9.
        // Ultrawides are commonly 21:9, 32:9, or similar.
        switch aspectRatio {
        case ..<1.70:
            return "macbook"
        case 1.70..<2.05:
            return "display"
        default:
            return "display"
        }
    }

    private func displayAspectRatio(for displayWindow: HostedPeelWindow) -> Float? {
        let text = "\(displayWindowTitle(displayWindow)) \(displayCaptureSubtitle(displayWindow))"
        let pattern = #"(\d{3,5})\s*[x×]\s*(\d{3,5})"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text),
              let width = Float(text[widthRange]),
              let height = Float(text[heightRange]),
              width > 0,
              height > 0
        else {
            return nil
        }

        let longSide = max(width, height)
        let shortSide = min(width, height)
        return longSide / shortSide
    }

    private func displayStatusIndicator(for displayWindow: HostedPeelWindow) -> some View {
        Group {
            if let status = displayListStatus(for: displayWindow) {
                StatusDot(status: status, size: 10)
            } else {
                Circle()
                    .fill(.clear)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 10, height: 10)
    }

    private func displayListStatus(for displayWindow: HostedPeelWindow) -> WindowStreamStatus? {
        guard scenes.isPeeledWindowOpen(displayWindow) else {
            return nil
        }

        let streamStatus = browser.session(for: displayWindow.hostKey)?.streamStatus(for: displayWindow.window.windowId)
            ?? browser.streamStatus(for: displayWindow.window.windowId)

        if streamStatus == .offline {
            return .offline
        }

        // Display capture streams do not map to a normal AX-focused app window.
        // If the virtual display stream is open and online, show it as active.
        return .active
    }
}
