#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR="${ROOT_DIR}/build"
TARGET_PLATFORM=${TARGET_PLATFORM:-windows}
TARGET_ARCH=${TARGET_ARCH:-x64}
FFMPEG_ARCH=${FFMPEG_ARCH:-}
ARTIFACT_BASENAME=${ARTIFACT_BASENAME:-javm-ffmpeg-${TARGET_PLATFORM}-${TARGET_ARCH}}
SOURCE_DIR="${BUILD_DIR}/FFmpeg-${TARGET_PLATFORM}-${TARGET_ARCH}"
ARTIFACT_DIR="${ROOT_DIR}/dist/${ARTIFACT_BASENAME}"
BUILD_INFO_DIR="${ARTIFACT_DIR}/build-info"
CONFIGURE_TARGET_OS=${CONFIGURE_TARGET_OS:-mingw32}
FFMPEG_BIN_NAME=${FFMPEG_BIN_NAME:-ffmpeg.exe}
EXTRA_LDEXEFLAGS=${EXTRA_LDEXEFLAGS:-}
HOST_FFMPEG=${HOST_FFMPEG:-$(command -v ffmpeg || true)}
FFMPEG_VERSION=${FFMPEG_VERSION:-n8.0.1}

log() {
    printf '[build] %s\n' "$*"
}

fail() {
    printf '[build] error: %s\n' "$*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

resolve_ffmpeg_arch() {
    if [ -n "${FFMPEG_ARCH}" ]; then
        return
    fi

    case "${TARGET_ARCH}" in
        x64|x86_64)
            FFMPEG_ARCH=x86_64
            ;;
        arm64|aarch64)
            FFMPEG_ARCH=aarch64
            ;;
        *)
            fail "unsupported TARGET_ARCH for Windows build: ${TARGET_ARCH}"
            ;;
    esac
}

configure_linker_flags() {
    if [ -n "${EXTRA_LDEXEFLAGS}" ]; then
        return
    fi

    case "${TARGET_ARCH}" in
        x64|x86_64)
            EXTRA_LDEXEFLAGS='-static -static-libgcc'
            ;;
        arm64|aarch64)
            EXTRA_LDEXEFLAGS='-static'
            ;;
        *)
            fail "unsupported TARGET_ARCH for Windows linker flags: ${TARGET_ARCH}"
            ;;
    esac
}

clean_dirs() {
    rm -rf "${SOURCE_DIR}" "${ARTIFACT_DIR}"
    mkdir -p "${BUILD_DIR}" "${ARTIFACT_DIR}/bin" "${BUILD_INFO_DIR}"
}

clone_source() {
    log "cloning FFmpeg ${FFMPEG_VERSION}"
    git clone --depth 1 --branch "${FFMPEG_VERSION}" https://github.com/FFmpeg/FFmpeg.git "${SOURCE_DIR}"
}

