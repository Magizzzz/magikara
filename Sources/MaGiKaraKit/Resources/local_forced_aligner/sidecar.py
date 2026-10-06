#!/usr/bin/env python3
"""Local Yohane/MMS wav2vec2 CTC alignment worker for MaGiKara.

The process accepts one JSON request on stdin and writes one JSON response to
stdout.  Model output is returned as float seconds in the original, untrimmed
audio timeline.  Diagnostics go to stderr so the JSON channel stays clean.

This is an experimental adapter, not a copy of FA-Kara's application code.
"""

from __future__ import annotations

import json
import math
import os
import re
import sys
import time
import uuid as _uuid
from typing import Any

PROTOCOL_VERSION = 1
TARGET_SAMPLE_RATE = 16_000
DEFAULT_MODEL_PATH = os.path.expanduser(
    "~/Library/Application Support/MaGiKara/LocalForcedAligner/models/yohane-ja-latn"
)

# --- Conservative repeat detection -----------------------------------------
#
# When one tail lyric is stretched across an implausibly long span, the CTC
# path can be re-run with the tail label sequence duplicated 2..24 times over
# the *same* emissions (the acoustic model is never re-run).  Candidate counts
# are then ranked purely from audio evidence: how well the audio inside the
# candidate segments repeats (local spectral self-similarity), how much of each
# segment is covered by aligned labels, and whether durations are pathological.
# CTC posterior / rawScore is reported for
# diagnostics only and must never decide the count: it grows monotonically with
# the number of copies and would bias toward over-segmentation.
#
# The detector is deliberately conservative. A wrong split is worse than a
# flagged line, but high phone coverage can resolve close period aliases
# provisionally instead of leaving a proven repeated outro as one long row.
REPEAT_CHECK_MIN_SECONDS = 8.0
REPEAT_MIN_COPIES = 2
# Japanese/English outro hooks can repeat well beyond eight times. Keep a
# bounded ceiling, but do not assume a short refrain has only a few copies.
REPEAT_MAX_COPIES = 24
REPEAT_RESAMPLE_FRAMES = 40
REPEAT_MAX_DURATION_CV = 0.15
REPEAT_MIN_SPECTRAL = 0.70
REPEAT_MIN_SUPPORT = 0.55
REPEAT_MIN_MARGIN = 0.05
# A narrowly-scoped soft spectral floor for a highly regular, clearly dominant
# repeat candidate. This avoids leaving an obvious loop as one overlong line
# when real vocals score just below the normal similarity threshold.
REPEAT_SOFT_MIN_SPECTRAL = 0.65
REPEAT_SOFT_MIN_SUPPORT = 0.62
REPEAT_SOFT_MAX_DURATION_CV = 0.08
REPEAT_SOFT_MIN_LEAD = 0.15
REPEAT_PROVISIONAL_MIN_COVERAGE = 0.90


class AlignmentError(RuntimeError):
    pass


def _romanize(kakasi: Any, text: str) -> str:
    converted = kakasi.convert(text)
    if not converted:
        return ""
    return str(converted[0].get("hepburn", "")).lower().replace("-", "")


def romanize_units(units: list[str], kakasi: Any) -> list[str]:
    """Map Japanese morae to the same compact Hepburn phone text used by FA-Kara.

    A sokuon gets its own repeated-consonant label, allowing MaGiKara to retain
    a mora boundary instead of silently merging っ into the previous mora.
    Long-vowel marks repeat the preceding vowel within that mora's span.
    """
    raw = [unit.strip().replace("ｰ", "ー") for unit in units]
    base = [_romanize(kakasi, unit.replace("ー", "")) for unit in raw]
    result: list[str] = []
    previous_vowel = ""
    for index, unit in enumerate(raw):
        if not unit:
            result.append("")
            continue
        if unit in {"っ", "ッ"}:
            following = next((value for value in base[index + 1 :] if value), "")
            onset = following[:1]
            if onset == "c":
                onset = "t"  # FA-Kara's Hepburn geminate normalization.
            result.append(onset if onset and onset not in "aeiou" else "h")
            if not following:
                # Match FA-Kara's terminal-sokuon fallback; this is unusual in
                # lyrics, so the row remains flagged with an explicit warning.
                pass
            continue

        spelling = base[index]
        if unit == "ー":
            if not previous_vowel:
                raise AlignmentError("歌词以长音符开头，缺少可延长的前置元音")
            spelling = previous_vowel
        elif "ー" in unit:
            vowel = next((char for char in reversed(spelling) if char in "aeiou"), "")
            if not vowel:
                raise AlignmentError(f"无法确定长音符 {unit!r} 应延长的元音")
            spelling += vowel
        # The CTC vocabulary is Latin letters plus apostrophe.  Reject anything
        # else instead of letting tokenizer UNK silently corrupt the transcript.
        if spelling and not re.fullmatch(r"[a-z']+", spelling):
            raise AlignmentError(f"无法将读音 {unit!r} 转成模型支持的拉丁音素")
        result.append(spelling)
        vowel = next((char for char in reversed(spelling) if char in "aeiou"), "")
        if vowel:
            previous_vowel = vowel
    return result


