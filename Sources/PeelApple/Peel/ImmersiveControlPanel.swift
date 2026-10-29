//
//  PeelImmersiveControlPanel.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//


//
//  PeelImmersiveControlPanel.swift
//  Peel
//

#if os(visionOS)
import SwiftUI
import UIKit

struct PeelImmersiveControlPanel: View {
    @EnvironmentObject private var browser: PeelClientBrowser

    let windows: [PeelWindow]
    let primaryWindowId: UInt32?
    @Binding var surfaceScale: CGFloat
    @Binding var layoutMode: PeelImmersiveLayoutMode

    let selectWindow: (PeelWindow) -> Void
    let openHome: () -> Void
    let openTrackpad: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openHome) {
                Image("PeelHostMenuBarIcon_128x128")
                    .resizable()
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Peel Pro")

            Divider()
                .frame(height: 44)

            windowStrip

            Divider()
                .frame(height: 44)

            Button {
                layoutMode = layoutMode == .focus ? .field : .focus
            } label: {
                Label(layoutMode.label, systemImage: layoutMode.systemImage)
            }

            HStack(spacing: 6) {
                Button {
                    surfaceScale = max(0.72, surfaceScale - 0.08)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }

                Button {
                    surfaceScale = min(1.42, surfaceScale + 0.08)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
            }

            Button(action: openTrackpad) {
                Image(systemName: "rectangle.and.hand.point.up.left")
            }
            .accessibilityLabel("Open Trackpad")

            Button(role: .cancel, action: close) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close Field")
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassBackgroundEffect(in: Capsule())
    }

    private var windowStrip: some View {
        HStack(spacing: 8) {
            ForEach(windows.prefix(5), id: \.windowId) { window in
                Button {
                    selectWindow(window)
                } label: {
                    HStack(spacing: 6) {
                        if let image = browser.appIconImage(for: window) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        Text(label(for: window))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 120)
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(window.windowId == primaryWindowId ? Color.primary.opacity(0.24) : Color.secondary.opacity(0.16))
            }
        }
    }

    private func label(for window: PeelWindow) -> String {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appName.isEmpty { return appName }

        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }

        return "Window"
    }
}
#endif
