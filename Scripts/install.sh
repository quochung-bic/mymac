#!/bin/bash
# Builds MyMac.app and puts it in /Applications.
#
# The whole install for someone who has just cloned the repo:
#
#   git clone <repo> && cd mymac
#   ./Scripts/install.sh
#
#   MYMAC_DEST=~/Applications ./Scripts/install.sh   install for one user only
#   MYMAC_UNIVERSAL=0 ./Scripts/install.sh           build only for this Mac
#
# There is nothing to download and nothing to unarchive, so the bundle never
# carries a quarantine flag and Gatekeeper has nothing to warn about: an app you
# compiled yourself is not an app you downloaded. The signature is still ad-hoc,
# which costs exactly one thing — Open at Login, which SMAppService refuses for
# any bundle without a Developer ID identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${MYMAC_DEST:-/Applications}"
APP="$DEST/MyMac.app"

"$ROOT/Scripts/build-app.sh" release

# A running copy is holding the bundle that is about to be replaced. Asking it
# to quit lets it save its settings; killing it would not.
if pgrep -f "$APP/Contents/MacOS/MyMac" >/dev/null 2>&1; then
    echo "==> Quitting the running copy"
    osascript -e 'tell application id "com.mymac.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -f "$APP/Contents/MacOS/MyMac" >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

if [[ ! -d "$DEST" ]]; then
    echo "error: $DEST does not exist" >&2
    exit 1
fi
if [[ ! -w "$DEST" ]]; then
    echo "error: $DEST is not writable by $(whoami)." >&2
    echo "       Either run this with sudo, or install for yourself with" >&2
    echo "       MYMAC_DEST=\"\$HOME/Applications\" $0" >&2
    exit 1
fi

# Replaced rather than copied over: a merge would leave behind any file the
# previous version had and this one does not.
echo "==> Installing $APP"
rm -rf "$APP"
cp -R "$ROOT/build/MyMac.app" "$APP"

echo "==> Done"
open "$APP"

cat <<'NOTE'

Two things worth knowing after an install:

  * Full Disk Access has to be granted again. macOS ties the grant to the code
    signature, and an ad-hoc signature is different for every build, so the
    Permissions page will ask for it after each install. Sign with a Developer
    ID identity if that matters to you.
  * Open at Login will refuse, and say so, for the same reason.

To remove it: quit the app and drag MyMac.app to the Trash. It leaves nothing
behind but its own preferences, in ~/Library/Preferences/com.mymac.app.plist.
NOTE
