//
//  HostPowerLockObserver.swift
//  Peel
//
//  Created by Zach on 12/22/25.
//


import AppKit

final class HostPowerLockObserver {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?

    private var workspaceNC: NotificationCenter { NSWorkspace.shared.notificationCenter }
    private let distNC = DistributedNotificationCenter.default()

    init() {
        workspaceNC.addObserver(self,
                                selector: #selector(handleWillSleep),
                                name: NSWorkspace.willSleepNotification,
                                object: nil)

        workspaceNC.addObserver(self,
                                selector: #selector(handleDidWake),
                                name: NSWorkspace.didWakeNotification,
                                object: nil)

        // These are “known good” in practice even though Apple doesn’t really “bless” them in shiny docs.
        distNC.addObserver(self,
                           selector: #selector(handleLocked),
                           name: Notification.Name("com.apple.screenIsLocked"),
                           object: nil)

        distNC.addObserver(self,
                           selector: #selector(handleUnlocked),
                           name: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil)
    }

    deinit {
        workspaceNC.removeObserver(self)
        distNC.removeObserver(self)
    }

    @objc private func handleWillSleep() { DispatchQueue.main.async { self.onSleep?() } }
    @objc private func handleDidWake()   { DispatchQueue.main.async { self.onWake?() } }
    @objc private func handleLocked()    { DispatchQueue.main.async { self.onLock?() } }
    @objc private func handleUnlocked()  { DispatchQueue.main.async { self.onUnlock?() } }
}