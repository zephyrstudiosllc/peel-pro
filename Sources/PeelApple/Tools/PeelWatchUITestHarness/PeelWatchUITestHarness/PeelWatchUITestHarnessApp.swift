//
//  PeelWatchUITestHarnessApp.swift
//  PeelWatchUITestHarness
//
//  Simulator-only placeholder target for the watchOS UI-testing bundle. The UI tests
//  drive the separately installed Peel Pro Watch app (com.zephyrstudiosllc.Peel.watchkitapp)
//  by bundle identifier; this app is never launched by them and contains no production code.
//

import SwiftUI

@main
struct PeelWatchUITestHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 6) {
                Image(systemName: "checklist")
                    .imageScale(.large)
                Text("Peel Watch UI Test Harness")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Test host only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
