#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  bash scripts/package-mac.sh [--version <X.Y.Z>] [--help]

Builds the Release iPhoneSyncMac universal app and packages one-click
install artifacts into build/mac-dist/:

  iPhoneSync-Mac-<version>.dmg   drag-to-Applications disk image
  iPhoneSync-Mac-<version>.pkg   double-click installer into /Applications

--version defaults to MARKETING_VERSION in project.yml; a leading "v" is
stripped, so tag names like v1.2.3 are accepted as-is.

Environment:
  MAC_BUILD_NUMBER        CFBundleVersion (default: 1; CI passes the run number)
  MAC_SIGN_IDENTITY       codesign identity (default: the first Apple
                          Development identity in the Keychain, else "-" =
                          ad-hoc; set to "Developer ID Application: ..." for
                          distribution — an Apple Development identity is
                          rejected by Gatekeeper on other machines and cannot
                          be notarized)
  MAC_INSTALLER_IDENTITY  optional "Developer ID Installer: ..." for the pkg
  MAC_NOTARY_PROFILE      optional notarytool keychain profile; alternatively
                          set MAC_NOTARY_APPLE_ID + MAC_NOTARY_TEAM_ID +
                          MAC_NOTARY_PASSWORD (App-Specific Password).
                          Notarization only runs with a non-ad-hoc identity.
USAGE
}

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
command -v plutil >/dev/null
command -v codesign >/dev/null
command -v hdiutil >/dev/null
command -v productbuild >/dev/null

version=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --version)
            [[ $# -ge 2 ]] || {
                printf '錯誤: --version 需要一個值\n' >&2
                exit 1
            }
            version="$2"
            shift 2
            ;;
        *)
            printf '錯誤: 不支援參數: %s\n' "$1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$version" ]]; then
    version="$(awk '$1 == "MARKETING_VERSION:" {print $2; exit}' project.yml)"
fi
version="${version#v}"
[[ "$version" =~ ^[0-9][A-Za-z0-9.-]*$ ]] || {
    printf '錯誤: 無效版本字串: %s\n' "$version" >&2
    exit 1
}

build_number="${MAC_BUILD_NUMBER:-1}"
identity="${MAC_SIGN_IDENTITY:-$(
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}' || true
)}"
identity="${identity:--}"
entitlements="apps/macos/iPhoneSyncMac.entitlements"
derived="build/mac-release-derived"
dist="build/mac-dist"
app="$derived/Build/Products/Release/iPhone Sync.app"
dmg="$dist/iPhoneSync-Mac-$version.dmg"
pkg="$dist/iPhoneSync-Mac-$version.pkg"

rm -rf "$dist"
mkdir -p "$dist"

xcodegen generate
xcodebuild -quiet \
    -project iPhoneSync.xcodeproj \
    -scheme iPhoneSyncMac \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGNING_ALLOWED=NO \
    clean build

test -d "$app"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version"
test "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" = "$build_number"

if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --entitlements "$entitlements" "$app"
else
    codesign --force --options runtime --timestamp \
        --sign "$identity" --entitlements "$entitlements" "$app"
fi
codesign --verify --deep --strict "$app"
codesign --display --entitlements - "$app" 2>/dev/null \
    | grep -q 'com.apple.security.app-sandbox'

volume_root="$dist/dmg-root"
mkdir -p "$volume_root"
cp -R "$app" "$volume_root/"
ln -s /Applications "$volume_root/Applications"
hdiutil create -quiet \
    -volname "iPhone Sync" \
    -srcfolder "$volume_root" \
    -fs HFS+ \
    -ov -format UDZO \
    "$dmg"
rm -rf "$volume_root"

if [[ -n "${MAC_INSTALLER_IDENTITY:-}" ]]; then
    productbuild --component "$app" /Applications \
        --sign "$MAC_INSTALLER_IDENTITY" "$pkg"
else
    productbuild --component "$app" /Applications "$pkg"
fi

have_notary_credentials() {
    [[ -n "${MAC_NOTARY_PROFILE:-}" ]] && return 0
    [[ -n "${MAC_NOTARY_APPLE_ID:-}" \
        && -n "${MAC_NOTARY_TEAM_ID:-}" \
        && -n "${MAC_NOTARY_PASSWORD:-}" ]]
}

notarize() {
    local artifact="$1"
    if [[ -n "${MAC_NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$artifact" \
            --keychain-profile "$MAC_NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$artifact" \
            --apple-id "$MAC_NOTARY_APPLE_ID" \
            --team-id "$MAC_NOTARY_TEAM_ID" \
            --password "$MAC_NOTARY_PASSWORD" --wait
    fi
    xcrun stapler staple "$artifact"
}

if [[ "$identity" != "-" ]] && have_notary_credentials; then
    notarize "$dmg"
    if [[ -n "${MAC_INSTALLER_IDENTITY:-}" ]]; then
        notarize "$pkg"
    fi
elif [[ "$identity" != "-" ]]; then
    printf '未設定 notary credentials，跳過公證\n'
fi

printf '產出:\n'
ls -lh "$dist"
