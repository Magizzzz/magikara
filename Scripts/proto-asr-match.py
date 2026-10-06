#!/usr/bin/env python3
"""原型：把用户歌词按顺序全局匹配到 ASR token 时间戳上。

先用 Python 快速验证算法与代价参数，验证通过后再落到 Swift 生产代码。
这是**顺序约束的全局 DP**（Needleman-Wunsch 变体），因此重复副歌会各自匹配到
自己那一次出现的位置，不会互相抢，也不依赖任何均分。
"""
import json
import sys
import unicodedata


def normalize(s: str) -> str:
    """日文归一化：NFKC、去标点/空白、片假名→平假名、小假名保持。"""
    s = unicodedata.normalize("NFKC", s)
    out = []
    for ch in s:
        # 片假名 → 平假名
        if 0x30A1 <= ord(ch) <= 0x30F6:
            out.append(chr(ord(ch) - 0x60))
            continue
        if ch in "ーヽヾ":
            out.append(ch)
            continue
        cat = unicodedata.category(ch)
        if cat.startswith("P") or cat.startswith("Z") or cat.startswith("C"):
            continue  # 标点/空白/控制符丢掉
        if cat.startswith("S"):
            continue  # 记号和货币等丢掉
        out.append(ch)
    return "".join(out)


def is_kana(ch: str) -> bool:
    o = ord(ch)
    return 0x3041 <= o <= 0x309F or 0x30A1 <= o <= 0x30FA or o == 0x30FC


def is_kanji(ch: str) -> bool:
    o = ord(ch)
    return (0x4E00 <= o <= 0x9FFF) or (0x3400 <= o <= 0x4DBF) or o in (0x3005, 0x3007)


def sub_cost(a: str, b: str) -> float:
    if a == b:
        return 0.0
    # 假名之间的错认代价低（演唱 ASR 常把清浊音、长短音听错）
    if is_kana(a) and is_kana(b):
        return 0.8
    if is_kanji(a) and is_kanji(b):
        return 1.6
    return 1.2


def align(lyric_chars, asr_chars, gap_lyric=1.3, gap_asr=0.7):
    """返回 (匹配表, 总代价)。匹配表 match[i] = ASR 下标 或 None。"""
    n, m = len(lyric_chars), len(asr_chars)
    INF = float("inf")
    # dp[i][j]：lyric 前 i 个 与 asr 前 j 个 的最小代价
    dp = [[INF] * (m + 1) for _ in range(n + 1)]
    back = [[None] * (m + 1) for _ in range(n + 1)]
    dp[0][0] = 0.0
    for i in range(1, n + 1):
        dp[i][0] = dp[i - 1][0] + gap_lyric      # 歌词有、ASR 没有
        back[i][0] = ("del", i - 1, 0)
    for j in range(1, m + 1):
        dp[0][j] = dp[0][j - 1] + gap_asr        # ASR 有、歌词没有
        back[0][j] = ("ins", 0, j - 1)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            c = dp[i - 1][j - 1] + sub_cost(lyric_chars[i - 1], asr_chars[j - 1])
            d = dp[i - 1][j] + gap_lyric
            e = dp[i][j - 1] + gap_asr
            best = min(c, d, e)
            dp[i][j] = best
            if best == c:
                back[i][j] = ("diag", i - 1, j - 1)
            elif best == d:
                back[i][j] = ("del", i - 1, j)
            else:
                back[i][j] = ("ins", i, j - 1)
    # 回溯
    match = [None] * n
    i, j = n, m
    while i > 0 or j > 0:
        step = back[i][j]
        if step is None:
            break
        kind, pi, pj = step
        if kind == "diag":
            match[pi] = pj
        i, j = pi, pj
    return match, dp[n][m]


