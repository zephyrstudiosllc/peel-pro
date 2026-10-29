//
//  HostAwakeController.swift
//  Peel
//
//  Created by Zach on 12/22/25.
//


import Foundation

// Callers must keep the returned activity alive and call `stop()` when done.
final class HostAwakeController {
    private var activity: NSObjectProtocol?

    /// Keeps the Mac awake (prevents idle *system* sleep). This preserves the original API.
    func start(reason: String) {
        start(reason: reason, keepDisplayAwake: false)
    }

    /// Keeps the Mac awake, and optionally keeps the display from sleeping due to user-idle.
    ///
    /// - keepDisplayAwake: When true, includes `.idleDisplaySleepDisabled` so the screen stays powered on.
    func start(reason: String, keepDisplayAwake: Bool) {
        guard activity == nil else { return }

        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if keepDisplayAwake {
            options.insert(.idleDisplaySleepDisabled)
        }

        activity = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: reason
        ) as NSObjectProtocol
    }

    func stop() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
