#!/usr/bin/env bash
# 启动 MaGi Kara 并截图。
#
# 为什么不用 `open`：实测 `open <app>` 在当前环境经常不创建窗口
# （LaunchServices 注册状态会失效），而**直接执行 bundle 内的二进制**总是能起窗口。
# 所以统一走直接执行，截图仍按窗口 ID，不受焦点抢占影响。
#
# 同时为了避免 macOS 的文稿/下载目录权限弹窗：工程与媒体请放在非受保护目录，
# 本脚本默认用 /Users/Shared/magikara-run。
#
# 用法: Scripts/app-shot.sh <输出png> [工程.magikara] [额外参数...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?用法: Scripts/app-shot.sh <输出png> [工程.magikara] [额外参数...]}"
PROJECT="${2:-/Users/Shared/magikara-run/demo.magikara}"
shift 2 2>/dev/null || shift 1
EXTRA_ARGS=("$@")

APP="${MAGIKARA_APP:-$ROOT/dist/MaGi Kara.app}"
BIN="$APP/Contents/MacOS/MaGiKara"
[ -x "$BIN" ] || { echo "找不到可执行文件: $BIN（先跑 Scripts/build.sh bundle）"; exit 1; }

pkill -f "MacOS/MaGiKara" 2>/dev/null || true
sleep 1

LOG="$(mktemp -t magikara-app)"
"$BIN" "$PROJECT" "${EXTRA_ARGS[@]}" >"$LOG" 2>&1 &
APP_PID=$!

WINDOW=""
for _ in $(seq 1 20); do
  sleep 1
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "App 进程已退出，日志："; cat "$LOG"; exit 1
  fi
  WINDOW="$(/tmp/listwin 2>/dev/null | grep -i "MaGi Kara" | head -1 | awk '{print $1}')"
  [ -n "$WINDOW" ] && break
done

if [ -z "$WINDOW" ]; then
  echo "未出现窗口，日志："; cat "$LOG"; kill "$APP_PID" 2>/dev/null || true; exit 1
fi

# 给 SwiftUI 一点时间完成首帧渲染（尤其是视频首帧）
sleep "${MAGIKARA_SETTLE:-5}"
mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l "$WINDOW" "$OUT"
echo "已截图: $OUT (window $WINDOW)"

if [ "${MAGIKARA_KEEP_RUNNING:-0}" != "1" ]; then
  pkill -f "MacOS/MaGiKara" 2>/dev/null || true
fi
