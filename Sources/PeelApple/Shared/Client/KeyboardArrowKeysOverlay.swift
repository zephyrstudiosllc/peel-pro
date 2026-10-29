//
//  KeyboardArrowKeysOverlay.swift
//  Peel
//
//  Created by Zach on 6/15/26.
//

import SwiftUI

struct KeyboardArrowKeysOverlay: View {
    var onLeft: () -> Void
    var onUp: () -> Void
    var onDown: () -> Void
    var onRight: () -> Void

    var body: some View {
        HStack(spacing: KeyboardMacroOrnamentMetrics.spacing) {
            VStack(spacing: KeyboardMacroOrnamentMetrics.spacing) {
                KeyboardMacroOrnamentPlaceholder()

                KeyboardMacroOrnamentButton(accessibilityLabel: "Left arrow") {
                    onLeft()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 17, weight: .semibold))
                }
            }

            VStack(spacing: KeyboardMacroOrnamentMetrics.spacing) {
                KeyboardMacroOrnamentButton(accessibilityLabel: "Up arrow") {
                    onUp()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                }

                KeyboardMacroOrnamentButton(accessibilityLabel: "Down arrow") {
                    onDown()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                }
            }

            VStack(spacing: KeyboardMacroOrnamentMetrics.spacing) {
                KeyboardMacroOrnamentPlaceholder()

                KeyboardMacroOrnamentButton(accessibilityLabel: "Right arrow") {
                    onRight()
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
    }
}
