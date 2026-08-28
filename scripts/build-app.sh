#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_PATH="$PROJECT_DIR/MirrorPod.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
ICON_DOCUMENT_PATH="$PROJECT_DIR/Assets/AppIcon.icon"
ASSET_INFO_PATH="$(mktemp "${TMPDIR:-/tmp}/mirrorpod-asset-info.XXXXXX")"

cleanup() {
    rm -f "$ASSET_INFO_PATH"
}

trap cleanup EXIT

mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$PROJECT_DIR/MirrorPod-Info.plist" "$CONTENTS_PATH/Info.plist"
rm -f "$RESOURCES_PATH/MirrorPod.icns"

xcrun actool "$ICON_DOCUMENT_PATH" \
    --compile "$RESOURCES_PATH" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO_PATH" \
    --output-format human-readable-text

plutil -replace CFBundleIconFile \
    -string "$(plutil -extract CFBundleIconFile raw "$ASSET_INFO_PATH")" \
    "$CONTENTS_PATH/Info.plist"
plutil -replace CFBundleIconName \
    -string "$(plutil -extract CFBundleIconName raw "$ASSET_INFO_PATH")" \
    "$CONTENTS_PATH/Info.plist"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -D MENUBAR_APP \
    "$PROJECT_DIR/Sources/MirrorPod/MirrorPod.swift" \
    "$PROJECT_DIR/Sources/MirrorPod/MenuBarApp.swift" \
    -o "$MACOS_PATH/MirrorPod"

codesign --force --deep --sign - "$APP_PATH"
touch "$APP_PATH"

echo "Built $APP_PATH"
