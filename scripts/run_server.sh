#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="${PROJECT:-iPhoneSync.xcodeproj}"
SCHEME="${SCHEME:-iPhoneSyncMac}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_ROOT="${BUILD_ROOT:-build/mac}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_ROOT/DerivedData}"
APP_NAME="${APP_NAME:-iPhone Sync}"
APP_PATH="${APP_PATH:-$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app}"

step() {
    printf '\n▸ %s\n' "$*"
}

fail() {
    printf '\n錯誤: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少 $1"
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/run_server.sh [--build-only|--no-build|--help]

  (no option)  Regenerate, build, and launch the macOS receiver app.
  --build-only  Regenerate and build without launching the app.
  --no-build    Launch the previously built app without rebuilding.

Optional environment:
  PROJECT            Xcode project (default: iPhoneSync.xcodeproj).
  SCHEME             Xcode scheme (default: iPhoneSyncMac).
  CONFIGURATION      Build configuration (default: Debug).
  BUILD_ROOT         Build output root (default: build/mac).
  DERIVED_DATA_PATH  Xcode derived-data path (default: build/mac/DerivedData).
  APP_NAME           Built app name (default: iPhone Sync).
  APP_PATH           Override the app bundle path.
USAGE
}

build_app() {
    require_command xcodegen
    require_command xcodebuild

    step "Regenerating Xcode project"
    xcodegen generate

    step "Building $SCHEME ($CONFIGURATION)"
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        build

    [[ -d "$APP_PATH" ]] || fail "找不到建置後的 App: $APP_PATH"
}

launch_app() {
    [[ -d "$APP_PATH" ]] || fail "找不到 App: $APP_PATH；請先執行建置或移除 --no-build"

    local executable_path="$APP_PATH/Contents/MacOS/$APP_NAME"
    if pgrep -f -- "$executable_path" >/dev/null 2>&1; then
        step "Stopping previous receiver"
        pkill -TERM -f -- "$executable_path" || true
        for _ in {1..20}; do
            pgrep -f -- "$executable_path" >/dev/null 2>&1 || break
            sleep 0.1
        done
        pgrep -f -- "$executable_path" >/dev/null 2>&1 && fail "無法停止舊的 receiver process"
    fi

    step "Launching $APP_PATH"
    /usr/bin/open "$APP_PATH" --args --open-setup
    printf '\nMac receiver 已啟動，Setup 視窗應已開啟；請選擇 destination 並完成配對。\n'
}

case "${1:-run}" in
    --help)
        usage
        ;;
    --build-only)
        [[ $# -eq 1 ]] || fail "--build-only 不接受其他參數"
        build_app
        printf '\nApp: %s\n' "$APP_PATH"
        ;;
    --no-build)
        [[ $# -eq 1 ]] || fail "--no-build 不接受其他參數"
        launch_app
        ;;
    run)
        [[ $# -eq 0 ]] || fail "未知參數: $*（使用 --help 查看說明）"
        build_app
        launch_app
        ;;
    *)
        fail "未知參數: $*（使用 --help 查看說明）"
        ;;
esac
