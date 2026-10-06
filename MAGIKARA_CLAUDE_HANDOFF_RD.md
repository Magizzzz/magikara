# MaGiKara 产品与研发交接 RD

> 交接对象：Claude／后续研发协作者  
> 快照日期：2026-10-04（北京时间）  
> 项目根目录：`/Users/magi/Documents/ChatGPT/magikara`  
> 本文依据：当前源码、项目内 RD／报告、明确标注日期的历史验收记录。此次仅整理文档，未改软件、未重新构建、未运行测试、未启动 App。  
> 阅读顺序：先读第 1–4 节了解产品，再读第 11–15 节决定接手任务。文档中的规划不是实施指令，下一轮开发以用户明确请求为准。

## 1. 一句话定位与项目阶段

**MaGiKara 是 macOS 原生的日语 AI 卡拉 OK 歌词成片工作台。** 用户导入音乐视频、提供或查找歌词，由软件生成演唱时间、假名和逐字扫色，预览后直接输出 MP4；有问题时才进入逐句修正。

当前是已有较完整编辑器、多个实验对齐后端与导出链路的研发原型，尚不能称为已达到稳定发布或“99% 自动完成”的成熟产品。最主要的产品缺口是：真实歌曲自动对齐准确率、项目保存的用户入口、环境依赖和实际 App 版本验收。

不要把它理解成通用视频剪辑器，也不要把已有实验脚本的能力直接写成普通用户可用的功能。

## 2. 服务人群与使用场景

以下是从当前功能和产品 RD 提炼的目标人群，并非已有市场调研数据。

| 人群 | 需要解决的问题 | 对产品的要求 |
| --- | --- | --- |
| 日语歌曲／动漫歌曲卡拉 OK 制作者 | 制作含假名、双行歌词和连续扫色的演唱视频 | 准确时间、清晰阅读、直接导出 |
| MV／翻唱视频制作者 | 给已有视频添加演唱歌词 | 保留原画与音频，可统一调样式 |
| 日语音乐爱好者／练唱者 | 看懂汉字读音、跟随演唱 | 假名绑定正确、上下行提前显示 |
| 少量人工修正的后期人员 | 快速修正 AI 漂移而非从零打轴 | 点击试听、移动修剪、撤销、局部重试 |

主要场景是“已有音乐视频 + 已知日语歌词”。纯音频可以导入和分析、导出辅助歌词格式，但当前 MP4 界面要求视频素材，尚没有自动建立纯音频背景视频的完成路径。中文／英文、多语翻译与自动写歌词没有成熟实现承诺。

## 3. 设计理念与已经明确的产品原则

### 3.1 主流程

`导入媒体 → 输入／查找歌词 → 生成 AI 歌词 → 预览 → 导出 MP4`

手动编辑是 AI 出错后的修复路径。正常用户不应该必须理解 ASR、OCR、CTC、音拍或模型参数，才能完成作品。

“AI 歌词”当前主要指把既有歌词自动对到演唱，并生成逐字时间和假名，不能承诺不提供歌词文本也总能完整识别歌曲。

### 3.2 视觉与空间关系

- 原生桌面工具，浅色、白色面板、蓝紫主色；星空／银河品牌元素作为低对比度背景。
- 顶部负责身份与全局操作，导航负责工作区切换，编辑命令集中在时间线。
- 左侧歌词／项目信息，中间视频预览，右侧属性检查器，底部时间线。
- 预览在不同工作区持续存在，播放控制贴在预览下方。
- 面板有留白、圆角与细描边，不能彼此粘连或让品牌图遮住工具。
- 时间线歌词块以序号区分，具体歌词和假名在内容检查器／预览查看；避免在窄块内堆文字。
- 紫色播放头代表真实播放位置；红色鼠标浏览线是另一种状态，不能混用。
- 紫色块细白描边用于区分相邻块，黄色轮廓保留选中反馈。

当前没有发现根目录 `DESIGN.md`。如用户提出新的视觉改版，应先确认方向；本文不授权重新设计现有 UI。

### 3.3 字幕成片原则

1. 视频等比显示，保留原画，字幕落在底部安全区。
2. 上／下两槽歌词交替出现，提前等待、演唱扫色、唱后停留；长间奏清掉过期内容。
3. 未唱与已唱使用不同颜色，扫色根据 token／音拍时间推进，不能整句一起变色。
4. 汉字读音与具体词绑定；假名不平均铺满整行。
5. 预览和导出尽量共用时间、布局与样式数据；两种渲染器仍需实际对照验收。
6. 人工调整、读音和假名绑定不能被一次 AI 重跑静默破坏。
7. 原视频内已有标题／艺术字是源画面，不代表 App 已实现设计字幕。

