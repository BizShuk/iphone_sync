#!/bin/bash
# iPhoneSync - iOS Simulator 執行入口
#
#   ./scripts/run-simulator.sh              # 建置、安裝並在模擬器上啟動
#   ./scripts/run-simulator.sh --build-only # 只建置，不開模擬器
#   ./scripts/run-simulator.sh --help
#
# `SIMULATOR` 環境變數可換機型，預設 iPhone 17 Pro。
#
# 模擬器建置一律 `CODE_SIGNING_ALLOWED=NO`：模擬器不驗簽章，把 provisioning
# 拉進來只會讓「程式能不能編過」卡在憑證上。實機請改用 npm run deploy:ios。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

SCHEME="iPhoneSyncIOS"
BUNDLE_ID="com.shuk.iphonesync.ios"
PROJECT="${PROJECT_DIR}/iPhoneSync.xcodeproj"
APP_NAME="iPhone Sync.app"
DERIVED_DATA="${DERIVED_DATA:-${PROJECT_DIR}/build/simulator}"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
MODE="run"

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "錯誤：找不到 $1。$2" >&2
        exit 1
    }
}

fail() {
    echo "錯誤：$*" >&2
    exit 1
}

step() {
    printf '\n▸ %s\n' "$*"
}

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

while (( $# > 0 )); do
    case "$1" in
        --build-only) MODE="build" ;;
        --help) usage; exit 0 ;;
        *) fail "未知參數：$1（--help 查看說明）" ;;
    esac
    shift
done

require xcodebuild "請安裝 Xcode"

require xcodegen "請執行：brew install xcodegen"

step "Regenerating Xcode project"
xcodegen generate --quiet

step "Building ${SCHEME} for ${SIMULATOR}"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=${SIMULATOR}" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ "${MODE}" == "build" ]]; then
    echo "已建置完成（未安裝到模擬器）。"
    exit 0
fi

APP="$(find "${DERIVED_DATA}/Build/Products" -maxdepth 2 -name "${APP_NAME}" -print -quit)"
[[ -n "${APP}" ]] || fail "找不到建置產物 ${APP_NAME}"

# boot 已經開機的模擬器會回傳非零，這不是錯誤；後續步驟一律針對 booted。
step "Booting ${SIMULATOR}"
xcrun simctl boot "${SIMULATOR}" 2>/dev/null || true
open -a Simulator

step "Installing and launching ${BUNDLE_ID}"
xcrun simctl install booted "${APP}"
xcrun simctl launch booted "${BUNDLE_ID}"
