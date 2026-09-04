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

# --no-xcode support. The app layer lives in the MyMacUI library, so SwiftPM can
# link a runnable executable out of it without Xcode; `mymac` is lower-cased so
# it cannot collide with the Xcode application target.
readonly SPM_PRODUCT="mymac"
readonly INFO_PLIST="Resources/Info.plist"
readonly APP_ICON="Resources/AppIcon.icns"
readonly NO_XCODE_REASON=""

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
no_xcode=false
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
  -n, --no-xcode         Build with SwiftPM only, this Mac only, no Xcode needed
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
  Scripts/build.sh --no-xcode                   # a runnable app without Xcode
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
        -n|--no-xcode)  no_xcode=true; shift ;;
        -c|--clean)     do_clean=true; shift ;;
        -o|--output)    [[ $# -ge 2 ]] || die "--output needs a directory"
                        output_dir="$2"; shift 2 ;;
        -q|--quiet)     quiet=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown option: $1" ;;
    esac
done

# --no-xcode exists so nobody has to install several gigabytes of Xcode to
# produce a few megabytes of bundle. It builds for this Mac alone, through
# SwiftPM, which the Command Line Tools can do on their own.
if [[ "${no_xcode}" == true ]]; then
    [[ -n "${SPM_PRODUCT}" ]] || die "--no-xcode is not available in this project.
    ${NO_XCODE_REASON}"
    [[ "${run_ui}" == false ]] || die "--no-xcode cannot run the UI tests: XCUITest
    is part of Xcode, and this mode exists for machines that do not have it."
fi

# Check before starting, and say what is actually wrong.
#
# `xcodebuild` still exists as a stub when only the Command Line Tools are
# installed, and every failure downstream of that names something the reader has
# never heard of: SwiftPM says "xcbuild executable ... does not exist", and
# xcodebuild itself talks about licences. Someone who had just cloned this hit
# exactly that and had no way to tell it meant "install Xcode".
#
# Both branches are covered deliberately — Xcode absent, and Xcode present but
# not selected — because telling someone with no Xcode to run `xcode-select` at
# it just produces a second unhelpful error.
if [[ "${no_xcode}" == false ]] && { ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; }; then
    die "this needs the full Xcode, not just the Command Line Tools.

    If Xcode is not installed, install it from the App Store (it is free), then
    open it once so it can finish setting itself up.

    If Xcode is already installed, point the command line tools at it:
        sudo xcode-select -s /Applications/Xcode.app"
fi

# Swift 6 needs Xcode 16. Without this the failure is a tools-version error from
# inside SwiftPM, which reads as a bug in the project rather than as "your Xcode
# is too old". An unparseable version is not worth blocking on, so skip it.
#
# The whole probe is skipped under --no-xcode, and not merely its verdict: with
# no Xcode installed `xcodebuild -version` fails, and a failing pipeline inside
# a command substitution takes the script down under `set -e` with `pipefail` —
# silently, before anything has been printed.
if [[ "${no_xcode}" == false ]]; then
    xcode_major="$(xcodebuild -version 2>/dev/null | sed -n '1s/^Xcode \([0-9][0-9]*\).*/\1/p' || true)"
    if [[ -n "${xcode_major}" ]] && (( xcode_major < 16 )); then
        die "Xcode $(xcodebuild -version | sed -n '1s/^Xcode //p') is too old.
    This needs Xcode 16 or newer, for Swift 6."
    fi
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

# SwiftPM cannot produce a bundle, only a bare Mach-O, so the .app is assembled
# around it here. The result deliberately has no hardened runtime and no
# entitlements — it is a build to run on this machine, not one to hand out.
if [[ "${no_xcode}" == true ]]; then
    spm_config="$(printf '%s' "${configuration}" | tr '[:upper:]' '[:lower:]')"
    log "Building ${APP_NAME} (${configuration}, SwiftPM, this Mac only)"
    swift build -c "${spm_config}" --package-path "${PACKAGE_PATH}" --product "${SPM_PRODUCT}"
    bin_dir="$(swift build -c "${spm_config}" --package-path "${PACKAGE_PATH}" --show-bin-path)"

    mkdir -p "${output_dir}"
    final_app="${output_dir}/${APP_NAME}.app"
    rm -rf "${final_app:?}"
    mkdir -p "${final_app}/Contents/MacOS" "${final_app}/Contents/Resources"

    # The product is lower-cased to stay out of the Xcode target's way, but the
    # bundle executable has to match CFBundleExecutable in the Info.plist.
    cp "${bin_dir}/${SPM_PRODUCT}" "${final_app}/Contents/MacOS/${APP_NAME}"
    cp "${REPO_ROOT}/${INFO_PLIST}" "${final_app}/Contents/Info.plist"
    printf 'APPL????' > "${final_app}/Contents/PkgInfo"
    if [[ -f "${REPO_ROOT}/${APP_ICON}" ]]; then
        cp "${REPO_ROOT}/${APP_ICON}" "${final_app}/Contents/Resources/"
    fi

    # No --deep: Apple deprecated it, and there is nothing nested here to sign.
    codesign --force --sign - "${final_app}" >/dev/null 2>&1 \
        || warn "ad-hoc signing failed; the app will still run on this machine"

    log "Built ${final_app}"
    printf '    configuration : %s\n' "${configuration}"
    printf '    architectures : %s\n' "$(lipo -archs "${final_app}/Contents/MacOS/${APP_NAME}")"
    warn "This is a --no-xcode build: one architecture, no hardened runtime and
         no entitlements. Fine for running here; build without --no-xcode to
         produce the universal bundle that gets handed to someone else."
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
