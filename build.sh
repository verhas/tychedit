#!/bin/bash
#
# Build / run helper for Tychedit, in the same shape as Diptych's.
#
#   ./build.sh           build (Debug)
#   ./build.sh run [file.md]   build, then relaunch the app, optionally on a file
#   ./build.sh release   build optimised (Release)
#   ./build.sh test      run the unit tests
#   ./build.sh clean     delete build products
#   ./build.sh path      print the path of the built .app
#   ./build.sh stop      quit a running instance
#
# Everything Xcode does with Cmd-R, without opening Xcode.

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Tychedit.xcodeproj"
SCHEME="Tychedit"
CONFIG="${CONFIG:-Debug}"

# Pinning the destination avoids xcodebuild's "using the first of multiple
# matching destinations" warning.
DESTINATION="platform=macOS,arch=$(uname -m)"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi

info() { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
die()  { printf '%s==> %s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }

# Ask xcodebuild where the product goes rather than hardcoding a DerivedData
# path, which contains a hash of the project location.
app_path() {
    local dir
    dir=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                     -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
          | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')
    [ -n "$dir" ] || die "could not determine BUILT_PRODUCTS_DIR"
    printf '%s/%s.app\n' "$dir" "$SCHEME"
}

build() {
    local log
    log=$(mktemp -t tychedit-build)
    trap 'rm -f "$log"' RETURN

    info "Building $SCHEME ($CONFIG)..."

    if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                  -destination "$DESTINATION" build >"$log" 2>&1; then
        local warnings
        warnings=$(grep -E '^/.*: warning:' "$log" | sort -u || true)
        if [ -n "$warnings" ]; then
            printf '%s%s%s\n' "$YELLOW" "$warnings" "$OFF"
        fi
        printf '%s==> Build succeeded%s\n' "$GREEN" "$OFF"
    else
        grep -E '^/.*: (error|warning):' "$log" || tail -40 "$log"
        die "Build failed"
    fi
}

stop_app() {
    if pgrep -x "$SCHEME" >/dev/null; then
        info "Quitting running $SCHEME..."
        osascript -e "tell application \"$SCHEME\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            pgrep -x "$SCHEME" >/dev/null || return 0
            /bin/sleep 0.1
        done
        pkill -x "$SCHEME" || true
    fi
}

# The test bundle is injected into the app, so the app launches and floods
# stderr with unrelated system logging; only the test lines are shown.
run_tests() {
    local log
    log=$(mktemp -t tychedit-test)
    trap 'rm -f "$log"' RETURN

    info "Testing $SCHEME..."

    if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
                  -destination "$DESTINATION" test >"$log" 2>&1; then
        grep -E "^Test Case .*(passed|failed)" "$log" \
            | sed -E "s/^Test Case '-\[[A-Za-z]+ (.*)\]'/    \1/" \
            | sed 's/ (.*seconds).*//' || true
        grep -E "^\s*Executed [0-9]+ test" "$log" | tail -1 | sed 's/^[[:space:]]*/    /'
        printf '%s==> Tests passed%s\n' "$GREEN" "$OFF"
    else
        # `|| true` throughout: under pipefail a grep that finds nothing would
        # end the script before it says why the tests failed.
        grep -E "^Test Case .*failed|: error: -\[" "$log" | head -40 || true
        # A test run that never started failed to compile.
        grep -E '^/.*: error:' "$log" | sort -u | head -40 || true
        grep -E "^\s*Executed [0-9]+ test" "$log" | tail -1 || true
        die "Tests failed"
    fi
}

case "${1:-build}" in
    build)   build ;;
    release) CONFIG=Release; build ;;
    run)
        build
        stop_app
        app=$(app_path)
        "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
        info "Launching $app"
        if [ -n "${2:-}" ]; then
            open -a "$app" "$2"
        else
            open "$app"
        fi
        ;;
    clean)
        info "Cleaning..."
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                   -destination "$DESTINATION" clean >/dev/null
        printf '%s==> Clean%s\n' "$GREEN" "$OFF"
        ;;
    path)  app_path ;;
    stop)  stop_app ;;
    test)  run_tests ;;
    *)     die "unknown command '$1' (build | run | release | test | clean | path | stop)" ;;
esac
