import copy
import io
import json
import unittest
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from measure_stream import evaluate, main


class TrialEvaluationChecks(unittest.TestCase):
    def fixture(self):
        return {
            "streams": [{"windowId": 7, "active": True, "width": 5120, "height": 2880, "encodedFPS": 90}],
            "receiver": {"stale": False, "reportAgeSeconds": 1, "report": {
                "sampledAtClientUptimeSeconds": 100, "streams": [{
                    "windowId": 7, "width": 5120, "height": 2880,
                    "avPerformance": {"estimatedPresentedFPS": 90},
                    "displayedFixtureQuality": {"markerMatched": True, "comparedPixels": 32768,
                        "sampledAtClientUptimeSeconds": 99, "sourceToObservationUpperBoundMilliseconds": 49,
                        "observationStage": "displayLayerPixelObservation"}
                }]
            }}
        }

    def test_valid_snapshot_does_not_certify_physical_ceiling(self):
        result = evaluate(self.fixture(), 7)
        self.assertEqual(result["pipelineStatus"], "pass")
        self.assertEqual(result["acceptanceStatus"], "unverified")

    def test_default_remains_90_with_half_frame_allowance(self):
        snapshot = self.fixture()
        snapshot["streams"][0]["encodedFPS"] = 89.5
        snapshot["receiver"]["report"]["streams"][0]["avPerformance"]["estimatedPresentedFPS"] = 89.5
        result = evaluate(snapshot, 7)
        self.assertEqual(result["pipelineStatus"], "pass")
        self.assertEqual(result["targetFPS"], 90)
        self.assertEqual(result["criteria"], {
            "targetFPS": 90, "minimumFPS": 89.5, "cadenceAllowanceFPS": 0.5,
            "width": 5120, "height": 2880, "latencyCeilingMilliseconds": 50.0,
            "latencyComparison": "strictlyLessThan",
        })
        for stage in ("encoder", "receiver"):
            below = copy.deepcopy(snapshot)
            if stage == "encoder":
                below["streams"][0]["encodedFPS"] = 89.499
            else:
                below["receiver"]["report"]["streams"][0]["avPerformance"]["estimatedPresentedFPS"] = 89.499
            with self.subTest(stage=stage):
                self.assertEqual(evaluate(below, 7)["pipelineStatus"], "fail")

    def test_explicit_60_uses_same_allowance_for_both_receiver_paths(self):
        for spatial in (False, True):
            snapshot = self.spatial_fixture() if spatial else self.fixture()
            row = snapshot["receiver"]["report"]["streams"][0]
            receiver = row["spatialPipeline"] if spatial else row["avPerformance"]
            receiver_key = "publishedFPS" if spatial else "estimatedPresentedFPS"
            snapshot["streams"][0]["encodedFPS"] = 59.5
            receiver[receiver_key] = 59.5
            result = evaluate(snapshot, 7, target_fps=60)
            with self.subTest(spatial=spatial):
                self.assertEqual(result["pipelineStatus"], "pass")
                self.assertEqual(result["targetFPS"], 60)
                self.assertEqual(result["criteria"]["minimumFPS"], 59.5)
                self.assertEqual(result["criteria"]["cadenceAllowanceFPS"], 0.5)
                self.assertEqual(result["acceptanceStatus"], "unverified")
                self.assertIn("unique changing 60-Hz source content", result["remainingEvidence"])
                self.assertNotIn("unique changing 90-Hz source content", result["remainingEvidence"])
                self.assertEqual(evaluate(snapshot, 7)["pipelineStatus"], "fail")
            for stage in ("encoder", "receiver"):
                below = copy.deepcopy(snapshot)
                if stage == "encoder":
                    below["streams"][0]["encodedFPS"] = 59.499
                else:
                    receiver = below["receiver"]["report"]["streams"][0]
                    (receiver["spatialPipeline"] if spatial else receiver["avPerformance"])[receiver_key] = 59.499
                with self.subTest(spatial=spatial, stage=stage):
                    self.assertEqual(evaluate(below, 7, target_fps=60)["pipelineStatus"], "fail")

    def test_evaluation_rejects_invalid_targets(self):
        for target in (0, 59, 61, 120, True, 60.0, "60", None):
            with self.subTest(target=target), self.assertRaises(ValueError):
                evaluate(self.fixture(), 7, target_fps=target)

    def test_60_keeps_strict_and_unavailable_absolute_latency_gates(self):
        for spatial in (False, True):
            for maximum in (50, 50.1, None, float("nan"), True):
                snapshot = self.spatial_fixture() if spatial else self.fixture()
                row = snapshot["receiver"]["report"]["streams"][0]
                row["displayedFixtureQuality"]["sourceToObservationUpperBoundMilliseconds"] = maximum
                result = evaluate(snapshot, 7, target_fps=60)
                with self.subTest(spatial=spatial, maximum=maximum):
                    self.assertEqual(result["pipelineStatus"], "fail")
                    self.assertEqual(result["acceptanceStatus"], "unverified")
                    self.assertEqual(result["criteria"]["latencyCeilingMilliseconds"], 50.0)
        for maximum in (50, 50.1, None):
            with self.subTest(localMaximum=maximum):
                result = evaluate(self.spatial_fixture(maximum), 7, target_fps=60)
                self.assertEqual(result["pipelineStatus"], "fail")
                self.assertEqual(result["acceptanceStatus"], "unverified")

    def test_60_does_not_substitute_relative_or_encoder_only_timing(self):
        snapshot = self.fixture()
        row = snapshot["receiver"]["report"]["streams"][0]
        row["receiverTiming"] = {
            "measurementKind": "sourcePTSRelativeMinimum",
            "sourcePTSRelativeEnqueueExcess": {"maximumMilliseconds": 0.0},
            "physicalPresentationMeasured": False,
        }
        snapshot["streams"][0]["encodeCallback"] = {"maximumMilliseconds": 1.0}
        snapshot["streams"][0]["sourceOfferedFPS"] = 90
        row["displayedFixtureQuality"].pop("sourceToObservationUpperBoundMilliseconds")
        result = evaluate(snapshot, 7, target_fps=60)
        self.assertEqual(result["pipelineStatus"], "fail")
        self.assertIsNone(result["sourceToApplicationObservationUpperBoundMilliseconds"])
        self.assertEqual(result["acceptanceStatus"], "unverified")

    def run_fake_cli(self, snapshot, options=()):
        with tempfile.TemporaryDirectory(prefix="peel-target-evaluator-") as directory:
            output = Path(directory) / "trial.jsonl"
            stdout = io.StringIO()
            with patch("measure_stream.BridgeClient") as bridge, \
                 patch("measure_stream.time.monotonic", side_effect=[0, 0, 12, 21]), \
                 patch("measure_stream.time.sleep"), redirect_stdout(stdout):
                bridge.return_value.request.return_value = snapshot
                status = main(["--window-id", "7", "--output", str(output), *options])
                bridge.return_value.request.assert_called_once_with("getStreamDiagnostics", {})
            return status, json.loads(stdout.getvalue()), [json.loads(line) for line in output.read_text().splitlines()]

    def test_cli_default_90_and_explicit_60_label_every_result(self):
        for options, target in (((), 90), (("--target-fps", "60"), 60), (("--target-fps", "90"), 90)):
            snapshot = self.fixture()
            snapshot["streams"][0]["encodedFPS"] = target - 0.5
            snapshot["receiver"]["report"]["streams"][0]["avPerformance"]["estimatedPresentedFPS"] = target - 0.5
            status, summary, records = self.run_fake_cli(snapshot, options)
            with self.subTest(options=options):
                self.assertEqual(status, 0)
                self.assertEqual(summary["targetFPS"], target)
                self.assertEqual(summary["criteria"]["minimumFPS"], target - 0.5)
                self.assertEqual(summary["criteria"]["latencyComparison"], "strictlyLessThan")
                self.assertEqual(summary["acceptanceStatus"], "unverified")
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["evaluation"]["targetFPS"], target)
                self.assertEqual(records[0]["evaluation"]["criteria"], summary["criteria"])

    def test_cli_60_cadence_cannot_pass_default_90(self):
        snapshot = self.fixture()
        snapshot["streams"][0]["encodedFPS"] = 60
        snapshot["receiver"]["report"]["streams"][0]["avPerformance"]["estimatedPresentedFPS"] = 60
        status, summary, records = self.run_fake_cli(snapshot)
        self.assertEqual(status, 1)
        self.assertEqual(summary["targetFPS"], 90)
        self.assertEqual(summary["firstFailure"], records[0]["evaluation"])

    def test_cli_rejects_invalid_targets_before_bridge_or_output(self):
        for target in ("59", "61", "120", "60.0", "nan"):
            with tempfile.TemporaryDirectory(prefix="peel-target-invalid-") as directory:
                output = Path(directory) / "trial.jsonl"
                with self.subTest(target=target), patch("measure_stream.BridgeClient") as bridge, \
                     redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    main(["--window-id", "7", "--target-fps", target, "--output", str(output)])
                self.assertEqual(error.exception.code, 2)
                bridge.assert_not_called()
                self.assertFalse(output.exists())

    def test_cli_60_rejects_boundary_or_missing_latency(self):
        for maximum in (50, None):
            snapshot = self.fixture()
            snapshot["receiver"]["report"]["streams"][0]["displayedFixtureQuality"]["sourceToObservationUpperBoundMilliseconds"] = maximum
            status, summary, records = self.run_fake_cli(snapshot, ("--target-fps", "60"))
            with self.subTest(maximum=maximum):
                self.assertEqual(status, 1)
                self.assertEqual(summary["pipelineStatus"], "fail")
                self.assertEqual(summary["acceptanceStatus"], "unverified")
                self.assertEqual(records[0]["evaluation"]["criteria"]["latencyCeilingMilliseconds"], 50.0)

    def test_relative_receiver_timing_cannot_replace_absolute_clock_evidence(self):
        for missing in ("displayedFixtureQuality", "sourceToObservationUpperBoundMilliseconds"):
            snapshot = self.fixture()
            row = snapshot["receiver"]["report"]["streams"][0]
            row["receiverTiming"] = {
                "measurementKind": "sourcePTSRelativeMinimum",
                "sourcePTSAvailability": "relativeMinimum",
                "frameAdmissionToDisplayEnqueue": {"maximumMilliseconds": 0.1},
                "sourcePTSRelativeEnqueueExcess": {"maximumMilliseconds": 0.0},
                "physicalPresentationMeasured": False,
            }
            if missing == "displayedFixtureQuality":
                row.pop(missing)
            else:
                row["displayedFixtureQuality"].pop(missing)
            result = evaluate(snapshot, 7)
            self.assertEqual(result["pipelineStatus"], "fail")
            self.assertEqual(result["acceptanceStatus"], "unverified")
            self.assertIsNone(result["sourceToApplicationObservationUpperBoundMilliseconds"])
            self.assertFalse(result["sourcePTSUpperBoundApplied"])

    def test_ceiling_is_strict(self):
        for maximum in (50, 50.1, None, float("nan"), True):
            snapshot = self.fixture()
            snapshot["receiver"]["report"]["streams"][0]["displayedFixtureQuality"]["sourceToObservationUpperBoundMilliseconds"] = maximum
            self.assertEqual(evaluate(snapshot, 7)["pipelineStatus"], "fail")

    def test_missing_stale_and_wrong_raster_fail(self):
        snapshots = [{}, self.fixture(), self.fixture(), self.fixture(), self.fixture()]
        snapshots[1]["receiver"]["stale"] = True
        snapshots[2]["streams"][0]["width"] = 4096
        snapshots[3]["receiver"]["report"]["streams"][0]["displayedFixtureQuality"]["sampledAtClientUptimeSeconds"] = 80
        snapshots[4]["streams"][0]["encodedFPS"] = 30
        for snapshot in snapshots:
            with self.subTest(snapshot=snapshot):
                self.assertEqual(evaluate(snapshot, 7)["pipelineStatus"], "fail")

    def test_spatial_does_not_silently_fall_back_to_sampled_stamp(self):
        snapshot = self.fixture()
        row = snapshot["receiver"]["report"]["streams"][0]
        row["spatialPipeline"] = {"sourceTimebaseVerified": False, "publishedFPS": 90}
        result = evaluate(snapshot, 7)
        self.assertEqual(result["pipelineStatus"], "fail")
        self.assertFalse(result["sourcePTSUpperBoundApplied"])

    def test_valid_pts_does_not_replace_missing_stamp(self):
        snapshot = self.fixture()
        row = snapshot["receiver"]["report"]["streams"][0]
        row["spatialPipeline"] = {"sourceTimebaseVerified": True, "publishedFPS": 90,
            "sourcePTSToPublicationUpperBound": {"maximumMilliseconds": 45}}
        row["displayedFixtureQuality"]["sourceToObservationUpperBoundMilliseconds"] = None
        result = evaluate(snapshot, 7)
        self.assertEqual(result["pipelineStatus"], "fail")
        self.assertTrue(result["sourcePTSUpperBoundApplied"])

    def spatial_fixture(self, publication_ms=20):
        snapshot = self.fixture()
        row = snapshot["receiver"]["report"]["streams"][0]
        row["displayedFixtureQuality"]["observationStage"] = "spatialImageInspection"
        row["spatialPipeline"] = {"sourceTimebaseVerified": True, "publishedFPS": 90,
            "sourcePTSToPublicationUpperBound": {"maximumMilliseconds": 49},
            "receiveToPublication": {"maximumMilliseconds": publication_ms}}
        return snapshot

    def test_spatial_publication_coverage_remains_available(self):
        result = evaluate(self.spatial_fixture(), 7)
        self.assertEqual(result["pipelineStatus"], "pass")
        self.assertEqual(result["timingEndpoint"], "applicationPublication")
        self.assertEqual(result["acceptanceStatus"], "unverified")

    def test_local_publication_ceiling_is_independent_of_stamp_and_pts(self):
        for value in (50, 50.1, 200):
            with self.subTest(value=value):
                result = evaluate(self.spatial_fixture(value), 7)
                self.assertEqual(result["pipelineStatus"], "fail")
                self.assertTrue(result["ceilingExceeded"])
                self.assertEqual(result["observationConsistency"], "inconsistent")
                self.assertEqual(result["receiveToPublicationMaximumMilliseconds"], value)

    def test_inconsistent_publication_bounds_fail_below_ceiling(self):
        result = evaluate(self.spatial_fixture(49.5), 7)
        self.assertEqual(result["pipelineStatus"], "fail")
        self.assertFalse(result["ceilingExceeded"])
        self.assertEqual(result["observationConsistency"], "inconsistent")

    def test_missing_or_invalid_local_publication_fails(self):
        for value in (None, True, float("nan"), -1):
            with self.subTest(value=value):
                self.assertEqual(evaluate(self.spatial_fixture(value), 7)["pipelineStatus"], "fail")

    def test_image_inspection_never_substitutes_for_flat_publication(self):
        for endpoint in (None, "spatialImageInspection"):
            snapshot = self.fixture()
            snapshot["receiver"]["report"]["streams"][0]["displayedFixtureQuality"]["observationStage"] = endpoint
            self.assertEqual(evaluate(snapshot, 7)["pipelineStatus"], "fail")

    def test_warmup_does_not_ignore_observed_ceiling_violation(self):
        snapshot = self.spatial_fixture(200)
        class FakeBridge:
            def __init__(self, **kwargs):
                pass
            def request(self, method, arguments):
                return snapshot
        with tempfile.TemporaryDirectory(prefix="peel-timing-evaluator-") as directory:
            output = str(Path(directory) / "trial.jsonl")
            with patch("measure_stream.BridgeClient", FakeBridge), \
                 patch("measure_stream.time.monotonic", side_effect=[0, 0, 1]), \
                 patch("measure_stream.time.sleep", side_effect=AssertionError("must stop before sleeping")), \
                 patch("sys.argv", ["measure_stream.py", "--window-id", "7", "--output", output]):
                self.assertEqual(main(), 1)


if __name__ == "__main__":
    unittest.main()
