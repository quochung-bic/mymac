#!/bin/bash
#
# Builds MyMac.app and puts it in /Applications.
#
# The whole install for someone who has just cloned the repo:
#
#   git clone <repo> && cd mymac
#   ./Scripts/install.sh
#
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- Repo configuration — the ONLY part that differs between MyMac and Caffeinate ----
readonly APP_NAME="MyMac"
readonly BUNDLE_ID="com.mymac.app"
readonly INSTALL_ENV_VAR="MYMAC_INSTALLING"
# ---- END CONFIG — everything below is kept byte-identical with the other repo ----

# MYMAC_DEST is the old interface, kept working because the README published it.
# Deprecated in favour of --destination; it will go in a later release.
destination="${MYMAC_DEST:-/Applications}"
if [[ -n "${MYMAC_DEST:-}" ]]; then
    printf '\033[33mwarning:\033[0m MYMAC_DEST is deprecated; use --destination %s\n' \
        "${MYMAC_DEST}" >&2
fi

run_tests=false
build_app=true
quiet=false

log()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: Scripts/install.sh [options]

Builds ${APP_NAME}.app and installs it, replacing any copy already there and
reopening it afterwards.

Options:
  -d, --destination DIR   Install somewhere else (default: /Applications)
  -t, --test              Run every test before building
  -n, --no-build          Install the existing build/${APP_NAME}.app as-is
  -q, --quiet             Show only warnings, errors and test results
  -h, --help              Print this help

--destination is for experimenting rather than an equal alternative: macOS
only treats /Applications as a trusted location for a login item.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--destination) [[ $# -ge 2 ]] || die "--destination needs a directory"
                          destination="$2"; shift 2 ;;
        -t|--test)        run_tests=true; shift ;;
        -n|--no-build)    build_app=false; shift ;;
        -q|--quiet)       quiet=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "unknown option: $1" ;;
    esac
done

[[ "${build_app}" == true || "${run_tests}" == false ]] \
    || die "--no-build and --test are mutually exclusive"

built_app="${REPO_ROOT}/build/${APP_NAME}.app"

if [[ "${build_app}" == true ]]; then
    export "${INSTALL_ENV_VAR}=1"
    build_args=(--release)
    [[ "${run_tests}" == true ]] && build_args+=(--test)
    [[ "${quiet}" == true ]] && build_args+=(--quiet)
    "${REPO_ROOT}/Scripts/build.sh" "${build_args[@]}"
fi

[[ -d "${built_app}" ]] || die "${built_app} not found. Drop --no-build to build it."

installed_app="${destination}/${APP_NAME}.app"

# A running copy is holding the bundle that is about to be replaced. Asking it
# to quit lets it save its settings; killing it would not.
if pgrep -f "${installed_app}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
    log "Quitting the running copy"
    osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -f "${installed_app}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 || break
        sleep 0.25
    done
    # Replacing a bundle out from under a running process leaves a half-updated
    # app, so stop rather than push on.
    pgrep -f "${installed_app}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 \
        && die "${APP_NAME} is still running and will not quit. Quit it and try again."
fi

[[ -d "${destination}" ]] || die "${destination} does not exist"
if [[ ! -w "${destination}" ]]; then
    die "${destination} is not writable by $(whoami).
    Either run this with sudo, or install for yourself with
    ${0} --destination \"\$HOME/Applications\""
fi

# Replaced rather than copied over: a merge would leave behind any file the
# previous version had and this one does not.
log "Installing ${installed_app}"
rm -rf "${installed_app}"
cp -R "${built_app}" "${installed_app}"

log "Done"
open "${installed_app}"

if [[ "${destination}" != "/Applications" ]]; then
    warn "Open at Login only works from /Applications: SMAppService refuses to
         register a bundle anywhere else."
fi

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
