# Third-party notices / 第三方声明

本项目 `MaGiKaraKit` 的本地人声分离后端（`Sources/MaGiKaraKit/Separation/`）包含
从第三方 MIT 代码改编的算法，并会在首次使用时下载第三方 MIT 模型。这些内容都
**不随本仓库分发**，各自保留其原始许可。

---

## 1. arraypress/swift-vocal-isolation — MIT

`Sources/MaGiKaraKit/Separation/VocalSeparationSTFT.swift`（STFT / ISTFT，
`n_fft = 8192`、`hop = 1024`、periodic Hann、`center = true`、丢弃 Nyquist）
改编自：

- Repository: https://github.com/arraypress/swift-vocal-isolation
- 原文件: `Sources/VocalIsolation/VocalSTFT.swift`
- Copyright (c) 2026 David Sherlock (ArrayPress)
- License: MIT

完整许可证文本见 [`swift-vocal-isolation-MIT.txt`](swift-vocal-isolation-MIT.txt)。

> 说明：本仓库只抽取了兼容 AVFoundation / CoreML / Accelerate 的算法代码，
> 没有添加该 package 依赖，也没有提升 deployment target（保持 macOS 14 / Swift 5）。

---

## 2. huggingsounds/nubeaudio-mdx — MIT（模型权重）

分离所用声源模型：

- Repository: https://huggingface.co/huggingsounds/nubeaudio-mdx
- 固定 revision: `a133c157760773700ecbdaadcba755d7e94739c3`
- 文件: `mdx23c_instvoc_hq.mlpackage.zip`（约 41,797,322 字节，Int8 Core ML）
- License: MIT
- 架构: KUIELab TFC-TDF v3 / MDX23C
- 原始 checkpoint: `MDX23C-8KFFT-InstVoc_HQ.ckpt`（ZFTurbo 训练，UVR 分发）
- CoreML 打包: NubeAudio

模型权重由用户设备在首次运行 `VocalSeparator.ensureModel` 时按固定 revision
下载并校验（长度 + SHA-256），**不随本仓库提交**。

---

## 3. FFmpeg — GPL-3.0-or-later（随安装包内置的可执行文件）

`Scripts/build.sh bundle` 会把一个静态编译、带 libass 的 `ffmpeg` 可执行文件复制到
`MaGi Kara.app/Contents/Resources/bin/ffmpeg`，App 以独立子进程调用它烧录字幕，
未与 App 代码链接。

- 来源：ffmpeg-static（https://github.com/eugeneware/ffmpeg-static ，release `b6.1.1`，FFmpeg 6.0，`--enable-gpl`）
- FFmpeg 源代码：https://ffmpeg.org/download.html
- License: GPL-3.0-or-later（含 libx264 / libx265 / libass 等 GPL 组件）

## 4. uv — MIT OR Apache-2.0（随安装包内置的可执行文件）

`MaGi Kara.app/Contents/Resources/bin/uv`，运行环境配置单用它下载 Python 3.12
并按 `Sources/MaGiKaraKit/Resources/local_forced_aligner/requirements.txt` 安装对轨依赖。

- Repository: https://github.com/astral-sh/uv
- License: MIT OR Apache-2.0

## 5. NextFire/mms-300m-ForcedAligner-karaoke-ja-Latn（Yohane）— CC BY-NC-SA 4.0（模型权重）

日语歌唱 CTC 对轨模型，由运行环境配置单在用户确认许可后按固定 revision
`2ab2b5f46539ee284703c281f286b01d2410ee12` 下载并校验（长度 + SHA-256），**不随本仓库或安装包分发**。

- Repository: https://huggingface.co/NextFire/mms-300m-ForcedAligner-karaoke-ja-Latn
- License: CC BY-NC-SA 4.0 —— **仅限非商业使用**；相关成果需以相同方式共享。

## 6. Python 依赖（PyTorch、transformers、pykakasi 等）

由配置单从 PyPI（或镜像）安装到用户目录下的独立虚拟环境，不随安装包分发；
完整版本清单见 `requirements.txt`，各自遵循其许可证。