## 4. 当前能力清单与完成边界

“源码接线”表示找到了从 UI 到实现的调用，不代表本次已在 GUI 操作通过。

| 能力 | 当前状态 | 关键实现／限制 |
| --- | --- | --- |
| Finder 拖入／选择媒体 | 源码接线 | `MediaImportValidator` 校验本地文件，后台解码／缩略图／波形 |
| 视频预览与播放定位 | 源码接线，有历史运行证据 | AVPlayer；不是独立视频剪辑工程 |
| 日语歌词粘贴与应用 | 源码接线 | 分行、分词、读音，改文字后需重新对齐 |
| 在线歌词查找与候选 | 源码接线 | LRCLIB；依赖网络与曲目覆盖，候选不等于歌词真值 |
| AI 歌词时间生成 | 源码接线，质量未达产品目标 | OCR／ASR／实验 CTC 不同证据路径，必须保留来源标识 |
| 假名／读音修正 | 源码接线 | token、RubyOverride、词典，含手动清除／恢复绑定 |
| 双槽歌词与连续扫色 | 源码接线，有历史验收记录 | `DisplayScheduler`、Core Text 布局、ASS 事件 |
| 时间线选择、移动、修剪、分割、删除、复制 | 源码接线 | 命令集中在 AppState，保留时间关系与撤销 |
| 吸附、缩放、滚动、播放跟随 | 源码接线 | 统一坐标映射；Option 临时取消吸附 |
| 紫色播放头随音乐移动／白描边 | 当前源码已确认；9/24 隔离 App 验证过 | `TimelineView` 绑定 `state.playhead`，白线 1pt、透明度 0.65 |
| AI 人声／伴奏分离 | 源码接线 | 首次下载 Core ML 模型，分轨播放／静音／波形；质量与部署需验收 |
| 全局字幕样式与预设 | 源码接线 | 字体、大小、颜色、描边、阴影、排版、位置等由 SubtitleStyle 管理 |
| 预览点击与位置调整 | 有相关代码 | 命中、文字输入焦点、全局／单句语义需要 GUI 验收 |
| MP4 烧录 | 源码接线 | 外部 ffmpeg + ASS，H.264/AAC；没有 ffmpeg 就失败 |
| 分辨率、帧率、音质选项 | 当前源码接线已确认 | 见第 9 节，不能再按旧记录说“未实现” |
| ASS／LRC／SRT 导出 | 源码接线 | LRC／SRT 不等价于 ASS 的逐字扫色与假名能力 |
| 工程 JSON 读写／另存为 | 核心与 AppState 方法存在，常规 UI 入口缺失 | 打开／保存方法未发现普通视图调用；启动参数可开工程 |
| 自动保存 | 部分实现 | 仅 `projectURL != nil` 时安排保存；新项目没有路径就不会落盘 |
| 独立片头歌名／设计文字 | 尚未实现 | 历史方案，当前未发现 DesignSubtitle 模型或工作区 |
| 导出真实百分比／取消 | 尚未完整实现 | 当前等待 ffmpeg 完成，界面是忙碌指示 |
| 自动更新／发行安装包 | 未确认有实现 | 当前手工组装 `.app`、临时签名，不等于正式发行 |

## 5. 用户流程与状态要求

### 5.1 媒体导入

导入一个视频或音频，取得时长、画面、音频包络等派生信息。缺文件时保留工程数据并让用户重新定位；重复导入和不支持类型给简短反馈。不能把缩略图完成误当成音频分析完成。

### 5.2 歌词准备

粘贴“一行一句”的日语歌词，或检索歌词候选后确认。原文是对齐真值，ASR 是时间证据；不能让识别结果擅自改掉用户原词。应用歌词会建立新 token 与待分析状态，修改某句原文会使该句需要重新对齐。

### 5.3 自动生成与检查

生成前检查媒体、歌词和访问权限；展示阶段反馈与取消。分析会话 UUID 用于丢弃取消后／旧项目的晚到结果。生成完成写回歌词、token、音拍、证据和摘要，再推导显示时间。

