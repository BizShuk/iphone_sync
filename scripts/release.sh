#!/bin/bash
# iPhoneSync - App Store 上架入口
#
#   ./scripts/release.sh                # archive → export(.ipa) → upload 到 App Store Connect
#   ./scripts/release.sh --export-only  # 只產生 .ipa，不上傳
#   ./scripts/release.sh --help
#
# 上傳需要 App Store Connect API key
# （App Store Connect → Users and Access → Integrations → App Store Connect API）：
#
#   ASC_KEY_ID     Key ID
#   ASC_ISSUER_ID  Issuer ID
#   ASC_KEY_PATH   .p8 私鑰路徑，預設 ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
#
# 這個腳本只送`建置產物`。App record、screenshots、metadata、送審與釋出都在
# App Store Connect 上完成——那些是產品決策，不是可重跑的建置步驟。
#
# TODO(上架前置)：這條路徑`尚未實際跑過`。缺的是 App Store Connect 上的 app record
# 與 distribution 憑證；未設定 API key 時腳本會在 archive 之前就失敗，
# 不會留下看起來像上架成功的產物。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

SCHEME="iPhoneSyncIOS"
BUNDLE_ID="com.shuk.iphonesync.ios"
PROJECT="${PROJECT_DIR}/iPhoneSync.xcodeproj"
BUILD_ROOT="${BUILD_ROOT:-${PROJECT_DIR}/build/appstore}"
ARCHIVE_PATH="${BUILD_ROOT}/iPhoneSync.xcarchive"
EXPORT_PATH="${BUILD_ROOT}/ipa"
EXPORT_OPTIONS="${BUILD_ROOT}/ExportOptions.plist"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
MODE="upload"

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
        --export-only) MODE="export" ;;
        --help) usage; exit 0 ;;
        *) fail "未知參數：$1（--help 查看說明）" ;;
    esac
    shift
done

require xcodebuild "請安裝 Xcode"

[[ -n "${DEVELOPMENT_TEAM}" ]] || fail "尚未設定 DEVELOPMENT_TEAM（Apple Developer team ID）；distribution 簽章沒有它無法進行"

# 先檢查上傳憑證再開始 archive。archive 要跑好幾分鐘，把檢查放最後等於白等；
# 更糟的是「archive 成功」看起來會像上架成功。
if [[ "${MODE}" == "upload" ]]; then
    [[ -n "${ASC_KEY_ID:-}" ]] || fail "尚未設定 ASC_KEY_ID，無法上傳 App Store（只要 .ipa 請用 --export-only）"
    [[ -n "${ASC_ISSUER_ID:-}" ]] || fail "尚未設定 ASC_ISSUER_ID，無法上傳 App Store（只要 .ipa 請用 --export-only）"
    ASC_KEY_PATH="${ASC_KEY_PATH:-${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
    [[ -f "${ASC_KEY_PATH}" ]] || fail "找不到 App Store Connect API key：${ASC_KEY_PATH}"
fi

require xcodegen "請執行：brew install xcodegen"

step "Regenerating Xcode project"
xcodegen generate --quiet

rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}"
mkdir -p "${BUILD_ROOT}"

# Archive 一律 Release：Debug 產物帶著 debug entitlement 與未最佳化的 binary，
# App Store Connect 會直接退件。
step "Archiving ${SCHEME} (Release) for App Store"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    archive

# destination 停在 export：先把 .ipa 落地再上傳，失敗時才有東西可以檢查。
# 讓 xcodebuild 直接 upload 的話，磁碟上不會留下任何產物。
cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>teamID</key>
  <string>${DEVELOPMENT_TEAM}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST

step "Exporting .ipa"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates

IPA="$(find "${EXPORT_PATH}" -maxdepth 1 -name '*.ipa' -print -quit)"
[[ -n "${IPA}" ]] || fail "export 沒有產生 .ipa"
printf '\nIPA: %s\n' "${IPA}"

if [[ "${MODE}" == "export" ]]; then
    echo "已停在 export；要上傳請不加 --export-only 重跑。"
    exit 0
fi

step "Uploading ${BUNDLE_ID} to App Store Connect"
xcrun altool --upload-app \
    --type ios \
    --file "${IPA}" \
    --apiKey "${ASC_KEY_ID}" \
    --apiIssuer "${ASC_ISSUER_ID}"

echo "已上傳。App Store Connect 處理完成後，在該處選這個 build 送審。"
