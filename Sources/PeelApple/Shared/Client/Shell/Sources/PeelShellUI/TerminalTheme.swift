// Adapted from OrcheSSHtra (Conductor) 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
// See ORIGIN.md for provenance and changes.
//
//  TerminalTheme.swift
//  Conductor
//
//  Theme + font model skeleton for the terminal renderer (Phase 3). Colors are
//  stored as plain 8-bit RGB so themes stay Codable-friendly and independent of
//  UIKit/AppKit/SwiftTerm types; the host view converts at the edge. nonisolated
//  so themes are usable off the main actor and testable directly.
//

import Foundation

nonisolated struct TerminalThemeColor: Hashable, Codable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

nonisolated struct TerminalFontPreference: Hashable, Codable {
    /// Point size for the monospaced terminal font.
    var size: Double

    static let `default` = TerminalFontPreference(size: 12)
    /// Legible bounds for pinch-to-zoom / +/- adjustment.
    static let range: ClosedRange<Double> = 8...28

    /// A copy with `size` clamped into `range`.
    func clamped() -> TerminalFontPreference {
        TerminalFontPreference(size: min(max(size, Self.range.lowerBound), Self.range.upperBound))
    }

    /// Adjust by whole points (e.g. +/- buttons), clamped.
    func adjusted(bySteps steps: Int) -> TerminalFontPreference {
        TerminalFontPreference(size: size + Double(steps)).clamped()
    }

    /// Scale by a pinch magnification factor, clamped. Factor 1 = no change.
    func scaled(by factor: Double) -> TerminalFontPreference {
        guard factor > 0 else { return self }
        return TerminalFontPreference(size: (size * factor).rounded()).clamped()
    }
}

nonisolated struct TerminalTheme: Hashable, Codable, Identifiable {
    var id: String { name }
    var name: String
    var background: TerminalThemeColor
    var foreground: TerminalThemeColor
    /// The 16 ANSI palette entries, colors 0–15 in standard order
    /// (black, red, green, yellow, blue, magenta, cyan, white, then brights).
    var ansi: [TerminalThemeColor]

    /// Default dark theme; palette follows the common xterm defaults with a
    /// slightly lifted foreground for small pane sizes.
    static let defaultDark = TerminalTheme(
        name: "OrcheSSHtra Dark",
        background: TerminalThemeColor(0, 0, 0),
        foreground: TerminalThemeColor(230, 230, 230),
        ansi: [
            TerminalThemeColor(0, 0, 0),        // 0 black
            TerminalThemeColor(205, 49, 49),    // 1 red
            TerminalThemeColor(13, 188, 121),   // 2 green
            TerminalThemeColor(229, 229, 16),   // 3 yellow
            TerminalThemeColor(36, 114, 200),   // 4 blue
            TerminalThemeColor(188, 63, 188),   // 5 magenta
            TerminalThemeColor(17, 168, 205),   // 6 cyan
            TerminalThemeColor(229, 229, 229),  // 7 white
            TerminalThemeColor(102, 102, 102),  // 8 bright black
            TerminalThemeColor(241, 76, 76),    // 9 bright red
            TerminalThemeColor(35, 209, 139),   // 10 bright green
            TerminalThemeColor(245, 245, 67),   // 11 bright yellow
            TerminalThemeColor(59, 142, 234),   // 12 bright blue
            TerminalThemeColor(214, 112, 214),  // 13 bright magenta
            TerminalThemeColor(41, 184, 219),   // 14 bright cyan
            TerminalThemeColor(255, 255, 255),  // 15 bright white
        ]
    )
}
