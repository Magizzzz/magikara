#!/usr/bin/env python3
"""原型 v3：参数化代价 + 网格搜索。

v2 的关键教训：
  方案 B（错误切分）把 region2 的 62 个字**全部**「匹配」上了，
  未匹配 0 字 —— 因为替换代价(1.2)比空位代价(1.3)还便宜，
  于是把「オナってる」硬匹配到「笑って今日も」这种垃圾上，DP 反而觉得划算。
  正确做法是让「明显不同的字」的替换代价高于「留空」，
  这样 DP 才会承认「这段 ASR 没有对应歌词」而不是硬凑。

这里把代价参数化，直接在真实指标（句首平均误差 / P90 / ±0.5s 命中率）上做网格搜索，
用数据选参数，而不是凭感觉调。
"""
import json
import sys
import unicodedata
from functools import lru_cache

REGION_GAP = 2.5
EMPTY_REGION = 8.0


def normalize(s: str) -> str:
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


def is_kana(ch):
    o = ord(ch)
    return 0x3041 <= o <= 0x309F or 0x30A1 <= o <= 0x30FA or o == 0x30FC


def is_kanji(ch):
    o = ord(ch)
    return 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or o in (0x3005, 0x3007)


class Params:
    def __init__(self, s_kana, s_kanji, s_mixed, gap_lyric, gap_asr_base, skip_w,
                 min_quality=0.5):
        # min_quality：一行里「逐字完全命中」的比例低于该值时，
        # 不承认它拿到了直接证据，改走插值。
        # 为什么必须这么做：DP 为了降低总代价，会把「いつかきっと叶うから」
        # 这种在 ASR 里根本没有的行硬匹配到远处的垃圾文本上，
        # 结果给出一个 -8.6 秒的「直接证据」时间。宁可承认没有证据。
        self.min_quality = min_quality
        self.s_kana = s_kana
        self.s_kanji = s_kanji
        self.s_mixed = s_mixed
        self.gap_lyric = gap_lyric
        self.gap_asr_base = gap_asr_base
        self.skip_w = skip_w

    def sub(self, a, b):
        if a == b:
            return 0.0
        ka, kb = is_kana(a), is_kana(b)
        ja, jb = is_kanji(a), is_kanji(b)
        if ka and kb:
            return self.s_kana
        if ja and jb:
            return self.s_kanji
        if (ka and jb) or (ja and kb):
            return self.s_mixed
        return max(self.s_kana, self.s_mixed)


def char_align(lyr, asr, P: Params, asr_dur, want_path=False):
    n, m = len(lyr), len(asr)
    INF = float("inf")
    ins = [P.gap_asr_base + P.skip_w * asr_dur[j] for j in range(m)]
    prev = [INF] * (m + 1)
    prev[0] = 0.0
    rows = [prev]
    for i in range(1, n + 1):
        cur = [INF] * (m + 1)
        cur[0] = prev[0] + P.gap_lyric
        li = lyr[i - 1]
        for j in range(1, m + 1):
            cur[j] = min(prev[j - 1] + P.sub(li, asr[j - 1]),
                         prev[j] + P.gap_lyric,
                         cur[j - 1] + ins[j - 1])
        rows.append(cur); prev = cur
    if not want_path:
        return prev[m], None
    match = [None] * n
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and rows[i][j] == rows[i - 1][j - 1] + P.sub(lyr[i - 1], asr[j - 1]):
            match[i - 1] = j - 1; i -= 1; j -= 1
        elif i > 0 and rows[i][j] == rows[i - 1][j] + P.gap_lyric:
            i -= 1
        elif j > 0 and rows[i][j] == rows[i][j - 1] + ins[j - 1]:
            j -= 1
        else:
            break
    return prev[m], match


class Data:
    def __init__(self, asr_path, lyrics_path, timed_path):
        asr = json.load(open(asr_path, encoding="utf-8"))["results"]
        self.asr = asr
        self.lyrics = [l.rstrip("\n") for l in open(lyrics_path, encoding="utf-8") if l.strip()]
        self.truth = json.load(open(timed_path, encoding="utf-8"))["lines"]
        self.line_chars = [normalize(t) for t in self.lyrics]

        self.regions = []
        cur = []
        for k, t in enumerate(asr):
            if cur and t["start"] - asr[cur[-1]]["end"] > REGION_GAP:
                self.regions.append(cur); cur = []
            cur.append(k)
        if cur:
            self.regions.append(cur)

        self.asr_chars, self.asr_owner, self.asr_dur = [], [], []
        for k, t in enumerate(asr):
            txt = normalize(t["text"])
            if not txt:
                continue
            per = (t["end"] - t["start"]) / len(txt)
            for ch in txt:
                self.asr_chars.append(ch); self.asr_owner.append(k); self.asr_dur.append(per)

        self.rr = []
        for reg in self.regions:
            lo = sum(len(normalize(asr[k]["text"])) for k in range(reg[0]))
            hi = lo + sum(len(normalize(asr[k]["text"])) for k in reg)
            self.rr.append((lo, hi))
        self.N = len(self.lyrics)
        self.R = len(self.regions)