def ctc_viterbi(log_probs: Any, labels: list[int], blank_id: int) -> tuple[list[tuple[int, int]], list[float]]:
    """Return per-label [startFrame, endFrame) and mean target posteriors.

    Uses the standard CTC trellis with blank states and the repeated-label skip
    rule.  NumPy is imported lazily to keep protocol-only tests lightweight.
    """
    import numpy as np

    if not labels:
        raise AlignmentError("歌词没有可用于强制对齐的音素")
    emissions = np.asarray(log_probs, dtype=np.float32)
    if emissions.ndim != 2 or emissions.shape[0] == 0:
        raise AlignmentError("声学模型没有返回有效帧")
    frame_count = int(emissions.shape[0])
    state_labels = np.full(2 * len(labels) + 1, blank_id, dtype=np.int64)
    state_labels[1::2] = np.asarray(labels, dtype=np.int64)
    state_count = int(state_labels.size)
    if frame_count < len(labels):
        raise AlignmentError(
            f"音频帧数 {frame_count} 少于歌词音素数 {len(labels)}，无法可靠对齐"
        )

    back = np.zeros((frame_count, state_count), dtype=np.uint8)
    previous = np.full(state_count, -np.inf, dtype=np.float32)
    previous[0] = emissions[0, blank_id]
    previous[1] = emissions[0, labels[0]]
    can_skip = np.zeros(state_count, dtype=bool)
    can_skip[2:] = (state_labels[2:] != blank_id) & (state_labels[2:] != state_labels[:-2])

    for frame in range(1, frame_count):
        one_step = np.full(state_count, -np.inf, dtype=np.float32)
        one_step[1:] = previous[:-1]
        two_step = np.full(state_count, -np.inf, dtype=np.float32)
        two_step[2:] = previous[:-2]

        best = previous.copy()
        predecessor = np.zeros(state_count, dtype=np.uint8)
        use_one = one_step > best
        best[use_one] = one_step[use_one]
        predecessor[use_one] = 1
        use_two = can_skip & (two_step > best)
        best[use_two] = two_step[use_two]
        predecessor[use_two] = 2
        previous = best + emissions[frame, state_labels]
        back[frame] = predecessor

    final_candidates = [state_count - 1, state_count - 2]
    state = max(final_candidates, key=lambda candidate: float(previous[candidate]))
    if not math.isfinite(float(previous[state])):
        raise AlignmentError("CTC 找不到覆盖整段歌词的合法路径")

    state_path = np.empty(frame_count, dtype=np.int32)
    for frame in range(frame_count - 1, -1, -1):
        state_path[frame] = state
        if frame:
            state -= int(back[frame, state])

    spans: list[tuple[int, int]] = []
    scores: list[float] = []
    posterior = np.exp(np.clip(emissions, -80.0, 0.0))
    for label_index, label in enumerate(labels):
        frames = np.flatnonzero(state_path == (2 * label_index + 1))
        if frames.size == 0:
            spans.append((-1, -1))
            scores.append(0.0)
        else:
            spans.append((int(frames[0]), int(frames[-1]) + 1))
            scores.append(float(posterior[frames, label].mean()))
    return spans, scores


# --- Pure-audio repeat evidence -------------------------------------------


def spectral_features(waveform: Any, sample_rate: int, hop_seconds: float) -> Any:
    """Log-magnitude spectrogram whose frame rate matches the CTC frame rate.

    Frame ``i`` covers samples ``[i * hop, i * hop + 2 * hop)`` so a global CTC
    frame index can be used directly as a spectrogram index.
    """
    import numpy as np

    samples = np.asarray(waveform, dtype=np.float32).reshape(-1)
    hop = max(1, int(round(float(sample_rate) * float(hop_seconds))))
    window = max(hop, hop * 2)
    if samples.size < window:
        return np.zeros((0, 1), dtype=np.float32)
    frames = np.lib.stride_tricks.sliding_window_view(samples, window)[::hop]
    windowed = frames * np.hanning(window).astype(np.float32)
    magnitude = np.log1p(np.abs(np.fft.rfft(windowed, axis=1)))
    return magnitude.astype(np.float32)


