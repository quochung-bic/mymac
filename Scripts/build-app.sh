#!/bin/bash
# Assembles MyMac.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O binary; a menu bar app needs a bundle so that
# LSUIElement, the bundle identifier and SMAppService all work. This script is
# the whole packaging step — there is no Xcode project to keep in sync.
#
# Usage:
#   ./Scripts/build-app.sh [debug|release]
#
#   MYMAC_UNIVERSAL=0 ./Scripts/build-app.sh    build only for this Mac
#
# The default is a universal binary, so a bundle built on an Apple Silicon Mac
# still runs on an Intel one. It costs roughly twice the build time and nothing
# else: every architecture-dependent path in the code — the mach timebase, the
# performance-level sysctls, the battery capacity keys — already handles both.
# Set MYMAC_UNIVERSAL=0 while iterating locally.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${MYMAC_UNIVERSAL:-1}" == "0" ]]; then
    ARCH_FLAGS=()
    echo "==> Building ($CONFIGURATION, this Mac only)"
else
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    echo "==> Building ($CONFIGURATION, universal: arm64 + x86_64)"
fi

swift build -c "$CONFIGURATION" --product MyMac "${ARCH_FLAGS[@]}"

BIN_PATH="$(swift build -c "$CONFIGURATION" --product MyMac "${ARCH_FLAGS[@]}" --show-bin-path)"
APP="$ROOT/build/MyMac.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MyMac" "$APP/Contents/MacOS/MyMac"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Enough for local use; replace with a Developer ID identity
# to distribute, which is also what SMAppService (Open at Login) needs.
# No --deep: Apple deprecated it, and there is nothing nested here to sign.
echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
    echo "warning: ad-hoc signing failed; the app will still run locally" >&2
}

echo "==> Done: $APP"
lipo -info "$APP/Contents/MacOS/MyMac"