def run(D: Data, P: Params):
    N, R = D.N, D.R

    @lru_cache(maxsize=None)
    def block_cost(i, j, r):
        lo, hi = D.rr[r]
        text = "".join(D.line_chars[i:j])
        c, _ = char_align(text, D.asr_chars[lo:hi], P, D.asr_dur[lo:hi])
        return c

    INF = float("inf")
    dp = [[INF] * (N + 1) for _ in range(R + 1)]
    back = [[None] * (N + 1) for _ in range(R + 1)]
    dp[0][0] = 0.0
    for r in range(R):
        for i in range(N + 1):
            if dp[r][i] == INF:
                continue
            if dp[r][i] + EMPTY_REGION < dp[r + 1][i]:
                dp[r + 1][i] = dp[r][i] + EMPTY_REGION
                back[r + 1][i] = (i, r, i)
            for j in range(i + 1, N + 1):
                c = dp[r][i] + block_cost(i, j, r)
                if c < dp[r + 1][j]:
                    dp[r + 1][j] = c
                    back[r + 1][j] = (i, r, j)
    best, best_i = INF, N
    for i in range(N + 1):
        c = dp[R][i] + (N - i) * P.gap_lyric * 6
        if c < best:
            best, best_i = c, i

    assign = [None] * N
    r, i = R, best_i
    while r > 0:
        st = back[r][i]
        if st is None:
            break
        pi, pr, pj = st
        if pj > pi:
            for k in range(pi, pj):
                assign[k] = pr
        i, r = pi, pr

    rows = []
    for li in range(N):
        r = assign[li]
        if r is None:
            rows.append({"order": li + 1, "start": None, "end": None,
                         "direct": False, "chars": len(D.line_chars[li])})
            continue
        lo, hi = D.rr[r]
        group = [k for k in range(N) if assign[k] == r]
        gi, gj = min(group), max(group) + 1
        text_all = "".join(D.line_chars[gi:gj])
        _, match = char_align(text_all, D.asr_chars[lo:hi], P, D.asr_dur[lo:hi], want_path=True)
        offset = sum(len(D.line_chars[k]) for k in range(gi, li))
        my = match[offset:offset + len(D.line_chars[li])]
        lc = D.line_chars[li]
        exact = sum(1 for pos, m in enumerate(my)
                    if m is not None and lc[pos] == D.asr_chars[lo + m])
        quality = exact / max(1, len(lc))
        idxs = [lo + m for m in my if m is not None]
        if idxs and quality >= P.min_quality:
            a0, a1 = D.asr_owner[idxs[0]], D.asr_owner[idxs[-1]]
            rows.append({"order": li + 1, "start": D.asr[a0]["start"], "end": D.asr[a1]["end"],
                         "direct": True, "chars": len(lc), "quality": round(quality, 2)})
        else:
            rows.append({"order": li + 1, "start": None, "end": None,
                         "direct": False, "chars": len(lc), "quality": round(quality, 2)})

    known = [k for k, x in enumerate(rows) if x["start"] is not None]
    for li, x in enumerate(rows):
        if x["start"] is not None:
            continue
        prev = max([k for k in known if k < li], default=None)
        nxt = min([k for k in known if k > li], default=None)
        lo_t = rows[prev]["end"] if prev is not None else 0.0
        hi_t = rows[nxt]["start"] if nxt is not None else lo_t + 5.0
        span = max(0.1, hi_t - lo_t)
        mid = list(range((prev + 1) if prev is not None else 0, nxt if nxt is not None else N))
        total = sum(rows[k]["chars"] for k in mid) or 1
        cursor = lo_t
        for k in mid:
            share = span * rows[k]["chars"] / total
            rows[k]["start"] = cursor + share * 0.15
            rows[k]["end"] = cursor + share * 0.85
            cursor += share

    errs = [abs(x["start"] - t["start"]) for x, t in zip(rows, D.truth)]
    errs_s = sorted(errs)
    n = len(errs)
    return {
        "mean": sum(errs) / n,
        "p90": errs_s[min(n - 1, int(n * 0.9))],
        "within05": sum(1 for e in errs if e <= 0.5) / n,
        "within10": sum(1 for e in errs if e <= 1.0) / n,
        "rows": rows,
        "assign": assign,
    }


def main():
    D = Data(sys.argv[1], sys.argv[2], sys.argv[3])
    print(f"歌词 {D.N} 行 / {len(D.asr_chars)} ASR 字；{D.R} 个演唱区")
    print()
    print(" q   s_kana gap_l  W  |  平均误差    P90   ±0.5s  ±1.0s")
    best = None
    for q in (0.0, 0.3, 0.5, 0.6, 0.8):
        for s_kana in (1.4, 2.0):
            for gap_lyric in (1.0, 1.2, 1.4):
                for W in (0.0, 1.0):
                    P = Params(s_kana, s_kana * 1.2, 1.2, gap_lyric, 0.4, W, min_quality=q)
                    r = run(D, P)
                    print(f" {q:.1f} {s_kana:6.1f} {gap_lyric:5.1f} {W:2.1f}  | {r['mean']:9.3f} {r['p90']:6.3f} {r['within05']*100:5.0f}% {r['within10']*100:5.0f}%")
                    score = r["mean"] + r["p90"]
                    if best is None or score < best[0]:
                        best = (score, q, s_kana, gap_lyric, W, r)
    print()
    _, q, s_kana, gap_lyric, W, r = best
    print(f"最佳: min_quality={q} s_kana={s_kana} gap_lyric={gap_lyric} W={W}")
    print(f"  平均 {r['mean']:.3f}s  P90 {r['p90']:.3f}s  ±0.5s {r['within05']*100:.0f}%  ±1.0s {r['within10']*100:.0f}%")
    print("  行→演唱区分配:", r["assign"])


if __name__ == "__main__":
    main()