def _resample_feature(matrix: Any, length: int) -> Any:
    import numpy as np

    if matrix.shape[0] == length:
        return matrix
    if matrix.shape[0] < 2:
        return np.repeat(matrix, length, axis=0)
    old = np.linspace(0.0, 1.0, matrix.shape[0])
    new = np.linspace(0.0, 1.0, length)
    out = np.empty((length, matrix.shape[1]), dtype=np.float32)
    for column in range(matrix.shape[1]):
        out[:, column] = np.interp(new, old, matrix[:, column])
    return out


def segment_spectral_similarity(features: Any, spans: list[tuple[int, int]],
                                resample_frames: int = REPEAT_RESAMPLE_FRAMES) -> float:
    """Mean pairwise cosine similarity of the candidate segments' spectra.

    Every segment is resampled to the same number of frames first, so the score
    measures whether the *time-varying* spectral content repeats across the
    candidate copies.  A wrong copy count mis-aligns the segments and lowers the
    score; a genuine loop keeps it high.  This is the pure-audio interval /
    boundary evidence and never looks at CTC posteriors.
    """
    import numpy as np

    if features.shape[0] == 0 or len(spans) < 2:
        return 0.0
    vectors = []
    for start, end in spans:
        start = max(0, int(start))
        end = min(int(features.shape[0]), int(end))
        if end - start < 2:
            return 0.0
        matrix = _resample_feature(features[start:end], resample_frames)
        vector = matrix.reshape(-1).astype(np.float64)
        vector -= vector.mean()
        norm = float(np.linalg.norm(vector))
        if norm < 1e-8:
            return 0.0
        vectors.append(vector / norm)
    stacked = np.stack(vectors)
    similarity = stacked @ stacked.T
    upper = np.triu_indices(len(vectors), 1)
    return float(np.clip(similarity[upper].mean(), -1.0, 1.0))


def repeat_duration_cv(spans: list[tuple[int, int]], frame_seconds: float) -> float:
    import numpy as np

    durations = np.asarray([(end - start) * frame_seconds for start, end in spans], dtype=np.float64)
    durations = durations[durations > 0]
    if durations.size < 2:
        return 1.0
    mean = float(durations.mean())
    if mean <= 1e-6:
        return 1.0
    return float(durations.std() / mean)


def repeat_candidate_support(spectral: float, coverage: float) -> float:
    # Duration CV alone rewards coarse tilings: one candidate copy can contain
    # several real phrase repeats and still have perfectly regular outer bounds.
    # Acoustic label coverage instead rewards candidates whose labels account
    # for the sung audio inside each proposed copy.
    coverage = max(0.0, min(1.0, coverage))
    similarity = max(0.0, min(1.0, spectral))
    return float((similarity ** 0.6) * (coverage ** 0.4))


def is_repeat_check_needed(line_duration: float, mora_count: int) -> bool:
    if mora_count < 2:
        return False
    return float(line_duration) >= REPEAT_CHECK_MIN_SECONDS


