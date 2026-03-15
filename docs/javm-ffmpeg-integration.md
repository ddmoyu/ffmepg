# JAVM FFmpeg Integration Guide

这份文档不是给人读故事的，而是给 javm 仓库里的 AI 或自动化脚本直接执行的集成契约。

## 目标

当 javm 需要 FFmpeg 时：

- 不要在 javm 仓库内编译 FFmpeg。
- 直接下载这个仓库发布的预编译 `javm-ffmpeg` 资产。
- 按当前 runner 的平台和架构选择正确 zip。
- 解压后直接使用其中的 `ffmpeg` 可执行文件。

## 资产来源

假设以下环境变量可用：

```text
JAVM_FFMPEG_REPO=<owner>/<repo>
JAVM_FFMPEG_TAG=<optional-release-tag>
```

说明：

- `JAVM_FFMPEG_REPO` 指向这个 FFmpeg 构建仓库。
- `JAVM_FFMPEG_TAG` 可选。如果指定，就下载这个明确 tag。
- 如果没有指定 `JAVM_FFMPEG_TAG`，则查询最新一个 `javm-ffmpeg-*` 预发布 Release。

## 目标映射

按 GitHub Actions runner 选择资产：

| Runner OS | Runner Arch | Asset fragment |
| --- | --- | --- |
| Linux | X64 | `linux-x64` |
| Linux | ARM64 | `linux-arm64` |
| macOS | X64 | `macos-x64` |
| macOS | ARM64 | `macos-arm64` |
| Windows | X64 | `windows-x64` |
| Windows | ARM64 | `windows-arm64` |

最终匹配模式：

```text
javm-ffmpeg-<platform>-<arch>-*.zip
```

## 解压后的目录结构

zip 内部根目录固定为：

```text
javm-ffmpeg-<platform>-<arch>
```

二进制路径：

- Linux/macOS：`javm-ffmpeg-<platform>-<arch>/bin/ffmpeg`
- Windows：`javm-ffmpeg-<platform>-<arch>/bin/ffmpeg.exe`

## 推荐下载流程

AI 或自动化脚本应按以下顺序执行：

1. 识别当前 runner 的 OS 和 CPU 架构。
2. 映射到 `linux-x64`、`linux-arm64`、`macos-x64`、`macos-arm64`、`windows-x64`、`windows-arm64` 之一。
3. 如果提供了 `JAVM_FFMPEG_TAG`，直接下载该 tag 对应 Release 资产。
4. 如果没有提供 `JAVM_FFMPEG_TAG`，查询最新一个 `javm-ffmpeg-*` Release。
5. 下载匹配 `javm-ffmpeg-<platform>-<arch>-*.zip` 的资产。
6. 解压到项目缓存目录，例如 `.tools/ffmpeg/<release-tag>/`。
7. 使用其中的 `bin/ffmpeg` 或 `bin/ffmpeg.exe`。

## 推荐 GitHub Actions 片段

Linux 或 macOS：

```yaml
- name: Install FFmpeg from javm-ffmpeg release
  shell: bash
  env:
    JAVM_FFMPEG_REPO: your-org/ffmepg
    JAVM_FFMPEG_TAG: ""
    GH_TOKEN: ${{ github.token }}
  run: |
    set -euo pipefail

    case "${RUNNER_OS}-${RUNNER_ARCH}" in
      Linux-X64) target="linux-x64" ;;
      Linux-ARM64) target="linux-arm64" ;;
      macOS-X64) target="macos-x64" ;;
      macOS-ARM64) target="macos-arm64" ;;
      *)
        echo "unsupported runner: ${RUNNER_OS}-${RUNNER_ARCH}" >&2
        exit 1
        ;;
    esac

    if [ -n "${JAVM_FFMPEG_TAG}" ]; then
      release_tag="${JAVM_FFMPEG_TAG}"
    else
      release_tag="$(gh release list --repo "${JAVM_FFMPEG_REPO}" --limit 20 --json tagName,isPrerelease --jq '.[] | select(.isPrerelease == true and (.tagName | startswith("javm-ffmpeg-"))) | .tagName' | head -n 1)"
    fi

    test -n "${release_tag}"

    mkdir -p .tools/ffmpeg/download .tools/ffmpeg/extract
    gh release download "${release_tag}" \
      --repo "${JAVM_FFMPEG_REPO}" \
      --pattern "javm-ffmpeg-${target}-*.zip" \
      --dir .tools/ffmpeg/download

    unzip -q .tools/ffmpeg/download/*.zip -d .tools/ffmpeg/extract

    ffmpeg_bin="$(find .tools/ffmpeg/extract -path '*/bin/ffmpeg' | head -n 1)"
    test -x "${ffmpeg_bin}"

    echo "JAVM_FFMPEG_BIN=${ffmpeg_bin}" >> "${GITHUB_ENV}"
```

Windows：

```yaml
- name: Install FFmpeg from javm-ffmpeg release
  shell: powershell
  env:
    JAVM_FFMPEG_REPO: your-org/ffmepg
    JAVM_FFMPEG_TAG: ""
    GH_TOKEN: ${{ github.token }}
  run: |
    switch ("$env:RUNNER_OS-$env:RUNNER_ARCH") {
      "Windows-X64" { $target = "windows-x64" }
      "Windows-ARM64" { $target = "windows-arm64" }
      default { throw "unsupported runner: $env:RUNNER_OS-$env:RUNNER_ARCH" }
    }

    if ($env:JAVM_FFMPEG_TAG) {
      $releaseTag = $env:JAVM_FFMPEG_TAG
    } else {
      $releaseTag = gh release list --repo $env:JAVM_FFMPEG_REPO --limit 20 --json tagName,isPrerelease --jq '.[] | select(.isPrerelease == true and (.tagName | startswith("javm-ffmpeg-"))) | .tagName' | Select-Object -First 1
    }

    if (-not $releaseTag) {
      throw "unable to resolve javm-ffmpeg release tag"
    }

    New-Item -ItemType Directory -Force -Path .tools/ffmpeg/download | Out-Null
    New-Item -ItemType Directory -Force -Path .tools/ffmpeg/extract | Out-Null

    gh release download $releaseTag `
      --repo $env:JAVM_FFMPEG_REPO `
      --pattern "javm-ffmpeg-$target-*.zip" `
      --dir .tools/ffmpeg/download

    $zip = Get-ChildItem .tools/ffmpeg/download/*.zip | Select-Object -First 1
    Expand-Archive -Path $zip.FullName -DestinationPath .tools/ffmpeg/extract -Force

    $ffmpeg = Get-ChildItem .tools/ffmpeg/extract -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $ffmpeg) {
      throw "ffmpeg.exe not found after extraction"
    }

    "JAVM_FFMPEG_BIN=$($ffmpeg.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
```

## AI 执行约束

如果你是 javm 仓库里的 AI 代理，默认遵循以下规则：

1. 优先下载预编译 `javm-ffmpeg`，不要本地编译 FFmpeg。
2. 优先使用明确指定的 `JAVM_FFMPEG_TAG`。
3. 没有显式 tag 时，只选择 tag 以 `javm-ffmpeg-` 开头的最新 Release。
4. 必须按当前 runner 的 OS/Arch 精确匹配资产名。
5. 解压后，把最终可执行文件路径写入 `JAVM_FFMPEG_BIN`。
6. 运行前可执行一次 `"$JAVM_FFMPEG_BIN" -version` 做快速确认。

## 可选增强

如果 javm 需要更稳定地锁定资产，可以额外读取 Release 中的 `release-manifest.json`，而不是只靠文件名匹配。