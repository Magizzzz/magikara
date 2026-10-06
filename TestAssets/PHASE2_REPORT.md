# 第二阶段（剪映式时间线体验）实现报告

参考剪映/CapCut 官方：Track Magnet / Auto Snapping、字幕在播放头分割（⌘B）、
空格播放暂停、方向键逐帧、I/O 导出范围、分割后左右删除。
**只移植适合本产品的逻辑**，不做功能大全，不做智能换行。

验收清单见 `TestAssets/PHASE2_CHECKLIST.md`。

---

## 0. 手势分工（按正常 NLE 逻辑）

| 位置 | 拖动行为 |
| --- | --- |
| 时间尺 | **scrub**（连续定位播放头） |
| 视频缩略图 / 波形 | **scrub** |
| 歌词/假名轨的**空白区域** | **scrub** |
| 歌词块**主体** | **移动**（四段时间 + 全部音拍一起平移，保持时长） |
| 歌词块**左右边缘** | **trim**（改显示起止；选中后内部演唱区边缘改演唱起止） |
| 滚轮 / **Shift+滚轮** | **时间线平移** |
| ⌘+滚轮 | 缩放（额外便利，不影响平移） |

实现要点：scrub 只绑在**背景空白层**上，歌词块在 ZStack 上层。
早期版本把 scrub 用 `simultaneousGesture` 挂在整条轨道容器上，
拖动块时会**同时**触发「移动片段」和「scrub」—— 已按上述分工修正。
命中判定收敛到 `LyricBlockHitTest`、滚轮映射收敛到 `TimelineScrollMapper`，两者都有单测。

### 1.1 时间线点击 / 拖动定位

- **点击定位**：时间尺、视频缩略图、波形、假名轨、歌词轨的**空白区域**单击即定位播放头。
- **拖动 scrub**：上述所有区域按住拖动连续定位。用 `DragGesture(minimumDistance: 0)`，
  所以单击与拖动是同一条路径，手感一致。
- **块的拖动优先**：手势挂在轨道背景（ZStack 下层），块的拖动在上层，两者不抢。
- **平移改为滚轮/触控板横向滚动**（`ScrollWheelCatcher`）。
  这是刻意的取舍：轨道拖动已经给了 scrub，如果平移也绑拖动就会互相抢手势；
  macOS 上横向滚动本来就是最自然的平移方式。⌘+滚轮 = 缩放。
- **缩放不再漂移**：点击手势挂在内容坐标系（内容整体 `-scrollX` 偏移），
  `location.x` 就是内容坐标；缩放以播放头为锚点保持视口相对位置。
- **可回溯**：时间夹在 `[0, duration]`，播放后再点 0 秒能回来。

### 1.2 轻量吸附（对标 Auto Snapping / Track Magnet）

`SnapEngine`（纯逻辑，可测）候选来源：

- 播放头
- 时间线开头 / 音频边界
- 相邻句的 **acousticOnset / acousticOffset**（演唱起止）
- 相邻块的显示起止
- 音频侧**人声段起点**（与 ASR 无关的能量/似然检测，加载媒体时算好缓存）

- 阈值按**像素**算（默认 8px），换算出时间，所以 4 px/秒 与 400 px/秒 手感一致。
- 吸附开关：时间尺右侧「吸附」按钮；**按住 Option 临时关闭**。
- **不改 ASR 真实声学时间**：吸附只决定拖动落点；写入的是这一句的时间值，
  token/mora 只做**整体平移**，绝不被吸附重写。有单元测试专门守这条
  （`snapUsesPlayheadAndAcousticPointsOnRealLengths`、`snapsToPlayheadWithinThreshold`）。

### 1.3 分割 / 修剪 / 移动 / 删除

- **⌘B 在播放头分割**（也有时间尺上的「分割」按钮和右键菜单，三个入口同一实现）。
- **切割点吸附到最近的音拍边界**。这一条是被测试逼出来的真 bug：
  早期实现若切在音拍中间，那个音拍会同时属于两侧，它对应的字会在两段里**各出现一次**
  （实测「きみのうた」切成「きみの」+「のうた」）。
  现在总是吸附到音拍边界，文字与音拍都能干净地一分为二；只有「切完某段过短」才拒绝。
- **拖动左右边缘修剪**，拖动时右上角显示**时间提示**（边名 + 落点时间 + 吸附状态）。
- **拖动主体移动**：四个时间值与全部音拍一起平移，**保持时长**；越界贴边停住。
- **移动/修剪后自动标记「手动调整」**，并记录原因。
- **删除 / 撤销 / 重做**：所有编辑走同一个 `beginEdit` → 一次编辑一条撤销记录。
- **手动调整保护**：标记过的句子在 `AnalysisCoordinator.merge` 里被跳过，
  **不会被「AI 一键生成」覆盖**（`mergeKeepsManuallyAdjustedTimes`）。

### 1.4 轨道头

只保留 **显隐 / 锁定 / 静音** 三个开关，不做嵌套层级。