def select_repeat_count(candidates: list[dict[str, Any]],
                        min_spectral: float = REPEAT_MIN_SPECTRAL,
                        min_support: float = REPEAT_MIN_SUPPORT,
                        max_cv: float = REPEAT_MAX_DURATION_CV,
                        min_margin: float = REPEAT_MIN_MARGIN) -> dict[str, Any]:
    """Pick a copy count from audio evidence, or explicitly abstain.

    ``ctcRawScore`` is intentionally ignored here.  A candidate is eligible only
    when spectral repetition and aligned-label coverage are strong; duration
    CV remains a sanity gate, not a reward for coarse under-segmentation.
    """
    if not candidates:
        return {"applied": False, "count": None, "reason": "没有可评估的重复候选",
                "margin": None, "chosen": None, "candidates": []}

    ranked = sorted(candidates, key=lambda item: item["support"], reverse=True)
    best = ranked[0]
    runner = ranked[1] if len(ranked) > 1 else None
    margin = best["support"] - (runner["support"] if runner else 0.0)

    # Permit only a tightly constrained exception below the normal spectral
    # floor: the best count must still have strong combined support, very
    # regular copy durations, and a decisive lead over every alternative.
    # This is intentionally not a global lowering of the spectral threshold.
    soft_spectral_acceptance = (
        best["spectral"] >= REPEAT_SOFT_MIN_SPECTRAL
        and best["support"] >= REPEAT_SOFT_MIN_SUPPORT
        and best["durationCv"] <= REPEAT_SOFT_MAX_DURATION_CV
        and (runner is None or margin >= REPEAT_SOFT_MIN_LEAD)
    )

    if ((best["spectral"] < min_spectral and not soft_spectral_acceptance)
            or best["support"] < min_support):
        reason = (f"纯音频重复证据不足（最佳谱相似度 {best['spectral']:.2f}，"
                  f"综合支持度 {best['support']:.2f}），保留单份结果")
        return {"applied": False, "count": None, "reason": reason,
                "margin": margin, "chosen": None, "candidates": ranked}

    eligible = [item for item in ranked
                if (item["spectral"] >= min_spectral
                    or (soft_spectral_acceptance and item["count"] == best["count"]))
                and item["support"] >= min_support
                and item["durationCv"] <= max_cv]
    if not eligible:
        reason = (f"重复段时长不够规整（最佳 CV {best['durationCv']:.3f}），"
                  f"保留单份结果")
        return {"applied": False, "count": None, "reason": reason,
                "margin": margin, "chosen": None, "candidates": ranked}

    support_winner = eligible[0]
    support_margin = (support_winner["support"] - eligible[1]["support"]
                      if len(eligible) > 1 else support_winner["support"])
    if soft_spectral_acceptance and support_winner["count"] == best["count"] and runner:
        support_margin = margin
    chosen = support_winner
    margin = support_margin

    if margin < min_margin:
        # When period aliases remain close, still prevent a proven repeated
        # outro from being emitted as one 20-second subtitle if one candidate
        # has exceptionally strong phone coverage. Keep it explicitly flagged.
        if (best["spectral"] >= min_spectral
                and best.get("coverage", 0.0) >= REPEAT_PROVISIONAL_MIN_COVERAGE
                and best["durationCv"] <= max_cv):
            reason = (f"重复次数候选接近，暂按音素覆盖率最高的 {best['count']} 次分段"
                      f"（谱相似度 {best['spectral']:.2f}，音素覆盖率 {best['coverage']:.2f}；"
                      f"需复核，非人工真值）")
            return {"applied": True, "count": int(best["count"]),
                    "reason": reason, "margin": margin, "chosen": best,
                    "provisional": True, "candidates": ranked}
        counts = "、".join(str(item["count"]) for item in eligible[:3])
        reason = (f"{counts} 等重复次数候选分数接近（margin {margin:.3f}），"
                  f"无法可靠判断，需复核")
        return {"applied": False, "count": None, "reason": reason,
                "margin": margin, "chosen": None, "candidates": ranked}

    if soft_spectral_acceptance and chosen["count"] == best["count"] and chosen["spectral"] < min_spectral:
        reason = (f"纯音频重复支持 {chosen['count']} 次（谱相似度 {chosen['spectral']:.2f} 略低于常规阈值，"
                  f"但时长高度规整且候选明显领先；CV {chosen['durationCv']:.3f}，"
                  f"margin {margin:.3f}；非人工真值）")
    else:
        reason = (f"纯音频谱重复与音素覆盖支持 {chosen['count']} 次"
                  f"（谱相似度 {chosen['spectral']:.2f}，音素覆盖率 {chosen.get('coverage', 0.0):.2f}，"
                  f"时长 CV {chosen['durationCv']:.3f}，"
                  f"margin {margin:.3f}；非人工真值）")
    return {"applied": True, "count": int(chosen["count"]), "reason": reason,
            "margin": margin, "chosen": chosen, "provisional": False,
            "candidates": ranked}


