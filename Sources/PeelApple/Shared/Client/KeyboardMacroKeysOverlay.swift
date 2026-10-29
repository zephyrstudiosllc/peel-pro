//
//  KeyboardMacroKeysOverlay.swift
//  Peel
//
//  Created by Zach on 6/15/26.
//

import SwiftUI

struct KeyboardMacroKeysOverlay: View {
    var onEscape: () -> Void
    var onTab: () -> Void
    var isShiftEnabled: Bool = false
    var isShiftActive: Bool = false
    var onShift: () -> Void = {}

    var body: some View {
        VStack(spacing: KeyboardMacroOrnamentMetrics.spacing) {
            KeyboardMacroOrnamentButton(accessibilityLabel: "Escape") {
                onEscape()
            } label: {
                Text("Esc")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }

            KeyboardMacroOrnamentButton(accessibilityLabel: "Tab") {
                onTab()
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 17, weight: .semibold))
            }

            KeyboardMacroOrnamentButton(
                accessibilityLabel: "Shift",
                isEnabled: isShiftEnabled,
                isActive: isShiftActive
            ) {
                onShift()
            } label: {
                Image(systemName: "shift")
                    .font(.system(size: 17, weight: .semibold))
            }
        }
    }
}

enum KeyboardMacroOrnamentMetrics {
    static let width: CGFloat = 48
    static let height: CGFloat = 34
    static let cornerRadius: CGFloat = 14
    static let spacing: CGFloat = 10
}

struct KeyboardMacroOrnamentButton<Label: View>: View {
    let accessibilityLabel: String
    let isEnabled: Bool
    let isActive: Bool
    let action: () -> Void

    private let label: () -> Label

    init(
        accessibilityLabel: String,
        isEnabled: Bool = true,
        isActive: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
        self.isActive = isActive
        self.action = action
        self.label = label
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: KeyboardMacroOrnamentMetrics.cornerRadius,
            style: .continuous
        )

        let button = Button {
            action()
        } label: {
            label()
                .foregroundStyle(isActive ? Color.blue : Color.primary)
                .frame(
                    width: KeyboardMacroOrnamentMetrics.width,
                    height: KeyboardMacroOrnamentMetrics.height
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .clipShape(shape)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)

#if os(visionOS)
        return button.glassBackgroundEffect(in: shape)
#else
        return button.background(.regularMaterial, in: shape)
#endif
    }
}

struct KeyboardMacroOrnamentPlaceholder: View {
    var body: some View {
        Color.clear
            .frame(
                width: KeyboardMacroOrnamentMetrics.width,
                height: KeyboardMacroOrnamentMetrics.height
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct KeyboardModifierKeysOverlay: View {
    var heldCommands: [KeyboardCommand] = []
    var onFunction: () -> Void
    var onControl: () -> Void
    var onOption: () -> Void
    var onCommand: () -> Void

    var body: some View {
        HStack(spacing: KeyboardMacroOrnamentMetrics.spacing) {
            KeyboardMacroOrnamentButton(
                accessibilityLabel: "Function",
                isActive: heldCommands.contains(.function)
            ) {
                onFunction()
            } label: {
                Text("fn")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }

            KeyboardMacroOrnamentButton(
                accessibilityLabel: "Control",
                isActive: heldCommands.contains(.control)
            ) {
                onControl()
            } label: {
                Image(systemName: "control")
                    .font(.system(size: 17, weight: .semibold))
            }

            KeyboardMacroOrnamentButton(
                accessibilityLabel: "Option",
                isActive: heldCommands.contains(.option)
            ) {
                onOption()
            } label: {
                Image(systemName: "option")
                    .font(.system(size: 17, weight: .semibold))
            }

            KeyboardMacroOrnamentButton(
                accessibilityLabel: "Command",
                isActive: heldCommands.contains(.command)
            ) {
                onCommand()
            } label: {
                Image(systemName: "command")
                    .font(.system(size: 17, weight: .semibold))
            }
        }
    }
}
