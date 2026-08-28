#!/bin/zsh

set -e

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

if [[ ! -x .build/release/mirrorpod ]]; then
  echo "Building MirrorPod…"
  swift build -c release
fi

echo ""
echo "MirrorPod is starting. Keep this window open; press Control-C to stop."
echo ""
exec .build/release/mirrorpod --delay-ms "${MIRRORPOD_DELAY_MS:-2000}"
