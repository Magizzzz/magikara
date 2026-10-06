#!/bin/bash
#
# MaGi Kara 构建 / 测试 / 打包脚本
#
# 这个环境没有 Xcode（只有 Command Line Tools），并且 DSH 文件沙箱不允许
# 写入 ~/Library 与 /var/folders 下的默认缓存，因此这里：
#   1. 把 clang module cache 与 SwiftPM 缓存全部重定向到工程目录内；
#   2. 用 --disable-sandbox 关掉 SwiftPM 自己的 sandbox-exec（嵌套沙箱会被拒）；
#   3. 手工组装 .app bundle（没有 xcodebuild 可用）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export CLANG_MODULE_CACHE_PATH="$ROOT/.modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.modulecache"

SWIFT_FLAGS=(
  --disable-sandbox
  --cache-path "$ROOT/.cache"
  --config-path "$ROOT/.swiftpm-config"
  --security-path "$ROOT/.swiftpm-security"
  --scratch-path "$ROOT/.build"
)

APP_NAME="MaGi Kara"
BUNDLE="$ROOT/dist/$APP_NAME.app"

usage() {
  cat <<'EOF'
用法: Scripts/build.sh <命令>

  build        编译全部 target (debug)
  release      编译全部 target (release)
  test         运行单元测试
  bundle       组装 dist/MaGi Kara.app (release)
  dmg          组装并打成给别人用的安装包 dist/MaGi-Kara-<版本>.dmg
  phase0       运行 Phase 0 真实音频对轨基线并输出指标
  run          组装并启动 App
  clean        清理构建产物
EOF
}

cmd="${1:-build}"

