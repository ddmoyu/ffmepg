#!/usr/bin/env bash

set -euo pipefail

ARTIFACT_FFMPEG=${1:-}
HOST_FFMPEG=${HOST_FFMPEG:-$(command -v ffmpeg || true)}

log() {
    printf '[smoke] %s\n' "$*"
}

fail() {
    printf '[smoke] error: %s\n' "$*" >&2
    exit 1
}

[ -n "${ARTIFACT_FFMPEG}" ] || fail "usage: smoke-test-ffmpeg.sh <path-to-built-ffmpeg>"
[ -x "${ARTIFACT_FFMPEG}" ] || fail "ffmpeg binary not found or not executable: ${ARTIFACT_FFMPEG}"
[ -n "${HOST_FFMPEG}" ] || fail "HOST_FFMPEG is not available; install a host ffmpeg package for smoke testing"

log "creating sample video with host ffmpeg"
"${HOST_FFMPEG}" -hide_banner -y -f lavfi -i testsrc2=size=320x180:rate=10 -frames:v 20 sample.mp4

"${ARTIFACT_FFMPEG}" -hide_banner -protocols | tee protocols.txt
"${ARTIFACT_FFMPEG}" -hide_banner -hwaccels | tee hwaccels.txt
"${ARTIFACT_FFMPEG}" -hide_banner -muxers | tee muxers.txt
"${ARTIFACT_FFMPEG}" -hide_banner -encoders | tee encoders.txt
"${ARTIFACT_FFMPEG}" -hide_banner -decoders | tee decoders.txt
"${ARTIFACT_FFMPEG}" -hide_banner -demuxers | tee demuxers.txt

if grep -wEq 'http|https|rtmp|rtsp|tcp|udp' protocols.txt; then
    fail "unexpected network protocol enabled"
fi

if tail -n +2 hwaccels.txt | grep -q '[[:alnum:]]'; then
    fail "unexpected hardware acceleration enabled"
fi

grep -wq image2 muxers.txt
grep -wq mjpeg encoders.txt
grep -wq h264 decoders.txt
grep -wq hevc decoders.txt
grep -wq vp9 decoders.txt
grep -wq av1 decoders.txt
grep -Eq 'mov,mp4,m4a,3gp,3g2,mj2| mov ' demuxers.txt
grep -Eq 'matroska,webm| matroska ' demuxers.txt
grep -Eq 'avi ' demuxers.txt
grep -Eq 'mpegts ' demuxers.txt

mkdir -p smoke-output
"${ARTIFACT_FFMPEG}" -hide_banner -y -i sample.mp4 -vf 'fps=2,scale=160:-1' smoke-output/frame-%03d.jpg

test -f smoke-output/frame-001.jpg
test "$(find smoke-output -name '*.jpg' | wc -l)" -gt 0

log "smoke test passed"