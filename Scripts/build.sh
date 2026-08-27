#!/bin/bash
#
# Builds MyMac.app into ./build, and for a Release build verifies that the
# binary really is universal.
#
# The universal check is part of the build rather than a note on a checklist:
# an arm64-only build runs perfectly on the machine that produced it and dies
# for every Intel user.
#
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- Repo configuration — the ONLY part that differs between the two repos ----
readonly APP_NAME="MyMac"
readonly SCHEME="MyMac"
readonly PROJECT="${REPO_ROOT}/MyMac.xcodeproj"
readonly PACKAGE_PATH="."
readonly UI_TEST_TARGET="MyMacUITests"
readonly INSTALL_ENV_VAR="MYMAC_INSTALLING"
readonly UNIT_FILTER_EXAMPLE="PathSafety"

install_hint() {
    cat <<EOF

Install:
    ./Scripts/install.sh          # rebuild and place it in /Applications
    cp -R "$1" /Applications/    # or copy it by hand

Full Disk Access has to be granted again after every install: macOS ties the
grant to the code signature, and an ad-hoc one differs from build to build.
EOF
}
# ---- END CONFIG — everything below must be byte-identical in both repos ----

readonly DERIVED_DATA="${REPO_ROOT}/build/DerivedData"

configuration="Release"
output_dir="${REPO_ROOT}/build"
run_unit=false
run_ui=false
build_app=true
do_clean=false
quiet=false
filter=""

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: Scripts/build.sh [options]

Builds ${APP_NAME}.app into ./build, and for a Release build verifies that the
binary really is universal (arm64 + x86_64).

Options:
  -d, --debug            Debug configuration, host architecture only (faster)
  -r, --release          Release configuration, universal binary (default)
  -t, --test             Run every test, then build
  -T, --test-only        Run every test and stop
  -u, --unit-only        Run only the package unit tests and stop (fast, no GUI)
  -U, --ui-only          Run only the UI tests and stop (takes over the screen)
  -f, --filter PATTERN   Narrow the tests. Unit: a regex over test names.
                         UI: Class, or Class/method.
  -c, --clean            Delete derived data before building
  -o, --output DIR       Where to put ${APP_NAME}.app (default: ./build)
  -q, --quiet            Show only warnings, errors and test results
  -h, --help             Print this help

