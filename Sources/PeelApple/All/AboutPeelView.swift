//
//  AboutPeelView.swift
//  Peel
//
//  Created by Zach on 12/28/25.
//

import SwiftUI
import StoreKit

struct AboutPeelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview

    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Peel Pro" }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    private var termsURL: URL { URL(string: "https://zephyrstudios.dev/terms-of-use.html")! }
    private var privacyURL: URL { URL(string: "https://zephyrstudios.dev/privacy-policy.html")! }
    
    @State private var isGettingStartedExpanded = false
    @State private var isConnectExpanded = false
    @State private var isBrowseExpanded = false

    // MARK: - Copy
    private let gettingStartedBullets: [String] = [
        "Peel mirrors windows from your computer to your iPhone, iPad or Apple Vision Pro.",
        "Input passes through Peel. Whatever you tap, click, scroll, or type here happens on your computer."
    ]

    private let connectBullets: [String] = [
        "On the computer you want to connect: open Peel Pro, allow sharing, and leave it running.",
        "On this device: open Peel Pro, pair with your computer, and enter the 6-digit code. Only use the Advanced Pairing token if the 6-digit code does not work."
    ]

    private let browseBullets: [String] = [
        "The App Browser lists windows currently available from your computer.",
        "On Mac, windows must be visible in the current Space to appear.",
        "Tap a window to start streaming it. Peel Pro will bring it to focus.",
        "Status appears in the top bar (Active, Standby, No Signal). Only one window can be Active at a time.",
        "To switch apps, open App Browser again and pick a different window."
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DisclosureGroup(isExpanded: $isGettingStartedExpanded) {
                        BulletList(items: gettingStartedBullets)
                            .padding(.top, 6)
                    } label: {
                        Text("Getting Started")
                            .font(.headline)
                            .textCase(nil)
                    }
                } footer: {
                    EmptyView()
                }

                Section {
                    DisclosureGroup(isExpanded: $isConnectExpanded) {
                        BulletList(items: connectBullets)
                            .padding(.top, 6)
                    } label: {
                        Text("Connect")
                            .font(.headline)
                            .textCase(nil)
                    }
                } footer: {
                    Text("Peel connects over your local network. If your computer isn’t showing up, confirm both devices are on the same Wi-Fi.")
                }

                Section {
                    DisclosureGroup(isExpanded: $isBrowseExpanded) {
                        BulletList(items: browseBullets)
                            .padding(.top, 6)
                    } label: {
                        Text("Browse & Switch Apps")
                            .font(.headline)
                            .textCase(nil)
                    }
                } footer: {
                    Text("Tip: If a window isn’t listed, make sure it isn’t minimized. On Mac, it must be on the active Space.")
                }
                
                Section {
                    Link(destination: URL(string: "https://zephyrstudios.dev")!) {
                        Label("Zephyr Studios", systemImage: "safari")
                    }

                    Link(destination: URL(string: "mailto:support@zephyrstudios.dev")!) {
                        Label("Email Support", systemImage: "envelope")
                    }

                    Button {
                        requestReview()
                    } label: {
                        Label("Write a Review", systemImage: "star.bubble")
                    }
                } header: {
                    Text("Support")
                        .textCase(nil)
                }

                Section {
                    Link(destination: termsURL) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }

                    Link(destination: privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                } header: {
                    Text("Legal")
                        .textCase(nil)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appName)
                            .font(.title2).bold()
                        Text("Version \(version) (\(build))")
                            .foregroundStyle(.secondary)
                        Text("©2026 Zephyr Studios")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("About")
                        .textCase(nil)
                }

                
            }
            .navigationTitle("Info")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Components

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { idx in
                BulletRow(text: items[idx])
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct BulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