- 锁定：块变灰 + 斜纹 + 虚线描边，手柄消失，拖动/修剪/分割/删除全部拒绝，
  锁定轨道的编辑闸门收敛到 `KaraProject.isEditable(_:)` 一个判断，所有入口共用。
- 显隐：隐藏后该轨道内容不渲染并压暗。
- 静音：音频轨静音真的落到播放器音量上（`applyMuteState`）。
- 状态随工程保存（`trackStates`），旧工程缺字段也能打开。

### 1.5 键盘

`TimelineKeyMapper`（纯映射，可测）+ `TimelineKeyboardMonitor`（本地事件监听）。

| 键 | 行为 |
| --- | --- |
| Space | 播放 / 暂停 |
| ← / → | 逐帧（1/30 秒） |
| Shift + ← / → | 1 秒 |
| ↑ / ↓ | 上一句 / 下一句（并定位到该句） |
| ⌘B | 在播放头分割 |
| Delete | 删除选中句 |
| Esc | 取消拖动 / 取消选择 |
| ⌘Z / ⌘⇧Z | 撤销 / 重做 |

**文本框聚焦时不抢键**：`TextEditor`/`TextField` 的 firstResponder 是 `NSTextView`，
据此判断；聚焦时空格、方向键、删除、Esc 一律让位（撤销/重做也交给系统处理文本自身的撤销）。

---

## 2. 测试结果

```
./Scripts/build.sh build   → Build complete!
./Scripts/build.sh test    → ✔ 165 tests in 18 suites passed
```

本阶段新增 61 项（104 → 165）：

| 套件 | 覆盖 |
| --- | --- |
| `SnapEngineTests`（9） | 阈值内/外、缩放无关、开关关闭、Option 临时关闭、吸到相邻演唱起止、开头/音频末尾、**不改 ASR token 时间**、zoom=0 不崩 |
| `LineSplitterTests`（12） | 句外拒绝、过近拒绝、中间切、不丢字不重复、并集等于原区间、音拍不重不漏、按音拍边界切、吸附到边界、吸附塌到端点则拒绝、关闭吸附则拒绝 |
| `LineTrimTests`（9） | 修剪四条边的边界、穿越拒绝、移动保持时长、左右越界贴边、修剪后重映射音拍 |
| `TrackStateTests`（5） | 默认值、三个开关互相独立、锁定轨道拒绝编辑、存盘往返、旧工程缺字段兼容 |
| `UndoRedoTests`（3） | 连续编辑逐步回退/重做完全一致、**分割后撤销恢复单句**、空栈 |
| `ManualAdjustmentTests`（3） | 合并时保留手动时间、未手动句正常写入、标记存盘往返 |
| `TimelineKeyCommandTests`（8） | 空格/方向键/⌘B/⌘Z/⌘⇧Z/Esc、Option 不算快捷键、**文本框聚焦让位**、逐帧步长 |
| `RealMediaTimelineTests`（7） | **真实 MP4**：0/中段/末尾点击 × 5 缩放 × 3 滚动位置精确映射、越界夹取、反复缩放不漂移、**100 次 seek**、**100 次播放暂停后回到开头**、真实工程锁定/显隐/静音存盘、真实时长下分割+撤销、真实时长下吸附 |
| `LyricBlockLayout` / `LyricCharTiming`（既有） | 块内逐字位置与计数 |

### 真实 MP4 回归（无头执行，不启动 GUI）

| 项 | 结果 |
| --- | --- |
| 0 秒 / 中段 / 末尾点击定位 | 5 个缩放档 × 3 个滚动位置全部精确到 1e-6 |
| 越界点击 | 夹到 0 / duration |
| 连续播放后回到开头 | **100 次播放暂停后 seek(0) 返回 < 0.2 秒** |
| 100 次 seek | 全部有限、在 `[-0.05, duration+0.05]` 内，无失败 |
| 多 zoom 拖动歌词 | 反复缩放 12 次锚点不漂移，scrollX 始终在合法范围 |
| 锁定 / 显隐 / 静音 | 真实工程设置后存盘再读回一致 |
| 分割 + 撤销 | 真实时长下切分、renumber 后上下行交替、撤销恢复单句 |

### 回归未发生

| 项 | 结果 |
| --- | --- |
| TTS baseline | **199 ms / 62% / 92.5% / 错配 1**（与阶段一完全一致） |
| 真实 ASR 对轨 | ASRForcedAligner，17.8 s，句首平均 0.955 s（正常波动范围内） |
| `.magikara` | 正常写出，`trackStates` / `isManuallyAdjusted` 随工程保存 |
| `.ass` | 正常导出，头部仍写明对齐方法与证据分布 |
| AI 按钮位置 | 仍在右侧「字幕」面板底部页脚（未改动） |
| Logo | 仍为新 Logo（`b29dee78…`，未改动） |
| 拖放导入 | `MediaImportValidatorTests` 全过（未改动） |
| 智能换行 | **未实现**（按要求） |

---

## 3. 产物 / 证据

