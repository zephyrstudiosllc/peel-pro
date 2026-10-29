import Foundation

@main
struct EncoderRecoveryChecks {
    static func main() {
        // A productive HEVC stream survives isolated watchdogs indefinitely;
        // one stalled callback must not permanently switch it to H.264.
        var productive = PeelVideoEncoderRecovery(prefersHEVC: true)
        for time in 0..<100 {
            productive.producedValidOutput()
            productive.runtimeFailed(at: Double(time))
            precondition(productive.candidate == .hevcLowLatency)
            precondition(productive.consecutiveRuntimeFailures == 1)
            precondition(productive.canAttempt(at: Double(time)))
        }

        // Consecutive failures without valid output exhaust each candidate,
        // then pause all attempts. A new burst starts with the preferred codec.
        var broken = PeelVideoEncoderRecovery(prefersHEVC: true)
        for candidate in [PeelVideoEncoderRecovery.Candidate.hevcLowLatency, .h264LowLatency, .h264Legacy] {
            precondition(broken.candidate == candidate)
            broken.runtimeFailed(at: 10)
            precondition(broken.candidate == candidate)
            broken.runtimeFailed(at: 10)
        }
        precondition(broken.retryAfterUptime == 15)
        for _ in 0..<1200 { precondition(!broken.canAttempt(at: 14.999)) }
        precondition(broken.canAttempt(at: 15))
        precondition(broken.retryAfterUptime == nil && broken.candidate == .hevcLowLatency)

        // Synchronous create/property/prepare failures cannot loop at source
        // cadence, including on a client that never negotiated HEVC.
        for prefersHEVC in [false, true] {
            var unavailable = PeelVideoEncoderRecovery(prefersHEVC: prefersHEVC)
            var attempts = 0
            while unavailable.canAttempt(at: 20) {
                attempts += 1
                precondition(attempts <= 3)
                if !prefersHEVC { precondition(unavailable.candidate != .hevcLowLatency) }
                unavailable.creationFailed(at: 20)
            }
            precondition(attempts == (prefersHEVC ? 3 : 2))
            precondition(unavailable.retryAfterUptime == 25)
            precondition(!unavailable.canAttempt(at: 24))
            precondition(unavailable.canAttempt(at: 25))
            precondition(unavailable.candidate == (prefersHEVC ? .hevcLowLatency : .h264LowLatency))
        }

        // A fake clock advances during synchronous attempts. Even a burst
        // longer than the cooldown leaves five full seconds after final failure.
        var slow = PeelVideoEncoderRecovery(prefersHEVC: true)
        var fakeUptime: TimeInterval = 100
        for _ in 0..<3 {
            precondition(slow.canAttempt(at: fakeUptime))
            fakeUptime += 3
            slow.creationFailed(at: fakeUptime)
        }
        precondition(slow.retryAfterUptime == 114)
        precondition(!slow.canAttempt(at: fakeUptime))
        precondition(!slow.canAttempt(at: 113.999))
        precondition(slow.canAttempt(at: 114))

        // A mixed create/runtime failure moves on and preserves the cooldown.
        var mixed = PeelVideoEncoderRecovery(prefersHEVC: true)
        mixed.runtimeFailed(at: 1)
        mixed.creationFailed(at: 2)
        precondition(mixed.candidate == .h264LowLatency && mixed.consecutiveRuntimeFailures == 0)
        mixed.creationFailed(at: 3)
        mixed.runtimeFailed(at: 4)
        mixed.runtimeFailed(at: 5)
        precondition(!mixed.canAttempt(at: 9.999))
        precondition(mixed.canAttempt(at: 10))
        print("PASS: transient recovery, bounded failures, cooldown and negotiated codec scope")
    }
}
