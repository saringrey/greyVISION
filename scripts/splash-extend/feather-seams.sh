#!/bin/zsh
# Softens the two seams where the live film band meets the AI-extended
# stills (rows ~1080 and ~1788 of the 1320x2868 splash): a 300pt band at each
# is vertically blurred and blended in with a triangular mask.
set -e
cd "$(dirname "$0")"
IN=${1:-../../GreyVision/Resources/Splash.mp4}
OUT=${2:-Splash-feathered.mp4}
ffmpeg -v error -y -i "$IN" -filter_complex "$(cat feather-seams.filter)" -map "[v]" -an \
  -c:v libx265 -crf 17 -preset fast -x265-params log-level=error -tag:v hvc1 -movflags +faststart -t 10.8 "$OUT"