| 文件 | 说明 |
| --- | --- |
| `TestAssets/ui-phase2-timeline-offscreen.png` | 时间线离屏渲染（与 App 共用 `LyricBlockLayout`/`LyricCharTiming`）：块按演唱时间分布、块内逐字不均匀、播放头高亮、**锁定轨斜纹虚线**、**隐藏轨压暗**、选中块描边、待确认橙边 |
| `TestAssets/ui-lyrics-workspace.png` | 上一阶段的歌词工作区 + 字幕面板底部 AI 按钮（未回归） |
| `TestAssets/PHASE2_CHECKLIST.md` | 本阶段验收清单 |
| `TestAssets/real-nanmonee-asr.magikara` / `.ass` | 真实 ASR 工程与导出 |

离屏渲染命令（不启动 GUI，不触发权限弹窗）：
```bash
MAGIKARA_PLAYHEAD=114.2 MAGIKARA_SELECTED=24 \
  magikara-phase0 --render-timeline <工程.magikara> <out.png> 108 16 72
```

---

## 4. 报告的异常项（按要求）

| 类别 | 结论 |
| --- | --- |
| **权限弹窗** | **未触发任何弹窗**。所有 GUI 尝试都在 `/tmp` 与 `/Users/Shared` 完成，工程与媒体都复制到这两个非受保护目录，未访问文稿/下载目录，未要求完全磁盘访问 |
| **卡死** | 无。100 次 seek + 100 次播放暂停的整套真实媒体回归 **5.4 秒**跑完（含 165 项测试总耗时） |
| **坐标漂移** | 无。时间↔x 往返映射在 5 缩放下精确到 1e-6；反复缩放 12 次锚点不漂移；scrollX 始终夹在合法范围 |
| **时间回跳** | 无。100 次 seek 全部有限且在界内；100 次播放暂停后 `seek(0)` 返回 < 0.2 秒 |

---

## 5. 阻塞与限制

1. **GUI 截图拿不到（阻塞，已停止重试）**：`dist/MaGi Kara.app` 从 `/tmp` 与 `/Users/Shared`
   启动都不出现窗口（进程未起来，与路径无关）。按无人值守要求不反复重启，改用**离屏渲染**
   出等价证据。要拿窗口截图请手动执行一次：
   ```bash
   open "/Users/Shared/magikara-run/MaGi Kara.app" --args "/Users/Shared/magikara-run/demo.magikara" --at 114.2
   ```
2. **点击/拖动的端到端验证是模型层的**：`RealMediaTimelineTests` 驱动的是
   `TimelineGeometry` / `SnapEngine` / `LineEditor` / `AVPlayer` 这些真实实现，
   但没有真实鼠标事件流（受 GUI 阻塞影响）。坐标换算、边界、吸附、分割、撤销这些
   纯逻辑部分是逐项断言过的。
3. **平移方式已变**：轨道区域拖动现在是 scrub，平移改为滚轮/触控板。
   这是我为了保证「轨道可拖动定位」而做的取舍，需要你确认可接受。
4. **4/35 句演唱区间过短**（#4 0.85s、#21 0.79s、#27 0.06s、#32 0.73s 对应 8–11 字），
   在 64 px/秒 下块宽只有 2–5 像素。本阶段**不改对轨数据**（你要求不回归 ASR 声学时间），
   改为：极窄块只画一个字符标记、保留待确认描边，并新增测试守住「极窄块不塞字」。
   根因属第二阶段自动对轨的「二次修正」范围。
5. **I/O 标记（导出范围）未实现 —— 明确记录为未做**。用户列表里提到但标注可暂缓，
   本阶段未投入：没有入点/出点标记，没有「只导出选区」，也没有标记间的左右删除。
   现有导出仍是整曲 ASS。

---

## 6. 改动文件

**新增（Kit，纯逻辑 + 测试）**
`Sources/MaGiKaraKit/Models/SnapEngine.swift`、`LineSplitter.swift`、`LineEditor.swift`、
`TrackState.swift`、`TimelineKeyCommand.swift`、`LyricBlockLayout.swift`

**修改（Kit）**
`Models/LyricModel.swift`（手动调整标记）、`Models/KaraProject.swift`（trackStates 编解码 + isEditable）、
`Models/LyricCharTiming.swift`、`Alignment/AnalysisCoordinator.swift`（抽出可测 merge + 手动调整保护）

**新增/修改（UI）**
`UI/TimelineKeyboard.swift`（新）、`UI/ScrollWheelCatcher.swift`（新）、
`UI/TimelineView.swift`（点击+拖动 scrub、吸附、修剪提示、锁定渲染、轨道头三开关、
吸附/分割按钮、右键菜单）、`UI/AppState.swift`（吸附/分割/轨道状态/键盘命令/手动标记）、
`UI/RootView.swift`（挂键盘层）

**测试**：`Tests/MaGiKaraKitTests/Phase2TimelineTests.swift`（新，61 项的一部分）、
`RealMediaTimelineTests.swift`（新）、`RealProjectCharTimingTests.swift`（扩充）

**CLI**：`Sources/MaGiKaraPhase0/main.swift`（`--render-timeline` 支持锁定/隐藏/选中状态）
