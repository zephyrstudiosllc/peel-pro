//
//  MacMechanicUpdateAvailableBanner.swift
//  Kill Switch
//
//  Created by Zach on 4/17/26.
//


import SwiftUI

struct MacMechanicUpdateAvailableBanner: View {
    let update: MacMechanicUpdaterController.PendingUpdate
    let onUpdateNow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label("Update Available", systemImage: "arrow.down.circle.fill")
                    .font(.headline)

                Spacer()

                Text("v\(update.version)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !update.title.isEmpty {
                Text(update.title)
                    .font(.subheadline.weight(.semibold))
            }

            Text(update.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not Now") {
                    onNotNow()
                }

                Spacer()

                Button("Update Now") {
                    onUpdateNow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 10)
        .padding()
    }
}