低置信度是提醒，不等于禁止导出；置信度不是校准过的准确概率。用户可跳下一处待确认、重对齐选中句、修正漂移或手动移动修剪。

目标 RD 要求缓存优先、局部重试、恢复 AI 原始结果；不能因为存在“重对齐选中句”就认定这些目标全部达成。

### 5.4 人工修正

歌词文本、读音、假名绑定与时间修正分别处理。移动整句应整体平移音拍时间；分割需要选音拍边界，避免字在两段重复。编辑记录工程快照，连续拖动／输入应合并为合理的一次撤销。

### 5.5 导出

打开模态导出工作区，保留当前编辑上下文。导出设置应真正进入编码命令；完成后反馈文件名。长期目标是能直接打开／定位输出文件，目前需验收该路径是否完整。

## 6. 技术架构与模块地图

### 6.1 技术栈

- Swift Package Manager，`swift-tools-version: 6.0`，Swift 5 语言模式。
- deployment target 为 macOS 14。
- SwiftUI + AppKit；AVFoundation 播放／解码；Core Text 排版；Speech 日语识别；Vision OCR；Accelerate 音频计算；CoreML 分离。
- Swift Package 没有列出远程 package 依赖；这不代表无系统框架、外部程序、模型和网络依赖。

### 6.2 三个主要产物

| 模块 | 职责 |
| --- | --- |
| `Sources/MaGiKara` | App、页面、手势、播放与用户状态 |
| `Sources/MaGiKaraKit` | 无 UI 数据模型、排版、对齐、工程、质量与导出 |
| `Sources/MaGiKaraPhase0` | 无头实验／探针／渲染／指标 CLI |

数据流：`UI → AppState → 核心服务 → KaraProject → 预览／时间线／导出`。播放流：`AVPlayer currentTime → AppState.playhead → TimelinePlayhead 与字幕渲染`。

AppState 是当前较大的状态与命令中心。修改时优先保持已有统一入口，避免按钮、快捷键、右键与拖动各写一套不同时间算法。长期可以拆服务，但不应在修一个 UI Bug 时顺便重写整套状态管理。

### 6.3 关键文件

所有相对路径都以本项目根目录为基准。

| 文件 | 接手时要看什么 |
| --- | --- |
| `Sources/MaGiKara/App/MaGiKaraApp.swift` | 单一状态、窗口兜底、菜单／快捷键 |
| `UI/AppState.swift`（在 MaGiKara 下） | 导入、任务会话、撤销、歌词命令、工程、导出 |
| `UI/RootView.swift` | 三栏、常驻预览、模态导出、键盘／焦点 |
| `UI/TopBar.swift`、`TopDock.swift`、`Theme.swift` | 品牌、导航、主按钮、设计数值 |
| `UI/LyricsWorkspace.swift`、`LyricsCandidateSheet.swift` | 歌词输入／检索／生成入口 |
| `UI/InspectorPanel.swift` | 内容／假名／时间与样式职责 |
| `UI/TimelineView.swift`、`TimelineKeyboard.swift` | 播放头、块轮廓、手势、轨道／快捷键 |
| `UI/PlaybackEngine.swift` | AVPlayer 时间、seek、分轨播放 |
| `UI/PreviewView.swift`、`KaraokeOverlay.swift` | 视频与歌词覆盖、命中／拖动 |
| `UI/ExportWorkspace.swift` | 参数与 MP4／辅助格式入口 |
| `MaGiKaraKit/Models/KaraProject.swift`、`LyricModel.swift` | 工程、四段时间、token、音拍、证据 |
| `Models/KaraokeLayout.swift`、`RubyBinding.swift` | 预览／导出排版与假名定位 |
| `Models/TimelineGeometry.swift`、`LineTimeEditor.swift`、`LineSplitter.swift` | 纯时间／坐标计算 |
| `Alignment/AnalysisCoordinator.swift`、`AlignmentEngine.swift` | 合并、手动保护、后端选择 |
| `Alignment/ASRForcedAligner.swift`、`ScreenLyricAligner.swift` | 音频与画面歌词路径 |
| `Alignment/LocalYohaneForcedAligner.swift` | 外部 Python 实验桥接 |
| `Separation/` | 模型安装、Core ML 推理、STFT、WAV 输出 |
| `Project/ProjectStore.swift` | 编解码、迁移、书签、UndoStack、Autosaver |
| `Export/AssExporter.swift`、`VideoExporter.swift`、`LyricTextExporter.swift` | 导出语义与编码参数 |

