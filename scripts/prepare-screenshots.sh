#!/bin/bash
# iPhoneSync - App Store screenshot 準備入口
#
#   ./scripts/prepare-screenshots.sh              # flatten + 驗證 appstore/preview
#   ./scripts/prepare-screenshots.sh --check      # 只驗證，不改檔
#   ./scripts/prepare-screenshots.sh --help
#
# App Store Connect 拒收帶 alpha channel 的截圖。模擬器與實機截圖都會帶一條
# 全不透明的 alpha，肉眼看不出來，但上傳時才會被擋。此腳本把 alpha 去掉
# （全不透明時為無損），並檢查尺寸是否符合送審規格。
#
# 送審尺寸見 docs/app-store-connect.md §5。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREVIEW_DIR="${PREVIEW_DIR:-${PROJECT_DIR}/appstore/preview}"
MODE="fix"

# App Store 接受的 iPhone 截圖尺寸（直向與橫向）。
VALID_SIZES=(
    "1320x2868" "2868x1320"   # 6.9"（必要）
    "1284x2778" "2778x1284"   # 6.5"（相容）
    "1242x2688" "2688x1242"   # 6.5" 舊版
)

fail() {
    echo "錯誤：$*" >&2
    exit 1
}

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

while (( $# > 0 )); do
    case "$1" in
        --check) MODE="check" ;;
        --help) usage; exit 0 ;;
        *) fail "未知參數：$1（--help 查看說明）" ;;
    esac
    shift
done

command -v sips >/dev/null 2>&1 || fail "找不到 sips（macOS 內建）"
[[ -d "${PREVIEW_DIR}" ]] || fail "找不到截圖目錄 ${PREVIEW_DIR}"

# 只處理送審用的 iPhone 截圖；其他素材（例如 intro page 用圖）以檔名前綴排除。
shopt -s nullglob
shots=("${PREVIEW_DIR}"/iphone-*.png)
shopt -u nullglob
(( ${#shots[@]} > 0 )) || fail "${PREVIEW_DIR} 內沒有 iphone-*.png 截圖"

status=0

for shot in "${shots[@]}"; do
    name="$(basename "${shot}")"
    width="$(sips -g pixelWidth "${shot}" | awk '/pixelWidth/ { print $2 }')"
    height="$(sips -g pixelHeight "${shot}" | awk '/pixelHeight/ { print $2 }')"
    alpha="$(sips -g hasAlpha "${shot}" | awk '/hasAlpha/ { print $2 }')"

    size_ok="no"
    for valid in "${VALID_SIZES[@]}"; do
        [[ "${width}x${height}" == "${valid}" ]] && size_ok="yes" && break
    done

    if [[ "${size_ok}" == "no" ]]; then
        echo "✗ ${name}：尺寸 ${width}×${height} 不在 App Store 接受清單"
        status=1
        continue
    fi

    if [[ "${alpha}" == "yes" ]]; then
        if [[ "${MODE}" == "check" ]]; then
            echo "✗ ${name}：含 alpha channel，上傳會被拒（跑一次不加 --check 修正）"
            status=1
            continue
        fi
        # sips 沒有 hasAlpha setter，且每次轉檔都會把 alpha 加回來；改用
        # 標準函式庫實作的 RGBA → RGB 重寫（全不透明時無損）。
        "${SCRIPT_DIR}/png-drop-alpha.py" "${shot}" >/dev/null
        alpha="$(sips -g hasAlpha "${shot}" | awk '/hasAlpha/ { print $2 }')"
        if [[ "${alpha}" == "yes" ]]; then
            echo "✗ ${name}：alpha 移除失敗"
            status=1
            continue
        fi
        echo "✓ ${name}：${width}×${height}，已移除 alpha"
    else
        echo "✓ ${name}：${width}×${height}，無 alpha"
    fi
done

exit "${status}"
