import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "evaluate-acoustic-truth.py"
SPEC = importlib.util.spec_from_file_location("evaluate_acoustic_truth", SCRIPT)
EVALUATOR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(EVALUATOR)


class AcousticTruthEvaluatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.media_path = Path(self.temp.name) / "fixture.wav"
        self.media_path.write_bytes(b"audio fixture for evaluator unit test")
        digest = hashlib.sha256(self.media_path.read_bytes()).hexdigest()
        self.truth = {
            "kind": "human-acoustic-truth",
            "method": "audio-only-blind-listen",
            "blindToModelOutput": True,
            "annotator": "unit-test-human-label",
            "annotatedAt": "2026-01-01T00:00:00Z",
            "media": {"filename": self.media_path.name, "path": str(self.media_path),
                      "bytes": self.media_path.stat().st_size, "durationSec": 10.0, "sha256": digest},
            "lines": [
                {"order": 1, "text": "花です", "acousticOnset": 1.0, "acousticOffset": 2.0},
                {"order": 2, "text": "花です", "acousticOnset": 3.0, "acousticOffset": 4.0},
            ],
        }
        self.project = {
            "duration": 10.0,
            "mediaURL": self.media_path.as_uri(),
            "lyricLines": [
                {"order": 1, "displayText": "花です。", "singStart": 1.2, "singEnd": 2.2, "needsReview": False},
                {"order": 2, "displayText": "花です", "singStart": 3.8, "singEnd": 4.0, "needsReview": True},
            ],
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_strict_rate_requires_start_end_text_and_no_review(self):
        report = EVALUATOR.evaluate(self.project, self.truth, 0.5)
        self.assertEqual(report["summary"]["truthLines"], 2)
        self.assertEqual(report["summary"]["noManualAdjustmentLines"], 1)
        self.assertEqual(report["summary"]["noManualAdjustmentRate"], 0.5)
        self.assertEqual(report["summary"]["offsetError"]["withinTolerance"], 2)

    def test_missing_prediction_stays_in_fixed_truth_denominator(self):
        self.project["lyricLines"].pop()
        report = EVALUATOR.evaluate(self.project, self.truth, 0.5)
        self.assertEqual(report["summary"]["truthLines"], 2)
        self.assertEqual(report["summary"]["missingPredictionLines"], 1)
        self.assertEqual(report["summary"]["noManualAdjustmentRate"], 0.5)

    def test_ocr_or_synthetic_truth_is_rejected(self):
        self.truth["kind"] = "vision-ocr"
        with self.assertRaisesRegex(EVALUATOR.EvaluationError, "拒绝模型/OCR/TTS"):
            EVALUATOR.evaluate(self.project, self.truth, 0.5)

    def test_media_fingerprint_mismatch_is_rejected(self):
        self.truth["media"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(EVALUATOR.EvaluationError, "SHA-256"):
            EVALUATOR.evaluate(self.project, self.truth, 0.5)

    def test_same_media_accepts_small_container_duration_decoder_difference(self):
        # Real Hana and Lei files are byte-identical while AVFoundation and
        # ffprobe differ by about 50-63 ms in their reported MP4 durations.
        samples = [
            (248.268, 248.3184375),
            (232.930, 232.992625),
        ]
        for project_duration, truth_duration in samples:
            with self.subTest(project=project_duration, truth=truth_duration):
                self.project["duration"] = project_duration
                self.truth["media"]["durationSec"] = truth_duration
                report = EVALUATOR.evaluate(self.project, self.truth, 0.5)
                self.assertAlmostEqual(
                    report["media"]["durationDifferenceSec"],
                    abs(project_duration - truth_duration),
                    places=6,
                )

    def test_large_duration_metadata_difference_is_rejected(self):
        self.project["duration"] = 10.0
        self.truth["media"]["durationSec"] = 10.3
        with self.assertRaisesRegex(EVALUATOR.EvaluationError, "容错 0.25 秒"):
            EVALUATOR.evaluate(self.project, self.truth, 0.5)


if __name__ == "__main__":
    unittest.main()