def main():
    asr_path, lyrics_path, timed_path, out_path = sys.argv[1:5]
    asr = json.load(open(asr_path, encoding="utf-8"))["results"]
    lyrics = [l.rstrip("\n") for l in open(lyrics_path, encoding="utf-8") if l.strip()]
    truth = json.load(open(timed_path, encoding="utf-8"))["lines"]

    # ASR 字符序列
    asr_chars, asr_owner = [], []
    for k, t in enumerate(asr):
        for ch in normalize(t["text"]):
            asr_chars.append(ch)
            asr_owner.append(k)

    # 歌词字符序列 + 归属行
    lyr_chars, lyr_line = [], []
    for li, text in enumerate(lyrics):
        for ch in normalize(text):
            lyr_chars.append(ch)
            lyr_line.append(li)

    print(f"歌词字符 {len(lyr_chars)}   ASR 字符 {len(asr_chars)}")
    match, cost = align(lyr_chars, asr_chars)
    matched = sum(1 for m in match if m is not None)
    print(f"匹配上 {matched}/{len(lyr_chars)} 字符，DP 代价 {cost:.1f}")

    # 每行的起止时间
    rows = []
    for li, text in enumerate(lyrics):
        idxs = [k for k in range(len(lyr_chars)) if lyr_line[k] == li and match[k] is not None]
        if idxs:
            a0 = asr_owner[match[idxs[0]]]
            a1 = asr_owner[match[idxs[-1]]]
            start, end = asr[a0]["start"], asr[a1]["end"]
            direct = True
        else:
            start = end = None
            direct = False
        rows.append({"order": li + 1, "text": text, "start": start, "end": end,
                     "direct": direct,
                     "chars": len([k for k in range(len(lyr_chars)) if lyr_line[k] == li]),
                     "matched": len(idxs)})

    # 没有直接证据的行：在前后有证据的行之间按字符数插值
    known = [i for i, r in enumerate(rows) if r["direct"]]
    for i, r in enumerate(rows):
        if r["direct"]:
            continue
        prev = max([k for k in known if k < i], default=None)
        nxt = min([k for k in known if k > i], default=None)
        lo = rows[prev]["end"] if prev is not None else 0.0
        hi = rows[nxt]["start"] if nxt is not None else (lo + 5.0)
        span = max(0.1, hi - lo)
        # 这一行及中间所有无证据行按字符数分摊
        mid = [k for k in range(prev + 1 if prev is not None else 0, nxt if nxt is not None else len(rows))]
        total = sum(rows[k]["chars"] for k in mid) or 1
        cursor = lo
        for k in mid:
            share = span * rows[k]["chars"] / total
            rows[k]["start"] = cursor + share * 0.15
            rows[k]["end"] = cursor + share * 0.85
            cursor += share

    # 用 OCR 真值评估
    errs = []
    for r, t in zip(rows, truth):
        errs.append(r["start"] - t["start"])
    abs_errs = sorted(abs(e) for e in errs)
    n = len(abs_errs)
    print()
    print(f"{'#':>3} {'ASR对齐起':>10} {'OCR真值起':>10} {'误差':>8}  直接证据")
    for r, t, e in list(zip(rows, truth, errs))[:20]:
        print(f"{r['order']:>3} {r['start']:>10.2f} {t['start']:>10.2f} {e:>+8.2f}  {'是' if r['direct'] else '插值'}")
    print("  …")
    print(f"\n句首误差: 平均 {sum(abs_errs)/n:.3f}s  中位 {abs_errs[n//2]:.3f}s  "
          f"P90 {abs_errs[min(n-1,int(n*0.9))]:.3f}s  最大 {abs_errs[-1]:.3f}s")
    for tol in (0.25, 0.5, 1.0):
        hit = sum(1 for v in abs_errs if v <= tol)
        print(f"  ±{tol}s: {hit}/{n} ({hit/n*100:.0f}%)")
    print(f"有直接 ASR 证据的行: {len(known)}/{len(rows)}")
    json.dump({"rows": rows}, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
