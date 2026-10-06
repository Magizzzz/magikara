# 顶部 UI RD · T3 玻璃层与控件报告

日期：2026-09-22

## 改动

- 仅修改 `Sources/MaGiKara/UI/TopBar.swift`。
- 将 T2 的可读性渐变收进 22pt 圆角玻璃容器。
- 增加轻微白色描边和紫调阴影，保持中段银河/角色的透出。
- 播放进度条改为低饱和紫蓝渐变；音量滑块保持原有简洁样式。
- 播放按钮仅做轻微尺寸、浅色渐变和阴影强化，没有改变交互。

## 验证

- `./Scripts/build.sh build`：通过。
- `./Scripts/build.sh test`：182 tests / 22 suites 全部通过。
- `./Scripts/build.sh bundle`：通过，已重建 `dist/MaGi Kara.app`。

## 未验证

- 当前截图脚本在本机启动窗口时仍有环境/脚本问题，T3 尚未生成可靠的新截图。
- T2 的截图已验证角色、银河和控件不冲突；T3 的圆角材质叠加效果仍需下一次可视 smoke check 确认。