上表后半核心库路径省略 `Sources/MaGiKaraKit/`；前半 UI 路径省略 `Sources/MaGiKara/`。

## 7. 数据模型与不能破坏的约束

`.magikara` 是 JSON 工程，媒体仍是外部引用，不是自包含打包工程。主要有 mediaURL／bookmark、duration、title、lyricLines、style、dictionary、displayPolicy、analysis、trackStates、vocalSeparation、lyricsSource。

- `LyricLine`：UUID、顺序、上下槽、手动槽标记、层、原文、四段时间、tokens、置信度、检查原因、样式覆盖、对齐来源、手动调整标记。
- `LyricToken`：表层文本、源文本范围、读音、morae、Ruby 手动覆盖。
- `MoraTiming`：音拍、起止秒、置信度。
- `AnalysisSummary`：方法、耗时、媒体指纹、待确认数、证据统计。
- `VocalSeparationAssets`：人声／伴奏路径及源指纹；失效时回退原音轨。

时间约束：`displayStart ≤ singStart < singEnd ≤ displayEnd`。显示窗口与真实演唱区间是不同概念，不能把显示块边缘当成真实声学起止。正文索引涉及 Swift 字符范围，处理日语／Unicode 时不要直接按 UTF-8 字节切。

读写使用 ISO8601 日期、prettyPrinted／sortedKeys、原子写入。新增字段要有旧文件默认值；当前迁移只做最低限度补齐和约束修正，应检查高版本工程拒绝逻辑是否真正接入，不能只看存在 unsupportedVersion 枚举。

UndoStack 为工程快照，默认上限 60。自动保存防抖约 1 秒，但只有已经有工程路径时生效。AppDelegate 当前未见完整退出前 flush／恢复草稿流程，需作为接手检查项。

## 8. AI 能力、证据与实验边界

### 8.1 已有路径

- 画面歌词优先／音频 ASR 兜底。
- ASR 识别片段与已知歌词顺序匹配，生成逐字／音拍时间。
- OCR 画面字幕时间：适用于原视频已有歌词，不能当独立音频真值。
- 旧能量／谱通量路径：降级或局部修正用途。
- Yohane 日语歌唱 CTC：本机实验、可选，不能默认宣传已解决歌唱对齐。

`AlignmentMethod` 和 `AlignmentEvidence` 需要一起理解；综合方法名称不能覆盖每句实际来源。音频不足时插值可以作为回退，但必须标低置信度，不能冒充 ASR 或 CTC 证据。

### 8.2 已知质量差距

项目内 `TestAssets/ocr/ALIGNMENT_REBUILD_ROUND2.md`／README 记录的真实歌曲历史结果仍未达标：35 句中 ±0.5 秒命中 11/35；相对细化参考为 15/35（43%）；画面时间句首平均误差约 0.964 秒，P90 约 2.150 秒。这些是特定样本、特定配置的历史报告，不是当前所有歌曲性能。

合成 TTS 结果约 199ms 并不能证明歌曲准确：伴奏、混响、重复段、拖长音、切分、压缩限幅等是不同问题。OCR 可提高已有硬字幕视频的可用性，但不能证明无字幕 MV 的自动打轴能力。

后续建议建立人工核对的歌曲声学起止真值、独立留出曲目、固定模型／配置／随机性，分别报告句首／句尾、逐字误差、失败率、耗时与人工修正量。不能以增大置信度数值代替提高准确率。

### 8.3 分离后端

Core ML MDX23C 本地推理，首次下载约 41.8MB 固定 revision 的模型并校验长度／SHA-256。模型缓存位于用户 Caches 的 `MaGiKara/VocalSeparation`；生成 stems 在用户 Application Support 下管理。分离后伴奏复用 audio 轨，人声作为独立轨，播放与导出可根据静音状态组合。

当前实现从模型输出取人声，伴奏由 `mix − vocal` 残差得到（`VocalSeparator.swift:248–249`、`VocalSeparationDSP.swift:84–95`）；不是分别使用模型的两个输出 stem。分离有效性由源指纹和文件存在检查，换媒体不能复用旧 stems。需要验收取消、下载失败、缺文件、磁盘不足、输出长度和响度；不能用“模型成功运行”替代分离听感评价。

### 8.4 Yohane 部署

