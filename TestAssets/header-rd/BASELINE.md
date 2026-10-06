# 顶部 UI RD · T1 基线报告

- 任务：顶部播放器 / 角色横条 RD 的 T1 基线（只做构建、测试、打包、截图、写报告）
- 日期：2026-09-22（本地 +0800）
- 工程根：`/Users/magi/Documents/ChatGPT/magikara`
- 约束遵守：未改 `Sources/`、未改 `Scripts/*.sh`、未删现有文件、未 `git commit`、未装依赖
- 说明：本报告区分「已验证」（有命令输出/截图证据）与「未验证」（推断或无法执行）

## 1. 执行摘要

- `build` / `test` / `bundle` 三条命令全部成功（exit 0）；测试 182 项 / 22 套全部通过。
- 截图：`app-shot.sh` 本身在当前 shell 下不可用（两处脚本缺陷，见 §3）；改用「手动启动 bundle + `capture-window.sh`」成功截到最新 bundle 的窗口。
- 事实检查结论（详见 §5）：背景**没有**地图/海岸线/指南针/地点标记；**没有**出现概念图烘焙的假控件/假文字；角色**不在**画面中、不可辨——这是本轮基线最重要的问题。

## 2. 命令与结果

| # | 命令 | 开始 (UTC) | 结束 (UTC) | 结果 |
|---|------|-----------|-----------|------|
| 1 | `./Scripts/build.sh build` | 2026-09-22T14:35:16Z | 14:35:20Z | **exit 0**，`Build complete! (2.88s)` |
| 2 | `./Scripts/build.sh test` | 2026-09-22T14:35:23Z | 14:35:31Z | **exit 0**，`Test run with 182 tests in 22 suites passed after 5.103 seconds.`（wall 8.16s） |
| 3 | `./Scripts/build.sh bundle` | 2026-09-22T14:35:33Z | 14:35:40Z | **exit 0**，`已生成: .../dist/MaGi Kara.app`（wall 7.19s） |
| 4a | `./Scripts/app-shot.sh <out.png> <demo.magikara>` | 14:35:43Z | 14:35:45Z | **exit 1**，`EXTRA_ARGS[@]: unbound variable`（`set -u` + bash 3.2 空数组） |
| 4b | `MAGIKARA_SETTLE=8 ./Scripts/app-shot.sh <out.png> <demo.magikara> --at 0` | 14:35:55Z | 14:35:57Z | **exit 1**，`bash -x` 追踪：首轮轮询时 `WINDOW="$(/tmp/listwin \| grep -i 'MaGi Kara' \| ...)"` 因 grep 无匹配返回 1，`set -o pipefail` + `set -e` 直接退出，窗口尚未出现 |
| 4c | 手动启动 `dist/MaGi Kara.app/Contents/MacOS/MaGiKara <demo.magikara> --at 0` + `./Scripts/capture-window.sh "MaGi Kara" <out.png>` | 14:36:20Z | 14:36:30Z | **exit 0**，`已截图 ... (window 30408)` |

补充（截图方式）：
- 4a/4b 的失败是脚本自身缺陷，**未修改脚本**；4b 通过给 App 传一个它本就忽略的额外参数绕过空数组问题（App 只解析 `*.magikara` 与 `--at/--section`）。
- 4c 中 `capture-window.sh` 内建 `winid` 探针把窗口尺寸报告为 **1301×849**（逻辑点）。现有脚本**没有**调整窗口宽度的能力，本次窗口宽度为上次 autosave 的默认值，无法自动改宽（如需窄屏验证须另行处理）。
- 启动命令与 `app-shot.sh` 一致（直接执行 bundle 内二进制），并注册了 `--at 0` 保证播放头确定。

## 3. 截图产物

| 文件 | 尺寸 | sha256 |
|------|------|--------|
| `TestAssets/header-rd/topbar-baseline-fullwindow.png` | 2602×1698 px（2× Retina，窗口 1301×849 点） | `90d39c7e74b56f37516bb4235cf5f92b25443bfae12f4fef018430b014c71644` |
| `TestAssets/header-rd/topbar-baseline-crop.png` | 2602×300 px（顶栏区域裁切） | `f37e5871e4e9a57b4bb9f1b76c7821efd0b8f47d57d510774159c04672a5146a` |

## 4. 源码 / bundle 修改时间与资源哈希

### 4.1 源码与 app bundle 修改时间（本地 +0800，任务前后一致）

| 文件 | mtime |
|------|-------|
| `Sources/MaGiKara/UI/TopBar.swift` | 2026-09-22 21:11:29 +0800 |
| `Sources/MaGiKara/UI/TopDock.swift` | 2026-09-22 18:10:10 +0800 |
| `Sources/MaGiKara/UI/RootView.swift` | 2026-09-22 19:15:53 +0800 |
| `Sources/MaGiKara/UI/Theme.swift` | 2026-09-22 19:49:49 +0800 |
| `Sources/MaGiKaraKit/Models/Resources.swift` | 2026-09-22 19:49:49 +0800 |
| `dist/MaGi Kara.app` | 2026-09-22 22:02:55 +0800 → **22:35:40 +0800**（本次 bundle 重建） |

源码 sha256（可核对任务后未变）：
- `TopBar.swift` `e1522bebbdbab8405b30b046848b4dbd952f9156b5094767802dca3cef90985b`
- `TopDock.swift` `422a8d7daad4a1fd812c06fb75f85a0c14d9f2999b2dd4a8a749cedfa9fe58e9`
- `RootView.swift` `833aec3dd569b7549d6df7fef13e0680e710e30601c0b6404407c11796704b65`

### 4.2 header 资源 sha256

