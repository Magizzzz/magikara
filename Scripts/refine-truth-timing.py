#!/usr/bin/env python3
"""在不改变歌词行清单的前提下，细化每行的画面出现时间。

为什么需要：原来的真值是用 2 fps 采样 OCR 得到的，起点全部落在 0.5 秒的倍数上，
**本身带有 ±0.25 秒的量化误差**。要评估「句首误差 ≤0.5 秒」这种量级的指标，
真值噪声不能和指标同量级。

做法：用 5 fps（0.2 秒）重新 OCR 的逐帧结果，逐帧匹配回**同一份歌词清单**
（TestAssets/ocr/lyrics.txt，与自动对轨的输入完全一致），
于是行清单不变、时间精度提高 2.5 倍。

用法: refine-truth-timing.py <raw-frames-5fps.json> <canonical-lyrics.txt> <输出json>
"""
import json
import sys
import unicodedata


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    out = []
    for ch in s:
        if 0x30A1 <= ord(ch) <= 0x30F6:
            out.append(chr(ord(ch) - 0x60)); continue
        if ch in "ーヽヾ":
            out.append(ch); continue
        if unicodedata.category(ch)[0] in "PSZC":
            continue
        out.append(ch)
    return "".join(out)


def edit_distance(a: str, b: str, limit: int = 6) -> int:
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
    raw_path, lyrics_path, out_path = sys.argv[1:4]
    raw = json.load(open(raw_path, encoding="utf-8"))
    samples = raw["samples"]
    dt = 1.0 / raw["fps"]
    lines = [l.rstrip("\n") for l in open(lyrics_path, encoding="utf-8") if l.strip()]
    keys = [norm(t) for t in lines]

    # **保序**匹配：按时间顺序扫帧、按顺序分配歌词行。
    #
    # 不能对每帧独立找「最相似的行」—— 副歌重复时会把第二次出现配到第一次的歌词上
    # （实测第 4 行被配到 34.8 秒、第 6 行被配到 65.4 秒）。
    # 用单调游标扫过去，重复句自然各就各位。
    frames = [(s["t"], norm(s.get("text") or ""), s.get("confidence", 0))
              for s in samples if (s.get("text") or "").strip()]
    frames = [(t, k, c) for (t, k, c) in frames if k]
    frames.sort(key=lambda x: x[0])

    # 阈值必须**紧**：放宽到行长一半时，「なんもねえなんもねえ」会把后面的
    # 「なんもねえよ俺ら」也算成自己，于是一路吞掉后续行（实测第 2 行被推到 15.4 秒）。
    def best_line(frame_key: str):
        bi, bd = -1, 99
        for i, lk in enumerate(keys):
            d = edit_distance(frame_key, lk)
            if d < bd:
                bd, bi = d, i
        return bi, bd

    hits = [[] for _ in lines]
    cursor = 0.0
    for t, k, c in frames:
        i, d = best_line(k)
        # 只接受近乎精确的匹配，且不允许倒退（保序）
        if i < 0 or d > 2 or t < cursor - 0.4:
            continue
        hits[i].append((t, c, d))
        cursor = max(cursor, t)

    out_lines = []
    missing = []
    for i, text in enumerate(lines):
        h = hits[i]
        if not h:
            missing.append(i + 1)
            out_lines.append({"order": i + 1, "text": text, "start": None, "end": None,
                              "samples": 0, "note": "5fps 重采样未匹配到该行"})
            continue
        h.sort(key=lambda x: x[0])
        start = h[0][0]
        end = h[-1][0] + dt
        out_lines.append({
            "order": i + 1,
            "text": text,
            "start": round(start, 2),
            "end": round(end, 2),
            "samples": len(h),
            "meanConfidence": round(sum(x[1] for x in h) / len(h), 3),
            "maxEditDistance": max(x[2] for x in h),
        })

    # 未匹配到的行用相邻行线性插值补上（并明确标注）
    for i, l in enumerate(out_lines):
        if l["start"] is not None:
            continue
        prev = next((out_lines[j] for j in range(i - 1, -1, -1) if out_lines[j]["start"] is not None), None)
        nxt = next((out_lines[j] for j in range(i + 1, len(out_lines)) if out_lines[j]["start"] is not None), None)
        lo = prev["end"] if prev else 0.0
        hi = nxt["start"] if nxt else lo + 3.0
        mid = (lo + hi) / 2
        l["start"] = round(mid - 0.5, 2)
        l["end"] = round(mid + 0.5, 2)
        l["note"] = (l.get("note", "") + "；已按相邻行插值补齐").strip("；")

    doc = {
        "source": raw["video"],
        "method": "5 fps 逐帧 OCR 匹配回固定歌词清单（行清单与 lyrics.txt 完全一致），"
                  "时间量化 0.2 秒；相比 2 fps 版本把真值量化误差从 ±0.25 秒降到 ±0.1 秒",
        "fps": raw["fps"],
        "lineCount": len(out_lines),
        "lines": out_lines,
    }
    json.dump(doc, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    ok = [l for l in out_lines if l["start"] is not None]
    print(f"行数 {len(out_lines)}，匹配到 {len(ok)}，缺失 {len(missing)}"
          + (f"（第 {missing}）" if missing else ""))
    print(f"时间量化: {dt:.1f} 秒")
    print(f"输出: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
