#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="${PROJECT:-iPhoneSync.xcodeproj}"
SCHEME="${SCHEME:-iPhoneSyncMac}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/mac-install-derived}"
APP_NAME="${APP_NAME:-iPhone Sync}"
BUNDLE_ID="${BUNDLE_ID:-com.shuk.iphonesync.mac}"
ENTITLEMENTS="${ENTITLEMENTS:-apps/macos/iPhoneSyncMac.entitlements}"
SIGN_IDENTITY="${MAC_SIGN_IDENTITY:--}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

launch=1

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
Usage: ./scripts/run-mac.sh [--no-launch|--help]

把 macOS receiver 以 Release 建置並安裝到 /Applications，取代既有版本後啟動。
與 package-mac.sh 不同：這裡不產生 DMG / PKG，直接安裝可日常使用的 App。

  (no option)  建置、簽章、安裝、啟動。
  --no-launch  安裝完成後不啟動 App。

Optional environment:
  PROJECT            Xcode project (default: iPhoneSync.xcodeproj).
  SCHEME             Xcode scheme (default: iPhoneSyncMac).
  CONFIGURATION      Build configuration (default: Release).
  DERIVED_DATA_PATH  Xcode derived-data path (default: build/mac-install-derived).
  APP_NAME           Built app name (default: iPhone Sync).
  BUNDLE_ID          Bundle identifier used to stop the running App.
  ENTITLEMENTS       Entitlements file (default: apps/macos/iPhoneSyncMac.entitlements).
  MAC_SIGN_IDENTITY  codesign identity (default: "-" = ad-hoc).
  INSTALL_DIR        Install destination (default: /Applications).

ad-hoc 簽章每次建置都是不同的 code identity，macOS 會把安裝後的 App 視為
另一個程式：login Keychain 中的 PSK 與 sandbox 的 destination bookmark 需要
重新授權。要保留既有配對，設 MAC_SIGN_IDENTITY 為固定的 Developer ID。
USAGE
}

case "${1:-run}" in
    --help)
        usage
        exit 0
        ;;
    --no-launch)
        [[ $# -eq 1 ]] || fail "--no-launch 不接受其他參數"
        launch=0
        ;;
    run)
        [[ $# -eq 0 ]] || fail "未知參數: $*（使用 --help 查看說明）"
        ;;
    *)
        fail "未知參數: $*（使用 --help 查看說明）"
        ;;
esac

require_command xcodegen
require_command xcodebuild
require_command codesign
require_command ditto

[[ -d "$INSTALL_DIR" ]] || fail "安裝目的地不存在: $INSTALL_DIR"

step "Regenerating Xcode project"
xcodegen generate

step "Building $SCHEME ($CONFIGURATION)"
xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build

[[ -d "$BUILT_APP" ]] || fail "找不到建置後的 App: $BUILT_APP"

step "Signing $APP_NAME.app"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUILT_APP"
else
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$BUILT_APP"
fi
codesign --verify --deep --strict "$BUILT_APP"
codesign --display --entitlements - "$BUILT_APP" 2>/dev/null \
    | grep -q 'com.apple.security.app-sandbox' \
    || fail "簽章後缺少 app-sandbox entitlement"

if pgrep -f -- "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    step "Stopping running $APP_NAME"
    /usr/bin/osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -f -- "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.1
    done
    if pgrep -f -- "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
        pkill -TERM -f -- "$APP_NAME.app/Contents/MacOS/$APP_NAME" || true
        for _ in {1..20}; do
            pgrep -f -- "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    pgrep -f -- "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 \
        && fail "無法停止執行中的 $APP_NAME；請手動退出後重試"
fi

step "Installing to $INSTALLED_APP"
if [[ -e "$INSTALLED_APP" ]]; then
    [[ -d "$INSTALLED_APP" && "$INSTALLED_APP" == *.app ]] \
        || fail "安裝路徑存在但不是 App bundle: $INSTALLED_APP"
    rm -rf "$INSTALLED_APP" \
        || fail "無法移除既有的 $INSTALLED_APP；若權限不足請用 sudo 執行"
fi
ditto "$BUILT_APP" "$INSTALLED_APP" \
    || fail "無法寫入 $INSTALL_DIR；若權限不足請用 sudo 執行"

if [[ "$launch" -eq 1 ]]; then
    step "Launching $INSTALLED_APP"
    /usr/bin/open "$INSTALLED_APP"
    printf '\n已安裝並啟動；menu bar 應出現 %s 圖示。\n' "$APP_NAME"
else
    printf '\n已安裝: %s\n' "$INSTALLED_APP"
fi
