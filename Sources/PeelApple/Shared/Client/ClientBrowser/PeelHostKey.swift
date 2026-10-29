//
//  PeelHostKey.swift
//  Peel
//
//  Created by Zach on 6/15/26.
//


import Foundation

struct PeelHostKey: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }
}

struct PeelWindowInstanceID: Hashable, Codable, Identifiable {
    let hostKey: PeelHostKey
    let windowId: UInt32

    var id: String {
        "\(hostKey.rawValue)::windowId:\(windowId)"
    }
}

struct HostedPeelWindow: Identifiable, Hashable, Codable {
    let hostKey: PeelHostKey
    let hostName: String
    let window: PeelWindow

    var instanceID: PeelWindowInstanceID {
        PeelWindowInstanceID(hostKey: hostKey, windowId: window.windowId)
    }

    var id: String {
        instanceID.id
    }
}

extension PeelHostInfo {
    var hostKey: PeelHostKey {
        PeelHostKey(rawValue: stableIdentityKey)
    }
}