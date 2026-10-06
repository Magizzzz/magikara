# HANDOFF

> 日期：2026-10-04（北京时间）。项目：`/Users/magi/Documents/ChatGPT/magikara`。依据：当前源码、项目文档和明确标日期的历史记录；本次仅交接文档整理。

**详细产品、研发和 Claude 接手说明：[MAGIKARA_CLAUDE_HANDOFF_RD.md](MAGIKARA_CLAUDE_HANDOFF_RD.md)**。

## 2026-10-05 最新状态（以本节为准；下面旧章节部分已过时）

**代码状态**：Git `main` 已有完整历史（约 25 个提交，最新 `879a54f`），工作区干净；`swift build` 通过，`swift test` 394 个测试 / 52 个套件通过；`dist/MaGi Kara.app` 为 2026-10-05 04:06 的打包。旧的 `/Users/Shared/magikara-run/` 副本已移到废纸篓，系统里只登记 `dist/` 这一份。

**这一轮完成的事**
- **导出**：修复 ffmpeg 管道读取死锁；真实进度与取消；先写临时文件再替换（失败不破坏已有文件）；纯音频用黑底画布成片；自动选择带 libass 的 ffmpeg（`~/.local/bin` 的 6.0 有 `ass` 滤镜，Homebrew 9.0.2 没有，旧逻辑会优先选中并报错）；无分离素材时音轨静音与预览一致；修复每句开头 0.5 秒显示 `\alpha&H00&` 乱码。
- **工程**：文件菜单加打开 / 保存 / 另存为；无路径但有内容时，新建 / 打开 / 退出前确认；退出前同步落盘。
- **时间线**：修复色块手势坐标（`.gesture` 必须挂在 `.offset` **之前**，否则 localX 是整条时间线上的绝对坐标，边缘修剪与走轨条永远点不中）；走轨条（拖两端调范围、拖中间在块内平移）；手动改过的显示起止不再被自动排程覆盖（`displayStartIsManual` / `displayEndIsManual`）；拖动色块 / scrub 时不自动跟随播放头；拖入视频 / 音频到时间线导入。
- **倒计时**：时间线上的「倒计时」轨道（`CountdownItem`），自动生成开头倒计时并跟随第一句；逐点走轨填色 / 逐点熄灭；点数、大小、间距、偏移、未走轨色与走轨色可编辑；ASS 用文字「●」（导出不能含绘图命令，这是验收规则）。
- **对轨**：默认 Yohane 优先、失败回退 ASR（`FallbackLyricAligner`）；修复全角标点（`？ ！ …`）让 Yohane 整次失败（`isLatinOrDigit` 把全角 ASCII 区全算成字母）；修复一键对轨崩溃（`ScreenLyricAligner.similarity` 遇到空字符串执行 `1...0`）；在线歌词搜索对 5xx / 超时自动重试、歌手名搜不到时去掉歌手名再搜。
- **样式与模版**：假名与主词用同一个整句进度扫色（预览读缓存里过期的时间是旧 bug 的来源）；App 强制浅色外观（深色模式下系统控件是白字）；上下行各自对齐 + 左右边距（`upperAlignment` / `lowerAlignment` / `horizontalMargin`，统一用 `SubtitleStyle.lineCenterX`，预览 / ASS / 倒计时共用；原来的「对齐」控件只是摆设）；歌词模版 3 → 11 套，每套带自己的换行节奏；新项目默认错开排版（旧默认单独保留为 `SubtitleStyle.legacyDefault`，只给解码旧工程补字段）；行距按「假名放得下」算；`DisplayPolicy.mode = .pageFlip`（翻页：上下行成对换页、下行延后 0.8 秒、页间空白 0.4 秒、提前量 1.5 秒）。

- **走轨时间（10-05 晚）**：Yohane 结果统一提前 0.19 秒（`LocalYohaneForcedAligner.onsetDelayCompensation`；《花》对比 LRCLIB 偏差中位数 0.19 → 0.00 秒，用户也反馈普遍晚 0.2–0.3 秒）；样式页「换行节奏」下新增「整体走轨 提前 / 延后」（每次 0.05 秒，可撤销，`KaraProject.shiftAllLines`）；整行只有符号的歌词不再让 Yohane 失败、ASR 崩溃。

- **吸附与菜单（10-05 晚）**：时间线工具栏「吸附」开关（快捷键 N，记在 UserDefaults `timelineSnappingEnabled`，默认开）；拖动歌词块 / 边缘 / 走轨、倒计时、播放头时 8 像素内吸到播放头、其它句四条边、倒计时两端、0 秒，吸住时画黄色竖线（`TimelineSnapper`）。菜单栏「撤销 / 重做」「分析」原来一直停在启动时的禁用状态（App.body 读 state 不刷新），改为 `MaGiKaraCommands` 监听只含开关的 `MenuState`，避免播放头每帧重建菜单。

- **人声分离质量评估（10-05）**：MDX23C「去全部人声」保留，不另下模型。合成真值测试（分好的伴奏 + 错开 7 秒的人声重新混合，再分离）：伴奏 SDR 19.06 dB，人声 12.96 dB；神经引擎与 CPU Float32 结果相同；75% 重叠、模型直出伴奏、两者平均都只差 ≤0.02 dB。真实《花》整首伴奏用 Yohane CTC 检测人声残留基本为 0，有人声段 10–20 kHz 比真值低约 1.6 dB。复测命令：`magikara-phase0 --separate <媒体> <目录> [--compute all|cpu|gpu] [--overlap 2|4] [--inst residual|model|blend]`。播放静音改为重建只含未静音轨的合成；分离结果与分轨导出都做峰值限制。

