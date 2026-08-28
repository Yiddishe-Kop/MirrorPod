#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_PATH="$PROJECT_DIR/MirrorPod.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$PROJECT_DIR/MirrorPod-Info.plist" "$CONTENTS_PATH/Info.plist"
cp "$PROJECT_DIR/Assets/MirrorPod.icns" "$RESOURCES_PATH/MirrorPod.icns"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -D MENUBAR_APP \
    "$PROJECT_DIR/Sources/MirrorPod/MirrorPod.swift" \
    "$PROJECT_DIR/Sources/MirrorPod/MenuBarApp.swift" \
    -o "$MACOS_PATH/MirrorPod"

codesign --force --deep --sign - "$APP_PATH"

echo "Built $APP_PATH"