collect_video_decoders() {
    local -n result_ref=$1
    local -a discovered_decoders=()
    local decoder

    [ -n "${HOST_FFMPEG}" ] || fail "HOST_FFMPEG is not available; install a host ffmpeg package for decoder discovery"

    mapfile -t discovered_decoders < <(
        "${HOST_FFMPEG}" -hide_banner -decoders \
        | awk '$1 ~ /^V/ && $2 ~ /^[A-Za-z0-9_]+$/ && $2 != "=" { print $2 }' \
        | sort -u
    )

    for decoder in "${discovered_decoders[@]}"; do
        case "${decoder}" in
            lib*|*_amf|*_crystalhd|*_cuvid|*_mediacodec|*_mmal|*_qsv|*_v4l2m2m|*_videotoolbox)
                continue
                ;;
        esac

        result_ref+=("${decoder}")
    done

    [ ${#result_ref[@]} -gt 0 ] || fail "failed to discover video decoders from host ffmpeg"
}

collect_video_parsers() {
    local -n result_ref=$1
    local -a all_parsers=()
    local -a video_codec_ids=()
    local -a source_files=()
    local parser
    local config_key
    local makefile_key
    local makefile_block
    local codec_id
    local source_file
    local has_video_codec
    local -A video_codec_lookup=()

    collect_configure_list parsers all_parsers

    mapfile -t video_codec_ids < <(
        awk '
            BEGIN { RS = "}," }
            /\.id[[:space:]]*=[[:space:]]*AV_CODEC_ID_[A-Z0-9_]+/ && /\.type[[:space:]]*=[[:space:]]*AVMEDIA_TYPE_VIDEO/ {
                if (match($0, /\.id[[:space:]]*=[[:space:]]*(AV_CODEC_ID_[A-Z0-9_]+)/, match_result)) {
                    print match_result[1]
                }
            }
        ' "${SOURCE_DIR}/libavcodec/codec_desc.c" \
        | sort -u
    )

    [ ${#video_codec_ids[@]} -gt 0 ] || fail "failed to discover video codec ids from FFmpeg source"

    for codec_id in "${video_codec_ids[@]}"; do
        video_codec_lookup["${codec_id}"]=1
    done

    for parser in "${all_parsers[@]}"; do
        config_key=$(printf '%s' "${parser}" | tr '[:lower:]' '[:upper:]')_PARSER
        makefile_key="OBJS-\$(CONFIG_${config_key})"
        makefile_block=$(awk -v key="${makefile_key}" '
            collecting {
                print
                if ($0 !~ /\\[[:space:]]*$/) {
                    exit
                }
                next
            }
            index($0, key) == 1 {
                collecting = 1
                print
                if ($0 !~ /\\[[:space:]]*$/) {
                    exit
                }
            }
        ' "${SOURCE_DIR}/libavcodec/Makefile")

        source_files=()
        if [ -n "${makefile_block}" ]; then
            while IFS= read -r source_file; do
                [ -n "${source_file}" ] || continue
                if [ -f "${SOURCE_DIR}/libavcodec/${source_file}" ]; then
                    source_files+=("${SOURCE_DIR}/libavcodec/${source_file}")
                fi
            done < <(
                printf '%s\n' "${makefile_block}" \
                | tr '\\' ' ' \
                | tr '[:space:]' '\n' \
                | grep -E '\.o$' \
                | sed 's/\.o$/.c/' \
                | sort -u
            )
        fi

        if [ ${#source_files[@]} -eq 0 ]; then
            log "could not resolve sources for parser ${parser}; enabling it conservatively"
            result_ref+=("${parser}")
            continue
        fi

        has_video_codec=0
        while IFS= read -r codec_id; do
            if [ -n "${video_codec_lookup["${codec_id}"]+x}" ]; then
                has_video_codec=1
                break
            fi
        done < <(
            grep -hoE 'AV_CODEC_ID_[A-Z0-9_]+' "${source_files[@]}" \
            | grep -v '^AV_CODEC_ID_NONE$' \
            | sort -u
        )

        if [ ${has_video_codec} -eq 1 ]; then
            result_ref+=("${parser}")
        fi
    done

    [ ${#result_ref[@]} -gt 0 ] || fail "failed to discover video parsers from FFmpeg source"
}

collect_configure_list() {
    local list_name=$1
    local -n result_ref=$2

    mapfile -t result_ref < <(
        cd "${SOURCE_DIR}"
        ./configure "--list-${list_name}" \
        | tr ' ' '\n' \
        | grep -E '^[A-Za-z0-9_]+$' \
        | sort -u
    )

    [ ${#result_ref[@]} -gt 0 ] || fail "failed to collect configure list: ${list_name}"
}

append_enable_flags() {
    local prefix=$1
    shift
    local item

    for item in "$@"; do
        CONFIGURE_FLAGS+=("--enable-${prefix}=${item}")
    done
}

write_component_report() {
    local output_file=$1
    shift

    printf '%s\n' "$@" > "${output_file}"
}

write_build_metadata() {
    cat > "${BUILD_INFO_DIR}/target-info.txt" <<EOF
platform=${TARGET_PLATFORM}
arch=${TARGET_ARCH}
ffmpeg_arch=${FFMPEG_ARCH}
ffmpeg_version=${FFMPEG_VERSION}
artifact_basename=${ARTIFACT_BASENAME}
configure_target_os=${CONFIGURE_TARGET_OS}
EOF
}

configure_ffmpeg() {
    local -a video_decoders=()
    local -a demuxers=()
    local -a video_parsers=()
    local -a common_video_bsfs=(
        av1_frame_merge
        av1_frame_split
        extract_extradata
        h264_mp4toannexb
        hevc_mp4toannexb
        mjpeg2jpeg
        mpeg4_unpack_bframes
        vc1_asftorcv
        vp9_superframe
        vp9_superframe_split
    )

    collect_video_decoders video_decoders
    collect_configure_list demuxers demuxers
    collect_video_parsers video_parsers

    write_component_report "${BUILD_INFO_DIR}/video-decoders.txt" "${video_decoders[@]}"
    write_component_report "${BUILD_INFO_DIR}/demuxers.txt" "${demuxers[@]}"
    write_component_report "${BUILD_INFO_DIR}/video-parsers.txt" "${video_parsers[@]}"

    CONFIGURE_FLAGS=(
        "--prefix=${ARTIFACT_DIR}"
        "--arch=${FFMPEG_ARCH}"
        "--target-os=${CONFIGURE_TARGET_OS}"
        --pkg-config-flags=--static
        --extra-cflags=-O2\ -pipe
        --disable-autodetect
        --disable-debug
        --disable-doc
        --disable-network
        --disable-hwaccels
        --disable-swresample
        --disable-avdevice
        --disable-ffplay
        --disable-ffprobe
        --disable-programs
        --enable-ffmpeg
        --enable-small
        --disable-shared
        --enable-static
        --disable-everything
        --enable-avcodec
        --enable-avformat
        --enable-avutil
        --enable-swscale
        --enable-avfilter
        --enable-protocol=file
        --enable-muxer=image2
        --enable-encoder=mjpeg
        --enable-filter=buffer
        --enable-filter=buffersink
        --enable-filter=format
        --enable-filter=fps
        --enable-filter=scale
        --enable-filter=select
    )

    if [ -n "${EXTRA_LDEXEFLAGS}" ]; then
        CONFIGURE_FLAGS+=("--extra-ldexeflags=${EXTRA_LDEXEFLAGS}")
    fi

    append_enable_flags decoder "${video_decoders[@]}"
    append_enable_flags demuxer "${demuxers[@]}"
    append_enable_flags parser "${video_parsers[@]}"
    append_enable_flags bsf "${common_video_bsfs[@]}"

    printf '%s\n' "${CONFIGURE_FLAGS[@]}" > "${BUILD_INFO_DIR}/configure-flags.txt"
    write_build_metadata

    log "configuring FFmpeg"
    (
        cd "${SOURCE_DIR}"
        if ! ./configure "${CONFIGURE_FLAGS[@]}"; then
            if [ -f ffbuild/config.log ]; then
                printf '\n[build] configure failed; ffbuild/config.log tail follows\n' >&2
                tail -n 120 ffbuild/config.log >&2 || true
            fi
            exit 1
        fi
    )
}

build_ffmpeg() {
    log "building FFmpeg"
    (
        cd "${SOURCE_DIR}"
        make -j"$(nproc)"
        make install
    )
}

finalize_artifact() {
    local license_file=

    if [ -f "${SOURCE_DIR}/LICENSE.md" ]; then
        license_file="${SOURCE_DIR}/LICENSE.md"
    elif [ -f "${SOURCE_DIR}/COPYING.LGPLv2.1" ]; then
        license_file="${SOURCE_DIR}/COPYING.LGPLv2.1"
    fi

    [ -x "${ARTIFACT_DIR}/bin/${FFMPEG_BIN_NAME}" ] || fail "${FFMPEG_BIN_NAME} was not produced"

    strip "${ARTIFACT_DIR}/bin/${FFMPEG_BIN_NAME}" || true
    cp "${SOURCE_DIR}/README.md" "${BUILD_INFO_DIR}/ffmpeg-upstream-readme.md"

    if [ -n "${license_file}" ]; then
        cp "${license_file}" "${ARTIFACT_DIR}/LICENSE.txt"
    fi

    "${ARTIFACT_DIR}/bin/${FFMPEG_BIN_NAME}" -hide_banner -buildconf > "${BUILD_INFO_DIR}/buildconf.txt"
    "${ARTIFACT_DIR}/bin/${FFMPEG_BIN_NAME}" -hide_banner -version > "${BUILD_INFO_DIR}/version.txt"
}

main() {
    resolve_ffmpeg_arch
    configure_linker_flags

    require_tool git
    require_tool make
    require_tool awk
    require_tool grep
    require_tool sort
    require_tool strip

    clean_dirs
    clone_source
    configure_ffmpeg
    build_ffmpeg
    finalize_artifact

    log "artifact ready at ${ARTIFACT_DIR}"
}

main "$@"
