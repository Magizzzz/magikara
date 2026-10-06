#!/usr/bin/env python3
"""原型 v2：两层 DP。

v1 的问题：全局字符 DP 允许**一行歌词跨越 ASR 的大段空白**。
实测第 21 行的前几个字被匹配到 73.8 秒、后几个字匹配到 106 秒，
于是一行横跨了 31 秒的间奏，句首误差 -31.7 秒。

v2 的做法：
  1. 先把 ASR token 按时间空隙切成若干「演唱区」（gap > 2.5 秒即切开）；
  2. 外层 DP：把一个**连续区间**的歌词行分配给一个演唱区（允许一个区多行、也允许空区）；
     这样「一行横跨大段空白」在结构上就不可能发生；
  3. 内层：在每个 (行区间, 演唱区) 里做字符级顺序 DP，得到逐字时间。

重复副歌因此天然被消歧：第二次副歌只能落到第二个演唱区。
"""
import json
import sys
import unicodedata

REGION_GAP = 2.5
GAP_LYRIC = 1.3      # 歌词有、ASR 没有
GAP_ASR = 0.7        # ASR 有、歌词没有
EMPTY_REGION = 8.0   # 整个演唱区没有对应歌词（纯伴奏/间奏）
TIME_SKIP_W = 2.0    # 「跳过 ASR 内容」的代价按被跳过的演唱时长加权（关键项，见下）

# 为什么需要 TIME_SKIP_W：
# 只按字符计代价时，「跳过 1 个 2 秒的长音」和「跳过 1 个 0.1 秒的短音」一样便宜，
# 于是 DP 会把整个演唱区里最长的几段人声当噪声丢掉，再把歌词挤到别处。
# 实测这会让第 29–35 行整体偏晚 +4…+14 秒。
# 把 insert 代价改成 GAP_ASR + TIME_SKIP_W × 该字所属 token 的时长后，
# 「把 8 秒人声当噪声丢掉」变得很贵，切分随之回到正确位置。


def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    out = []
    for ch in s:
        if 0x30A1 <= ord(ch) <= 0x30F6:
            out.append(chr(ord(ch) - 0x60)); continue
        if ch in "ーヽヾ":
            out.append(ch); continue
        cat = unicodedata.category(ch)
        if cat[0] in "PSZC":
            continue
        out.append(ch)
    return "".join(out)


def is_kana(ch):
    o = ord(ch)
    return 0x3041 <= o <= 0x309F or 0x30A1 <= o <= 0x30FA or o == 0x30FC


def is_kanji(ch):
    o = ord(ch)
    return 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or o in (0x3005, 0x3007)


def sub_cost(a, b):
    if a == b:
        return 0.0
    if is_kana(a) and is_kana(b):
        return 0.8
    if is_kanji(a) and is_kanji(b):
        return 1.6
    return 1.2


def char_align(lyr, asr, want_path=False, asr_dur=None):
    """顺序字符 DP。asr_dur[j] 为第 j 个 ASR 字符所属 token 的时长（秒）。"""
    n, m = len(lyr), len(asr)
    INF = float("inf")
    dur = asr_dur if asr_dur is not None else [0.0] * m
    ins_cost = [GAP_ASR + TIME_SKIP_W * dur[j] for j in range(m)]
    prev = [INF] * (m + 1)
    prev[0] = 0.0
    rows = [prev]
    for i in range(1, n + 1):
        cur = [INF] * (m + 1)
        cur[0] = prev[0] + GAP_LYRIC
        for j in range(1, m + 1):
            cur[j] = min(prev[j - 1] + sub_cost(lyr[i - 1], asr[j - 1]),
                         prev[j] + GAP_LYRIC,
                         cur[j - 1] + ins_cost[j - 1])
        rows.append(cur)
        prev = cur
    cost = prev[m]
    if not want_path:
        return cost, None
    # 回溯
    match = [None] * n
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and rows[i][j] == rows[i - 1][j - 1] + sub_cost(lyr[i - 1], asr[j - 1]):
            match[i - 1] = j - 1; i -= 1; j -= 1
        elif i > 0 and rows[i][j] == rows[i - 1][j] + GAP_LYRIC:
            i -= 1
        elif j > 0 and rows[i][j] == rows[i][j - 1] + ins_cost[j - 1]:
            j -= 1
        else:
            break
    return cost, match