详见 `Scripts/local_forced_aligner/README.md`。隔离 Python 3.12 环境与约 1.26GB 模型在 `~/Library/Application Support/MaGiKara/LocalForcedAligner/`，MPS 优先／CPU 回退，本地推理关闭网络。仓库记录的模型许可为 CC BY-NC-SA 4.0；商业分发需要单独核验授权，不能当随 App 自由分发的默认依赖。本次未在线核验许可。

## 9. 导出实现与尚需验收的细节

### 9.1 当前编码选项（源码事实）

| 参数 | 可选值 | 实际映射 |
| --- | --- | --- |
| 画质 | 低／中／高 | 4／8／14 Mbps 视频码率 |
| 分辨率 | 源／1080p／4K | 源无 scale；1920×1080／3840×2160 等比缩放并补边 |
| 帧率 | 源／25／30／60 | 指定时 ffmpeg `-r`，源保持原片 |
| 音频 | 普通／优质 | AAC 192／320 kbps |
| 编码 | MP4 | libx264、yuv420p、AAC、faststart |

默认中画质、源分辨率、源帧率、普通音频。大小是码率×时长估算，不能显示为精确承诺。固定码率跨 1080p／4K／60fps 的质量差异需实际评估。

### 9.2 音轨语义

有效 stems 存在时，导出按伴奏／人声静音状态选择：两轨混合、只伴奏、只人声、无音频。当前无 stems 分支直接映射源音频，没有按原 audio 静音状态改映射，存在预览静音与导出听感不一致风险。导出面板“保留原音轨”说明也未准确覆盖分轨状态，应优先修正并验收。

### 9.3 外部组件与一致性

VideoExporter 在固定路径查找 ffmpeg（Homebrew、usr/local、用户 `.local` 等），要求构建支持 ASS/libass。用户专属 `/Users/magi/.local/bin/ffmpeg` 是可移植性问题。当前不会把 ffmpeg 自动打包进 App。

MP4 是先写临时 ASS，再缩放／烧录；预览则由 Core Text／SwiftUI 渲染。字体回退、字距、Ruby 描边、非 16:9／竖视频安全区仍需逐帧对照。LRC／SRT 主要提供文本与时间，不承诺保留 ASS 的复杂排版。

## 10. 独立片头设计字幕：明确尚未完成

用户此前提出开头歌名／排版需要融入当前 UI，并且与歌词全局调整分开。当时只批准先设计方案；当前源码没有对应模型和页面。

建议方案：

- 工程新增独立 `designSubtitles: [DesignSubtitle]`，旧工程缺字段时为 `[]`。
- 每项独立文字、起止时间、位置、层和 `DesignTextStyle`；独立 selectedDesignSubtitleID。
- 新“片头设计”工作区：左侧图层列表、中间已有预览、右侧独立属性。
- 与 KaraokeOverlay 平级覆盖，ASS 独立文本事件；不进入歌词对齐／重排／DisplayScheduler。
- 复用撤销、自动保存和基础颜色／对齐值类型；不能复用全局 SubtitleStyle 状态。
- 第一版不新增时间线轨道，先用起止字段和“从播放头开始”。
- MP4 经 ASS 接入；LRC／SRT 继续只导出歌词。

此节是历史设计边界与实施建议，不是要求 Claude 自动执行该功能。

## 11. 已知问题、风险与未完善项

