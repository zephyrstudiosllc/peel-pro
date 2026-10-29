#!/usr/bin/env python3
"""Exercise the exact creation loop with a clock that advances inside each attempt."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
HOST = HERE.parents[1] / "Peel-Host/PeelHost"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=HOST / "WindowStreamer.swift")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("    private func createSession() {")
end = source.index("    private func recordRecovery(state:", start)
method = source[start:end]
clock = "ProcessInfo.processInfo.systemUptime"
assert method.count(clock) in (1, 2), "Review changed production clock markers"
compiled_method = method.replace(clock, "fakeUptime")
fixture = """import Foundation
@MainActor final class CreationFixture {
    enum SessionMode { case lowLatency, legacy }
    enum Codec { case hevc, h264 }
    var isInvalidated = false
    var width = 5120, height = 2880
    var fakeUptime: TimeInterval = 100
    var activeCodec = Codec.hevc
    var session: Int?, sessionRetainedSelf: Int?
    var sessionMode: SessionMode?
    var recovery = PeelVideoEncoderRecovery(prefersHEVC: true)
    var attempts = 0
    func offer() { createSession() }
    private func recordRecovery(state: String) {}
    private func makeSession(mode: SessionMode, codec: Codec) -> (session: Int, retainedSelf: Int)? {
        attempts += 1
        fakeUptime += 3 // Simulated slow create/configure/prepare, no actual wait.
        return nil
    }
""" + compiled_method + """
}
@main struct Checks {
    static func main() {
        let fixture = CreationFixture()
        fixture.offer()
        guard fixture.attempts == 3, fixture.fakeUptime == 109,
              fixture.recovery.retryAfterUptime == 114 else {
            print("FAIL: cooldown must begin after the final slow attempt")
            exit(1)
        }
        for _ in 0..<1200 { fixture.offer() }
        guard fixture.attempts == 3 else { print("FAIL: source-cadence retries"); exit(1) }
        fixture.fakeUptime = 113.999
        fixture.offer()
        guard fixture.attempts == 3 else { exit(1) }
        fixture.fakeUptime = 114
        fixture.offer()
        guard fixture.attempts == 6, fixture.recovery.retryAfterUptime == 128 else { exit(1) }
        print("PASS: exact production loop waits five full seconds after slow failure")
    }
}
"""
with tempfile.TemporaryDirectory(prefix="peel-creation-loop-") as scratch:
    directory = Path(scratch)
    unit = directory / "CreationLoopChecks.swift"
    unit.write_text(fixture)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
                    str(HOST / "PeelVideoEncoderRecovery.swift"), str(unit), "-o", str(binary)],
                   check=True, timeout=60)
    result = subprocess.run([str(binary)], timeout=5)
    print(json.dumps({"productionCreationMethodSHA256": hashlib.sha256(method.encode()).hexdigest(),
                      "fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                      "substitution": "monotonic clock only; session creation stub advances three seconds",
                      "exitCode": result.returncode}), flush=True)
    raise SystemExit(result.returncode)
