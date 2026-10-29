//
//  AppsTabView.swift
//  Peel
//
//  Created by Zach on 6/1/26.
//

import SwiftUI

struct HostedPeelWindowSection: Identifiable, Hashable {
    let id: String
    let title: String
    let windows: [HostedPeelWindow]
}

struct AppsTabView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @Environment(\.colorScheme) private var colorScheme

    let connectedMacDisplayName: String
    let appWindows: [HostedPeelWindow]
    let appWindowSections: [HostedPeelWindowSection]
    let displayCaptureWindows: [HostedPeelWindow]
    let canOpenTopApps: Bool
    let quickOpenSymbolName: String
    let openPeeledWindowCountSnapshot: Int
    let appWindowSortOrderBinding: Binding<PeelAppWindowSortOrder>
    let openAllAvailableApps: () -> Void
    let closeAllAvailableApps: () -> Void
    let handleWindowOpenButtonTapped: (HostedPeelWindow) -> Void
    let closeSelectedWindow: (HostedPeelWindow) -> Void
    let showMacsTab: () -> Void

    @State private var expandedAppSectionID: String?

    private var hasConnectedHost: Bool {
        browser.isConnectionReady || browser.sessionsByHostKey.values.contains { session in
            session.isConnectionReady || session.connection != nil
        }
    }

    private var appCountText: String {
        "\(appWindows.count) \(appWindows.count == 1 ? "App" : "Apps")"
    }

    private var connectionSummaryText: String {
        guard hasConnectedHost else { return "No connected computer" }

        if appWindowSections.count == 1, let section = appWindowSections.first {
            return "\(section.title) • \(appCountText)"
        }

        if appWindowSections.count > 1 {
            return "\(appWindowSections.count) Computers • \(appCountText)"
        }

        return "\(connectedMacDisplayName) • \(appCountText)"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Text(connectionSummaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            if hasConnectedHost && !appWindows.isEmpty {
                HStack(spacing: 12) {
                    Spacer()
                    if canOpenTopApps {
                        Button {
                            openAllAvailableApps()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: quickOpenSymbolName)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(8)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                    }
                    if openPeeledWindowCountSnapshot > 0 {
                        Button {
                            closeAllAvailableApps()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                Text("Close Apps")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.red)
                            .padding(8)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal)
            }

            List {
                if !appWindows.isEmpty {
                    if appWindowSections.count <= 1, let section = appWindowSections.first {
                        Section {
                            ForEach(section.windows) { hostedWindow in
                                hostedAppWindowRow(hostedWindow, showsHostName: false)
                            }
                        } header: {
                            appsHeader(title: section.title)
                        }
                    } else {
                        Section {
                            appWindowDisclosureGroup(
                                id: "combined",
                                title: "Combined",
                                subtitle: appCountText,
                                windows: appWindows,
                                showsHostName: true
                            )

                            ForEach(appWindowSections) { section in
                                appWindowDisclosureGroup(
                                    id: section.id,
                                    title: section.title,
                                    subtitle: "\(section.windows.count) \(section.windows.count == 1 ? "App" : "Apps")",
                                    windows: section.windows,
                                    showsHostName: false
                                )
                            }
                        } header: {
                            appsHeader(title: "Apps")
                        }
                    }
                } else if hasConnectedHost && displayCaptureWindows.isEmpty {
                    Section("Apps") {
                        PeelLoadingView(
                            header: "No apps available",
                            subhead: "Your computer may be locked, asleep, closed, or not currently showing any app windows. Unlock it and open an app to see it here.",
                            variant: .minimal,
                            showsLogo: false
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 220)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                } else if !hasConnectedHost {
                    Section("Apps") {
                        VStack(spacing: 16) {
                            PeelLoadingView(
                                header: "Select a Computer",
                                subhead: "Connect to a paired computer to use its apps.",
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

                if hasConnectedHost {
                    Section("Launcher") {
                        Button {
                            browser.openLauncherFolder()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text("Applications Folder")
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                    }

                                    Text("Double-click an app to open")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .verticallyCentersUnderfilledList()
            .onChange(of: appWindowSections.map(\.id)) { _, sectionIDs in
                if let expandedAppSectionID,
                   !sectionIDs.contains(expandedAppSectionID),
                   !(expandedAppSectionID == "combined" && sectionIDs.count > 1) {
                    self.expandedAppSectionID = nil
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(colorScheme == .dark ? Color.black : Color.white)
    }

    private func appsHeader(title: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Menu {
                Picker("App Order", selection: appWindowSortOrderBinding) {
                    ForEach(PeelAppWindowSortOrder.allCases) { sortOrder in
                        Text(sortOrder.title)
                            .tag(sortOrder)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
    }

    private func appWindowDisclosureGroup(
        id: String,
        title: String,
        subtitle: String,
        windows: [HostedPeelWindow],
        showsHostName: Bool
    ) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(for: id)) {
            if windows.isEmpty {
                Text("No apps available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(windows) { hostedWindow in
                    hostedAppWindowRow(hostedWindow, showsHostName: showsHostName)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedAppSectionID == id },
            set: { isExpanded in
                expandedAppSectionID = isExpanded ? id : nil
            }
        )
    }

    private func hostedAppWindowRow(_ hostedWindow: HostedPeelWindow, showsHostName: Bool) -> some View {
        let window = hostedWindow.window
        let isOpen = scenes.isPeeledWindowOpen(hostedWindow)

        return HStack(spacing: 12) {
            appStatusIndicator(for: hostedWindow)

            Button {
                handleWindowOpenButtonTapped(hostedWindow)
            } label: {
                HStack(spacing: 12) {
#if canImport(UIKit)
                    if let iconImage = browser.session(for: hostedWindow.hostKey)?.appIconImage(for: window) ?? browser.appIconImage(for: window) {
                        Image(uiImage: iconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        Image(systemName: "macwindow")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
#else
                    Image(systemName: "macwindow")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
#endif

                    VStack(alignment: .leading, spacing: 4) {
                        Text(window.appName.isEmpty ? "(Untitled window)" : window.appName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if showsHostName {
                            Text(hostedWindow.hostName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !window.title.isEmpty,
                           window.title != window.appName {
                            Text(window.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            if isOpen {
                Button {
                    if !scenes.closePeeledWindowScene(for: hostedWindow) {
                        closeSelectedWindow(hostedWindow)
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

    private func appStatusIndicator(for hostedWindow: HostedPeelWindow) -> some View {
        Group {
            if let status = appListStatus(for: hostedWindow) {
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

    private func appListStatus(for hostedWindow: HostedPeelWindow) -> WindowStreamStatus? {
        guard scenes.isPeeledWindowOpen(hostedWindow),
              let session = browser.session(for: hostedWindow.hostKey) else {
            return nil
        }

        let streamStatus = session.streamStatus(for: hostedWindow.window.windowId)

        if streamStatus == .offline {
            return .offline
        }

        return session.isHostConfirmedActiveWindow(hostedWindow.window.windowId) ? .active : .sleeping
    }

}