**工作方式（后来者必读）**
- 构建 / 测试：`./Scripts/build.sh bundle|build|release|test`；`swift test` 直接可用。命令行：`.build/release/magikara-phase0 --align <媒体> <歌词txt> <输出> [--yohane-audio-only|--product-default]`、`--export-mp4 <工程> <输出.mp4> [--preset <名字>] [--ass-only]`、`--probe`。
- **界面必须在真实 App 里验证，不能只靠单元测试**：把 `dist/` 的 App 复制一份，用 PlistBuddy 把 `CFBundleIdentifier` 改成独立 id 并重新签名（`codesign --force --deep --sign -`），`open -n` 启动，再用 computer-use 的 `app_*` 工具操作，这样不碰用户正在用的实例。`app_click` 对时间线不稳定，`app_drag` 可靠；播放时时间线会滚动，先暂停。
- 工程兼容：新增字段必须 `decodeIfPresent` 并回落到**旧**默认值；样式 / 显示策略 / 倒计时的旧工程都有对应测试。
- Yohane 的模型许可是 CC BY-NC-SA 4.0（非商业），默认路径依赖它，发布前要重新评估。

**未完成 / 未验证**
- 从 Finder 真实拖文件到时间线、播放中拖色块时时间线不滚动：只有单元测试，没有实机验证。
- 翻页节奏数值（1.5 / 0.8 / 0.4 秒）来自对参考合集（B 站 BV1ip7R6oEck，术力口 ニコカラ 串烧）的粗测，OCR 有错字、Yohane 在那些片段置信度偏低，需要看真实效果微调。
- 参考合集画面最上方那行很小的灰色「下一句预告」字没有实现，也没搞清楚它的规则。
- 对轨精度只在《花》一首上验证（对比 LRCLIB，±0.5 秒内 39/40）；Yohane 句尾可能被 CTC 拉长，未定论；全部句子仍标「待确认」（置信度未校准）。
- 导出码率未按素材自适应（源 1.5Mbps 的视频默认导出约 8Mbps）。
- Remote Control 已开，但手机推送要用户在终端 `/config` 里开启。

## 已完成功能（2026-09 的旧记录，保留作参考）

当前源码接线：媒体导入、日语歌词输入／检索、AI 对齐、假名与扫色、双槽预览、歌词时间线编辑、撤销、人声分离、全局样式、MP4／ASS／LRC／SRT 导出。实现不代表本次 GUI 全流程验收通过。

## 当前架构

SwiftUI／AppKit App → AppState → MaGiKaraKit 核心 → KaraProject → 预览、时间线、导出。AVPlayer 发布时间，AppState.playhead 是播放头真值。另有 magikara-phase0 无头 CLI。

## 关键文件

- `Sources/MaGiKara/UI/AppState.swift`：状态、命令与后台任务。
- `Sources/MaGiKara/UI/TimelineView.swift`、`PlaybackEngine.swift`：时间线／播放。
- `Sources/MaGiKaraKit/Models/KaraProject.swift`、`LyricModel.swift`：工程与时间约束。
- `Sources/MaGiKaraKit/Alignment/`、`Separation/`：分析与模型。
- `Sources/MaGiKaraKit/Project/ProjectStore.swift`：读写／撤销／自动保存。
- `Sources/MaGiKaraKit/Export/`、`Sources/MaGiKara/UI/ExportWorkspace.swift`：导出。
- `Scripts/build.sh`：build／release／test／bundle／run。

## 刚才修改内容

本次只新增此入口和详细交接 RD，没有修改源代码、构建或重启 App。当前源码已有此前紫色播放头跟随与歌词块 1pt 白描边修复。

## 未完成事项

真实歌曲对齐质量；正常工程打开／保存入口；新项目持久化／退出保存；导出真实进度与取消；纯音频成片路径；环境可移植性；独立片头设计字幕；正式发行准备。详细分类见 RD 第 11 节。

## 已确认不能改动的设计原则

主路径是生成 AI 歌词后直接成片；手动时间线是修复路径。保持日语原文／读音／假名绑定，四段时间与手动调整保护，旧工程兼容，取消后的旧会话不得提交。片头设计必须与歌词全局样式隔离。视觉修改必须验收指定 App 实例。

## 已知 Bug

历史真实歌曲对齐未达标；曾有 demo fixture 解码缺字段错误。当前新项目没有 projectURL 时自动保存不执行，打开／保存方法缺普通 UI 调用。无分离素材的原音轨静音与导出可能不一致。模型并发安装、缓存清理属于待复核风险，不能当已复现 Bug。

## 下一步建议

先读详细 RD，再根据用户下一条明确需求做局部改动。Git main 当前没有 commit，大部分文件 untracked，先建立可恢复基线，避免清理／覆盖。可见 UI 修改需区分源码、构建、打包、实际启动、最终验收五层状态。

## 验证状态

本次：只读源码和文档审查，未运行测试／构建／App。dist 可执行文件日期为 2026-09-25 02:14:05，版本与当前源码对应关系未确认，本次未见运行进程。历史 2026-09-24：295 tests／38 suites 通过；隔离 App 验证播放头与描边，当时未替换主 App。不要把历史结果写成当前测试通过。
