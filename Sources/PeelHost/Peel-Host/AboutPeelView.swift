//
//  AboutPeelView.swift
//  Peel
//
//  Created by Zach on 12/28/25.
//

import SwiftUI

struct AboutPeelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyPeelLink = false

    private let peelDownloadURL = URL(string: "https://peelpro.app")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header

                        VStack(spacing: 14) {
                            TutorialStepRow(
                                number: "1",
                                title: "Enable Mac permissions",
                                message: "Allow Local Network, Screen Recording, and Accessibility when prompted."
                            )

                            TutorialStepRow(
                                number: "2",
                                title: "Open on Apple Vision Pro",
                                message: "Download Peel Pro from the App Store."
                            ) {
                          //      HStack(spacing: 10) {
                          //          Link(destination: peelDownloadURL) {
                          //              Label("Download Peel", systemImage: "arrow.down.circle.fill")
                          //                  .frame(width: 190)
                          //          }
                          //          .buttonStyle(.borderedProminent)
//
                          //          Button {
                          //              copyPeelDownloadLink()
                          //          } label: {
                          //              Label(
                          //                  didCopyPeelLink ? "Copied" : "Copy Link",
                          //                  systemImage: didCopyPeelLink ? "checkmark.circle.fill" : "doc.on.doc"
                          //              )
                          //              .frame(width: 130)
                          //          }
                          //          .buttonStyle(.bordered)
                          //      }
                            }

                            TutorialStepRow(
                                number: "3",
                                title: "Pair and use your Mac apps",
                                message: "Enter the pairing code, then open Mac apps from your device."
                            )
                        }

                        quickTips
                    }
                    .padding(24)
                }
            }
            .navigationTitle("About Peel Pro")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Peel Pro")
                .font(.largeTitle.bold())

            Text("Share your Mac with Peel.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickTips: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tips")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                TipRow(title: "Keep Peel Pro open", message: "Peel Pro needs the Mac app running while connected.")

            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func copyPeelDownloadLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(peelDownloadURL.absoluteString, forType: .string)

        didCopyPeelLink = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopyPeelLink = false
        }
    }
}

private struct TutorialStepRow<Accessory: View>: View {
    let number: String
    let title: String
    let message: String
    @ViewBuilder let accessory: Accessory

    init(
        number: String,
        title: String,
        message: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.number = number
        self.title = title
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.blue))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private extension TutorialStepRow where Accessory == EmptyView {
    init(number: String, title: String, message: String) {
        self.number = number
        self.title = title
        self.message = message
        self.accessory = EmptyView()
    }
}

private struct TipRow: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout.weight(.semibold))

            Spacer(minLength: 16)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