def evaluate_repeat_candidates(log_probs: Any,
                               prefix_labels: list[int],
                               last_labels: list[int],
                               start_frame: int,
                               waveform: Any,
                               sample_rate: int,
                               frame_seconds: float,
                               blank_id: int,
                               min_copies: int = REPEAT_MIN_COPIES,
                               max_copies: int = REPEAT_MAX_COPIES) -> list[dict[str, Any]]:
    """Re-align the tail 2..24 times over the existing emissions.

    The acoustic model is *not* re-run: only the CTC trellis is repeated on the
    same ``log_probs``.  ``prefix_labels`` conditions the tail on the preceding
    line so the first copy does not absorb unrelated frames.
    """
    import numpy as np

    if not last_labels:
        return []
    emissions = np.asarray(log_probs, dtype=np.float32)
    start_frame = max(0, int(start_frame))
    region = emissions[start_frame:]
    if region.shape[0] == 0:
        return []
    features = spectral_features(waveform, sample_rate, frame_seconds)
    offset = len(prefix_labels)
    length = len(last_labels)
    candidates: list[dict[str, Any]] = []

    for count in range(min_copies, max_copies + 1):
        sequence = list(prefix_labels) + list(last_labels) * count
        try:
            local_spans, local_scores = ctc_viterbi(region, sequence, blank_id)
        except AlignmentError:
            continue
        global_spans = [(a + start_frame, b + start_frame) for a, b in local_spans]
        copy_spans: list[tuple[int, int]] = []
        valid = True
        for copy_index in range(count):
            indices = range(offset + copy_index * length, offset + (copy_index + 1) * length)
            available = [global_spans[i] for i in indices if global_spans[i][0] >= 0]
            if not available:
                valid = False
                break
            copy_spans.append((min(a for a, _ in available), max(b for _, b in available)))
        if not valid:
            continue

        spectral = segment_spectral_similarity(features, copy_spans)
        duration_cv = repeat_duration_cv(copy_spans, frame_seconds)
        copy_coverages = []
        for copy_index, (copy_start, copy_end) in enumerate(copy_spans):
            indices = range(offset + copy_index * length, offset + (copy_index + 1) * length)
            active_frames = sum(max(0, global_spans[i][1] - global_spans[i][0])
                                for i in indices if global_spans[i][0] >= 0)
            outer_frames = max(1, copy_end - copy_start)
            copy_coverages.append(min(1.0, active_frames / outer_frames))
        coverage = min(copy_coverages, default=0.0)
        repeated_scores = [local_scores[i] for i in range(offset, offset + count * length)]
        candidates.append({
            "count": count,
            "spectral": spectral,
            "durationCv": duration_cv,
            "durationRegularity": max(0.0, 1.0 - duration_cv / REPEAT_MAX_DURATION_CV),
            "coverage": coverage,
            "ctcRawScore": float(np.mean(repeated_scores)) if repeated_scores else 0.0,
            "support": repeat_candidate_support(spectral, coverage),
            "labelSpans": global_spans,
            "charScores": list(local_scores),
            "labelOffset": offset,
            "copySpans": copy_spans,
            "startFrame": start_frame,
        })
    return candidates


def _public_repeat_analysis(decision: dict[str, Any]) -> dict[str, Any]:
    def clean(item: dict[str, Any]) -> dict[str, Any]:
        return {
            "count": int(item["count"]),
            "spectral": round(float(item["spectral"]), 4),
            "durationCv": round(float(item["durationCv"]), 4),
            "durationRegularity": round(float(item["durationRegularity"]), 4),
            "coverage": round(float(item.get("coverage", 0.0)), 4),
            "ctcRawScore": round(float(item["ctcRawScore"]), 4),
            "support": round(float(item["support"]), 4),
        }

    return {
        "applied": bool(decision["applied"]),
        "count": decision["count"],
        "reason": decision["reason"],
        "margin": None if decision["margin"] is None else round(float(decision["margin"]), 4),
        "candidates": [clean(item) for item in decision.get("candidates", [])],
    }


