//
//  PeelSidePulsePreferenceMigration.swift
//  Bounded, one-time preference migration for the unified Peel Host.
//
//  The source domain belongs to the released SidePulse component. The target
//  is the unified Host's normal UserDefaults domain. Only the explicit list
//  below is read or copied; the source domain is never removed or rewritten.
//

import Foundation

/// Copies the SidePulse settings that describe local presentation, hardware
/// appearance, and saved profiles into the unified Host.
///
/// This helper intentionally does not know about SidePulse model types. That
/// keeps the migration testable with in-memory dictionaries and preserves the
/// profile JSON bytes and import format exactly as they were stored.
nonisolated public enum PeelSidePulsePreferenceMigration {
    /// The current product bundle identifier from the SidePulse component.
    /// Keep this separate from the stale legacy identifier used by the old
    /// in-place replacement migration in the standalone app.
    public static let sourceBundleIdentifier = "com.zephyrstudiosllc.sidepulse-z"

    /// The unified Host's bundle identifier. The runtime destination is
    /// UserDefaults.standard when this helper is called by Peel Host.
    public static let targetBundleIdentifier = "com.zephyrstudiosllc.Peel-Host"

    /// Target-only marker. It is written after the allowlisted values have
    /// been copied, so a later Host launch does not repeatedly import them.
    public static let migrationMarker = "peel.migration.sidepulse-preferences.v1"

    /// Public SidePulse values that are safe to carry into the unified Host.
    /// Data values are copied byte-for-byte; scalar values are type-checked.
    public static let allowlistedKeys: [String] = [
        "sidepulse.profile-library.v1",
        "sidepulse.default-profile-id.v1",
        "sidepulse.live-output-enabled.v1",
        "sidepulse.battery-indicator.v1",
        "sidepulse.agent-display-mode.v1",
        "sidepulse.menu-bar-icon-style.v1",
        "sidepulse.menu-bar-visibility.v1",
        "sidepulse.menu-bar-keep-auto-hidden.v1",
        "sidepulse.notch-enabled.v1",
        "sidepulse.notch-brightness.v1",
        "sidepulse.universal-brightness.v1",
        "sidepulse.flashlight-mode.v1",
        "sidepulse.pro-color-balance.v1",
        "sidepulse.device-output-calibrations.v2",
    ]

    /// Known SidePulse values deliberately left behind. Keeping this list
    /// close to the allowlist makes it auditable when AppPreferences grows.
    /// It includes network identity/sharing, follow targets, power/system
    /// actions, and automation consent.
    public static let excludedKeys: [String] = [
        "sidepulse.focus-automation-enabled.v1",
        "sidepulse.keep-awake-enabled.v1",
        "sidepulse.nearby-mirroring-mode.v1",
        "sidepulse.selected-nearby-peer.v1",
        "sidepulse.nearby-sharing-enabled.v2",
        "sidepulse.nearby-discovery-enabled.v2",
        "sidepulse.device-signal-sources.v2",
        "sidepulse.nearby-node-id.v1",
        "sidepulse.eject-prevention-enabled.v1",
    ]

    /// The result is intentionally dictionary-based so callers and fixtures
    /// can inspect exactly which values would be written before applying them.
    public struct Plan {
        public let writes: [String: Any]
        public let shouldMarkComplete: Bool

        public init(writes: [String: Any], shouldMarkComplete: Bool) {
            self.writes = writes
            self.shouldMarkComplete = shouldMarkComplete
        }
    }

    private enum ValueRule {
        case data
        case string
        case uuidString
        case boolean
        case unitInterval
    }

    private static let valueRules: [String: ValueRule] = [
        "sidepulse.profile-library.v1": .data,
        "sidepulse.default-profile-id.v1": .uuidString,
        "sidepulse.live-output-enabled.v1": .boolean,
        "sidepulse.battery-indicator.v1": .data,
        "sidepulse.agent-display-mode.v1": .string,
        "sidepulse.menu-bar-icon-style.v1": .string,
        "sidepulse.menu-bar-visibility.v1": .string,
        "sidepulse.menu-bar-keep-auto-hidden.v1": .boolean,
        "sidepulse.notch-enabled.v1": .boolean,
        "sidepulse.notch-brightness.v1": .unitInterval,
        "sidepulse.universal-brightness.v1": .unitInterval,
        "sidepulse.flashlight-mode.v1": .string,
        "sidepulse.pro-color-balance.v1": .data,
        "sidepulse.device-output-calibrations.v2": .data,
    ]

    /// Returns values from the source suite by reading only the explicit
    /// allowlist. No dictionaryRepresentation or preference file is read.
    public static func sourceValues(from defaults: UserDefaults?) -> [String: Any] {
        guard let defaults else { return [:] }
        var values: [String: Any] = [:]
        for key in allowlistedKeys {
            guard let value = defaults.object(forKey: key), isValid(value, for: key) else {
                continue
            }
            values[key] = value
        }
        return values
    }

    /// Reads only target keys so an existing unified Host value can be
    /// preserved. Invalid existing target values are still returned because
    /// this migration must not overwrite anything the Host already owns.
    public static func destinationValues(from defaults: UserDefaults) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in allowlistedKeys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            }
        }
        if let marker = defaults.object(forKey: migrationMarker) {
            values[migrationMarker] = marker
        }
        return values
    }

    /// Builds a pure migration plan. Existing destination values always win;
    /// source values with the wrong type are ignored.
    public static func plan(
        source: [String: Any],
        destination: [String: Any]
    ) -> Plan {
        guard !isCompleteMarker(destination[migrationMarker]) else {
            return Plan(writes: [:], shouldMarkComplete: false)
        }

        var writes: [String: Any] = [:]
        for key in allowlistedKeys {
            guard destination[key] == nil,
                  let value = source[key],
                  isValid(value, for: key)
            else { continue }
            writes[key] = value
        }
        return Plan(writes: writes, shouldMarkComplete: true)
    }

    /// Applies the one-time migration during the unified Host initializer.
    /// The source UserDefaults suite is read one key at a time and is never
    /// mutated. A nil source suite leaves the marker unset so a later launch
    /// can retry if the source domain becomes available.
    @discardableResult
    public static func migrateIfNeeded(
        source: UserDefaults?,
        destination: UserDefaults = .standard
    ) -> Plan {
        guard source != nil else {
            return Plan(writes: [:], shouldMarkComplete: false)
        }

        let plan = plan(
            source: sourceValues(from: source),
            destination: destinationValues(from: destination)
        )
        guard plan.shouldMarkComplete else { return plan }

        for key in allowlistedKeys {
            if let value = plan.writes[key] {
                destination.set(value, forKey: key)
            }
        }
        destination.set(true, forKey: migrationMarker)
        return plan
    }

    private static func isValid(_ value: Any, for key: String) -> Bool {
        guard let rule = valueRules[key] else { return false }
        switch rule {
        case .data:
            return value is Data
        case .string:
            return value is String
        case .uuidString:
            guard let rawValue = value as? String else { return false }
            return UUID(uuidString: rawValue) != nil
        case .boolean:
            if value is Bool { return true }
            guard let number = value as? NSNumber else { return false }
            let type = String(cString: number.objCType)
            return type == "c" || type == "B"
        case .unitInterval:
            if value is Bool { return false }
            let number: Double?
            if let double = value as? Double {
                number = double
            } else if let float = value as? Float {
                number = Double(float)
            } else if let numberValue = value as? NSNumber {
                number = numberValue.doubleValue
            } else {
                number = nil
            }
            guard let number else { return false }
            return number.isFinite && (0...1).contains(number)
        }
    }

    private static func isCompleteMarker(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        return (type == "c" || type == "B") && number.boolValue
    }
}
