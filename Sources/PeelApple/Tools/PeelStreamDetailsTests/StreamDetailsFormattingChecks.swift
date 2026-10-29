import Foundation

struct FixtureMetric { let avPerformance: PeelAVPerformanceMetric? }

@main
struct StreamDetailsFormattingChecks {
    static func main() {
        func sample(age: Double, drops: Int64 = 0) -> PeelAVPerformanceMetric {
            .init(totalFrames: 10, droppedFrames: drops, corruptedFrames: 0,
                  optimizedCompositingFrames: 0, accumulatedFrameDelaySeconds: 0,
                  sampleAgeMilliseconds: age, intervalSeconds: nil, estimatedPresentedFPS: nil)
        }
        func value(_ metric: PeelAVPerformanceMetric?) -> String { actualDecoderDropRow(FixtureMetric(avPerformance: metric)) }
        precondition(value(nil) == "Unavailable", "No sample or reset must clear the displayed count")
        precondition(value(sample(age: 0)) == "0", "A fresh zero is a valid measurement")
        precondition(value(sample(age: 4_999, drops: 3)) == "3")
        precondition(value(sample(age: 5_000, drops: 2)) == "2", "Use the collector's inclusive five-second freshness boundary")
        precondition(value(sample(age: 5_000.1)) == "Unavailable", "Stale decoder count must be unavailable, never an old healthy zero")
        precondition(value(sample(age: 60_000, drops: 3)) == "Unavailable")
        precondition(value(nil) == "Unavailable", "Reset after a previous reading removes it")
        precondition(value(sample(age: 0, drops: 1)) == "1", "A fresh post-reset reading remains usable")
        precondition(value(sample(age: .nan)) == "Unavailable")
        precondition(value(sample(age: -1)) == "Unavailable")
        precondition(value(sample(age: 0, drops: 11)) == "Unavailable", "Invalid raw metrics must not be displayed")
        print("StreamDetailsFormattingChecks: PASS (actual display expression, fresh/stale/nil/reset/invalid readings)")
    }
}
