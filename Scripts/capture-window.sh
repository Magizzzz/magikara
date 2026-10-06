#!/bin/bash
#
# 按窗口 ID 截图，不依赖窗口是否在最前面。
#
# 为什么需要这个：在这个环境里做 UI smoke check 时，用户的浏览器会不断抢回焦点，
# 直接 screencapture 全屏经常拍到别的应用。用 CGWindowList 找到目标窗口的
# window number 再 `screencapture -l` 就能稳定拿到目标窗口。
#
# 用法: Scripts/capture-window.sh [窗口所属进程名] [输出png] [宽 高]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${1:-MaGi Kara}"
OUT="${2:-$ROOT/TestAssets/ui-capture.png}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.modulecache"

HELPER="$ROOT/.build/winid"
if [ ! -x "$HELPER" ] || [ "$ROOT/Scripts/winid.swift" -nt "$HELPER" ]; then
  mkdir -p "$ROOT/.build"
  swiftc -O -module-cache-path "$ROOT/.modulecache" \
    "$ROOT/Scripts/winid.swift" -o "$HELPER" >/dev/null
fi

WINDOW_ID="$("$HELPER" "$OWNER")"
if [ -z "$WINDOW_ID" ]; then
  echo "找不到进程「$OWNER」的可见窗口" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l "$WINDOW_ID" "$OUT"
echo "已截图: $OUT (window $WINDOW_ID)"
