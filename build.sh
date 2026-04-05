#!/usr/bin/env bash
# Builds AITranscribePro and wraps it into a proper .app bundle so
# macOS will honour the Info.plist (mic + speech usage descriptions).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="AI Transcribe Pro"
BIN_NAME="AITranscribePro"
APP_DIR="build/${APP_NAME}.app"

echo "→ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Build output not found at $BIN_PATH" >&2
    exit 1
fi

echo "→ Assembling .app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign so TCC (mic/speech) can attach a stable identity to the bundle.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "✓ Built: $APP_DIR"
echo "  Run with: open \"$APP_DIR\""
