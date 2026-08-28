#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_PATH="$SCRIPT_DIR/MirrorPod.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"

mkdir -p "$MACOS_PATH"
cp "$SCRIPT_DIR/MirrorPod-Info.plist" "$CONTENTS_PATH/Info.plist"

xcrun swiftc \
  -O \
  -swift-version 5 \
  -parse-as-library \
  -D MENUBAR_APP \
  "$SCRIPT_DIR/Sources/MirrorPod/MirrorPod.swift" \
  "$SCRIPT_DIR/Sources/MirrorPod/MenuBarApp.swift" \
  -o "$MACOS_PATH/MirrorPod"

codesign --force --deep --sign - "$APP_PATH"

echo "Built $APP_PATH"
