import AppKit
import Foundation

/// What each top-right utility can actually affect right now. Computed from
/// existing store state only; it adds no sampling, polling or stored settings.
extension CommandCenterStore {
    /// Lights (`setOutputPower`) drives connected SidePulse Pro/Dot hardware
    /// only. Notch Display has its own switch and brightness.
    var hardwareLightTargetConnected: Bool {
        proDevice.connected || dotDevice.connected
    }

    /// Hardware is connected and its output is on (agent lighting or White Light).
    var hardwareLightsActive: Bool {
        hardwareLightTargetConnected && outputPowerIsOn
    }

    /// Notch Display draws nothing at 0% brightness.
    var notchLightOutputVisible: Bool {
        notchEnabled && notchBrightness > 0.000_1
    }

    /// White Light and On-Air render on connected hardware and on a visible
    /// Notch Display.
    var lightOutputAvailable: Bool {
        hardwareLightTargetConnected || notchLightOutputVisible
    }

    var lightOutputUnavailableReason: String {
        notchEnabled
            ? "Notch Display brightness is 0%. Raise it in \(CommandCenterSection.settings.title) › Modes › Top Display or connect a SidePulse Pro or Dot."
            : "Needs Notch Display or a connected SidePulse Pro or Dot."
    }

    var hardwareLightsUnavailableReason: String {
        "Connect a SidePulse Pro or Dot. Notch Display has its own switch."
    }

    /// Where Notch Display draws. Macs without a notch use the top of the main display.
    var notchDisplayPlacement: String {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
            ? "around the notch at the top of the screen"
            : "at the top of the main display"
    }

    var hardwareLightTargets: String {
        var targets: [String] = []
        if proDevice.connected { targets.append("SidePulse Pro") }
        if dotDevice.connected { targets.append("SidePulse Dot") }
        return targets.joined(separator: ", ")
    }

    var lightOutputTargets: String {
        var targets: [String] = []
        if notchLightOutputVisible { targets.append("Notch Display") }
        if hardwareLightTargetConnected { targets.append(hardwareLightTargets) }
        return targets.isEmpty ? "no light output" : targets.joined(separator: ", ")
    }

    /// Lights is enabled while hardware is connected, or while its output is
    /// still set to on so it can be turned off before a device reconnects.
    var hardwareLightsHelp: String {
        let alsoWhiteLight = flashlightEnabled ? " and White Light" : ""
        if hardwareLightsActive {
            return "Turn off SidePulse lights\(alsoWhiteLight) on \(hardwareLightTargets). Notch Display has its own switch."
        }
        if hardwareLightTargetConnected {
            return "Turn on SidePulse lights on \(hardwareLightTargets). Notch Display has its own switch."
        }
        if outputPowerIsOn {
            return "SidePulse lights are set to on, but no SidePulse Pro or Dot is connected. Turn off\(alsoWhiteLight) to keep them dark when one connects."
        }
        return hardwareLightsUnavailableReason
    }

    var hardwareLightsStateDescription: String {
        if hardwareLightsActive { return "On" }
        if outputPowerIsOn { return "On when a SidePulse connects" }
        return hardwareLightTargetConnected ? "Off" : "Unavailable"
    }

    /// The configured Flashlight behavior, described for the current targets.
    /// The Notch Display shows uncalibrated white; SidePulse Pro applies the
    /// user's color balance; SidePulse Dot stays neutral.
    var whiteLightEffect: String {
        let proBalance = proDevice.connected ? " SidePulse Pro uses your color balance." : ""
        switch flashlightMode {
        case .overrideEverything:
            return "replaces all lighting with full-brightness white.\(proBalance)"
        case .behindAnimations:
            return "fills unlit LEDs with white while agent and utility colors and motion continue.\(proBalance)"
        }
    }

    var whiteLightHelp: String {
        let behavior = "Change in \(CommandCenterSection.settings.title) › App › Flashlight behavior."
        if flashlightEnabled {
            return "Turn off White Light (\(flashlightMode.title)). \(behavior)"
        }
        return "Turn on White Light (\(flashlightMode.title)) on \(lightOutputTargets): \(whiteLightEffect) \(behavior)"
    }

    /// True when at least one utility is doing something worth surfacing on
    /// pages outside Notch Pulse.
    var hasActiveUtility: Bool {
        keepAwakeEnabled || timerState.isActive || utilityMode == .microphone ||
            flashlightEnabled || hardwareLightsActive
    }
}
