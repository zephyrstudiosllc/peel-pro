//
//  HUDTabView.swift
//  Peel
//
//  Created by Zach on 6/23/26.
//



import SwiftUI

private struct ImmersiveFieldProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var offsetX: Float
    var offsetY: Float
    var scale: Float
    var distance: Float
    var opacity: Float

    init(
        id: UUID = UUID(),
        name: String,
        offsetX: Float,
        offsetY: Float,
        scale: Float,
        distance: Float,
        opacity: Float
    ) {
        self.id = id
        self.name = name
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
        self.distance = distance
        self.opacity = opacity
    }
}

struct HUDTabView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @EnvironmentObject private var store: PeelStore
    @State private var showingWindowPaywall = false
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("immersiveFieldProfilesData") private var immersiveFieldProfilesData: Data = Data()
    @AppStorage("immersiveFieldProfileCount") private var immersiveFieldProfileCount: Int = 0

    let connectedMacDisplayName: String
    let displayCaptureWindows: [HostedPeelWindow]
    let displayWindowTitle: (HostedPeelWindow) -> String
    let displayCaptureSubtitle: (HostedPeelWindow) -> String
    let showMacsTab: () -> Void

    private var hasConnectedHosts: Bool {
        browser.isConnectionReady ||
        browser.sessionsByHostKey.values.contains { $0.isConnectionReady || $0.connection != nil }
    }

    private var connectedDisplayHostCount: Int {
        Set(displayCaptureWindows.map { $0.hostKey }).count
    }

    private var hudHeaderTitle: String {
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
                Text("\(hudHeaderTitle) • \(displayCaptureWindows.count) \(displayCaptureWindows.count == 1 ? "Desktop" : "Desktops")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            List {
                if hasConnectedHosts {
                    Section("HUD") {
                        HStack(spacing: 12) {
                            Image(systemName: "inset.filled.toptrailing.rectangle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Immersive HUD")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text("A head-locked overlay to keep your computer in sight at all times")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            if scenes.isPeelImmersiveSpaceOpen {
                                HStack(spacing: 8) {
                                    hudDisplayMenu(title: "Change", systemImage: "rectangle.on.rectangle")
                                        .buttonStyle(.bordered)

                                    Button(role: .destructive) {
                                        Task { @MainActor in
                                            if scenes.peelImmersiveHostedWindows.isEmpty {
                                                browser.forceMouseUpIfNeeded(reason: "closing HUD immersive space")
                                            } else {
                                                for hostedWindow in scenes.peelImmersiveHostedWindows {
                                                    browser.session(for: hostedWindow.hostKey)?.forceMouseUpIfNeeded(reason: "closing HUD immersive space")
                                                }
                                            }
                                            await dismissImmersiveSpace()
                                            scenes.markPeelImmersiveSpaceClosed()
                                        }
                                    } label: {
                                        Label("Close", systemImage: "xmark")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            } else {
                                hudDisplayMenu(title: "Launch", systemImage: "inset.filled.toptrailing.rectangle")
                                    .buttonStyle(.borderedProminent)
                                    .disabled(displayCaptureWindows.isEmpty)
                            }
                        }
                        .padding(.vertical, 4)

                        if scenes.isPeelImmersiveSpaceOpen {
                            let _ = scenes.setImmersiveFieldArc(1.0)

                            HStack(spacing: 12) {
                                Image(systemName: "arrow.left.and.right")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .center)

                                Slider(
                                    value: Binding(
                                        get: { Double(scenes.immersiveFieldOffsetX) },
                                        set: { scenes.setImmersiveFieldOffsetX(Float($0)) }
                                    ),
                                    in: -1...1
                                )
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "arrow.up.and.down")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .center)

                                Slider(
                                    value: Binding(
                                        get: { Double(scenes.immersiveFieldOffsetY) },
                                        set: { scenes.setImmersiveFieldOffsetY(Float($0)) }
                                    ),
                                    in: -1...1
                                )
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .center)

                                Slider(
                                    value: Binding(
                                        get: { Double(scenes.immersiveFieldScale) },
                                        set: { scenes.setImmersiveFieldScale(Float($0)) }
                                    ),
                                    in: 0.5...3.0
                                )
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "plus.magnifyingglass")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .center)

                                Slider(
                                    value: Binding(
                                        get: { Double(scenes.immersiveFieldDistance) },
                                        set: { scenes.setImmersiveFieldDistance(Float($0)) }
                                    ),
                                    in: 1.0...3.0
                                )
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "circle.lefthalf.filled")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .center)

                                Slider(
                                    value: Binding(
                                        get: { Double(scenes.immersiveFieldOpacity) },
                                        set: { scenes.setImmersiveFieldOpacity(Float($0)) }
                                    ),
                                    in: 0.2...1.0
                                )
                            }

                            HStack(spacing: 16) {
                                Button {
                                    scenes.resetImmersiveFieldControls()
                                } label: {
                                    Label("Default", systemImage: "arrow.counterclockwise")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    saveCurrentImmersiveFieldProfile()
                                } label: {
                                    Label("Save", systemImage: "externaldrive.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.top, 4)
                        }

                        let profiles = immersiveFieldProfiles
                        if !profiles.isEmpty {
                            ForEach(profiles) { profile in
                                Button {
                                    guard scenes.isPeelImmersiveSpaceOpen else { return }
                                    applyImmersiveFieldProfile(profile)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(profile.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)

                                            HStack(spacing: 8) {
                                                Image(systemName: "arrow.left.and.right")
                                                Text(formattedProfileValue(profile.offsetX))

                                                Image(systemName: "arrow.up.and.down")
                                                Text(formattedProfileValue(profile.offsetY))

                                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                Text(formattedProfileValue(profile.scale))

                                                Image(systemName: "plus.magnifyingglass")
                                                Text(formattedProfileValue(profile.distance))

                                                Image(systemName: "circle.lefthalf.filled")
                                                Text(formattedProfileValue(profile.opacity))
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.forward")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(displayCaptureWindows.isEmpty || !scenes.isPeelImmersiveSpaceOpen)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteImmersiveFieldProfile(profile)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section("HUD") {
                        VStack(spacing: 16) {
                            PeelLoadingView(
                                header: "Select a Computer",
                                subhead: "Connect to a paired computer to launch the HUD.",
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
            .verticallyCentersUnderfilledList()
            .frame(minHeight: 260, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.black : Color.white)
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        .sheet(isPresented: $showingWindowPaywall) {
            PeelPaywallView(feature: .multipleWindows).environmentObject(store)
        }
    }

    private var immersiveFieldProfiles: [ImmersiveFieldProfile] {
        guard !immersiveFieldProfilesData.isEmpty else {
            return []
        }

        return (try? JSONDecoder().decode([ImmersiveFieldProfile].self, from: immersiveFieldProfilesData)) ?? []
    }

    private func launchImmersiveHUD(for displayWindow: HostedPeelWindow, profile: ImmersiveFieldProfile? = nil) {
        activateLegacyHUDContext(for: displayWindow)

        if let profile {
            applyImmersiveFieldProfile(profile)
        } else {
            scenes.resetImmersiveFieldControls()
        }

        guard scenes.preparePeelImmersiveSpace(
            primary: displayWindow,
            windows: [displayWindow]
        ) else {
            if !store.hasProAccess { showingWindowPaywall = true }
            return
        }
        scenes.preparePeelImmersiveLaunch(context: .hudEnvironment)

        Task { @MainActor in
            let result = await openImmersiveSpace(id: "peel-immersive")
            switch result {
            case .opened:
                break
            case .userCancelled, .error:
                scenes.markPeelImmersiveSpaceClosed()
            @unknown default:
                scenes.markPeelImmersiveSpaceClosed()
            }
        }
    }

    private func activateLegacyHUDContext(for displayWindow: HostedPeelWindow) {
        browser.selectedHostKey = displayWindow.hostKey
        browser.session(for: displayWindow.hostKey)?.setActiveWindow(displayWindow.window.windowId)
    }

    private func hudDisplayMenu(title: String, systemImage: String) -> some View {
        Menu {
            if displayCaptureWindows.isEmpty {
                Text("No desktops available")
            } else {
                ForEach(displayCaptureWindows) { displayWindow in
                    Button {
                        launchImmersiveHUD(for: displayWindow)
                    } label: {
                        Label(displayWindowTitle(displayWindow), systemImage: displaySymbolName(for: displayWindow))
                    }
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func saveCurrentImmersiveFieldProfile() {
        var profiles = immersiveFieldProfiles
        let nextCount = immersiveFieldProfileCount + 1
        let profile = ImmersiveFieldProfile(
            name: "Profile \(nextCount)",
            offsetX: scenes.immersiveFieldOffsetX,
            offsetY: scenes.immersiveFieldOffsetY,
            scale: scenes.immersiveFieldScale,
            distance: scenes.immersiveFieldDistance,
            opacity: scenes.immersiveFieldOpacity
        )

        profiles.append(profile)
        saveImmersiveFieldProfiles(profiles)
        immersiveFieldProfileCount = nextCount
    }

    private func applyImmersiveFieldProfile(_ profile: ImmersiveFieldProfile) {
        scenes.setImmersiveFieldOffsetX(profile.offsetX)
        scenes.setImmersiveFieldOffsetY(profile.offsetY)
        scenes.setImmersiveFieldScale(profile.scale)
        scenes.setImmersiveFieldDistance(profile.distance)
        scenes.setImmersiveFieldOpacity(profile.opacity)
    }

    private func deleteImmersiveFieldProfile(_ profile: ImmersiveFieldProfile) {
        let profiles = immersiveFieldProfiles.filter { $0.id != profile.id }
        saveImmersiveFieldProfiles(profiles)
    }

    private func saveImmersiveFieldProfiles(_ profiles: [ImmersiveFieldProfile]) {
        immersiveFieldProfilesData = (try? JSONEncoder().encode(profiles)) ?? Data()
    }

    private func formattedProfileValue(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private func displaySymbolName(for displayWindow: HostedPeelWindow) -> String {
        guard let aspectRatio = displayAspectRatio(for: displayWindow) else {
            return "display"
        }

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
}
