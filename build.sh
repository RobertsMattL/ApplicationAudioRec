#!/bin/bash
# Builds the executable with SwiftPM and assembles a signed .app bundle.
set -euo pipefail

APP_NAME="ApplicationAudioRec"
EXEC_NAME="ApplicationAudioRec"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Building (release)…"
swift build -c release

APP="$ROOT/$APP_NAME.app"
echo "==> Assembling $APP_NAME.app …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature gives the bundle a stable-ish identity so macOS can attach
# the Screen Recording permission to it.
echo "==> Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "==> Done."
echo "    Launch with:  open \"$APP\""
