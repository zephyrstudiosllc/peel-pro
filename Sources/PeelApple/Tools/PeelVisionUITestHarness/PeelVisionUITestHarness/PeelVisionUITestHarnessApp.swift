//
//  PeelVisionUITestHarnessApp.swift
//  PeelVisionUITestHarness
//
//  Simulator-only placeholder target for the visionOS UI-testing bundle. The UI tests
//  drive the separately installed Peel Pro (com.zephyrstudiosllc.Peel) by bundle
//  identifier; this app is never launched by them and contains no production code.
//

import SwiftUI

@main
struct PeelVisionUITestHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "checklist")
                    .imageScale(.large)
                Text("Peel Vision UI Test Harness")
                    .font(.headline)
                Text("Test host only. Tests drive the installed Peel Pro app.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
