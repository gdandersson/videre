#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$ROOT_DIR/.build/Videre.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"

RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/macOS/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/macOS/Videre.icns" "$RESOURCES_DIR/Videre.icns"
cp "$BIN_DIR/videre" "$MACOS_DIR/videre"

# mkdir -p "$MACOS_DIR"
# cp "$ROOT_DIR/macOS/Info.plist" "$CONTENTS_DIR/Info.plist"
# cp "$BIN_DIR/videre" "$MACOS_DIR/videre"


echo "$APP_DIR"
