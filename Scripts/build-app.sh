#!/bin/bash
# Assembles MyMac.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O binary; a menu bar app needs a bundle so that
# LSUIElement, the bundle identifier and SMAppService all work. This script is
# the whole packaging step — there is no Xcode project to keep in sync.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product MyMac

BIN_PATH="$(swift build -c "$CONFIGURATION" --product MyMac --show-bin-path)"
APP="$ROOT/build/MyMac.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MyMac" "$APP/Contents/MacOS/MyMac"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Enough for local use; replace with a Developer ID identity
# to distribute, which is also what SMAppService (Open at Login) needs.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "warning: ad-hoc signing failed; the app will still run locally" >&2
}

echo "==> Done: $APP"