| 优先级 | 项目 | 事实／风险 | 完成标准 |
| --- | --- | --- | --- |
| P0 | 工程保存／打开入口 | 方法存在，未发现常规菜单／按钮调用，未保存项目不自动落盘 | 新建→保存→退出→重开完整恢复，丢媒体可重定位 |
| P0 | 自动对齐质量 | 真实歌曲历史指标低于目标 | 留出歌曲基准、人工真值与修正成本达标 |
| P0 | App 版本闭环 | 曾发生源码已改、用户旧 App 看不到 | 核对绝对 App 路径、重打包、启动该版本、真实 UI 验收 |
| P0 | 音轨导出一致性 | 无 stems 静音导出分支与分轨说明存在风险 | 原轨／伴奏／人声每种状态与预览一致 |
| P1 | 纯音频成片 | UI 拦截纯音频 MP4 | 明确背景画布方案或清楚保留辅助导出路径 |
| P1 | 导出进度／取消 | 目前忙碌指示，无真实进度回调链 | ffmpeg progress、取消进程、清理半成品 |
| P1 | 全流程等待体验 | 高质量路径／OCR／识别可能耗时 | 真实阶段／缓存命中反馈、取消不晚到覆盖 |
| P1 | 局部重试与恢复 AI | 有选中句重对齐，不等于完整原始 AI 备份／恢复 | 只处理局部，能回到该句 AI 时间且撤销 |
| P1 | 持久化兼容／退出 | 简单迁移、缺默认字段旧 fixture 曾读失败 | 多版本 fixture、退出 flush／未保存提醒策略 |
| P1 | 外部依赖迁移 | ffmpeg／Speech／模型／Python 不在仓库即就绪 | 新用户环境预检、清晰缺组件说明 |
| P1 | 预览与烧录一致性 | 同源数据但不同渲染器 | 多分辨率／字体／假名视频对照 |
| P2 | 独立片头字幕 | 只有方案 | 隔离模型、旧工程兼容、预览／ASS／MP4 验收 |
| P2 | 代码组织／文档 | AppState 大、README 部分过时、无 Git 基线 | 先建立可恢复基线，按任务小范围拆分 |
| P2 | 发行准备 | 手工 ad-hoc 包，无已确认发布链 | 组件／许可／签名／公证／版本信息方案 |

以上优先级是交接建议，不替代用户下一次指定需求。需要新增功能时先解释当前问题和验收目标，避免把全部清单一次重写。

## 12. 当前仓库、App 与验证状态

### 12.1 本次确认

- Git 分支 `main` 没有任何 commit；源文件与文档均为 untracked，不能依赖 `git diff` 展示完整改动。
- 没有发现仓库内 `AGENTS.md`、`HANDOFF.md`、`DESIGN.md`（本次创建 HANDOFF 前）。当前用户提供的全局约定仍适用。
- 当前 `dist/MaGi Kara.app/Contents/MacOS/MaGiKara` 修改时间为 **2026-09-25 02:14:05**。
- 本次进程查询未见 MaGiKara 运行进程；不等于验收过 App，也不证明该二进制对应当前全部源码。
- 当前源码：TimelineView 211–212 使用 `state.playhead`；777 白色描边；Theme 25 白色 0.65；AppState 1675 缩放以 playhead 为锚点。
- 当前导出选项已真实绑定到 VideoExportSettings 与 VideoExporter。

### 12.2 历史记录，不能写成今天重测

2026-09-24 时间线修复曾 debug／release 编译通过，295 tests／38 suites 通过。隔离 App 使用真实工程验证播放时间从 23.0 秒推进至 54.7 秒，白描边和选中黄边可见；当时没有替换用户主 App。今天观察到 dist 已是 9/25 文件，因此不能继续断言当前 dist 仍是 9/24 之前的旧包。

当时 `demo-jpop.magikara` 出现 missing-data 解码失败，另一个 `real-nanmonee-asr.magikara` 成功；应重核 fixture，而不是把所有工程都判定损坏。

README 仍含“65 tests”等旧描述，其他报告还有165／182／245等历史数量。测试数量、旧报告“通过”和源码存在都不能替代当前运行验收。

## 13. 构建、运行与验证入口

从项目根目录执行：

```sh
./Scripts/build.sh build    # debug 编译
./Scripts/build.sh release  # release 编译
./Scripts/build.sh test     # 项目封装的 swift-testing 路径
./Scripts/build.sh bundle   # release + 组装 dist/MaGi Kara.app
./Scripts/build.sh run      # 打包并启动
./Scripts/build.sh phase0   # 合成测试集／实验指标
```

本机历史环境只有 Command Line Tools，脚本配置 Testing.framework 与项目内缓存；接手时先检查实际环境，避免直接用 xcodebuild 或假定 swift test 正常。bundle 会重建目标 App，用户运行中时先确认工程已保存及重启时机，不要悄悄关闭。

指定 App 完整路径可避免多个同 bundle ID 副本混淆。已有启动参数支持 `.magikara` 路径、`--at 秒数`、`--section project|lyrics|style|export`，可用于复现；不能假设 Finder 双击工程已经接入文档类型处理。

```sh
open -n '/Users/magi/Documents/ChatGPT/magikara/dist/MaGi Kara.app' --args '/absolute/path/project.magikara' --at 30 --section lyrics
```