def expand_repeated_line_results(line_result: dict[str, Any],
                                 candidate: dict[str, Any],
                                 units: list[dict[str, Any]],
                                 line_range: tuple[int, int],
                                 frame_seconds: float,
                                 duration: float,
                                 line_index: int) -> list[dict[str, Any]]:
    """Build one independent lyric-line result per copy, with unique ids.

    Every copy keeps the original ``tokenIndex`` / ``moraIndex`` / ``mora``
    mapping so the Swift bridge can re-validate it against the lyric draft.
    """
    import numpy as np

    line_start, line_end = int(line_range[0]), int(line_range[1])
    length = line_end - line_start
    offset = int(candidate["labelOffset"])
    spans = candidate["labelSpans"]
    scores = candidate["charScores"]
    line_units = [unit for unit in units if unit["lineIndex"] == line_index]
    expanded: list[dict[str, Any]] = []

    for copy_index in range(int(candidate["count"])):
        morae: list[dict[str, Any]] = []
        for unit in line_units:
            relative = int(unit["charStart"]) - line_start
            first = offset + copy_index * length + relative
            indices = range(first, first + (int(unit["charEnd"]) - int(unit["charStart"])))
            valid = [(spans[i], scores[i]) for i in indices if spans[i][0] >= 0]
            if not valid:
                raise AlignmentError("重复展开时音拍缺少有效区间")
            start_frame = min(span[0] for span, _ in valid)
            end_frame = max(span[1] for span, _ in valid)
            morae.append({
                "lineIndex": line_index,
                "tokenIndex": unit["tokenIndex"],
                "moraIndex": unit["moraIndex"],
                "mora": unit["mora"],
                "start": max(0.0, start_frame * frame_seconds),
                "end": min(duration, end_frame * frame_seconds),
                "score": float(np.mean([value for _, value in valid])),
            })
        usable = [item for item in morae if item["start"] is not None and item["end"] is not None]
        if not usable:
            raise AlignmentError("重复展开后整句没有有效音拍")
        expanded.append({
            "id": line_result["id"] if copy_index == 0 else str(_uuid.uuid4()),
            "order": int(line_result["order"]) + copy_index,
            "sourceLineIndex": line_index,
            "repeatIndex": copy_index,
            "start": min(float(item["start"]) for item in usable),
            "end": max(float(item["end"]) for item in usable),
            "rawScore": float(np.mean([item["score"] for item in usable])),
            "morae": morae,
        })
    return expanded


def build_target(request: dict[str, Any], tokenizer: Any) -> tuple[list[int], list[dict[str, Any]], list[str]]:
    from pykakasi import kakasi

    converter = kakasi()
    romanized: list[str] = []
    units: list[dict[str, Any]] = []
    warnings: list[str] = []
    lines = request.get("lines")
    if not isinstance(lines, list) or not lines:
        raise AlignmentError("请求中没有歌词行")

    for line_index, line in enumerate(lines):
        tokens = line.get("tokens", [])
        line_morae: list[tuple[int, int, str]] = []
        for token_index, token in enumerate(tokens):
            morae = token.get("morae", [])
            line_morae.extend((token_index, mora_index, str(mora))
                              for mora_index, mora in enumerate(morae))
        if not line_morae:
            raise AlignmentError(f"第 {line.get('order', line_index + 1)} 句没有可用于对齐的读音")

        readings = romanize_units([mora for _, _, mora in line_morae], converter)
        for index, ((token_index, mora_index, mora), spelling) in enumerate(zip(line_morae, readings)):
            if not spelling:
                raise AlignmentError(
                    f"第 {line.get('order', line_index + 1)} 句第 {token_index + 1} 词第 {mora_index + 1} 拍没有可映射的罗马音"
                )
            if mora in {"っ", "ッ"} and index == len(line_morae) - 1:
                warnings.append(f"第 {line.get('order', line_index + 1)} 句以促音结束，末拍读音使用保守兜底")
            start = len(romanized)
            romanized.extend(spelling)
            units.append({
                "lineIndex": line_index,
                "tokenIndex": token_index,
                "moraIndex": mora_index,
                "mora": mora,
                "charStart": start,
                "charEnd": len(romanized),
            })

    if not romanized:
        raise AlignmentError("歌词没有可用于强制对齐的罗马音")
    ids = tokenizer.convert_tokens_to_ids(romanized)
    if len(ids) != len(romanized):
        raise AlignmentError("模型 tokenizer 没有按单字符映射，无法保留音拍边界")
    unk_id = tokenizer.unk_token_id
    if unk_id is not None and any(int(value) == int(unk_id) for value in ids):
        bad = sorted({char for char, value in zip(romanized, ids) if int(value) == int(unk_id)})
        raise AlignmentError("读音含模型未知字符：" + "、".join(bad))
    return [int(value) for value in ids], units, warnings


