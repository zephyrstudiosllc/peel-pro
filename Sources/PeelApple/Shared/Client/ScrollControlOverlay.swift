//
//  ScrollControlOverlay.swift
//  Peel
//
//  Created by Zach on 6/3/26.
//

import SwiftUI

struct ScrollControlOverlay: View {
    @State private var scrollTask: Task<Void, Never>?
    @State private var pressedDirectionY: CGFloat?

    var onScroll: (CGFloat, CGFloat) -> Void

    private let ornamentButtonSize: CGFloat = 44
    private let ornamentSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: ornamentSpacing) {
            scrollHoldButton(systemName: "chevron.up", directionY: 1)
            scrollHoldButton(systemName: "chevron.down", directionY: -1)
        }
        .onDisappear {
            stopScrollInertia()
        }
    }

    private func scrollHoldButton(systemName: String, directionY: CGFloat) -> some View {
        let isPressed = pressedDirectionY == directionY

        return ZStack {
            if isPressed {
                Circle()
                    .fill(.primary.opacity(0.14))
            }

            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: ornamentButtonSize, height: ornamentButtonSize)
        .contentShape(Circle())
#if os(visionOS)
        .glassBackgroundEffect(in: Circle())
#endif
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    pressedDirectionY = directionY
                    startScrollInertia(directionY: directionY)
                }
                .onEnded { _ in
                    pressedDirectionY = nil
                    stopScrollInertia()
                }
        )
        .accessibilityLabel(directionY > 0 ? "Scroll up" : "Scroll down")
        .accessibilityAddTraits(.isButton)
    }

    private func startScrollInertia(directionY: CGFloat) {
        guard scrollTask == nil else { return }

        scrollTask = Task { @MainActor in
            var step: CGFloat = 14
            let maxStep: CGFloat = 72
            let acceleration: CGFloat = 1.34

            onScroll(0, directionY * step)

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(45))
                guard !Task.isCancelled else { break }

                step = min(step * acceleration, maxStep)
                onScroll(0, directionY * step)
            }
        }
    }

    private func stopScrollInertia() {
        scrollTask?.cancel()
        scrollTask = nil
        pressedDirectionY = nil
    }
}