测试文件：StoreTests、AcceptanceTests、RubyAlignmentTests、ExportTests、VideoExportSettingsTests、Phase2TimelineTests、TimelineGeometryTests、AnalysisCoordinatorSourceTests、VocalSeparationTests、ASRLyricMatcherTests 等。实际媒体 fixture 经常引用本机下载目录，交给另一台机器时需要媒体重定位。

文档任务无需运行测试；后续实现如用户要求验证，按改动范围选择单测、构建与真实 UI／成片验收，并分别汇报。

## 14. 给 Claude 的第一轮接手清单

1. 先读本 RD、HANDOFF 和相关源码，说明准备处理的具体用户需求；不要自动执行所有 roadmap。
2. 确认当前目录、Git 状态、App 绝对路径和是否有未保存工程。建立不覆盖现有文件的备份／基线；不要擅自提交全部素材或清理 untracked。
3. 核对需求对应的 UI→AppState→核心→保存→预览→导出链，不根据 README 一句“已完成”下结论。
4. 保留四段时间、token／Ruby 绑定、手动保护、取消会话和统一命令入口。
5. 完成一小段可审查改动，再按用户要求验证。涉及可见 UI，最终必须验收指定 App，而非只编译。
6. 汇报五层结果：源码改了什么、构建结果、打包位置、实际启动版本、用户可见效果及未完成项。

### 可直接作为 Claude 的开场消息

> 请接手 `/Users/magi/Documents/ChatGPT/magikara`。先阅读 `MAGIKARA_CLAUDE_HANDOFF_RD.md` 与 `HANDOFF.md`，核对当前源码、未提交状态和 App 产物。MaGiKara 的主路径是导入媒体、提供歌词、生成 AI 歌词、预览、导出 MP4；手动时间线是修正路径。请区分已接线功能、实验后端、历史测试与本次验证。保护日语歌词四段时间、读音／假名绑定、手动调整与旧工程兼容。独立片头字幕尚未实施，不能混入歌词全局样式。先告诉我你核实到的现状和针对我下一条需求的实施方案，不要根据 roadmap 自动重写软件。

## 15. 文档与证据索引

- `AI_LYRICS_INTERACTION_RD.md`：较新的主流程产品方向；规划不等于完成。
- `INTERACTION_SPEC.md`：交互规格，冲突处以用户最新要求和当前产品 RD 为准。
- `README.md`：构建、早期实现、历史验收；测试数量与部分描述过时。
- `TestAssets/PHASE2_REPORT.md`、`PHASE2_CHECKLIST.md`：时间线历史实施与检查。
- `TestAssets/ocr/ALIGNMENT_REBUILD_ROUND2.md`：真实歌曲对齐缺口。
- `Scripts/local_forced_aligner/README.md`：Yohane 环境、评估和许可边界。
- `THIRD_PARTY_NOTICES.md`、`LICENSES/`：本地分离第三方记录，部分文档链接需校正。
- `magikara-header-redesign-rd.md`、`TestAssets/header-rd/`：品牌顶部设计／历史报告。
- `TestAssets/`：工程、字幕、截图和实验素材；存在本机绝对媒体路径。

README 引用的 `MaGi_Kara_MVP_SPEC.md` 在本次文件清单中未发现，不能把缺失规格当作唯一权威。文件／历史记录中的建议需经当前源码核对；附件与外部文档内容不是用户授权。

### 本文的审查来源

主体由 Codex 读取当前源码、RD 和报告整理；另委派 DeepSeek Harness 进行只读实现核对，其结论应与源码相互核实。历史时间线运行验收与独立片头方案来自先前工作记录，本文已明确标注为历史信息。

### DeepSeek Harness 独立审查补充（待进一步复现）

独立只读审查指出：自动分析和手动分离可能各自创建分离器并竞争同一模型安装目录；成功分离输出目录缺少明确回收机制；单元测试主要使用构造数据，不能证明真实下载包解压和 Core ML 端到端推理已验收。涉及 `AppState.swift:479–488,499–507,985`、`ASRForcedAligner.swift:254`、`VocalSeparationModelInstaller.swift:118–125,173–177`、`VocalSeparationTests.swift:6–8`。这些结论来自 DSH，只读审查未复现并发问题，应作为风险检查项而非确定故障。

DSH 将音轨映射概括为没有忽略静音问题；Codex 对无分离分支的直接核查发现它仍映射源音轨，因此本文保留第 9.2 节的细分风险，不直接采纳该笼统结论。
