#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
command -v plutil >/dev/null

swift test --package-path packages/SyncCore
xcodegen generate

xcodebuild -quiet \
    -project iPhoneSync.xcodeproj \
    -scheme iPhoneSyncMac \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    clean build

xcodebuild -quiet \
    -project iPhoneSync.xcodeproj \
    -scheme iPhoneSyncIOS \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO \
    clean build

xcodebuild -quiet \
    -project iPhoneSync.xcodeproj \
    -scheme iPhoneSyncIOS \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build

test "$(plutil -extract NSBonjourServices.0 raw -o - apps/ios/Info.plist)" = "_iphonesync._tcp"
test "$(plutil -extract NSBonjourServices.1 raw -o - apps/ios/Info.plist)" = "_iphonesync-pair._tcp"
test "$(plutil -extract NSBonjourServices.0 raw -o - apps/macos/Info.plist)" = "_iphonesync._tcp"
test "$(plutil -extract NSBonjourServices.1 raw -o - apps/macos/Info.plist)" = "_iphonesync-pair._tcp"
test "$(plutil -extract LSUIElement raw -o - apps/macos/Info.plist)" = "true"
test "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - apps/macos/iPhoneSyncMac.entitlements)" = "true"
test "$(plutil -extract 'com\.apple\.security\.network\.client' raw -o - apps/macos/iPhoneSyncMac.entitlements)" = "true"
test "$(plutil -extract 'com\.apple\.security\.network\.server' raw -o - apps/macos/iPhoneSyncMac.entitlements)" = "true"
test "$(plutil -extract 'com\.apple\.security\.files\.user-selected\.read-write' raw -o - apps/macos/iPhoneSyncMac.entitlements)" = "true"
test "$(plutil -extract 'com\.apple\.security\.files\.bookmarks\.app-scope' raw -o - apps/macos/iPhoneSyncMac.entitlements)" = "true"

rg -F 'options.isNetworkAccessAllowed = false' apps/ios/Sources/PhotoLibrarySource.swift >/dev/null
rg -F 'parameters.includePeerToPeer = false' packages/SyncCore/Sources/SyncCore >/dev/null
rg -F 'TLS_PSK_WITH_AES_128_GCM_SHA256' packages/SyncCore/Sources/SyncCore/PSKTLSParameters.swift >/dev/null
rg -F 'private static let receiverRetryDelays: [UInt64] = [0, 1, 2, 4]' apps/ios/Sources/IOSSyncCoordinator.swift >/dev/null
rg -F 'UIApplication.openSettingsURLString' apps/ios/Sources/ContentView.swift >/dev/null
rg -F 'pairingExpiresAt' apps/ios/Sources/PairingView.swift >/dev/null
rg -F 'pairingError' apps/ios/Sources/PairingView.swift >/dev/null
rg -F 'cancelPairing' apps/ios/Sources/IOSSyncCoordinator.swift >/dev/null
if rg -F 'var assets: [PHAsset]' apps/ios/Sources/PhotoLibrarySource.swift >/dev/null; then
    exit 1
fi
if sed -n '/func cancel()/,/^    }/p' apps/ios/Sources/IOSAppModel.swift \
    | rg -F 'state = .ready' >/dev/null; then
    exit 1
fi

git diff --check
