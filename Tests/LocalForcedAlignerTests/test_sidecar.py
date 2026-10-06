import importlib.util
import math
import pathlib
import unittest

import numpy as np
from pykakasi import kakasi


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Sources/MaGiKaraKit/Resources/local_forced_aligner/sidecar.py"
SPEC = importlib.util.spec_from_file_location("magikara_local_aligner_sidecar", MODULE_PATH)
SIDECAR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SIDECAR)


class SidecarTests(unittest.TestCase):
    def test_kana_morae_map_to_hepburn_without_losing_sokuon_or_long_vowel(self):
        output = SIDECAR.romanize_units(["きゃ", "っ", "て", "きー", "ん", "あ"], kakasi())
        self.assertEqual(output, ["kya", "t", "te", "kii", "n", "a"])

    def test_standalone_long_vowel_repeats_previous_mora_vowel(self):
        output = SIDECAR.romanize_units(["こ", "ー", "ひ", "ｰ"], kakasi())
        self.assertEqual(output, ["ko", "o", "hi", "i"])

    def test_english_character_units_preserve_contractions(self):
        output = SIDECAR.romanize_units(list("flower's"), kakasi())
        self.assertEqual(output, list("flower's"))

    def test_ctc_viterbi_preserves_blank_between_repeated_labels(self):
        probabilities = np.array([
            [0.01, 0.98],
            [0.97, 0.02],
            [0.01, 0.98],
            [0.97, 0.02],
        ], dtype=np.float32)
        spans, scores = SIDECAR.ctc_viterbi(np.log(probabilities), [1, 1], blank_id=0)
        self.assertEqual(spans, [(0, 1), (2, 3)])
        self.assertGreater(scores[0], 0.95)
        self.assertGreater(scores[1], 0.95)

    def test_target_flattens_morae_across_token_boundary_for_sokuon(self):
        class Tokenizer:
            unk_token_id = -1

            def convert_tokens_to_ids(self, tokens):
                return [ord(token) for token in tokens]

        request = {
            "lines": [{
                "order": 1,
                "tokens": [
                    {"morae": ["き", "っ"]},
                    {"morae": ["て"]},
                ],
            }],
        }
        labels, units, warnings = SIDECAR.build_target(request, Tokenizer())
        self.assertEqual(len(labels), 5)  # ki + geminate t + te
        self.assertEqual([(u["tokenIndex"], u["moraIndex"]) for u in units], [(0, 0), (0, 1), (1, 0)])
        self.assertEqual(warnings, [])

    def test_ctc_viterbi_rejects_too_many_phones(self):
        with self.assertRaisesRegex(SIDECAR.AlignmentError, "少于歌词音素数"):
            SIDECAR.ctc_viterbi(np.log(np.array([[0.1, 0.9]], dtype=np.float32)), [1, 1], blank_id=0)

    # MARK: - 纯音频重复次数选择

    FRAME_SECONDS = 0.02
    SAMPLE_RATE = 16_000
    FRAME_SAMPLES = int(FRAME_SECONDS * SAMPLE_RATE)

    @staticmethod
    def _log_softmax(scores):
        shifted = scores - scores.max(axis=1, keepdims=True)
        return (shifted - np.log(np.exp(shifted).sum(axis=1, keepdims=True))).astype(np.float32)

    @classmethod
    def _emissions(cls, frame_labels, vocabulary=4):
        scores = np.full((len(frame_labels), vocabulary), -6.0, dtype=np.float32)
        for index, label in enumerate(frame_labels):
            scores[index, label] = 6.0
        return cls._log_softmax(scores)

    @classmethod
    def _tone(cls, frequency, frames):
        count = frames * cls.FRAME_SAMPLES
        t = np.arange(count) / cls.SAMPLE_RATE
        return (0.4 * np.sin(2.0 * np.pi * frequency * t)).astype(np.float32)

    @classmethod
    def _make_audio(cls, patterns, gap_frames=4):
        gap = np.zeros(gap_frames * cls.FRAME_SAMPLES, dtype=np.float32)
        return np.concatenate([part for pattern in patterns for part in (pattern, gap)])

    def _loop_case(self, loop_count):
        """Emissions and audio where one phrase clearly repeats N times."""
        labels = [1, 2, 3]
        layout = [(220.0, 6), (440.0, 6), (880.0, 6)]
        frame_labels = []
        for _ in range(loop_count):
            for label, (_, hold) in zip(labels, layout):
                frame_labels.extend([label] * hold)
            frame_labels.extend([0] * 4)
        pattern = np.concatenate([self._tone(frequency, frames) for frequency, frames in layout])
        audio = self._make_audio([pattern] * loop_count)
        return self._emissions(frame_labels), audio, labels

    def _five_loop_case(self):
        return self._loop_case(5)

    def test_stable_five_repeat_clearly_wins(self):
        emissions, audio, labels = self._five_loop_case()
        candidates = SIDECAR.evaluate_repeat_candidates(
            emissions, [], labels, 0, audio, self.SAMPLE_RATE, self.FRAME_SECONDS, blank_id=0)
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertTrue(decision["applied"], decision["reason"])
        self.assertEqual(decision["count"], 5)
        self.assertGreaterEqual(decision["margin"], SIDECAR.REPEAT_MIN_MARGIN)

    def test_sixteen_repeat_outro_is_within_search_range(self):
        emissions, audio, labels = self._loop_case(16)
        candidates = SIDECAR.evaluate_repeat_candidates(
            emissions, [], labels, 0, audio, self.SAMPLE_RATE, self.FRAME_SECONDS, blank_id=0)
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertTrue(decision["applied"], decision["reason"])
        self.assertEqual(decision["count"], 16)
        self.assertGreaterEqual(decision["margin"], SIDECAR.REPEAT_MIN_MARGIN)

    def test_original_audio_without_loop_is_not_expanded(self):
        emissions, _, labels = self._five_loop_case()
        distinct = []
        for index in range(5):
            frequencies = [150.0 * (index + 1), 900.0 + 300.0 * index, 2500.0 + 500.0 * index]
            distinct.append(np.concatenate([self._tone(frequency, 6) for frequency in frequencies]))
        audio = self._make_audio(distinct)
        candidates = SIDECAR.evaluate_repeat_candidates(
            emissions, [], labels, 0, audio, self.SAMPLE_RATE, self.FRAME_SECONDS, blank_id=0)
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertFalse(decision["applied"], decision["reason"])
        self.assertIsNone(decision["count"])

    def test_close_4_5_6_candidates_must_abstain(self):
        candidates = [
            {"count": 4, "spectral": 0.90, "durationCv": 0.03, "support": 0.88, "ctcRawScore": 0.50},
            {"count": 5, "spectral": 0.90, "durationCv": 0.03, "support": 0.86, "ctcRawScore": 0.60},
            {"count": 6, "spectral": 0.90, "durationCv": 0.03, "support": 0.84, "ctcRawScore": 0.70},
        ]
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertFalse(decision["applied"], "4/5/6 分数接近时必须弃权，不能猜次数")
        self.assertIsNone(decision["count"])
        self.assertLess(decision["margin"], SIDECAR.REPEAT_MIN_MARGIN)
        self.assertTrue(any("复核" in value for value in [decision["reason"]]))

    def test_soft_spectral_floor_requires_clear_audio_coverage(self):
        candidates = [
            {"count": 8, "spectral": 0.67, "durationCv": 0.048,
             "coverage": 0.97, "support": 0.75, "ctcRawScore": 0.47},
            {"count": 3, "spectral": 0.26, "durationCv": 0.105,
             "coverage": 0.35, "support": 0.28, "ctcRawScore": 0.42},
            {"count": 2, "spectral": 0.34, "durationCv": 0.201,
             "coverage": 0.0, "support": 0.00, "ctcRawScore": 0.41},
        ]
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertTrue(decision["applied"], decision["reason"])
        self.assertEqual(decision["count"], 8)
        self.assertGreaterEqual(decision["margin"], SIDECAR.REPEAT_MIN_MARGIN)
        self.assertIn("略低于常规阈值", decision["reason"])

    def test_soft_spectral_floor_still_abstains_on_ambiguous_or_irregular_loops(self):
        ambiguous = [
            {"count": 8, "spectral": 0.67, "durationCv": 0.048,
             "coverage": 0.82, "support": 0.67, "ctcRawScore": 0.47},
            {"count": 7, "spectral": 0.68, "durationCv": 0.05,
             "coverage": 0.80, "support": 0.57, "ctcRawScore": 0.46},
        ]
        irregular = [
            {"count": 8, "spectral": 0.67, "durationCv": 0.081,
             "coverage": 0.97, "support": 0.67, "ctcRawScore": 0.47},
            {"count": 3, "spectral": 0.26, "durationCv": 0.105,
             "coverage": 0.35, "support": 0.28, "ctcRawScore": 0.42},
        ]
        self.assertFalse(SIDECAR.select_repeat_count(ambiguous)["applied"])
        self.assertFalse(SIDECAR.select_repeat_count(irregular)["applied"])

    def test_ctc_raw_score_cannot_force_larger_count(self):
        # N=8 has the best CTC posterior, but its audio evidence is worse than
        # N=5.  Selection must ignore rawScore and keep the audio winner.
        candidates = [
            {"count": 4, "spectral": 0.86, "durationCv": 0.02, "support": 0.70, "ctcRawScore": 0.40},
            {"count": 5, "spectral": 0.93, "durationCv": 0.02, "support": 0.95, "ctcRawScore": 0.55},
            {"count": 8, "spectral": 0.85, "durationCv": 0.02, "support": 0.80, "ctcRawScore": 0.99},
        ]
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertTrue(decision["applied"], decision["reason"])
        self.assertEqual(decision["count"], 5)
        self.assertNotEqual(decision["count"], 8, "rawScore 更高不能强行选更大的 N")

    def test_hana_outro_coverage_selects_phrase_scale_over_coarse_tiling(self):
        # Real Hana diagnostics: N=5 cuts a phrase into coarse ~5.8s chunks
        # with large internal blank gaps; N=16 tracks the sung phrase period.
        # Coverage values here are recorded from aligned label spans, not timing truth.
        candidates = [
            {"count": 5, "spectral": 0.74, "durationCv": 0.003,
             "coverage": 0.64,
             "support": SIDECAR.repeat_candidate_support(0.74, 0.64), "ctcRawScore": 0.42},
            {"count": 16, "spectral": 0.72, "durationCv": 0.085,
             "coverage": 0.96,
             "support": SIDECAR.repeat_candidate_support(0.72, 0.96), "ctcRawScore": 0.50},
            {"count": 3, "spectral": 0.43, "durationCv": 0.102,
             "coverage": 0.40,
             "support": SIDECAR.repeat_candidate_support(0.43, 0.40), "ctcRawScore": 0.41},
        ]
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertTrue(decision["applied"], decision["reason"])
        self.assertEqual(decision["count"], 16)
        self.assertGreaterEqual(decision["margin"], SIDECAR.REPEAT_MIN_MARGIN)
        for candidate in candidates:
            candidate["ctcRawScore"] = 1.0 - candidate["ctcRawScore"]
        ctc_reversed = SIDECAR.select_repeat_count(candidates)
        self.assertEqual(ctc_reversed["count"], 16)
        self.assertEqual(ctc_reversed["margin"], decision["margin"])

    def test_high_coverage_resolves_close_period_alias_as_provisional_split(self):
        candidates = [
            {"count": 16, "spectral": 0.74, "durationCv": 0.08,
             "coverage": 0.94, "support": 0.80, "ctcRawScore": 0.45},
            {"count": 5, "spectral": 0.75, "durationCv": 0.03,
             "coverage": 0.70, "support": 0.79, "ctcRawScore": 0.46},
        ]
        decision = SIDECAR.select_repeat_count(candidates)
        self.assertTrue(decision["applied"], decision["reason"])
        self.assertEqual(decision["count"], 16)
        self.assertTrue(decision["provisional"])
        self.assertIn("需复核", decision["reason"])

    def test_expanded_lines_keep_unique_id_order_and_mora_mapping(self):
        units = [
            {"lineIndex": 0, "tokenIndex": 0, "moraIndex": 0, "mora": "a", "charStart": 0, "charEnd": 2},
            {"lineIndex": 1, "tokenIndex": 0, "moraIndex": 0, "mora": "b", "charStart": 2, "charEnd": 3},
        ]
        candidate = {
            "count": 3,
            "labelOffset": 2,
            "labelSpans": [(0, 5), (5, 10), (20, 26), (40, 46), (60, 66)],
            "charScores": [0.9, 0.9, 0.8, 0.8, 0.8],
        }
        line_result = {"id": "11111111-2222-3333-4444-555555555555", "order": 7}
        expanded = SIDECAR.expand_repeated_line_results(
            line_result, candidate, units, (2, 3), self.FRAME_SECONDS, duration=10.0, line_index=1)

        self.assertEqual([item["order"] for item in expanded], [7, 8, 9])
        self.assertEqual([item["repeatIndex"] for item in expanded], [0, 1, 2])
        self.assertEqual([item["sourceLineIndex"] for item in expanded], [1, 1, 1])
        ids = [item["id"] for item in expanded]
        self.assertEqual(len(ids), len(set(ids)), "扩展行必须保持唯一 id")
        self.assertEqual(ids[0], line_result["id"], "第一份应沿用原句 id")
        for item in expanded:
            self.assertEqual(len(item["morae"]), 1)
            mora = item["morae"][0]
            self.assertEqual((mora["tokenIndex"], mora["moraIndex"], mora["mora"]), (0, 0, "b"))
            self.assertLess(mora["start"], mora["end"])
            self.assertGreaterEqual(mora["start"], 0.0)
            self.assertLessEqual(item["end"], 10.0)

    def test_repeat_check_only_triggers_for_implausibly_long_lines(self):
        self.assertTrue(SIDECAR.is_repeat_check_needed(23.3, 14))
        self.assertFalse(SIDECAR.is_repeat_check_needed(3.0, 14))
        self.assertFalse(SIDECAR.is_repeat_check_needed(25.0, 1))


if __name__ == "__main__":
    unittest.main()
