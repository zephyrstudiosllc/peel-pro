//
//  SystemMetricComponents.swift
//  Kill Switch
//

import SwiftUI

struct SystemMetricGauge: View {
    let progress: Double?
    let valueText: String
    let tint: Color
    var size: CGFloat = 92

    private var clampedProgress: Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: max(6, size * 0.09))

            if let clampedProgress {
                Circle()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: max(6, size * 0.09),
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0.08, to: 0.92)
                    .stroke(
                        Color.secondary.opacity(0.35),
                        style: StrokeStyle(
                            lineWidth: max(6, size * 0.09),
                            lineCap: .round,
                            dash: [3, 5]
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }

            Text(valueText)
                .font(size >= 80 ? .headline : .caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(tint)
                .padding(size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(valueText)
    }
}

struct SystemMetricGaugeCard: View {
    let title: String
    let status: String
    let subtitle: String
    let systemImage: String
    let progress: Double?
    let valueText: String
    let tint: Color

    var body: some View {
        VStack(spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)

            SystemMetricGauge(
                progress: progress,
                valueText: valueText,
                tint: tint,
                size: 108
            )

            VStack(spacing: 5) {
                Text(status)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
    }
}

struct SystemMetricSummaryTile: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let progress: Double?
    let tint: Color
    var gaugeValue: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)

                Text(value)
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            SystemMetricGauge(
                progress: progress,
                valueText: gaugeValue ?? value,
                tint: tint,
                size: 54
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .accessibilityElement(children: .combine)
    }
}

struct SystemMetricActivityRow: View {
    let title: String
    let value: String
    let detail: String?
    let systemImage: String
    let progress: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 20)

                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            if let progress, progress.isFinite {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(tint)
            } else {
                ProgressView(value: 0)
                    .tint(.secondary)
                    .opacity(0.35)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .accessibilityElement(children: .combine)
    }
}

enum SystemMetricFormatting {
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        let clampedValue = min(value, UInt64(Int64.max))
        return ByteCountFormatter.string(
            fromByteCount: Int64(clampedValue),
            countStyle: .file
        )
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        let clampedValue = min(value, Double(Int64.max))
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(clampedValue.rounded()),
            countStyle: .file
        )
        return "\(bytes)/s"
    }

    static func percent(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        let clampedValue = min(max(value, 0), 100)
        return String(format: "%.*f%%", fractionDigits, clampedValue)
    }
}
