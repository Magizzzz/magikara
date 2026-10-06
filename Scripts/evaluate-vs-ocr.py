#!/usr/bin/env python3
"""用 OCR 得到的「歌词在画面上的出现/消失时间」作为独立真值，评估真实对轨精度。

为什么这算真值：
  该素材的画面里已经烧录了人工做的歌词字幕，字幕出现/消失的时间就是
  制作者标定的演唱时间。这与我用音频自动推出来的时间是完全独立的两个来源。
  注意它并非完美真值：字幕通常略早于实际开口，且视频作者也可能有误差。

用法: evaluate-vs-ocr.py <工程.magikara> <lyrics-timed.json> <输出json>
"""
import json
import sys
import statistics
import difflib
import re
import unicodedata


def main() -> int:
    proj_path, ocr_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    proj = json.load(open(proj_path, encoding="utf-8"))
    ocr = json.load(open(ocr_path, encoding="utf-8"))

    lines = sorted(proj["lyricLines"], key=lambda x: x["order"])
    ocr_lines = sorted(ocr["lines"], key=lambda x: x.get("order", 0))

    def normalize(text: str) -> str:
        return re.sub(r"\s+", "", unicodedata.normalize("NFKC", text))

    # OCR 偶尔漏掉/多识别一句。按顺序匹配规范化后的歌词，避免从首个差异起
    # 用 zip 错配整首后续时间；重复副歌由 SequenceMatcher 的顺序约束消歧。
    matcher = difflib.SequenceMatcher(
        None,
        [normalize(line["displayText"]) for line in lines],
        [normalize(line["text"]) for line in ocr_lines],
        autojunk=False,
    )
    pairs = [
        (project_index + offset, ocr_index + offset)
        for project_index, ocr_index, size in matcher.get_matching_blocks()
        for offset in range(size)
    ]
    matched_project = {i for i, _ in pairs}
    matched_ocr = {j for _, j in pairs}

    rows = []
    for i, j in pairs:
        a, b = lines[i], ocr_lines[j]
        rows.append({
            "order": a["order"],
            "ocrOrder": b.get("order", j + 1),
            "text": a["displayText"],
            "ocrText": b["text"],
            "textMatch": True,
            "textExact": a["displayText"] == b["text"],
            "ocrStart": b["start"],
            "ocrEnd": b["end"],
            "ocrConfidence": b.get("ocrConfidence", b.get("meanConfidence", 0)),
            "ocrAgreement": b.get("agreement", 1.0),
            "singStart": a["singStart"],
            "singEnd": a["singEnd"],
            "displayStart": a["displayStart"],
            "displayEnd": a["displayEnd"],
            "confidence": a["confidence"],
            "needsReview": a["needsReview"],
            "reasons": a.get("reviewReasons", []),
            # 以 OCR 字幕出现时间为真值
            "singStartError": a["singStart"] - b["start"],
            "singEndError": a["singEnd"] - b["end"],
            "displayStartError": a["displayStart"] - b["start"],
        })

    def stats(vals):
        if not vals:
            return {}
        s = sorted(vals)
        n = len(s)
        return {
            "n": n,
            "mean": round(sum(vals) / n, 3),
            "median": round(statistics.median(vals), 3),
            "p90": round(s[min(n - 1, int(n * 0.9))], 3),
            "max": round(max(vals), 3),
            "min": round(min(vals), 3),
        }

    abs_start = [abs(r["singStartError"]) for r in rows]
    abs_end = [abs(r["singEndError"]) for r in rows]
    unmatched_project = [lines[i]["order"] for i in range(len(lines)) if i not in matched_project]
    unmatched_ocr = [ocr_lines[j].get("order", j + 1) for j in range(len(ocr_lines)) if j not in matched_ocr]

    report = {
        "note": "真值来自视频画面里烧录的字幕出现时间（OCR），与音频自动对轨相互独立；"
                "字幕通常略早于实际开口，因此存在系统性偏差的可能。歌词按顺序做 NFKC + 空白归一化匹配，未匹配行不计入时间误差。",
        "lineCount": len(rows),
        "projectLineCount": len(lines),
        "ocrLineCount": len(ocr_lines),
        "textMatchCount": len(rows),
        "textExactCount": sum(1 for r in rows if r["textExact"]),
        "unmatchedProjectOrders": unmatched_project,
        "unmatchedOCROrders": unmatched_ocr,
        "singStartError": stats(abs_start),
        "singEndError": stats(abs_end),
        "within": {
            "0.25s": sum(1 for v in abs_start if v <= 0.25),
            "0.50s": sum(1 for v in abs_start if v <= 0.50),
            "1.00s": sum(1 for v in abs_start if v <= 1.00),
            "total": len(abs_start),
        },
        "meanSignedError": round(sum(r["singStartError"] for r in rows) / len(rows), 3) if rows else None,
        "rows": rows,
    }
    json.dump(report, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    st = report["singStartError"]
    print(f"文本匹配: {len(rows)} 行（工程 {len(lines)} / OCR {len(ocr_lines)}；原文完全相同 {report['textExactCount']} 行）")
    if unmatched_project or unmatched_ocr:
        print(f"未匹配歌词: 工程序号 {unmatched_project}；OCR 序号 {unmatched_ocr}")
    if not st:
        print("没有可比较的歌词行")
        return 0
    print(f"句首误差(绝对值): 平均 {st['mean']:.3f}s  中位 {st['median']:.3f}s  P90 {st['p90']:.3f}s  最大 {st['max']:.3f}s")
    print(f"句首误差(带符号): 平均 {report['meanSignedError']:+.3f}s  （正=预测偏晚）")
    w = report["within"]
    print(f"落在容差内: ±0.25s {w['0.25s']}/{w['total']}   ±0.50s {w['0.50s']}/{w['total']}   ±1.00s {w['1.00s']}/{w['total']}")
    print(f"输出: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
