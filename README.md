# javm-ffmpeg Build Repository

这个仓库用于通过 GitHub Actions 构建一个给 javm 直接消费的精简版 FFmpeg 发布源。

目标很明确：

- 让 javm 直接复用这里产出的 FFmpeg，而不是在 javm 仓库里重复编译 FFmpeg。
- 覆盖 javm 常见运行环境：Linux、macOS、Windows，x64 和 arm64。
- 保留本地视频输入与抽帧所需的原生 FFmpeg 能力。
- 关闭网络、硬件加速、音频转码链路和无关程序，降低体积与行为复杂度。

## 当前实现

工作流入口在 [.github/workflows/build-windows-ffmpeg.yml](.github/workflows/build-windows-ffmpeg.yml)。

构建脚本：

- [scripts/build-ffmpeg-unix.sh](scripts/build-ffmpeg-unix.sh)
- [scripts/build-ffmpeg-windows.sh](scripts/build-ffmpeg-windows.sh)
- [scripts/smoke-test-ffmpeg.sh](scripts/smoke-test-ffmpeg.sh)

工作流会构建以下目标：

- Linux x64
- Linux arm64
- macOS x64
- macOS arm64
- Windows x64
- Windows arm64

每次成功运行都会生成一个带 FFmpeg 版本号和 UTC 时间戳的 Release，并上传：

- 按平台与架构拆分的 zip 资产
- `release-manifest.json`

## 资产命名规则

Release tag：

```text
javm-ffmpeg-<ffmpeg-version>-<utc-timestamp>
```

示例：

```text
javm-ffmpeg-n8.0.1-20260315-142530
```

Release 资产：

```text
javm-ffmpeg-<platform>-<arch>-<ffmpeg-version>-<utc-timestamp>.zip
```

示例：

```text
javm-ffmpeg-windows-x64-n8.0.1-20260315-142530.zip
javm-ffmpeg-macos-arm64-n8.0.1-20260315-142530.zip
javm-ffmpeg-linux-arm64-n8.0.1-20260315-142530.zip
```

压缩包内目录名固定为：

```text
javm-ffmpeg-<platform>-<arch>
```

## 裁剪策略

保留内容：

- `ffmpeg` 或 `ffmpeg.exe`
- `libavcodec`、`libavformat`、`libavutil`、`libswscale`、`libavfilter`
- 本地文件协议
- JPG 输出所需的 `image2` muxer 和 `mjpeg` encoder
- 全量 demuxer
- 仅视频 parser
- 通过宿主 ffmpeg 自动发现并启用的原生视频 decoder，排除明显的硬件和外部库包装 decoder
- 通过 FFmpeg 上游源码自动识别并启用的视频 parser
- 抽帧常用的 `scale`、`fps`、`select`、`format` 相关滤镜

关闭内容：

- 网络协议
- 硬件加速
- `ffplay`、`ffprobe`
- `avdevice`、`swresample`
- 所有非 `mjpeg` 编码器
- 音频编码功能
- 外部三方编解码库的自动探测

## 验证项

每个构建目标都会执行烟测，检查：

- 没有 `http`、`https`、`rtmp`、`rtsp`、`tcp`、`udp` 等网络协议
- 没有硬件加速实现
- 保留 `image2` muxer 和 `mjpeg` encoder
- 常见视频解码器仍然存在，例如 `h264`、`hevc`、`vp9`、`av1`
- 能实际把测试视频抽帧输出成 JPG

## javm 集成

javm 不应该在自己的 GitHub Actions 里重新编译 FFmpeg，而应该直接下载这个仓库发布的预编译资产。

专门给 javm 或 AI 使用的集成文档见：

- [docs/javm-ffmpeg-integration.md](docs/javm-ffmpeg-integration.md)

## 已知边界

- 当前是跨平台原生构建，不是用单一交叉编译工具链一次产出所有平台。
- Windows arm64 构建依赖 GitHub Hosted `windows-11-arm` runner 和 MSYS2 `CLANGARM64` 环境可用性。
- 为了尽量保留视频输入兼容性，demuxer 和 parser 仍然没有做激进白名单裁剪。

