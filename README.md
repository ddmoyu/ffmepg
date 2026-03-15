# Windows Static FFmpeg Build

这个仓库用于通过 GitHub Actions 构建一个面向 Windows x86_64 的精简版 FFmpeg。

目标很明确：

- 从本地视频文件抽帧。
- 只输出 JPG。
- 尽量保留 FFmpeg 原生内建的视频输入能力。
- 关闭网络、硬件加速、音频转码链路和无关程序。

## 当前实现

工作流入口在 [.github/workflows/build-windows-ffmpeg.yml](.github/workflows/build-windows-ffmpeg.yml)。

构建脚本在 [scripts/build-ffmpeg-windows.sh](scripts/build-ffmpeg-windows.sh)。

GitHub Actions 使用 MSYS2/MinGW 在 Windows runner 上直接编译 FFmpeg 官方源码，输出产物为：

- dist/ffmpeg-windows-x86_64/bin/ffmpeg.exe
- dist/ffmpeg-windows-x86_64/LICENSE.txt
- dist/ffmpeg-windows-x86_64/build-info/

## 裁剪策略

实现不是直接执行 nldzsz/ffmpeg-build-scripts，而是参考它从 disable-all 开始逐项启用模块的思路，再改造成更适合 GitHub Actions 的 Windows CI 流程。

保留内容：

- ffmpeg.exe
- libavcodec、libavformat、libavutil、libswscale、libavfilter
- 本地文件协议
- JPG 输出所需的 image2 muxer 和 mjpeg encoder
- 全量 demuxer
- 仅视频 parser
- 通过宿主 ffmpeg 自动发现并启用的原生视频 decoder，排除明显的硬件和外部库包装 decoder
- 通过 FFmpeg 上游源码自动识别并启用的视频 parser
- 抽帧常用的 scale、fps、select、format 相关滤镜

关闭内容：

- 网络协议
- 硬件加速
- ffplay、ffprobe
- avdevice、postproc、swresample
- 所有非 mjpeg 编码器
- 音频编码功能
- 外部三方编解码库的自动探测

## 关于“支持所有视频格式”

这里的定义是：尽量保留 FFmpeg 原生内建的视频输入能力，包括常见和冷门的视频容器、视频解码器与必要 parser。

这不等于启用所有外部库支持的格式。像某些依赖外部库的解码能力，如果 FFmpeg 默认需要额外第三方库，这个仓库当前不会引入，因为那会明显增加体积、构建时间和许可证复杂度。

## 使用方式

触发 GitHub Actions 后，下载构建产物中的 ffmpeg.exe。

单帧导出示例：

```powershell
ffmpeg.exe -i input.mp4 -frames:v 1 output.jpg
```

按帧率批量导出示例：

```powershell
ffmpeg.exe -i input.mp4 -vf "fps=1" frames/frame-%04d.jpg
```

按抽样并缩放导出示例：

```powershell
ffmpeg.exe -i input.mp4 -vf "fps=2,scale=320:-1" frames/frame-%04d.jpg
```

## 验证项

工作流会自动检查：

- 没有 http、https、rtmp、rtsp、tcp、udp 等网络协议。
- 没有硬件加速实现。
- 保留 image2 muxer 和 mjpeg encoder。
- 常见视频解码器仍然存在，例如 h264、hevc、vp9、av1。
- 能实际把测试视频抽帧输出成 JPG。

## 已知边界

- 当前仅覆盖 Windows x86_64。
- 当前产物目标是尽量静态，但 Windows 系统运行时依赖不一定能完全归零；这取决于 runner 工具链和底层 CRT 链接方式。
- 为了尽量保留视频输入兼容性，demuxer 和 parser 没有做更激进的白名单裁剪。
