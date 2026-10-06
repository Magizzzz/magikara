#!/bin/bash
#
# build-acoustic-truth-annotator.sh
#
# 用 Command Line Tools 的 swiftc 直接编译离线声学真值盲标器。
# 该工具是**本机真人听音校准用的一次性 GUI 工具**，不打包成 .app、不写入工程产物。
#
# 产物目录: /tmp/magikara-acoustic-truth-annotator/
# 可执行文件: /tmp/magikara-acoustic-truth-annotator/AcousticTruthAnnotator
#
# 用法:
#   Scripts/build-acoustic-truth-annotator.sh                 仅编译
#   Scripts/build-acoustic-truth-annotator.sh --run [参数…]   编译后启动 GUI（参数会预填输入框）
#   Scripts/build-acoustic-truth-annotator.sh --selftest <媒体> <lyrics.txt> <out.json> <作者>
#                                                             编译并跑一次校验/落盘诊断（不启动界面）
#
# 任何一步失败都会以非 0 退出。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Scripts/AcousticTruthAnnotator.swift"
OUT_DIR="/tmp/magikara-acoustic-truth-annotator"
BIN="$OUT_DIR/AcousticTruthAnnotator"
MODULE_CACHE="$OUT_DIR/modulecache"

usage() {
  cat <<'EOF'
用法: Scripts/build-acoustic-truth-annotator.sh [--run | --selftest] [参数…]

  (无参数)                     编译到 /tmp/magikara-acoustic-truth-annotator/
  --run [参数…]                编译后启动 GUI（--media/--lyrics/--out/--annotator 会预填）
  --selftest <媒体> <歌词> <输出> <作者>
                               编译后运行一次校验/原子写盘诊断，不启动界面
EOF
}

die() {
  echo "错误: $*" >&2
  exit 1
}

[ -f "$SRC" ] || die "找不到源文件: $SRC"

if ! command -v xcrun >/dev/null 2>&1; then
  die "找不到 xcrun，请先安装 Command Line Tools"
fi

SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || die "无法获取 macOS SDK 路径（xcrun --show-sdk-path 失败）"
[ -d "$SDK" ] || die "SDK 路径不存在: $SDK"

# 保留目录中的用户数据和 Swift 模块缓存；只替换编译器明确指定的可执行文件。
mkdir -p "$OUT_DIR" "$MODULE_CACHE"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

echo "==> 编译 AcousticTruthAnnotator"
echo "    源文件 : $SRC"
echo "    SDK    : $SDK"
echo "    输出   : $BIN"

if ! xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework CryptoKit \
  -framework AppKit \
  -o "$BIN" \
  "$SRC"; then
  die "swiftc 编译失败（见上方诊断）"
fi

[ -x "$BIN" ] || die "编译未产出可执行文件: $BIN"

echo "==> 编译成功"
echo "    可执行文件: $BIN"
echo "    链接框架检查:"
for fw in SwiftUI AVFoundation CryptoKit; do
  if otool -L "$BIN" 2>/dev/null | grep -q "/$fw.framework/"; then
    echo "      ✓ $fw"
  else
    echo "      ! 未在 otool 输出中找到 $fw（可能由 dyld 共享缓存提供）"
  fi
done

case "${1:-}" in
  --run)
    shift
    exec "$BIN" "$@"
    ;;
  --selftest)
    shift
    exec "$BIN" --selftest "$@"
    ;;
  "")
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