def main():
    asr_path, lyrics_path, timed_path, out_path = sys.argv[1:5]
    asr = json.load(open(asr_path, encoding="utf-8"))["results"]
    lyrics = [l.rstrip("\n") for l in open(lyrics_path, encoding="utf-8") if l.strip()]
    truth = json.load(open(timed_path, encoding="utf-8"))["lines"]

    # ASR 字符 + 归属 token；演唱区切分
    asr_chars, asr_owner, asr_char_dur, regions = [], [], [], []
    cur = []
    for k, t in enumerate(asr):
        if cur and t["start"] - asr[cur[-1]]["end"] > REGION_GAP:
            regions.append(cur); cur = []
        cur.append(k)
    if cur:
        regions.append(cur)
    for k, t in enumerate(asr):
        txt = normalize(t["text"])
        if not txt:
            continue
        per = (t["end"] - t["start"]) / len(txt)
        for ch in txt:
            asr_chars.append(ch); asr_owner.append(k); asr_char_dur.append(per)

    # 每个区在 asr_chars 里的字符区间
    reg_char_range = []
    for reg in regions:
        lo = sum(len(normalize(asr[k]["text"])) for k in range(reg[0]))
        hi = lo + sum(len(normalize(asr[k]["text"])) for k in reg)
        reg_char_range.append((lo, hi))

    lyr_chars, lyr_line = [], []
    for li, text in enumerate(lyrics):
        for ch in normalize(text):
            lyr_chars.append(ch); lyr_line.append(li)
    line_chars = [normalize(t) for t in lyrics]
    N = len(lyrics)
    R = len(regions)
    print(f"歌词 {N} 行 / {len(lyr_chars)} 字；ASR {R} 个演唱区 / {len(asr_chars)} 字")
    print(f"演唱区时长: " + ", ".join(f"{asr[reg[0]]['start']:.0f}-{asr[reg[-1]]['end']:.0f}s" for reg in regions))

    # 预计算 charCost[i][j][r]
    from functools import lru_cache
    @lru_cache(maxsize=None)
    def block_cost(i, j, r):
        lo, hi = reg_char_range[r]
        text = "".join(line_chars[i:j])
        c, match = char_align(text, asr_chars[lo:hi], want_path=True)
        reg = regions[r]
        region_dur = asr[reg[-1]]["end"] - asr[reg[0]]["start"]
        idxs = [lo + m for m in match if m is not None] if match else []
        if idxs:
            covered = asr[asr_owner[idxs[-1]]]["end"] - asr[asr_owner[idxs[0]]]["start"]
        else:
            covered = 0.0
        return c

    INF = float("inf")
    dp = [[INF] * (N + 1) for _ in range(R + 1)]
    back = [[None] * (N + 1) for _ in range(R + 1)]
    dp[0][0] = 0.0
    for r in range(R):
        for i in range(N + 1):
            if dp[r][i] == INF:
                continue
            # 该区不使用
            if dp[r][i] + EMPTY_REGION < dp[r + 1][i]:
                dp[r + 1][i] = dp[r][i] + EMPTY_REGION
                back[r + 1][i] = (i, r, i)   # 空区
            # 该区覆盖 lines[i:j]
            for j in range(i + 1, N + 1):
                c = dp[r][i] + block_cost(i, j, r)
                if c < dp[r + 1][j]:
                    dp[r + 1][j] = c
                    back[r + 1][j] = (i, r, j)
    # 末尾允许剩余行无区
    best, best_i = INF, N
    for i in range(N + 1):
        c = dp[R][i] + (N - i) * GAP_LYRIC * 6
        if c < best:
            best, best_i = c, i
    print(f"外层 DP 代价 {best:.1f}，覆盖到第 {best_i}/{N} 行")

    # 回溯得到每行所属区
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

    # 内层逐字对齐，得到每行起止
    rows = []
    for li, text in enumerate(lyrics):
        r = assign[li]
        if r is None:
            rows.append({"order": li + 1, "text": text, "start": None, "end": None,
                         "direct": False, "matched": 0, "chars": len(line_chars[li])})
            continue
        lo, hi = reg_char_range[r]
        # 同一区里可能有多行：以该区的 token 范围做整体对齐，再取本行匹配到的字符
        group = [k for k in range(N) if assign[k] == r]
        gi, gj = min(group), max(group) + 1
        text_all = "".join(line_chars[gi:gj])
        c, match = char_align(text_all, asr_chars[lo:hi], want_path=True, asr_dur=asr_char_dur[lo:hi])
        # 本行在 text_all 里的字符偏移
        offset = sum(len(line_chars[k]) for k in range(gi, li))
        my = match[offset:offset + len(line_chars[li])]
        idxs = [lo + m for m in my if m is not None]
        if idxs:
            a0, a1 = asr_owner[idxs[0]], asr_owner[idxs[-1]]
            rows.append({"order": li + 1, "text": text,
                         "start": asr[a0]["start"], "end": asr[a1]["end"],
                         "direct": True, "matched": len(idxs), "chars": len(line_chars[li])})
        else:
            rows.append({"order": li + 1, "text": text, "start": None, "end": None,
                         "direct": False, "matched": 0, "chars": len(line_chars[li])})

    # 无直接证据的行：在相邻有证据行之间按字符数插值
    known = [k for k, x in enumerate(rows) if x["start"] is not None]
    for li, x in enumerate(rows):
        if x["start"] is not None:
            continue
        prev = max([k for k in known if k < li], default=None)
        nxt = min([k for k in known if k > li], default=None)
        lo_t = rows[prev]["end"] if prev is not None else 0.0
        hi_t = rows[nxt]["start"] if nxt is not None else lo_t + 5.0
        span = max(0.1, hi_t - lo_t)
        mid = list(range((prev + 1) if prev is not None else 0,
                         nxt if nxt is not None else N))
        total = sum(rows[k]["chars"] for k in mid) or 1
        cursor = lo_t
        for k in mid:
            share = span * rows[k]["chars"] / total
            rows[k]["start"] = cursor + share * 0.15
            rows[k]["end"] = cursor + share * 0.85
            cursor += share

    errs = [x["start"] - t["start"] for x, t in zip(rows, truth)]
    ae = sorted(abs(e) for e in errs)
    n = len(ae)
    print()
    print(f"{'#':>3} {'对齐起':>8} {'真值起':>8} {'误差':>8} 证据")
    for x, t, e in list(zip(rows, truth, errs))[:12]:
        print(f"{x['order']:>3} {x['start']:>8.2f} {t['start']:>8.2f} {e:>+8.2f} {'直接' if x['direct'] else '插值'}")
    print("  …")
    for x, t, e in list(zip(rows, truth, errs))[20:]:
        print(f"{x['order']:>3} {x['start']:>8.2f} {t['start']:>8.2f} {e:>+8.2f} {'直接' if x['direct'] else '插值'}")
    print(f"\n句首误差: 平均 {sum(ae)/n:.3f}s  中位 {ae[n//2]:.3f}s  "
          f"P90 {ae[min(n-1,int(n*0.9))]:.3f}s  最大 {ae[-1]:.3f}s")
    for tol in (0.25, 0.5, 1.0):
        hit = sum(1 for v in ae if v <= tol)
        print(f"  ±{tol}s: {hit}/{n} ({hit/n*100:.0f}%)")
    print(f"有直接 ASR 证据: {len(known)}/{N}")
    json.dump({"rows": rows}, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