| 资源 | 字节 | sha256 |
|------|------|--------|
| `magikara-header-cosmic-character-v1.png`（工程根） | 2167144 | `6cdf19df78675e7778831480fbb979a71676ee2b60dc0e89b3830c18ae2aa775` |
| `rd-assets/cosmic-character-header.png`（概念稿） | 2167144 | `6cdf19df78675e7778831480fbb979a71676ee2b60dc0e89b3830c18ae2aa775`（与根资源**完全相同**） |
| `dist/MaGi Kara.app/Contents/Resources/magikara-header-cosmic-character-v1.png` | 2167144 | `6cdf19df78675e7778831480fbb979a71676ee2b60dc0e89b3830c18ae2aa775`（已正确打包） |
| `rd-assets/current-header.png` | — | `34abed09737a90c54f2f4440fa9ac5c89c288fae6eb6028b6f3dbc98d1266945` |
| `rd-assets/huai-shuilei-character.png` | — | `aa4240a78546b6f034a14585f7abfd38cd69ec51a16125a18748e7e23a26967e` |
| `rd-assets/bilibili-reference.png` | — | `b9524231b26408255697c212d33e4ff9c2f25699c3df5125192efbc0bf18bbc4` |

脚本 sha256（未被修改）：`build.sh` `8772cf4f…d5a5d2`，`app-shot.sh` `bc6135e0…65d85`，`capture-window.sh` `ae96d592…1f9`。

## 5. 事实性检查

依据：`TestAssets/header-rd/topbar-baseline-fullwindow.png`（含对顶栏做对比度拉伸/高通后的分析图）+ 静态代码。

### 5.1 背景是否出现地图 / 海岸线 / 指南针 / 地点标记 —— **未出现（已验证）**
- 截图中顶栏背景只是极淡的薰衣草/浅蓝渐变，没有任何地图类元素。
- 概念稿本身（`magikara-header-cosmic-character-v1.png`）内容为银河、星点、星座连线与角色，也不含地图/海岸线/指南针/地点标记。

### 5.2 是否出现概念图内烘焙的假控件 / 假文字 —— **未出现（已验证）**
- 概念稿里确实烘焙有一整条假控件（假头像、假 `MaGi Kara`、假 `DM_20260922061122_001`、假 transport、假进度条、假音量、假 `导出`、假 `…`）。
- 但当前 `TopBar.swift` 的 `backdrop` 用 `.aspectRatio(contentMode: .fill)` + `frame(..., alignment: .top)`，在 116pt 高、约 1301pt 宽的横条里**只显示概念图顶部约 194/724（≈27%）的横切**；而伪造控件条位于概念图中下部（约 y≈490–660），**根本不在可见切片内**。
- 截图（含 x8 高通）中未发现任何重影控件或假文字，只有真实 SwiftUI 控件。

### 5.3 角色是否在右侧且可辨 —— **角色不可见 / 不可辨（已验证，未达 RD 要求）**
- 概念图顶部切片（可见区域）里，角色头部确实位于**右侧约 40%**，含双蝴蝶结、紫蓝发、白色服装与一只眼睛。
- 但渲染后的顶栏里**看不到任何角色轮廓**：对比度拉伸与高通后仍只有纯渐变，无法辨认发型、蝴蝶结、五官或白裙。
- 静态原因：`TopBar.swift:16-18` 在背景图之上又叠了 `Rectangle().fill(.white.opacity(0.67)).background(.ultraThinMaterial)`，再叠加图片自身 `.opacity(0.60)`（`TopBar.swift:47-54`）。粗略有效可见度约 `0.60 × (1−0.67)` ≈ 20%，且被材质进一步提亮/模糊，远低于 RD §3.2「背景 45%–70%」与 §3.3「人物 55%–75%」的要求。
- 结论：当前基线**不满足** RD 第 8 节「能明显感受到星空/银河/宇宙氛围」「淮水蕾以半身/上半身视觉层出现且可辨认」。

### 5.4 其它已验证事实
- 真实信息架构与控件齐全：头像徽标、`MaGi Kara`、副标题 `歌い続ける限り、きっとまた出会える！`、transport、`00:00.0 / 02:51.0`、进度条、音量、`导出`、`…` 均正常显示且清晰。
- 第二行项目名显示为 **`media`**（来自所载工程引用的 `media.mp4` 文件名），并非 RD 示例里的 `DM_20260922061122_001`；这是数据决定的，不是缺陷。
- header 资源已正确打入 `dist/MaGi Kara.app`，`Resources.swift` 查名 `magikara-header-cosmic-character-v1` 与文件一致。

## 6. 未验证 / 仅为推断

- **未验证**：无法 100% 断定背景图是「已加载但被洗白」还是「加载失败而回退到 `Theme.windowBackground`」。截图无法区分二者；依据「bundle 内资源存在 + `Bundle.main` 路径可解析」**推断**为前者（已加载但几乎不可见）。标记为推断。
- **未验证**：窄屏/响应式降级。本次窗口固定 1301×849，现有脚本无法自动调整窗口宽度。
- **未验证**：动效（银河雾漂移、星点闪烁）——静态截图无法判断；代码中亦未见相关动画实现。
- **未验证**：`TopDock.swift` 与 `RootView.swift` 的视觉表现未单独截图逐项核对，仅确认参与编译且 Dock 正常显示。

## 7. 本次改动文件

- 新增：`TestAssets/header-rd/BASELINE.md`（本报告）
- 新增：`TestAssets/header-rd/topbar-baseline-fullwindow.png`、`TestAssets/header-rd/topbar-baseline-crop.png`（截图）
- 重建产物：`dist/MaGi Kara.app`（`bundle` 命令输出）
- 未修改：`Sources/**`、`Scripts/**`、`Package.swift`；未删除现有文件；未 `git commit`
