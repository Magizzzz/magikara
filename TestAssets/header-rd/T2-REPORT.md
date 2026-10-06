# 顶部 UI RD · T2 背景/角色层报告

日期：2026-09-22

## 改动

- 仅修改 `Sources/MaGiKara/UI/TopBar.swift`。
- 将整片白色材质遮罩改为分段可读性渐变，保留中段银河与角色的可见度。
- 对概念图做安全纵向裁切：显示约 `y=80...280` 的条带，避开图中下部烘焙的示意播放器控件。
- 背景图提高到 `0.90` 可见度，并保持资源缺失时回退到纯背景。
- 未修改播放、导出、菜单、AppState、时间线或其他页面。

## 验证

- `./Scripts/build.sh build`：通过。
- `./Scripts/build.sh test`：182 tests / 22 suites 全部通过。
- `./Scripts/build.sh bundle`：通过，已重建 `dist/MaGi Kara.app`。
- 最新截图：
  - `TestAssets/header-rd/t2-topbar-crop.png`
  - `TestAssets/header-rd/t2-topbar-fullwindow.png`
  - `TestAssets/header-rd/t2-topbar-narrow-simulated-1120.png`

## 结果

- 银河和星点明显可见。
- 淮水蕾在顶部右侧可辨认，未遮挡实际播放控件和导出按钮。
- 截图中未发现概念图内烘焙的假控件或假文字。
- 截图中未出现地图、海岸线、指南针或地点标记。
- 资源缺失回退路径仍保留并能通过构建。

## 尚未处理

- 玻璃容器圆角与控件渐变属于后续 T3。
- 真正的窄屏响应式布局属于后续 T5；当前窄屏文件是模拟验收截图，不代表已改窗口响应式逻辑。