Examples:
  Scripts/build.sh                              # Release build into ./build
  Scripts/build.sh --debug --clean              # a clean Debug build
  Scripts/build.sh --test-only                  # every test, then stop
  Scripts/build.sh -u -f '${UNIT_FILTER_EXAMPLE}'
  Scripts/build.sh -U -f 'SmokeTests'           # one UI test class
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--debug)     configuration="Debug"; shift ;;
        -r|--release)   configuration="Release"; shift ;;
        -t|--test)      run_unit=true; run_ui=true; shift ;;
        -T|--test-only) run_unit=true; run_ui=true; build_app=false; shift ;;
        -u|--unit-only) run_unit=true; build_app=false; shift ;;
        -U|--ui-only)   run_ui=true; build_app=false; shift ;;
        -f|--filter)    [[ $# -ge 2 ]] || die "--filter needs a pattern"
                        filter="$2"; shift 2 ;;
        -c|--clean)     do_clean=true; shift ;;
        -o|--output)    [[ $# -ge 2 ]] || die "--output needs a directory"
                        output_dir="$2"; shift 2 ;;
        -q|--quiet)     quiet=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown option: $1" ;;
    esac
done

# Check before starting. `xcodebuild` still exists as a stub when only the
# Command Line Tools are installed, and in that case it fails late with a
# confusing licence message — so confirm it really points at a full Xcode.
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode 16 or newer."
if ! xcodebuild -version >/dev/null 2>&1; then
    die "xcodebuild is not usable. Point it at a full Xcode install:
    sudo xcode-select -s /Applications/Xcode.app"
fi

xcb() {
    if [[ "${quiet}" == true ]]; then
        # xcbeautify and xcpretty are not project dependencies; filter by hand
        # instead, keeping only diagnostics and results. The patterns are
        # anchored deliberately: the bare word "warning" also appears inside the
        # compiler command lines xcodebuild echoes (-suppress-warnings,
        # --warnings), and without anchors every one of those 4 KB lines would
        # slip through.
        #
        # `|| true` sits INSIDE the braces so a grep that matches nothing does
        # not mask xcodebuild's exit status — `set -o pipefail` at the top of
        # the script surfaces that status out of the pipeline.
        xcodebuild "$@" | { grep -E '(^\*\*|: (error|warning): |^Test Case |^Executed |^Testing (failed|succeeded))' || true; }
        return
    fi
    xcodebuild "$@"
}

cd "${REPO_ROOT}"

if [[ "${do_clean}" == true ]]; then
    log "Deleting derived data"
    rm -rf "${DERIVED_DATA}"
    rm -rf "${REPO_ROOT}/${PACKAGE_PATH}/.build"
fi

if [[ "${run_unit}" == true ]]; then
    # The package tests are the fast, deterministic layer — run them first so a
    # broken core goes red in a second rather than after a full app build.
    log "Running the unit tests"
    if [[ -n "${filter}" ]]; then
        swift test --package-path "${PACKAGE_PATH}" --filter "${filter}"
    else
        swift test --package-path "${PACKAGE_PATH}"
    fi
fi

if [[ "${run_ui}" == true ]]; then
    log "Running the UI tests (takes over the screen)"
    ui_args=(-project "${PROJECT}"
             -scheme "${SCHEME}"
             -destination 'platform=macOS'
             -derivedDataPath "${DERIVED_DATA}"
             -resultBundlePath "${DERIVED_DATA}/TestResults.xcresult")
    if [[ -n "${filter}" ]]; then
        ui_args+=(-only-testing:"${UI_TEST_TARGET}/${filter}")
    fi
    rm -rf "${DERIVED_DATA}/TestResults.xcresult"
    xcb "${ui_args[@]}" test
fi

if [[ "${build_app}" != true ]]; then
    log "Tests green"
    exit 0
fi

log "Building ${SCHEME} (${configuration})"
xcb -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${configuration}" \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    build

built_app="${DERIVED_DATA}/Build/Products/${configuration}/${SCHEME}.app"
[[ -d "${built_app}" ]] || die "the build reported success but ${built_app} is missing"

mkdir -p "${output_dir}"
# Delete the old bundle rather than copying over it: `cp -R` merges into an
# existing directory, so leftover resources from a previous build can survive.
rm -rf "${output_dir:?}/${SCHEME}.app"
cp -R "${built_app}" "${output_dir}/"
final_app="${output_dir}/${SCHEME}.app"

binary="${final_app}/Contents/MacOS/${SCHEME}"
architectures="$(lipo -archs "${binary}")"

# The whole point of supporting Intel is that a bundle built anywhere runs
# everywhere, so the result is checked rather than assumed. An arm64-only build
# runs perfectly on the machine that produced it and dies for every Intel user.
if [[ "${configuration}" == "Release" ]]; then
    for arch in arm64 x86_64; do
        case " ${architectures} " in
            *" ${arch} "*) ;;
            *) die "the Release build is not universal: got '${architectures}', missing ${arch}" ;;
        esac
    done
fi

log "Built ${final_app}"
printf '    configuration : %s\n' "${configuration}"
printf '    architectures : %s\n' "${architectures}"
printf '    version       : %s (%s)\n' \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${final_app}/Contents/Info.plist" 2>/dev/null || echo '?')" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${final_app}/Contents/Info.plist" 2>/dev/null || echo '?')"

if [[ "${configuration}" == "Debug" ]]; then
    warn "A Debug build is single-architecture and unoptimized. Use --release to ship."
fi

# When install.sh calls in here it handles installation itself, and printing a
# second way to install right before it does that would only confuse the reader.
if [[ -z "${!INSTALL_ENV_VAR:-}" ]]; then
    install_hint "${final_app}"
fi
