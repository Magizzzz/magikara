# 第二阶段（剪映式时间线体验）acceptance checklist

参考：剪映/CapCut 官方（Track Magnet / Auto Snapping、字幕在播放头 Cmd+B 分割、空格播放暂停、
方向键逐帧、分割后左右删除）。只移植适合本产品的部分，不做功能大全、不做智能换行。

## A. 单元测试（纯逻辑，必须全绿）

| # | 验收项 | 测试落点 |
| --- | --- | --- |
| A1 | time ↔ x 映射：内容/视口坐标、滚动后、缩放后 | `TimelineGeometryTests`（已有 8 项） |
| A2 | 点击定位边界：0 秒 / 中段 / 末尾 / 越界夹取 | `TimelineGeometryTests.seekTimeClampsToBounds` |
| A3 | 拖动 scrub：同一坐标在多个 zoom/scroll 下解析出同一时间 | `TimelineScrubTests`（新增） |
| A4 | 吸附候选集：播放头 / 0 / 音频边界 / acousticOnset / acousticOffset / 相邻块 | `SnapEngineTests`（新增） |
| A5 | 吸附阈值：阈值内吸附、阈值外不动；开关关闭时不吸附；Option 临时关闭 | `SnapEngineTests` |
| A6 | **吸附不得修改 ASR 真实声学时间**：吸附只改「被拖动的那一句」，token/mora 时间只做整体平移 | `SnapEngineTests.noAsrTokenMutation` |
| A7 | 分割：播放头在句外 → 拒绝；在句首/句尾过近 → 拒绝；句中 → 切成两句 | `LineSplitterTests`（新增） |
| A8 | 分割后：左右两段区间首尾相接、并集等于原区间、token/mora 不丢不重 | `LineSplitterTests` |
| A9 | 修剪边界：左缘不得越过右缘、最短时长、display↔sing 不变量保持 | `LineTrimTests`（新增） |
| A10 | 移动保持时长（四个时间值同 delta） | `LineTrimTests.shiftKeepsDuration` |
| A11 | 锁定轨道拒绝编辑（移动/修剪/分割/删除） | `TrackStateTests`（新增） |
| A12 | 显隐 / 静音状态独立且可序列化 | `TrackStateTests` |
| A13 | undo/redo：连续编辑后逐步回退、再重做完全一致 | `UndoRedoTests`（新增） |
| A14 | 手动调整保护：手动改过的句子不被分析刷新覆盖 | `ManualAdjustmentTests`（新增） |
| A15 | 快捷键映射：空格/方向键/Cmd+B/Esc/Cmd+Z，文本框聚焦时不抢 | `TimelineKeyCommandTests`（新增） |

## B. UI / 真实 MP4 回归（脚本化 + 截图）

| # | 验收项 | 证据 |
| --- | --- | --- |
| B1 | 0 秒 / 中段 / 末尾点击定位 | 脚本 + 截图 |
| B2 | 连续播放后回到开头 | 脚本（真实媒体） |
| B3 | 100 次 播放/暂停 + seek 无卡死、无时间回跳 | `Scripts/timeline-stress.swift` |
| B4 | 多个 zoom 下拖动歌词，坐标不漂移 | 脚本断言 |
| B5 | 锁定 / 显隐 / 静音 | 截图 |
| B6 | Cmd+B 分割 + 撤销 | 脚本 + 截图 |
| B7 | 拖放导入不回归 | 已有 `MediaImportValidatorTests` + 截图 |

## C. 产物验收

- build / test 全绿
- TTS baseline 不退化（199 ms / 62% / 92.5%）
- 真实 ASR 指标不退化
- `.magikara` / `.ass` 正常导出
- UI 截图
- 报告：权限弹窗 / 卡死 / 坐标漂移 / 时间回跳

## D. 明确不做

- 智能换行
- 嵌套轨道 / 复杂轨道层级
- 过度动画
