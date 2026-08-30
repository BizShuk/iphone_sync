#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  bash scripts/stage-mac-download.sh [--help]

把 build/mac-dist/ 裡最新的 macOS 安裝檔複製到 web/download/, 讓上手指南站
`自己端出` Mac receiver, 不必經過 GitHub Releases:

  web/download/iPhoneSync-Mac.dmg
  web/download/iPhoneSync-Mac.pkg

檔名`固定不含版號`, 因為 web/index.html 的下載按鈕是寫死的相對路徑。

這兩個檔`會進版控`: liva 是 Linux, 沒有 Xcode, image 在那裡建的時候只能
COPY 一份已經存在的產物。代價是每次改版都會在 git 裡留下一份 ~8 MB 的
blob——所以只在`真的要發佈新版站台`時才跑這支腳本, 不要每次本機建置都跑。

先跑 scripts/package-mac.sh 產生 build/mac-dist/, 或直接用 npm run build:mac
(它會依序做完打包與 staging)。
USAGE
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

src="build/mac-dist"
dst="web/download"

newest() {
    # 同一個目錄可能留著多個版號的舊產物, 取 mtime 最新的那一份。
    ls -t "$src"/*."$1" 2>/dev/null | head -n1
}

dmg="$(newest dmg)"
pkg="$(newest pkg)"

for f in "$dmg" "$pkg"; do
    [[ -n "$f" && -f "$f" ]] || {
        printf '錯誤: %s/ 裡找不到 .dmg 或 .pkg, 先跑 bash scripts/package-mac.sh\n' "$src" >&2
        exit 1
    }
done

# 對外散布的那一份必須是 ad-hoc。package-mac.sh 預設會抓 Keychain 裡第一個
# Apple Development identity, 那種簽章在`別台機器上會被 Gatekeeper 直接拒絕`
# 且無法公證——比 ad-hoc 更糟, 而且錯誤訊息不會告訴使用者原因。
mount_point="$(hdiutil attach -nobrowse -readonly "$dmg" | awk -F'\t' '/Volumes/{print $NF}')"
signature="$(codesign -dv "$mount_point/iPhone Sync.app" 2>&1 | awk -F= '/^Signature/{print $2}')"
hdiutil detach "$mount_point" >/dev/null
if [[ "$signature" != "adhoc" ]]; then
    printf '錯誤: %s 的簽章是 %s, 不是 adhoc。\n' "$dmg" "${signature:-未知}" >&2
    printf '      對外散布請以 MAC_SIGN_IDENTITY=- 重跑 bash scripts/package-mac.sh,\n' >&2
    printf '      或設定 Developer ID + notarization 後再放寬這個檢查。\n' >&2
    exit 1
fi

mkdir -p "$dst"
cp -f "$dmg" "$dst/iPhoneSync-Mac.dmg"
cp -f "$pkg" "$dst/iPhoneSync-Mac.pkg"

printf '已 staging 到 %s/:\n' "$dst"
ls -lh "$dst"/iPhoneSync-Mac.dmg "$dst"/iPhoneSync-Mac.pkg | awk '{printf "  %-28s %s\n", $NF, $5}'
