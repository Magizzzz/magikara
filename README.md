# MaGi Kara

macOS 上的日语卡拉 OK 字幕工具：导入 MV 或歌曲，粘贴日语歌词，一键生成带假名、逐字扫色的卡拉 OK 字幕，直接导出成片。

- AI 逐字对轨：人声分离 + 日语歌唱对轨模型，歌词自动对到歌声上
- 自动标注假名、逐字扫色、上下两行交替显示、开头倒计时
- 时间线精修：拖动、修剪、走轨、吸附、撤销
- 导出 MP4（字幕烧录）、ASS、LRC、SRT

## 下载安装

> 需要 **Apple 芯片（M1 及以后）的 Mac，macOS 14 或更新**。Intel 芯片的 Mac 不支持。

1. 到 [Releases](../../releases/latest) 下载 `MaGi-Kara-x.x.x.dmg`，打开后把 **MaGi Kara** 拖进「应用程序」。
2. **第一次打开会被系统拦下**（作者没有付费买 Apple 签名，不是病毒），放行一次即可：
   - 双击打开 → 弹窗点「完成」→ 打开 **系统设置 → 隐私与安全性**，拉到最下面点 **「仍要打开」**，输入开机密码；
   - 如果提示「已损坏，无法打开」，打开「终端」运行下面这行，再双击打开：
     ```bash
     sudo xattr -dr com.apple.quarantine "/Applications/MaGi Kara.app"
     ```
3. 打开后会弹出 **「运行环境配置单」**，勾选许可、点 **「一键安装」**，等它跑完就能用了。

## 运行环境配置单

App 本体只有约 50 MB，AI 模型在第一次打开时按需下载：

| 组件 | 大小 | 用途 |
| --- | --- | --- |
| 视频导出组件（ffmpeg） | 内置 | 把字幕烧录进 MP4 |
| 人声分离模型（MDX23C） | 42 MB | 分离伴奏 / 人声 |
| 对轨运行环境（Python 3.12 + PyTorch） | 约 200 MB | 运行对轨模型的独立环境，不影响系统 |
| 日语歌唱对轨模型（Yohane） | 1.26 GB | 把歌词逐字对到歌声上 |

- 合计下载约 1.5 GB，一般 3–15 分钟。
- **下载源默认「自动选择」**：连不上 Hugging Face / PyPI / GitHub 时自动改用国内镜像（hf-mirror、阿里云 PyPI、npmmirror）。
- 支持断点续传：断网、取消、退出都没关系，下次接着下。
- 暂时不想装可以点「稍后再说」，之后在菜单栏 **MaGi Kara → 运行环境配置单…** 随时打开。
- 没装对轨模型时，App 会退回系统语音识别对轨，能用但精度较低。
- 卸载：删除 App，再删除 `~/Library/Application Support/MaGiKara` 和 `~/Library/Caches/MaGiKara`。

## 使用

导入 MV / 歌曲 → 粘贴日语歌词（或「在线搜歌词」）→ 点 **「生成 AI 歌词」** → 在时间线上检查、微调 → 右上角 **导出**。

## 许可说明

- 日语歌唱对轨模型 [Yohane（NextFire/mms-300m-ForcedAligner-karaoke-ja-Latn）](https://huggingface.co/NextFire/mms-300m-ForcedAligner-karaoke-ja-Latn) 采用 **CC BY-NC-SA 4.0**，**仅限非商业使用**，因此本 App 也只用于个人、非商业用途。
- 内置的 ffmpeg 为 GPL 版本，uv 为 MIT / Apache-2.0。完整第三方说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 从源码构建

只需要 Command Line Tools（不需要 Xcode）：

```bash
./Scripts/build.sh test     # 单元测试
./Scripts/build.sh bundle   # 生成 dist/MaGi Kara.app
./Scripts/build.sh dmg      # 生成给别人用的安装包 dist/MaGi-Kara-<版本>.dmg（内置 ffmpeg 与 uv）
```

开发与实现说明见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
