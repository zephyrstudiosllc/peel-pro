//
//  PeelSourceMediaKeys.swift
//  Peel-Host
//
//  Posts this Mac's own media keys (NX_SYSDEFINED aux control buttons, the
//  events a hardware play/next/previous key produces). It never uses the
//  Space key, scripts or a receiver-side media API, and asks for no permission.
//

import AppKit
import IOKit.hidsystem

struct PeelSourceMediaKeys: PeelSourceMediaKeyPosting {
    static func keyType(for action: PeelSourceMediaAction) -> Int32 {
        switch action {
        case .playPause: return NX_KEYTYPE_PLAY
        case .previousTrack: return NX_KEYTYPE_PREVIOUS
        case .nextTrack: return NX_KEYTYPE_NEXT
        }
    }

    func post(_ action: PeelSourceMediaAction) -> PeelSourceMediaKeyPostResult {
        // Preflight only reads the existing grant; it never prompts.
        guard CGPreflightPostEventAccess() else { return .accessDenied }
        let key = Int(Self.keyType(for: action))
        // Both events exist before either is posted, so a key is never left held.
        guard let down = Self.event(key: key, down: true),
              let up = Self.event(key: key, down: false) else { return .unavailable }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .posted
    }

    private static func event(key: Int, down: Bool) -> CGEvent? {
        let state = down ? 0xA : 0xB
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
            data1: (key << 16) | (state << 8),
            data2: -1
        )?.cgEvent else { return nil }
        // Same marker as other Peel posts so local-access input monitoring
        // does not mistake this for a person at this Mac.
        event.setIntegerValueField(.eventSourceUserData, value: PeelLocalComputerWindowPolicy.postedEventMarker)
        return event
    }
}
