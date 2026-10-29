#!/usr/bin/env python3
"""Compile and run the exact production encoder against synthetic motion only."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HOST = ROOT / "Sources/PeelHost/Peel-Host"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, choices=[1920, 2560, 3840, 5120], default=5120)
    parser.add_argument("--height", type=int, choices=[1080, 1440, 2160, 2880], default=2880)
    parser.add_argument("--fps", type=int, choices=[30, 60, 120], default=120)
    parser.add_argument("--seconds", type=int, choices=range(2, 31), default=10)
    parser.add_argument("--codec", choices=["hevc", "h264"], default="hevc")
    parser.add_argument("--pixel-format", choices=["nv12", "bgra"], default="bgra")
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--fault", choices=["none", "drop-one-output", "drop-all-outputs", "fail-all-session-creates"], default="none",
                        help="Explicit test-only failure injection; never changes the production source.")
    parser.add_argument("--capture-dir", type=pathlib.Path,
                        help="New directory for up to32 synthetic encoded frames; marks run as instrumented.")
    parser.add_argument("--variant", choices=["production", "hardware-realtime-experiment", "hardware-realtime-flush-experiment", "hardware-capability"], default="production",
                        help="Explicit experiment removes low-latency encoder selection and disallows reordering/lookahead.")
    args = parser.parse_args()
    if args.fault != "none" and args.variant != "production":
        parser.error("Fault injection is scoped to the production encoder variant")
    if args.capture_dir and args.variant == "hardware-capability":
        parser.error("Output capture requires the production encoder or its explicit transformed variants")
    source_path = HOST / "PeelHost/WindowStreamer.swift"
    source = source_path.read_text()
    color = source[source.index("private enum VideoColorMetadata {"):source.index("private final class WindowFrameScalerCache {")]
    encoder = source[source.index("private final class VideoH264Encoder {"):]
    production_encoder_hash = hashlib.sha256(encoder.encode()).hexdigest()
    if args.fault == "fail-all-session-creates":
        start = "        let status = VTCompressionSessionCreate("
        end = "            compressionSessionOut: &newSession\n        )"
        if encoder.count(start) != 1 or encoder.count(end) != 1:
            raise SystemExit("Production session-creation marker changed; transform must be reviewed")
        first = encoder.index(start)
        last = encoder.index(end, first) + len(end)
        encoder = encoder[:first] + "        let status: OSStatus = kVTInvalidSessionErr // TEST-ONLY create failure" + encoder[last:]
    elif args.fault != "none":
        fields = "    var onOutput: ((EncodedAccessUnit) -> Void)?"
        callback = "            guard encoder.encodeSequence == callbackSequence else { return }"
        if encoder.count(fields) != 1 or encoder.count(callback) != 1:
            raise SystemExit("Production fault-injection marker changed; transform must be reviewed")
        encoder = encoder.replace(fields, "    private var benchCallbackCount = 0\n" + fields)
        condition = "encoder.benchCallbackCount == 10" if args.fault == "drop-one-output" else "true"
        encoder = encoder.replace(callback, callback + "\n"
            "            encoder.benchCallbackCount += 1\n"
            f"            if {condition} {{ return }} // TEST-ONLY suppressed callback\n")
    if args.variant not in ["production", "hardware-capability"]:
        replacements = {
            "        if mode == .lowLatency {\n            let codec = codec ?? activeCodec":
                "        let speedStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)\n"
                "        diagnostics.setSpeedPriorityStatus(windowID: windowId, token: diagnosticToken, status: speedStatus)\n"
                "        if mode == .lowLatency {\n            let codec = codec ?? activeCodec",
            "                kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,\n": "",
            "                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),":
                "                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),\n"
                "                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),\n"
                "                (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0)),",
            'mode: mode == .lowLatency ? "lowLatency" : "legacy",':
                'mode: mode == .lowLatency ? "hardwareRealtimeExperiment" : "legacy",'
        }
        if args.variant == "hardware-realtime-flush-experiment":
            replacements["                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),"] = (
                "                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),\n"
                "                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),")
            replacements["        if status != noErr {\n            encodeInFlightCount"] = (
                "        if status == noErr {\n"
                "            let flushStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)\n"
                "            if flushStatus != noErr { diagnostics.sessionFailure(windowID: windowId, token: diagnosticToken, reason: \"experimental flush status=\\(flushStatus)\") }\n"
                "        }\n\n"
                "        if status != noErr {\n            encodeInFlightCount")
        for before, after in replacements.items():
            if encoder.count(before) != 1:
                raise SystemExit("Production marker changed; experimental transform must be reviewed")
            encoder = encoder.replace(before, after)
    wire = (HOST / "PeelSharedMessages.swift").read_text()
    codec = wire[wire.index("enum PeelVideoCodec:"):wire.index("struct VideoConfigPacket {")]
    harness = (HERE / "EncoderBench.swift").read_text()
    capture_support = (HERE / "EncodedCapture.swift").read_text()
    if args.variant == "hardware-capability":
        encoder = (HERE / "HardwareCapabilityEncoder.swift").read_text()
        harness = harness.replace("VideoH264Encoder", "HardwareCapabilityEncoder")
        harness = harness.replace("synthetic_production_encoder_only", "synthetic_hardware_capability_only")
        harness = harness.replace("        encoder.onOutput = { capture?.record($0) }", "")
        capture_support = capture_support.replace("extension VideoH264Encoder.EncodedAccessUnit: BenchEncodedUnit {}", "")
    unit = "import Foundation\nimport Darwin\nimport CoreMedia\nimport CoreVideo\nimport VideoToolbox\n" + codec + color + encoder + capture_support + harness
    with tempfile.TemporaryDirectory(prefix="peel-encoder-bench-") as scratch:
        directory = pathlib.Path(scratch)
        combined = directory / "ProductionEncoderBench.swift"
        combined.write_text(unit)
        binary = directory / "encoder-bench"
        support_sources = [HOST / "AgentBridge/PeelLocalAgentServer.swift",
                           HOST / "PeelHost/PeelVideoEncoderHardwarePolicy.swift",
                           HOST / "PeelHost/PeelVideoEncoderRecovery.swift",
                           HOST / "PeelHost/PeelStreamingDiagnostics.swift"]
        command = ["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5",
                   "-default-isolation", "MainActor", "-strict-concurrency=complete",
                   *map(str, support_sources), str(combined), "-o", str(binary)]
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            print(compiled.stderr)
            raise SystemExit(compiled.returncode)
        print(json.dumps({"productionEncoderSHA256": production_encoder_hash,
                          "variant": args.variant,
                          "faultInjection": args.fault,
                          "outputCaptureEnabled": bool(args.capture_dir),
                          "compiledEncoderSHA256": hashlib.sha256(encoder.encode()).hexdigest(),
                          "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                          "supportSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                  for path in support_sources},
                          "optimization": "O", "compileOnly": args.compile_only}), flush=True)
        if not args.compile_only:
            subprocess.run([str(binary), str(args.width), str(args.height), str(args.fps),
                            str(args.seconds), args.codec, args.pixel_format,
                            str(args.capture_dir.resolve()) if args.capture_dir else "-"], check=True, timeout=args.seconds + 15)


if __name__ == "__main__":
    main()
