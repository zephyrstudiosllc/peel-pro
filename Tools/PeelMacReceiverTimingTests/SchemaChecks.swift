import Foundation

@main struct SchemaChecks {
    static func main() throws {
        let distribution = PeelLatencyDistribution(sampleCount: 2, p50Milliseconds: 0,
            p95Milliseconds: 1, maximumMilliseconds: 1)
        let metric = PeelReceiverTimingMetric(measurementKind: "sourcePTSRelativeMinimum",
            measurementWindowSeconds: 5, timingSampleCapacity: 1024, sampleWindowTruncated: false,
            callbackToMainAdmission: distribution, callbackToReceiveRearm: distribution,
            frameAdmissionToRendererDrain: distribution, frameAdmissionToDisplayEnqueue: distribution,
            sourcePTSRelativeEnqueueExcess: distribution, sourcePTSAvailability: .relativeMinimum,
            sourcePTSWindowSpanMilliseconds: 40, assumedRelativeClockDriftPPM: 100,
            sourcePTSRelativeDriftAllowanceMilliseconds: 0.004, ingressCallbacks: 2,
            fullChunkCallbacks: 1, sourcePTSMissingFrames: 0, sourcePTSDiscontinuities: 0,
            physicalPresentationMeasured: false)
        precondition(metric.isValid)
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metric)) as! [String: Any]
        var checks = 1
        func rejects(_ change: (inout [String: Any]) -> Void) throws {
            var modified = original; change(&modified)
            let decoded = try JSONDecoder().decode(PeelReceiverTimingMetric.self,
                from: JSONSerialization.data(withJSONObject: modified))
            precondition(!decoded.isValid); checks += 1
        }
        try rejects { $0["sourcePTSWindowSpanMilliseconds"] = 0 }
        try rejects { $0["sourcePTSWindowSpanMilliseconds"] = -1 }
        try rejects { $0["sourcePTSRelativeDriftAllowanceMilliseconds"] = 0 }
        try rejects { $0.removeValue(forKey: "sourcePTSWindowSpanMilliseconds") }
        try rejects { $0["sourcePTSAvailability"] = "unavailable" }
        try rejects { $0["physicalPresentationMeasured"] = true }
        try rejects { $0["assumedRelativeClockDriftPPM"] = 0 }
        try rejects {
            var value = $0["sourcePTSRelativeEnqueueExcess"] as! [String: Any]
            value["sampleCount"] = 1; $0["sourcePTSRelativeEnqueueExcess"] = value
        }
        for key in ["callbackToMainAdmission", "callbackToReceiveRearm", "frameAdmissionToRendererDrain",
                    "frameAdmissionToDisplayEnqueue", "sourcePTSRelativeEnqueueExcess"] {
            try rejects {
                var value = $0[key] as! [String: Any]
                value["sampleCount"] = 1025; $0[key] = value
            }
        }
        var maximum = original
        maximum["sourcePTSWindowSpanMilliseconds"] = 5000
        maximum["sourcePTSRelativeDriftAllowanceMilliseconds"] = 0.5
        let validMaximum = try JSONDecoder().decode(PeelReceiverTimingMetric.self,
            from: JSONSerialization.data(withJSONObject: maximum))
        precondition(validMaximum.isValid); checks += 1
        print("MacReceiverTimingSchemaChecks: PASS (\(checks) coverage/count/span/drift validation checks)")
    }
}
