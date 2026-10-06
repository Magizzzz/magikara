#!/usr/bin/env python3
"""把 lyric-ocr 的逐帧结果合并成「歌词行 + 时间区间」。

做法：
  1. 去掉空格后作为比较键，把连续帧分组（允许中间漏 1 帧）；
  2. 每组取出现次数最多的写法作为该行文本（解决 ヘ/へ 这类逐帧抖动）；
  3. 相邻组若文本高度相似（编辑距离小）则合并，消除识别抖动造成的碎裂；
  4. 输出带时间的 JSON 与纯文本歌词，并给出置信度与疑似有问题的行供人工核对。

用法: consolidate-lyrics.py <raw-frames.json> <输出目录>
"""
import json
import sys
import os
import unicodedata
from collections import Counter


def key_of(text: str) -> str:
    """比较键：去掉所有空白。"""
    return "".join(text.split())


def edit_distance(a: str, b: str, limit: int = 3) -> int:
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def main() -> int:
    raw_path, out_dir = sys.argv[1], sys.argv[2]
    with open(raw_path, encoding="utf-8") as f:
        data = json.load(f)
    samples = data["samples"]
    fps = data["fps"]
    frame_dt = 1.0 / fps
    os.makedirs(out_dir, exist_ok=True)

    # ---- 1. 连续帧分组 ----
    groups = []
    current = None
    last_index = None
    for i, s in enumerate(samples):
        text = s["text"].strip()
        if not text:
            current = None
            continue
        k = key_of(text)
        if current is not None and last_index is not None and i - last_index <= 2:
            if edit_distance(k, current["key"]) <= 2:
                current["items"].append(s)
                current["end"] = s["t"]
                last_index = i
                continue
        if current is not None:
            groups.append(current)
        current = {"key": k, "items": [s], "start": s["t"], "end": s["t"]}
        last_index = i
    if current is not None:
        groups.append(current)

    # ---- 2. 多数写法 ----
    lines = []
    for g in groups:
        counter = Counter(x["text"].strip() for x in g["items"])
        best_text, count = counter.most_common(1)[0]
        confs = [x["confidence"] for x in g["items"]]
        all_variants = [v for v, _ in counter.most_common()]
        lines.append({
            "text": best_text,
            "start": round(g["start"], 2),
            "end": round(g["end"] + frame_dt, 2),
            "frames": len(g["items"]),
            "majority": count,
            "agreement": round(count / len(g["items"]), 3),
            "ocrConfidence": round(sum(confs) / len(confs), 3),
            "variants": all_variants[:4],
        })

    # ---- 3. 丢掉过短的组（多半是切换瞬间的残影） ----
    lines = [l for l in lines if l["frames"] >= 2 and (l["end"] - l["start"]) >= 0.8]
    lines.sort(key=lambda x: x["start"])
    for i, l in enumerate(lines, 1):
        l["order"] = i

    # ---- 4. 输出 ----
    out = {
        "source": data["video"],
        "duration": data["duration"],
        "method": "Vision OCR (ja-JP + zh-Hans)，裁底部 28%，仅取含假名的日文行；连续帧同名合并 + 多数写法投票",
        "lineCount": len(lines),
        "lines": lines,
    }
    with open(os.path.join(out_dir, "lyrics-timed.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    with open(os.path.join(out_dir, "lyrics.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(l["text"] for l in lines) + "\n")

    # 供人工核对的报告
    suspicious = [l for l in lines if l["agreement"] < 0.7 or l["ocrConfidence"] < 0.45 or l["frames"] < 3]
    with open(os.path.join(out_dir, "review.md"), "w", encoding="utf-8") as f:
        f.write("# OCR 歌词识别结果（需人工核对）\n\n")
        f.write(f"- 来源: `{data['video']}`\n")
        f.write(f"- 时长: {data['duration']:.1f} 秒\n")
        f.write(f"- 识别出 {len(lines)} 行\n")
        f.write(f"- 疑似需要核对: {len(suspicious)} 行（一致性 < 0.7 或置信度 < 0.45 或帧数 < 3）\n\n")
        f.write("| # | 起始 | 结束 | 时长 | 帧数 | 一致度 | OCR置信度 | 次数 | 歌词 | 其他写法 |\n")
        f.write("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n")
        for l in lines:
            mark = "⚠️" if l in suspicious else ""
            others = " / ".join(l["variants"][1:3])
            f.write(f"| {l['order']} | {l['start']:.2f} | {l['end']:.2f} | {l['end']-l['start']:.2f} "
                    f"| {l['frames']} | {l['agreement']:.2f} | {l['ocrConfidence']:.2f} "
                    f"| {l['majority']} | {mark}{l['text']} | {others} |\n")

    print(f"识别出 {len(lines)} 行歌词")
    print(f"  时间跨度: {lines[0]['start']:.1f}s – {lines[-1]['end']:.1f}s" if lines else "  (空)")
    avg_agreement = sum(l["agreement"] for l in lines) / len(lines) if lines else 0
    print(f"  平均一致度: {avg_agreement:.3f}")
    print(f"  疑似需核对: {len(suspicious)} 行")
    print(f"输出: {out_dir}/lyrics.txt, lyrics-timed.json, review.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
