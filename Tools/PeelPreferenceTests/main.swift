import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let profileBytes = Data([0x7b, 0x22, 0x73, 0x63, 0x68, 0x65, 0x6d, 0x61, 0x22, 0x3a, 0x39, 0x7d])
let batteryBytes = Data([0x01, 0x02, 0x03])
let colorBytes = Data([0x04, 0x05])
let calibrationBytes = Data([0x06, 0x07, 0x08, 0x09])

let source: [String: Any] = [
    "sidepulse.profile-library.v1": profileBytes,
    "sidepulse.default-profile-id.v1": "00000000-0000-0000-0000-000000000001",
    "sidepulse.live-output-enabled.v1": true,
    "sidepulse.battery-indicator.v1": batteryBytes,
    "sidepulse.agent-display-mode.v1": "detailed",
    "sidepulse.menu-bar-icon-style.v1": "horizontalEight",
    "sidepulse.menu-bar-visibility.v1": "whenNotchOff",
    "sidepulse.menu-bar-keep-auto-hidden.v1": false,
    "sidepulse.notch-enabled.v1": true,
    "sidepulse.notch-brightness.v1": 0.42,
    // The destination already owns this preference, so this source value
    // must not appear in the write plan.
    "sidepulse.universal-brightness.v1": 0.18,
    "sidepulse.flashlight-mode.v1": "overrideEverything",
    "sidepulse.pro-color-balance.v1": colorBytes,
    "sidepulse.device-output-calibrations.v2": calibrationBytes,

    // Validly typed values from network/action domains must remain excluded.
    "sidepulse.focus-automation-enabled.v1": true,
    "sidepulse.keep-awake-enabled.v1": true,
    "sidepulse.nearby-mirroring-mode.v1": "followNearbyMac",
    "sidepulse.selected-nearby-peer.v1": "peer-1",
    "sidepulse.nearby-sharing-enabled.v2": true,
    "sidepulse.nearby-discovery-enabled.v2": true,
    "sidepulse.device-signal-sources.v2": Data([0x0a]),
    "sidepulse.nearby-node-id.v1": "00000000-0000-0000-0000-000000000002",
    "sidepulse.eject-prevention-enabled.v1": true,

    // Unknown and malformed values are ignored as well.
    "sidepulse.provider-api-key.v1": "must-never-be-read",
    "sidepulse.default-profile-id.invalid": "00000000-0000-0000-0000-000000000003",
    "sidepulse.notch-brightness.invalid": 0.5,
    "sidepulse.default-profile-id.v1.invalid-type": 99,
]

let destination: [String: Any] = [
    "sidepulse.universal-brightness.v1": 0.91,
    "sidepulse.notch-enabled.v1": "host-owned-invalid-value",
]

let plan = PeelSidePulsePreferenceMigration.plan(source: source, destination: destination)
let expectedKeys: Set<String> = [
    "sidepulse.profile-library.v1",
    "sidepulse.default-profile-id.v1",
    "sidepulse.live-output-enabled.v1",
    "sidepulse.battery-indicator.v1",
    "sidepulse.agent-display-mode.v1",
    "sidepulse.menu-bar-icon-style.v1",
    "sidepulse.menu-bar-visibility.v1",
    "sidepulse.menu-bar-keep-auto-hidden.v1",
    "sidepulse.notch-brightness.v1",
    "sidepulse.flashlight-mode.v1",
    "sidepulse.pro-color-balance.v1",
    "sidepulse.device-output-calibrations.v2",
]
require(plan.shouldMarkComplete, "an unmarked destination should produce a one-time plan")
require(Set(plan.writes.keys) == expectedKeys, "only valid, absent allowlisted values may be written")
require(plan.writes["sidepulse.profile-library.v1"] as? Data == profileBytes, "profile JSON bytes must be copied verbatim")
require(plan.writes["sidepulse.battery-indicator.v1"] as? Data == batteryBytes, "battery data must be copied verbatim")
require(plan.writes["sidepulse.pro-color-balance.v1"] as? Data == colorBytes, "color data must be copied verbatim")
require(plan.writes["sidepulse.device-output-calibrations.v2"] as? Data == calibrationBytes, "calibration data must be copied verbatim")
require(plan.writes["sidepulse.universal-brightness.v1"] == nil, "an existing Host value must win")
require(plan.writes["sidepulse.notch-enabled.v1"] == nil, "any existing Host value must win, even if malformed")
require(plan.writes["sidepulse.provider-api-key.v1"] == nil, "unknown credential-like keys must be ignored")
require(plan.writes["sidepulse.focus-automation-enabled.v1"] == nil, "automation consent must be excluded")
require(plan.writes["sidepulse.nearby-node-id.v1"] == nil, "network identity must be excluded")

var malformedSource = source
malformedSource["sidepulse.notch-brightness.v1"] = 2.0
malformedSource["sidepulse.default-profile-id.v1"] = "not-a-uuid"
let malformedPlan = PeelSidePulsePreferenceMigration.plan(
    source: malformedSource,
    destination: [:]
)
require(malformedPlan.writes["sidepulse.notch-brightness.v1"] == nil, "out-of-range brightness must be ignored")
require(malformedPlan.writes["sidepulse.default-profile-id.v1"] == nil, "invalid profile IDs must be ignored")

require(
    PeelSidePulsePreferenceMigration.sourceBundleIdentifier == "com.zephyrstudiosllc.sidepulse-z",
    "migration must use the current SidePulse component bundle ID"
)
require(
    PeelSidePulsePreferenceMigration.targetBundleIdentifier == "com.zephyrstudiosllc.Peel-Host",
    "migration target must identify the unified Host"
)
require(
    Set(PeelSidePulsePreferenceMigration.allowlistedKeys).isDisjoint(
        with: PeelSidePulsePreferenceMigration.excludedKeys
    ),
    "the allowlist and exclusion list must remain disjoint"
)

let completedDestination: [String: Any] = [
    PeelSidePulsePreferenceMigration.migrationMarker: true,
]
let completedPlan = PeelSidePulsePreferenceMigration.plan(
    source: source,
    destination: completedDestination
)
require(!completedPlan.shouldMarkComplete && completedPlan.writes.isEmpty, "completed migration must be idempotent")

let malformedMarkerPlan = PeelSidePulsePreferenceMigration.plan(
    source: source,
    destination: [PeelSidePulsePreferenceMigration.migrationMarker: false]
)
require(malformedMarkerPlan.shouldMarkComplete, "a false marker permits a retry")

print("PeelSidePulsePreferenceMigrationChecks: PASS")
