#!/usr/bin/env python3
"""Save bounded, content-free bridge snapshots and evaluate a native 5K trial.

Run on the source Mac, optionally over SSH. This never starts a stream, changes
display settings or grants access. A pipeline pass cannot certify photons.
"""
from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

from peel_mcp_server import BridgeClient, BridgeError


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def measurement_criteria(target_fps=90, ceiling_ms=50.0):
    if type(target_fps) is not int or target_fps not in (60, 90):
        raise ValueError("target_fps must be 60 or 90")
    return {
        "targetFPS": target_fps,
        "minimumFPS": target_fps - 0.5,
        "cadenceAllowanceFPS": 0.5,
        "width": 5120,
        "height": 2880,
        "latencyCeilingMilliseconds": ceiling_ms,
        "latencyComparison": "strictlyLessThan",
    }


def evaluate(snapshot, window_id, *, target_fps=90, ceiling_ms=50.0):
    criteria = measurement_criteria(target_fps, ceiling_ms)
    minimum_fps = criteria["minimumFPS"]
    failures = []
    streams = snapshot.get("streams", [])
    host = next((row for row in streams if row.get("windowId") == window_id), {})
    receiver = snapshot.get("receiver", {})
    report = receiver.get("report") or {}
    client = next((row for row in report.get("streams", []) if row.get("windowId") == window_id), {})
    spatial = client.get("spatialPipeline") or {}
    fixture = client.get("displayedFixtureQuality") or spatial.get("fixtureQuality") or {}
    if not host.get("active") or host.get("width") != 5120 or host.get("height") != 2880:
        failures.append("source encoder is not active at exactly 5120x2880")
    fps = host.get("encodedFPS")
    if not number(fps) or fps < minimum_fps:
        failures.append("measured encoder cadence below target or unavailable")
    if receiver.get("stale") is not False or not number(receiver.get("reportAgeSeconds")) or receiver["reportAgeSeconds"] > 3:
        failures.append("receiver report missing or stale")
    if client.get("width") != 5120 or client.get("height") != 2880:
        failures.append("receiver configuration is not exactly 5120x2880")
    fps = spatial.get("publishedFPS") if spatial else (client.get("avPerformance") or {}).get("estimatedPresentedFPS")
    if not number(fps) or fps < minimum_fps:
        failures.append("measured application publication / AV presentation estimate below target or unavailable")
    if not fixture.get("markerMatched") or fixture.get("comparedPixels") != 32768:
        failures.append("native-scale known quality fixture missing or mismatched")
    age = report.get("sampledAtClientUptimeSeconds", 0) - fixture.get("sampledAtClientUptimeSeconds", 0)
    if not number(age) or age < 0 or age > 5:
        failures.append("quality fixture sample missing or stale")
    maximum = fixture.get("sourceToObservationUpperBoundMilliseconds")
    if not number(maximum):
        failures.append("sampled fixture clock bound unavailable")
    source_pts_applied = False
    local_publication_maximum = None
    inconsistent = False
    if spatial:
        if spatial.get("sourceTimebaseVerified") is not True:
            failures.append("spatial per-frame source PTS timebase unverified")
        pts_maximum = (spatial.get("sourcePTSToPublicationUpperBound") or {}).get("maximumMilliseconds")
        source_pts_applied = spatial.get("sourceTimebaseVerified") is True and number(pts_maximum)
        if source_pts_applied:
            maximum = max(maximum, pts_maximum) if number(maximum) else pts_maximum
        else:
            failures.append("spatial per-frame source PTS maximum unavailable")
        local_publication_maximum = (spatial.get("receiveToPublication") or {}).get("maximumMilliseconds")
        if not number(local_publication_maximum) or not 0 <= local_publication_maximum <= 60_000:
            failures.append("local receive-to-publication maximum unavailable")
        else:
            if local_publication_maximum >= ceiling_ms:
                failures.append("local receive-to-publication maximum reaches ceiling")
            # Both maxima cover the same publication samples when sourceTimebaseVerified
            # is true. A source bound cannot be shorter than its local suffix.
            if source_pts_applied and local_publication_maximum > pts_maximum + 0.001:
                inconsistent = True
                failures.append("source publication bound contradicts measured local publication time")
    elif fixture.get("observationStage") != "displayLayerPixelObservation":
        failures.append("displayed-pixel observation endpoint unavailable; image inspection is not publication")
    if not number(maximum) or maximum >= ceiling_ms:
        failures.append("source-to-publication upper bound reaches ceiling or is unavailable")
    ceiling_exceeded = (number(maximum) and maximum >= ceiling_ms) or (
        number(local_publication_maximum) and local_publication_maximum >= ceiling_ms)
    return {
        "windowId": window_id,
        "targetFPS": target_fps,
        "criteria": criteria,
        "pipelineStatus": "pass" if not failures else "fail",
        "failures": failures,
        "sourceToApplicationObservationUpperBoundMilliseconds": maximum,
        "sourcePTSUpperBoundApplied": source_pts_applied,
        "receiveToPublicationMaximumMilliseconds": local_publication_maximum,
        "observationConsistency": "inconsistent" if inconsistent else "unverified" if failures else "consistent",
        "ceilingExceeded": ceiling_exceeded,
        "timingEndpoint": "applicationPublication" if source_pts_applied else fixture.get("observationStage"),
        "timingCoverage": "per-frame publication plus sampled fixture" if source_pts_applied else "sampled fixture observation only",
        "acceptanceStatus": "unverified",
        "remainingEvidence": [
            f"unique changing {target_fps}-Hz source content",
            "representative scrolling and full-frame motion workload",
            "quality comparison against the native Screen Sharing reference",
            "continuous frame timing; fixture image observations are sampled",
            "compositor presentation and physical input-to-photon measurement",
            "declared-duration Tailscale run with all measured maxima below 50 ms",
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window-id", type=int, required=True)
    parser.add_argument("--target-fps", type=int, choices=(60, 90), default=90,
                        help="Requested trial cadence; minimum measured cadence is target minus 0.5 fps (default: 90)")
    parser.add_argument("--seconds", type=int, default=20, choices=range(10, 301), metavar="10..300")
    parser.add_argument("--warmup", type=int, default=12, choices=range(5, 16), metavar="5..15")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--socket")
    args = parser.parse_args(argv)
    if not 0 <= args.window_id <= 0xFFFFFFFF:
        parser.error("window-id is outside UInt32")
    bridge = BridgeClient(socket_path=args.socket)
    # Exclusive creation protects previous evidence; every call has a timeout.
    started = time.monotonic()
    summary = {"targetFPS": args.target_fps, "criteria": measurement_criteria(args.target_fps),
               "pipelineStatus": "pass", "acceptanceStatus": "unverified", "samples": 0, "firstFailure": None}
    with args.output.open("x") as output:
        while time.monotonic() - started < args.seconds:
            try:
                snapshot = bridge.request("getStreamDiagnostics", {})
                result = evaluate(snapshot, args.window_id, target_fps=args.target_fps)
                elapsed = time.monotonic() - started
                output.write(json.dumps({"elapsedSeconds": elapsed, "snapshot": snapshot,
                                         "evaluation": result}, allow_nan=False) + "\n")
                output.flush()
                if elapsed >= args.warmup or result["ceilingExceeded"]:
                    summary["samples"] += 1
                    if result["pipelineStatus"] != "pass":
                        summary["pipelineStatus"] = "fail"
                        summary["firstFailure"] = result
                        # Stop collecting immediately on a ceiling/cadence failure.
                        break
            except BridgeError as error:
                summary.update(pipelineStatus="fail", bridgeError={"code": error.code, "message": error.message})
                break
            time.sleep(1)
    if summary["samples"] == 0:
        summary["pipelineStatus"] = "fail"
    summary["evidencePath"] = str(args.output.resolve())
    print(json.dumps(summary, indent=2, allow_nan=False))
    return 0 if summary["pipelineStatus"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
