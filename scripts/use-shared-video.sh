#!/usr/bin/env bash
set -euo pipefail

# Build DASH assets from a reference video and install them into target so
# goDASH and WebRTC can use the same source clip.
#
# Usage:
#   ./scripts/use-shared-video.sh [path-to-video] [loop-seconds]
#
# Default example:
#   ./scripts/use-shared-video.sh
#   (uses browser/reference/FourPeople_lossless.mkv)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."

INPUT_VIDEO_REL="${1:-browser/reference/FourPeople_lossless.mkv}"
LOOP_SECONDS="${2:-60}"
INPUT_VIDEO="$REPO_ROOT/$INPUT_VIDEO_REL"
DASH_DIR_REL="data/shared-dash/current"
DASH_DIR="$REPO_ROOT/$DASH_DIR_REL"

case "$LOOP_SECONDS" in
  ''|*[!0-9]*)
    echo "ERROR: loop-seconds must be a positive integer (got: $LOOP_SECONDS)" >&2
    exit 1
    ;;
esac

if [ "$LOOP_SECONDS" -le 0 ]; then
  echo "ERROR: loop-seconds must be greater than 0" >&2
  exit 1
fi

if [ ! -f "$INPUT_VIDEO" ]; then
  echo "ERROR: input video not found: $INPUT_VIDEO_REL" >&2
  echo "Place videos under browser/reference/ or pass an explicit path." >&2
  exit 1
fi

mkdir -p "$DASH_DIR"
rm -f "$DASH_DIR"/*

echo "[use-shared-video] input:  $INPUT_VIDEO_REL"
echo "[use-shared-video] output: $DASH_DIR_REL"
echo "[use-shared-video] duration target: ${LOOP_SECONDS}s"
echo "[use-shared-video] generating DASH assets via ffmpeg container..."

docker run --rm \
  -v "$REPO_ROOT:/work" \
  jrottenberg/ffmpeg:6.1-alpine \
  -y \
  -stream_loop -1 -t "$LOOP_SECONDS" \
  -i "/work/$INPUT_VIDEO_REL" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000" \
  -filter_complex "[0:v]split=3[v1][v2][v3];[v1]scale=1280:720[v1out];[v2]scale=960:540[v2out];[v3]scale=640:360[v3out]" \
  -map "[v1out]" -c:v:0 libx264 -b:v:0 2000k -x264-params "keyint=100:scenecut=0" \
  -map "[v2out]" -c:v:1 libx264 -b:v:1 800k  -x264-params "keyint=100:scenecut=0" \
  -map "[v3out]" -c:v:2 libx264 -b:v:2 300k  -x264-params "keyint=100:scenecut=0" \
  -map 1:a -c:a aac -b:a 64k \
  -shortest \
  -use_template 1 -use_timeline 0 -seg_duration 4 \
  -init_seg_name 'init-stream$RepresentationID$.$ext$' \
  -media_seg_name 'chunk-stream$RepresentationID$-$Number$.$ext$' \
  -adaptation_sets "id=0,streams=0,1,2 id=1,streams=3" \
  -f dash "/work/$DASH_DIR_REL/manifest.mpd"

echo "[use-shared-video] running DASH manifest fixup..."
docker run --rm \
  -v "$REPO_ROOT:/work" \
  python:3.12-alpine \
  python3 /work/target/dash-fixup.py "/work/$DASH_DIR_REL/manifest.mpd"

if ! docker compose ps --status running target >/dev/null 2>&1; then
  echo "[use-shared-video] target container is not running yet."
  echo "Start it with: docker compose up -d target"
  echo "Then install generated assets with: docker compose cp $DASH_DIR_REL/. target:/var/www/dash"
  exit 0
fi

echo "[use-shared-video] installing assets into running target container..."
docker compose exec -T target sh -lc 'rm -f /var/www/dash/*'
docker compose cp "$DASH_DIR_REL/." target:/var/www/dash

echo "[use-shared-video] done."
echo "- goDASH now pulls the same clip content via /dash/manifest.mpd"
echo "- in WebRTC sender, choose file: $(basename "$INPUT_VIDEO_REL")"
echo "- for another video: ./scripts/use-shared-video.sh browser/reference/<file>.mkv [loop-seconds]"