case "$cmd" in
  build)
    swift build "${SWIFT_FLAGS[@]}"
    ;;

  release)
    swift build -c release "${SWIFT_FLAGS[@]}"
    ;;

  test)
    # 本机只有 Command Line Tools，没有随 Xcode 提供的 XCTest。
    # CLT 里带了 swift-testing 的 Testing.framework，但：
    #   1. 不在默认搜索路径上，需要 -F 指过去；
    #   2. Foundation 的 cross-import overlay（_Testing_Foundation.framework）
    #      在 CLT 里缺 Modules 目录（符号链接悬空），必须关掉 cross-import overlay。
    TEST_FLAGS=()
    CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
    if [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
      TEST_FLAGS+=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS")
      TEST_FLAGS+=(-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
      TEST_FLAGS+=(-Xlinker -F -Xlinker "$CLT_FRAMEWORKS")
      TEST_FLAGS+=(-Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS")
    fi
    swift test "${SWIFT_FLAGS[@]}" "${TEST_FLAGS[@]}" "${@:2}"
    ;;

  bundle)
    swift build -c release "${SWIFT_FLAGS[@]}"
    BIN_DIR="$(swift build -c release "${SWIFT_FLAGS[@]}" --show-bin-path)"

    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

    cp "$BIN_DIR/MaGiKara" "$BUNDLE/Contents/MacOS/MaGiKara"

    # SwiftPM 资源 bundle 需要一起放进 Contents/Resources，Bundle.module 才能找到
    if [ -d "$BIN_DIR/MaGiKara_MaGiKaraKit.bundle" ]; then
      cp -R "$BIN_DIR/MaGiKara_MaGiKaraKit.bundle" "$BUNDLE/Contents/Resources/"
    fi

    # App 图标：从品牌 Logo 生成 icns
    if [ -f "$ROOT/Sources/MaGiKaraKit/Resources/logo.png" ]; then
      ICONSET="$ROOT/.build/AppIcon.iconset"
      rm -rf "$ICONSET"; mkdir -p "$ICONSET"
      SRC="$ROOT/Sources/MaGiKaraKit/Resources/logo.png"
      for size in 16 32 64 128 256 512; do
        sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
        dbl=$((size * 2))
        sips -z $dbl $dbl "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
      done
      iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || true
      cp "$SRC" "$BUNDLE/Contents/Resources/logo.png"
    fi

    # 顶部播放器 RD 的银河/角色背景是纯 UI 装饰资源，不参与 SwiftPM 编译。
    # 放入 .app 根资源后，MaGiKaraResources 会优先从 Bundle.main 读取。
    HEADER_IMAGE="$ROOT/magikara-header-cosmic-character-v1.png"
    if [ -f "$HEADER_IMAGE" ]; then
      cp "$HEADER_IMAGE" "$BUNDLE/Contents/Resources/magikara-header-cosmic-character-v1.png"
    fi

    # 发给别人用时对方电脑上没有 ffmpeg / uv：两者都是只依赖系统库的单文件，直接内置。
    #   ffmpeg：必须带 libass（ass 滤镜），否则烧不了字幕；
    #   uv：配置单用它下载 Python 并安装对轨依赖。
    # 可用 MAGIKARA_FFMPEG_BIN / MAGIKARA_UV_BIN 指定来源。
    bundle_tool() {
      local name="$1" src="$2"
      if [ -z "$src" ] || [ ! -x "$src" ]; then
        echo "警告：没找到 $name，安装包里不会内置它（对方电脑上相应功能不可用）" >&2
        return
      fi
      src="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$src")"
      if [ -n "$(otool -L "$src" | tail -n +2 | grep -vE '^\s*(/usr/lib/|/System/Library/)' || true)" ]; then
        echo "警告：$src 依赖非系统动态库，换台电脑跑不起来，跳过内置" >&2
        return
      fi
      mkdir -p "$BUNDLE/Contents/Resources/bin"
      cp "$src" "$BUNDLE/Contents/Resources/bin/$name"
      chmod +x "$BUNDLE/Contents/Resources/bin/$name"
      codesign --force --sign - "$BUNDLE/Contents/Resources/bin/$name" >/dev/null 2>&1 || true
    }
    FFMPEG_SRC="${MAGIKARA_FFMPEG_BIN:-}"
    if [ -z "$FFMPEG_SRC" ]; then
      for c in "$HOME/.local/bin/ffmpeg" /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
        # 先把输出存下来再匹配：直接 | grep -q 会让 ffmpeg 收到 SIGPIPE，在 pipefail 下偶发判定失败
        if [ -x "$c" ] && [[ "$("$c" -hide_banner -filters 2>/dev/null || true)" == *" ass "* ]]; then FFMPEG_SRC="$c"; break; fi
      done
    fi
    bundle_tool ffmpeg "$FFMPEG_SRC"
    bundle_tool uv "${MAGIKARA_UV_BIN:-$(command -v uv || echo "$HOME/.local/bin/uv")}"
    mkdir -p "$BUNDLE/Contents/Resources/Licenses"
    cp "$ROOT/THIRD_PARTY_NOTICES.md" "$BUNDLE/Contents/Resources/Licenses/" 2>/dev/null || true
    cp "$ROOT"/LICENSES/* "$BUNDLE/Contents/Resources/Licenses/" 2>/dev/null || true

    cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MaGi Kara</string>
  <key>CFBundleDisplayName</key><string>MaGi Kara</string>
  <key>CFBundleExecutable</key><string>MaGiKara</string>
  <key>CFBundleIdentifier</key><string>com.magi.magikara</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>MaGi Kara 工程</string>
      <key>CFBundleTypeExtensions</key><array><string>magikara</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

    # ad-hoc 签名，避免 Gatekeeper 直接拒绝本地运行
    codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

    # 注册到 LaunchServices。
    # 手工组装出来的 bundle 若不注册，SwiftUI 的 WindowGroup 会静默地不创建窗口。
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
      "$LSREGISTER" -f "$BUNDLE" >/dev/null 2>&1 || true
    fi

    echo "已生成: $BUNDLE"
    ;;

  dmg)
    # 给别人用的安装包：dist/MaGi-Kara-<版本>.dmg（App + 应用程序快捷方式 + 首次打开说明）
    "$0" bundle
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist")"
    DMG="$ROOT/dist/MaGi-Kara-$VERSION.dmg"
    STAGE="$ROOT/.build/dmg-stage"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$BUNDLE" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp "$ROOT/Scripts/dmg-readme.txt" "$STAGE/打不开？先看我.txt"
    hdiutil create -volname "MaGi Kara" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    for tool in ffmpeg uv; do
      [ -x "$BUNDLE/Contents/Resources/bin/$tool" ] || { echo "错误：安装包里缺少 $tool，别人电脑上会用不了" >&2; exit 1; }
    done
    echo "已生成: $DMG（$(du -h "$DMG" | cut -f1)）"
    ;;

  phase0)
    swift build -c release "${SWIFT_FLAGS[@]}" --product magikara-phase0
    BIN_DIR="$(swift build -c release "${SWIFT_FLAGS[@]}" --show-bin-path)"
    # 透传附加参数（--rebuild / --mock / --demo …）
    "$BIN_DIR/magikara-phase0" "$ROOT/TestAssets" "${@:2}"
    ;;

  run)
    "$0" bundle
    open "$BUNDLE"
    ;;

  clean)
    rm -rf "$ROOT/.build" "$ROOT/.cache" "$ROOT/.modulecache" "$ROOT/dist"
    echo "已清理"
    ;;

  *)
    usage
    exit 1
    ;;
esac
