#!/usr/bin/env python3
"""Evaluate a MaGiKara project against blind, human audio-only timing marks.

This intentionally refuses OCR, ASR, synthetic, interpolated, or model-produced
timings as ground truth. It does not make the result more accurate; it fixes the
denominator and reports both timing agreement and the strict no-edit rate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import unicodedata
from pathlib import Path
from urllib.parse import unquote, urlparse


class EvaluationError(ValueError):
    pass


# AVFoundation and ffprobe can report slightly different container durations
# for the exact same byte-identical MP4. SHA-256 and byte count are the
# authoritative media identity checks; this is only a sanity bound for a
# corrupted project duration, not a media-version identity test.
MEDIA_DURATION_SANITY_TOLERANCE_SEC = 0.25


def normalized_lyric(text: object) -> str:
    value = unicodedata.normalize("NFKC", str(text)).casefold()
    kept = []
    for char in value:
        # Ignore layout/punctuation differences, but preserve apostrophes since
        # they can change a sung contraction (e.g. "flower's" vs "flowers").
        if char in {"'", "’"}:
            kept.append("'")
        elif unicodedata.category(char)[0] not in {"P", "Z", "C"}:
            kept.append(char)
    return "".join(kept)


def _finite_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvaluationError(f"{label} 必须是数字")
    result = float(value)
    if not math.isfinite(result):
        raise EvaluationError(f"{label} 必须是有限数字")
    return result


def validate_truth(truth: dict) -> tuple[list[dict], dict]:
    if truth.get("kind") != "human-acoustic-truth":
        raise EvaluationError("真值 kind 必须是 human-acoustic-truth，拒绝模型/OCR/TTS 产物")
    if truth.get("method") != "audio-only-blind-listen":
        raise EvaluationError("真值 method 必须是 audio-only-blind-listen")
    if truth.get("blindToModelOutput") is not True:
        raise EvaluationError("人工标注必须声明 blindToModelOutput=true")
    if not str(truth.get("annotator", "")).strip():
        raise EvaluationError("真值缺少 annotator")
    if not str(truth.get("annotatedAt", "")).strip():
        raise EvaluationError("真值缺少 annotatedAt")

    media = truth.get("media")
    if not isinstance(media, dict):
        raise EvaluationError("真值缺少 media 指纹")
    digest = str(media.get("sha256", "")).lower()
    if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
        raise EvaluationError("media.sha256 必须是 64 位 SHA-256")
    _finite_number(media.get("bytes"), "media.bytes")
    _finite_number(media.get("durationSec"), "media.durationSec")

    lines = truth.get("lines")
    if not isinstance(lines, list) or not lines:
        raise EvaluationError("真值 lines 不能为空")
    seen_orders: set[int] = set()
    for index, line in enumerate(lines, 1):
        if not isinstance(line, dict):
            raise EvaluationError(f"真值第 {index} 行格式错误")
        order = line.get("order")
        if isinstance(order, bool) or not isinstance(order, int) or order < 1 or order in seen_orders:
            raise EvaluationError(f"真值第 {index} 行 order 无效或重复")
        seen_orders.add(order)
        if not str(line.get("text", "")).strip():
            raise EvaluationError(f"真值第 {order} 行没有歌词文本")
        start = _finite_number(line.get("acousticOnset"), f"第 {order} 行 acousticOnset")
        end = _finite_number(line.get("acousticOffset"), f"第 {order} 行 acousticOffset")
        if start < 0 or end <= start:
            raise EvaluationError(f"真值第 {order} 行时间范围无效")
        if end > float(media["durationSec"]) + 0.05:
            raise EvaluationError(f"真值第 {order} 行超出媒体时长")

    lines.sort(key=lambda line: line["order"])
    return lines, media


def project_media_path(project: dict, override: str | None) -> Path:
    if override:
        return Path(override).expanduser().resolve()
    value = str(project.get("mediaURL", ""))
    parsed = urlparse(value)
    if parsed.scheme == "file":
        return Path(unquote(parsed.path)).expanduser().resolve()
    if parsed.scheme:
        raise EvaluationError("工程媒体不是本地 file URL；请通过 --media 指定原始媒体")
    return Path(value).expanduser().resolve()


def verify_media(project: dict, truth_media: dict, override: str | None) -> dict:
    media_path = project_media_path(project, override)
    if not media_path.is_file():
        raise EvaluationError(f"找不到待验收媒体：{media_path}；请用 --media 指定原始文件")
    stat = media_path.stat()
    digest = hashlib.sha256()
    with media_path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    actual_hash = digest.hexdigest()
    if stat.st_size != int(truth_media["bytes"]):
        raise EvaluationError("媒体字节数与人工真值不符；疑似不是同一文件版本")
    if actual_hash != str(truth_media["sha256"]).lower():
        raise EvaluationError("媒体 SHA-256 与人工真值不符；拒绝跨版本评测")
    duration = _finite_number(project.get("duration"), "工程 duration")
    truth_duration = float(truth_media["durationSec"])
    duration_difference = abs(duration - truth_duration)
    if duration_difference > MEDIA_DURATION_SANITY_TOLERANCE_SEC:
        raise EvaluationError(
            "工程与人工真值时长差超过容错 "
            f"{MEDIA_DURATION_SANITY_TOLERANCE_SEC:.2f} 秒；请确认工程时长元数据"
        )
    return {"path": str(media_path), "bytes": stat.st_size, "sha256": actual_hash,
            "durationSec": duration,
            "truthDurationSec": truth_duration,
            "durationDifferenceSec": round(duration_difference, 6)}


def _distribution(errors: list[float], tolerance: float) -> dict:
    if not errors:
        return {"count": 0, "meanAbsSec": None, "medianAbsSec": None,
                "p90AbsSec": None, "maxAbsSec": None, "withinTolerance": 0,
                "withinToleranceRate": 0.0}
    absolute = sorted(abs(value) for value in errors)
    p90_index = max(0, math.ceil(0.9 * len(absolute)) - 1)
    return {
        "count": len(errors),
        "meanSignedSec": round(statistics.mean(errors), 4),
        "meanAbsSec": round(statistics.mean(absolute), 4),
        "medianAbsSec": round(statistics.median(absolute), 4),
        "p90AbsSec": round(absolute[p90_index], 4),
        "maxAbsSec": round(absolute[-1], 4),
        "withinTolerance": sum(value <= tolerance for value in absolute),
        "withinToleranceRate": round(sum(value <= tolerance for value in absolute) / len(absolute), 6),
    }


def evaluate(project: dict, truth: dict, tolerance: float, media_override: str | None = None) -> dict:
    if not math.isfinite(tolerance) or tolerance <= 0:
        raise EvaluationError("tolerance 必须是正数")
    truth_lines, truth_media = validate_truth(truth)
    verified_media = verify_media(project, truth_media, media_override)
    predicted = project.get("lyricLines")
    if not isinstance(predicted, list):
        raise EvaluationError("工程缺少 lyricLines")
    by_order: dict[int, dict] = {}
    for line in predicted:
        order = line.get("order")
        if isinstance(order, bool) or not isinstance(order, int) or order in by_order:
            raise EvaluationError("工程歌词行 order 无效或重复")
        by_order[order] = line

    onset_errors: list[float] = []
    offset_errors: list[float] = []
    reports: list[dict] = []
    no_edit = 0
    missing_orders: list[int] = []
    text_mismatches: list[int] = []
    for gold in truth_lines:
        order = gold["order"]
        guess = by_order.get(order)
        problems: list[str] = []
        if guess is None:
            missing_orders.append(order)
            problems.append("missing_prediction")
            reports.append({"order": order, "text": gold["text"], "passed": False,
                            "problems": problems})
            continue
        text_matches = normalized_lyric(guess.get("displayText", "")) == normalized_lyric(gold["text"])
        if not text_matches:
            text_mismatches.append(order)
            problems.append("lyric_mismatch")
        start = end = None
        try:
            start = _finite_number(guess.get("singStart"), f"预测第 {order} 行 singStart")
            end = _finite_number(guess.get("singEnd"), f"预测第 {order} 行 singEnd")
            if start < 0 or end <= start or end > verified_media["durationSec"] + 0.05:
                problems.append("invalid_prediction_time")
        except EvaluationError:
            problems.append("missing_prediction_time")

        onset_error = offset_error = None
        if start is not None and end is not None and "invalid_prediction_time" not in problems:
            onset_error = start - float(gold["acousticOnset"])
            offset_error = end - float(gold["acousticOffset"])
            onset_errors.append(onset_error)
            offset_errors.append(offset_error)
            if abs(onset_error) > tolerance:
                problems.append("onset_outside_tolerance")
            if abs(offset_error) > tolerance:
                problems.append("offset_outside_tolerance")

        needs_review = guess.get("needsReview") is not False
        if needs_review:
            problems.append("needs_review")
        passed = (text_matches and onset_error is not None and offset_error is not None
                  and abs(onset_error) <= tolerance and abs(offset_error) <= tolerance
                  and not needs_review and "invalid_prediction_time" not in problems)
        no_edit += int(passed)
        reports.append({
            "order": order,
            "text": gold["text"],
            "predictionText": guess.get("displayText"),
            "textMatches": text_matches,
            "goldOnset": gold["acousticOnset"],
            "predictedOnset": start,
            "onsetErrorSec": round(onset_error, 4) if onset_error is not None else None,
            "goldOffset": gold["acousticOffset"],
            "predictedOffset": end,
            "offsetErrorSec": round(offset_error, 4) if offset_error is not None else None,
            "needsReview": needs_review,
            "passedNoManualAdjustment": passed,
            "problems": problems,
        })

    extra_orders = sorted(set(by_order) - {line["order"] for line in truth_lines})
    total = len(truth_lines)
    return {
        "kind": "audio-only-acoustic-truth-evaluation",
        "media": verified_media,
        "truth": {"kind": truth["kind"], "annotator": truth["annotator"],
                  "annotatedAt": truth["annotatedAt"], "blindToModelOutput": True},
        "metricDefinition": {
            "denominator": "all human truth lyric rows; missing/mismatched predictions fail",
            "noManualAdjustment": "exact ordered lyric + start and end within tolerance + needsReview=false",
            "toleranceSec": tolerance,
        },
        "summary": {
            "truthLines": total,
            "predictionLines": len(predicted),
            "missingPredictionLines": len(missing_orders),
            "extraPredictionLines": len(extra_orders),
            "lyricMismatches": len(text_mismatches),
            "noManualAdjustmentLines": no_edit,
            "noManualAdjustmentRate": round(no_edit / total, 6),
            "onsetError": _distribution(onset_errors, tolerance),
            "offsetError": _distribution(offset_errors, tolerance),
        },
        "missingOrders": missing_orders,
        "extraOrders": extra_orders,
        "lyricMismatchOrders": text_mismatches,
        "lines": reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path, help="MaGiKara .magikara output")
    parser.add_argument("truth", type=Path, help="blind human-acoustic-truth JSON")
    parser.add_argument("--media", help="override the original media path for SHA verification")
    parser.add_argument("--tolerance", type=float, default=0.5,
                        help="maximum onset AND offset error for one line to count; default 0.5 s")
    parser.add_argument("--out", type=Path, help="write a JSON report to this path")
    args = parser.parse_args()
    try:
        project = json.loads(args.project.read_text(encoding="utf-8"))
        truth = json.loads(args.truth.read_text(encoding="utf-8"))
        report = evaluate(project, truth, args.tolerance, args.media)
        encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.out:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.out.with_name(args.out.name + ".tmp")
            temporary.write_text(encoded, encoding="utf-8")
            temporary.replace(args.out)
        else:
            print(encoded, end="")
        return 0
    except (OSError, json.JSONDecodeError, EvaluationError) as error:
        parser.error(str(error))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