def _line_label_ranges(units: list[dict[str, Any]], line_count: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    for line_index in range(line_count):
        line_units = [unit for unit in units if unit["lineIndex"] == line_index]
        if not line_units:
            raise AlignmentError(f"第 {line_index + 1} 句没有可用于对齐的音素")
        ranges.append((min(int(unit["charStart"]) for unit in line_units),
                       max(int(unit["charEnd"]) for unit in line_units)))
    return ranges


def _load_model(model_path: str, requested_device: str) -> tuple[Any, Any, Any, str]:
    import torch
    from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

    if not os.path.isdir(model_path):
        raise AlignmentError(f"本地 Yohane 模型不存在：{model_path}")
    processor = Wav2Vec2Processor.from_pretrained(model_path, local_files_only=True)
    model = Wav2Vec2ForCTC.from_pretrained(model_path, local_files_only=True)
    model.eval()
    if requested_device == "cpu":
        device = torch.device("cpu")
    elif requested_device == "mps":
        if not torch.backends.mps.is_available():
            raise AlignmentError("当前 PyTorch 未检测到可用的 Apple Metal (MPS)")
        device = torch.device("mps")
    elif torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")
    model.to(device)
    return torch, processor, model, str(device)


def align(request: dict[str, Any]) -> dict[str, Any]:
    import numpy as np
    import torch
    import torchaudio

    if request.get("protocolVersion") != PROTOCOL_VERSION:
        raise AlignmentError(f"不支持的 sidecar 协议版本：{request.get('protocolVersion')}")
    audio_path = os.path.expanduser(str(request.get("audioPath", "")))
    if not audio_path or not os.path.isfile(audio_path):
        raise AlignmentError(f"找不到对齐音频：{audio_path or '(empty)'}")

    model_path = os.path.expanduser(str(request.get("modelPath") or DEFAULT_MODEL_PATH))
    start_time = time.perf_counter()
    torch, processor, model, device_name = _load_model(model_path, str(request.get("device", "auto")))
    waveform, sample_rate = torchaudio.load(audio_path)
    if waveform.ndim != 2 or waveform.shape[1] == 0:
        raise AlignmentError("音频为空或声道结构无效")
    source_duration = float(waveform.shape[1]) / float(sample_rate)
    waveform = waveform.mean(dim=0, keepdim=True)
    if int(sample_rate) != TARGET_SAMPLE_RATE:
        waveform = torchaudio.functional.resample(waveform, int(sample_rate), TARGET_SAMPLE_RATE)

    labels, unit_map, warnings = build_target(request, processor.tokenizer)
    line_ranges = _line_label_ranges(unit_map, len(request["lines"]))
    input_ratio = int(getattr(model.config, "inputs_to_logits_ratio", 320))
    if input_ratio <= 0:
        raise AlignmentError("模型没有提供有效的 logits 时间步长")

    inference_start = time.perf_counter()
    inputs = processor(waveform.squeeze(0).numpy(),
                       sampling_rate=TARGET_SAMPLE_RATE,
                       return_tensors="pt")
    try:
        with torch.inference_mode():
            logits = model(**{key: value.to(device_name) for key, value in inputs.items()}).logits[0]
            log_probs = torch.log_softmax(logits, dim=-1).to("cpu").numpy()
    except Exception as error:
        if device_name != "mps":
            raise
        # MPS can lack an operator for an upstream transformer version. Retry on
        # CPU explicitly and report the fallback; never return a partial result.
        print(f"MPS 推理失败，改用 CPU 重试：{error}", file=sys.stderr, flush=True)
        model.to("cpu")
        device_name = "cpu-fallback"
        with torch.inference_mode():
            logits = model(**inputs).logits[0]
            log_probs = torch.log_softmax(logits, dim=-1).numpy()

    blank_id = processor.tokenizer.pad_token_id
    if blank_id is None:
        raise AlignmentError("模型 tokenizer 没有 CTC blank/pad id")
    char_spans, char_scores = ctc_viterbi(log_probs, labels, int(blank_id))
    inference_seconds = time.perf_counter() - inference_start
    frame_seconds = float(input_ratio) / TARGET_SAMPLE_RATE

    per_mora: list[dict[str, Any]] = []
    for unit in unit_map:
        indices = range(int(unit["charStart"]), int(unit["charEnd"]))
        selected = [(char_spans[i], char_scores[i]) for i in indices]
        valid = [(span, score) for span, score in selected if span[0] >= 0]
        if not valid:
            start = end = None
            score = 0.0
        else:
            start_frame = min(span[0] for span, _ in valid)
            end_frame = max(span[1] for span, _ in valid)
            start = max(0.0, start_frame * frame_seconds)
            end = min(source_duration, end_frame * frame_seconds)
            score = float(np.mean([value for _, value in valid]))
        per_mora.append({
            "lineIndex": unit["lineIndex"],
            "tokenIndex": unit["tokenIndex"],
            "moraIndex": unit["moraIndex"],
            "mora": unit["mora"],
            "start": start,
            "end": end,
            "score": score,
        })

    line_results: list[dict[str, Any]] = []
    for index, line in enumerate(request["lines"]):
        line_morae = [item for item in per_mora if item["lineIndex"] == index]
        valid = [item for item in line_morae if item["start"] is not None and item["end"] is not None]
        if not valid:
            raise AlignmentError(f"第 {line.get('order', index + 1)} 句没有得到有效音拍区间")
        line_results.append({
            "id": str(line["id"]),
            "order": int(line["order"]),
            "sourceLineIndex": index,
            "repeatIndex": 0,
            "start": min(float(item["start"]) for item in valid),
            "end": max(float(item["end"]) for item in valid),
            "rawScore": float(np.mean([item["score"] for item in valid])),
            "morae": [item for item in line_morae],
        })

    # Conservative tail-repeat expansion: only the last line, only with clear
    # pure-audio evidence and a margin, and never by re-running the model.
    repeat_analysis: dict[str, Any] | None = None
    last_index = len(request["lines"]) - 1
    if line_results:
        last_result = line_results[last_index]
        last_duration = float(last_result["end"]) - float(last_result["start"])
        last_mora_count = len([item for item in last_result["morae"]
                               if item["start"] is not None and item["end"] is not None])
        if is_repeat_check_needed(last_duration, last_mora_count):
            last_range = line_ranges[last_index]
            last_labels = labels[last_range[0]:last_range[1]]
            if last_index > 0:
                previous_range = line_ranges[last_index - 1]
                previous_valid = [char_spans[i] for i in range(*previous_range)
                                  if char_spans[i][0] >= 0]
                start_frame = min(span[0] for span in previous_valid) if previous_valid else 0
                prefix_labels = labels[previous_range[0]:previous_range[1]]
            else:
                start_frame = 0
                prefix_labels = []
            try:
                candidates = evaluate_repeat_candidates(
                    log_probs, prefix_labels, last_labels, start_frame,
                    waveform.squeeze(0).numpy(), TARGET_SAMPLE_RATE, frame_seconds,
                    int(blank_id))
                decision = select_repeat_count(candidates)
            except Exception as error:  # never let an experiment break base alignment
                decision = {"applied": False, "count": None,
                            "reason": f"重复候选评估失败：{error}",
                            "margin": None, "chosen": None, "candidates": []}
            if decision["applied"]:
                try:
                    chosen = decision["chosen"]
                    line_results = line_results[:-1] + expand_repeated_line_results(
                        last_result, chosen, unit_map, last_range, frame_seconds,
                        source_duration, last_index)
                    warnings.append(
                        f"第 {last_result['order']} 句尾句纯音频重复证据明确，自动展开为 "
                        f"{int(chosen['count'])} 个独立歌词行（谱重复 + 音素覆盖率；"
                        f"非人工真值，仍需校准）。")
                except Exception as error:  # fall back instead of returning a partial result
                    decision = {"applied": False, "count": None,
                                "reason": f"重复展开失败：{error}",
                                "margin": decision.get("margin"), "chosen": None,
                                "candidates": decision.get("candidates", [])}
                    warnings.append(
                        f"第 {last_result['order']} 句尾句异常长（{last_duration:.1f} 秒），"
                        f"但重复展开失败，需复核；保留原单份结果，未猜次数。")
            else:
                warnings.append(
                    f"第 {last_result['order']} 句尾句异常长（{last_duration:.1f} 秒），"
                    f"但重复次数不确定，需复核；保留原单份结果，未猜次数。")
            repeat_analysis = _public_repeat_analysis(decision)

    response: dict[str, Any] = {
        "protocolVersion": PROTOCOL_VERSION,
        "ok": True,
        "model": os.path.basename(os.path.normpath(model_path)),
        "device": device_name,
        "sourceSampleRate": int(sample_rate),
        "targetSampleRate": TARGET_SAMPLE_RATE,
        "frameSeconds": frame_seconds,
        "duration": source_duration,
        "inferenceSeconds": inference_seconds,
        "elapsedSeconds": time.perf_counter() - start_time,
        "lines": line_results,
        "warnings": warnings,
    }
    if repeat_analysis is not None:
        response["repeatAnalysis"] = repeat_analysis
    return response


def main() -> int:
    try:
        request = json.load(sys.stdin)
        response = align(request)
    except Exception as error:
        response = {
            "protocolVersion": PROTOCOL_VERSION,
            "ok": False,
            "error": str(error),
        }
    json.dump(response, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.stdout.flush()
    return 0 if response.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
