#!/bin/bash
#
# 把当前提交同步到公开 GitHub 仓库（可选同时发布 DMG）。
#
#   Scripts/publish-github.sh            只同步源码
#   Scripts/publish-github.sh --release  同步源码并把 dist/MaGi-Kara-<版本>.dmg 发布为 Release
#
# 本地 git 历史里曾提交过 auk-work 的大模型（单个 1.6 GB），GitHub 推不上去；
# 所以公开仓库用独立历史：每次把本地 HEAD 的文件树（去掉不公开的测试素材）
# 复制到 .publish/ 下的公开仓库，再提交推送。本地历史不受影响。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${MAGIKARA_GITHUB_REPO:-Magizzzz/magikara}"
PUBLISH="$ROOT/.publish"

# 不公开：真实歌曲歌词 / OCR 帧 / 真实工程与探针（有版权或个人素材）。
# 依赖它们的测试在文件缺失时会自动跳过。
EXCLUDES=(
  "TestAssets/ocr"
  "TestAssets/asr"
  "TestAssets/real-*"
  "TestAssets/probe-*"
)

cd "$ROOT"
if [ -n "$(git status --porcelain)" ]; then
  echo "工作区有未提交的改动，请先提交再同步。" >&2
  exit 1
fi
HEAD_SHA="$(git rev-parse --short HEAD)"
HEAD_MSG="$(git log -1 --pretty=%s)"

if [ ! -d "$PUBLISH/.git" ]; then
  rm -rf "$PUBLISH"
  if gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo clone "$REPO" "$PUBLISH"
  else
    gh repo create "$REPO" --public \
      --description "macOS 日语卡拉 OK 字幕工具：AI 逐字对轨、假名、扫色、一键导出 MP4"
    mkdir -p "$PUBLISH"
    git -C "$PUBLISH" init -q -b main
    git -C "$PUBLISH" remote add origin "https://github.com/$REPO.git"
  fi
fi

# 用 HEAD 的文件树整体替换公开仓库内容（删掉的文件也会同步删掉）
find "$PUBLISH" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git archive HEAD | tar -x -C "$PUBLISH"
for pattern in "${EXCLUDES[@]}"; do
  # shellcheck disable=SC2086
  rm -rf "$PUBLISH"/$pattern
done

cd "$PUBLISH"
git add -A
if git diff --cached --quiet; then
  echo "公开仓库已是最新（$HEAD_SHA）。"
else
  git commit -q -m "$HEAD_MSG" -m "同步自本地提交 $HEAD_SHA"
  git push -u origin main
  echo "已同步到 https://github.com/$REPO"
fi

if [ "${1:-}" = "--release" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/dist/MaGi Kara.app/Contents/Info.plist")"
  DMG="$ROOT/dist/MaGi-Kara-$VERSION.dmg"
  [ -f "$DMG" ] || { echo "找不到 $DMG，先运行 Scripts/build.sh dmg" >&2; exit 1; }
  NOTES="$ROOT/Scripts/release-notes.md"
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" --repo "$REPO" --clobber
    gh release edit "v$VERSION" --repo "$REPO" --notes-file "$NOTES"
  else
    gh release create "v$VERSION" "$DMG" --repo "$REPO" \
      --title "MaGi Kara $VERSION" --notes-file "$NOTES"
  fi
  echo "已发布 https://github.com/$REPO/releases/tag/v$VERSION"
fi
