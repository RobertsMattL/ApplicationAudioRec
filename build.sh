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

# Screen Recording permission (TCC) is matched against the code-signing
# "designated requirement". An ad-hoc signature's requirement is the binary's
# cdhash, which changes on every build — so macOS forgets the grant each rebuild.
# Signing with a stable identity (a real cert) keeps the requirement constant, so
# you only grant permission once.
#
# Identity selection order:
#   1. $SIGN_IDENTITY env var, if set
#   2. first "Apple Development" identity in the keychain
#   3. fall back to ad-hoc (permission will need re-granting each build)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Apple Development' | head -1 | awk '{print $2}')"
fi

if [[ -n "$IDENTITY" ]]; then
    echo "==> Code signing with stable identity ($IDENTITY)…"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> Code signing (ad-hoc — no stable identity found)…"
    echo "    NOTE: Screen Recording permission will need re-granting after each build."
    codesign --force --deep --sign - "$APP"
fi

echo "==> Done."
echo "    Launch with:  open \"$APP\""
