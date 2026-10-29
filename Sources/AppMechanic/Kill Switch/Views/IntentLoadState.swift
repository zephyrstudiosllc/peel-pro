//
//  IntentLoadState.swift
//  Kill Switch
//

import SwiftUI

enum IntentLoadState: Equatable {
    case low
    case moderate
    case high
}

extension IntentLoadState {
    init(sample: ProcessSample?, metric: UsageMetric) {
        guard let sample else {
            self = .low
            return
        }

        switch metric {
        case .cpu:
            switch sample.cpu {
            case ..<35:
                self = .low
            case ..<70:
                self = .moderate
            default:
                self = .high
            }

        case .memory:
            switch sample.memoryMB {
            case ..<500:
                self = .low
            case ..<1500:
                self = .moderate
            default:
                self = .high
            }
        }
    }

    static func isAlerting(sample: ProcessSample?, metric: UsageMetric) -> Bool {
        guard let sample else { return false }

        switch metric {
        case .cpu:
            return sample.cpu >= 85
        case .memory:
            return sample.memoryMB >= 3000
        }
    }
}

struct IntentLoadGlyphView: View {
    let state: IntentLoadState
    var isAlerting: Bool = false
    var color: Color = .blue
    var alertColor: Color = .red
    var barWidth: CGFloat = 10
    var spacing: CGFloat = 6
    var cornerRadius: CGFloat = 6

    @State private var phase: Int = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            bar(height: heights[0])
            bar(height: heights[1])
            bar(height: heights[2])
        }
        .frame(height: maxHeight, alignment: .bottom)
        .onAppear {
            startAnimationLoop()
        }
        .onChange(of: state) { _, _ in
            phase = 0
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        activeColor.opacity(0.9),
                        activeColor
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: barWidth, height: height)
    }

    private var maxHeight: CGFloat {
        switch state {
        case .low: return 30
        case .moderate: return 40
        case .high: return 50
        }
    }

    private var heights: [CGFloat] {
        switch state {
        case .low:
            let frames: [[CGFloat]] = [
                [8, 12, 9],
                [9, 14, 10],
                [8, 13, 9],
                [9, 12, 10]
            ]
            return frames[phase % frames.count]

        case .moderate:
            let frames: [[CGFloat]] = [
                [12, 20, 14],
                [14, 24, 16],
                [13, 22, 15],
                [15, 25, 17]
            ]
            return frames[phase % frames.count]

        case .high:
            let frames: [[CGFloat]] = [
                [18, 30, 22],
                [22, 38, 26],
                [19, 32, 24],
                [24, 40, 28]
            ]
            return frames[phase % frames.count]
        }
    }

    private var shouldShowAlertState: Bool {
        state == .high && isAlerting
    }

    private var activeColor: Color {
        shouldShowAlertState ? alertColor : color
    }

    private var frameDuration: Double {
        shouldShowAlertState ? 0.32 : 0.75
    }

    private var accessibilityLabel: String {
        switch state {
        case .low: return "Low system load"
        case .moderate: return "Moderate system load"
        case .high: return "High system load"
        }
    }

    private func startAnimationLoop() {
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(frameDuration))
                withAnimation(.easeInOut(duration: frameDuration * 0.85)) {
                    phase = (phase + 1) % 4
                }
            }
        }
    }
}
