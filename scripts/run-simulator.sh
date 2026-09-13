#!/bin/bash
# iPhoneSync - iOS Simulator 執行入口
#
#   ./scripts/run-simulator.sh              # 建置、安裝並在模擬器上啟動
#   ./scripts/run-simulator.sh --build-only # 只建置，不開模擬器
#   ./scripts/run-simulator.sh --help
#
# `SIMULATOR` 環境變數可換機型，預設 iPhone 17 Pro Max（本工作區只維護這一台）。
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
SIMULATOR="${SIMULATOR:-iPhone 17 Pro Max}"

# 本工作區`只維護一台模擬器`，規則見 iphone/CLAUDE.md「模擬器只維護一台」。
#
# 一律把名稱解析成 udid 再用 `id=`：同名裝置有好幾台時（Xcode 升級會留下
# 前一版那一台），`name=` 是`整個失敗`而不是挑一台，而錯誤訊息會說
# 「找不到裝置」，同時在下面列出兩台一模一樣的。
#
# 同時跳過`幽靈裝置`：CoreSimulator 的 Devices 目錄被清掉之後，simctl 仍會
# 把那幾台列成 available，但 boot 一律回 `cannot be located on disk`，
# 而 xcodebuild 對它的說法是 `Channel disconnected` —— 看起來像測試壞了，
# 其實是機器壞了。
simulator_udid() {
    local udid
    while read -r udid; do
        [[ -d "${HOME}/Library/Developer/CoreSimulator/Devices/${udid}" ]] || continue
        echo "${udid}"
        return 0
    done < <(xcrun simctl list devices available \
        | grep -F "${SIMULATOR} (" \
        | grep -oiE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' || true)

    echo "錯誤：找不到可用的 ${SIMULATOR}。" >&2
    echo "本工作區只維護這一台；重建：xcrun simctl create \"${SIMULATOR}\" \"${SIMULATOR}\"" >&2
    exit 1
}

simulator_destination() { echo "platform=iOS Simulator,id=$(simulator_udid)"; }
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
    -destination "$(simulator_destination)" \
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
xcrun simctl boot "$(simulator_udid)" 2>/dev/null || true
open -a Simulator

step "Installing and launching ${BUNDLE_ID}"
xcrun simctl install booted "${APP}"
xcrun simctl launch booted "${BUNDLE_ID}"
