#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR="${ROOT_DIR}/build"
SOURCE_DIR="${BUILD_DIR}/FFmpeg"
ARTIFACT_DIR="${ROOT_DIR}/dist/ffmpeg-windows-x86_64"
BUILD_INFO_DIR="${ARTIFACT_DIR}/build-info"
HOST_FFMPEG=${HOST_FFMPEG:-$(command -v ffmpeg || true)}
FFMPEG_VERSION=${FFMPEG_VERSION:-n7.1.1}

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
        | awk '/^[[:space:]]V/ { print $2 }' \
        | sort -u
    )

    for decoder in "${discovered_decoders[@]}"; do
        case "${decoder}" in
            lib*|*_crystalhd|*_cuvid|*_mmal|*_mediacodec|*_qsv|*_v4l2m2m)
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
        --arch=x86_64
        --target-os=mingw32
        --pkg-config-flags=--static
        --extra-cflags=-O2\ -pipe
        --extra-ldexeflags=-static\ -static-libgcc
        --disable-autodetect
        --disable-debug
        --disable-doc
        --disable-postproc
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

    append_enable_flags decoder "${video_decoders[@]}"
    append_enable_flags demuxer "${demuxers[@]}"
    append_enable_flags parser "${video_parsers[@]}"
    append_enable_flags bsf "${common_video_bsfs[@]}"

    printf '%s\n' "${CONFIGURE_FLAGS[@]}" > "${BUILD_INFO_DIR}/configure-flags.txt"

    log "configuring FFmpeg"
    (
        cd "${SOURCE_DIR}"
        ./configure "${CONFIGURE_FLAGS[@]}"
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

    [ -x "${ARTIFACT_DIR}/bin/ffmpeg.exe" ] || fail "ffmpeg.exe was not produced"

    strip "${ARTIFACT_DIR}/bin/ffmpeg.exe" || true
    cp "${SOURCE_DIR}/README.md" "${BUILD_INFO_DIR}/ffmpeg-upstream-readme.md"

    if [ -n "${license_file}" ]; then
        cp "${license_file}" "${ARTIFACT_DIR}/LICENSE.txt"
    fi

    "${ARTIFACT_DIR}/bin/ffmpeg.exe" -hide_banner -buildconf > "${BUILD_INFO_DIR}/buildconf.txt"
    "${ARTIFACT_DIR}/bin/ffmpeg.exe" -hide_banner -version > "${BUILD_INFO_DIR}/version.txt"
}

main() {
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
