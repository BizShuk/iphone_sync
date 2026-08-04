#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  bash scripts/verify.sh [--build-only|--launch-view|--help]

  --build-only   run canonical verification only (build + checks). This is the default.
  --launch-view  launch the built macOS receiver app for visual check only.
  --help         show this usage.
USAGE
}

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
command -v jq >/dev/null
command -v plutil >/dev/null

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    --launch-view)
        bash scripts/run_server.sh --no-build
        exit 0
        ;;
    --build-only|"")
        [[ $# -le 1 ]] || {
            printf '錯誤: 僅接受 --build-only、--launch-view 或 --help\n' >&2
            exit 1
        }
        ;;
    *)
        printf '錯誤: 不支援參數: %s\n' "$1" >&2
        usage
        exit 1
        ;;
esac

settings_test_dir="build/verification"
settings_test_binary="$settings_test_dir/verify-mac-settings"
mkdir -p "$settings_test_dir"
synccore_build_dir="$(swift build --package-path packages/SyncCore --show-bin-path)"
synccore_module_dir="$synccore_build_dir/Modules"
test -f "$synccore_module_dir/SyncCore.swiftmodule"
xcrun swiftc \
    -D VERIFY_STANDALONE \
    -I "$synccore_module_dir" \
    apps/macos/Sources/MacSettingsStore.swift \
    scripts/verify_mac_settings.swift \
    -o "$settings_test_binary"
"$settings_test_binary"

destination_test_binary="$settings_test_dir/verify-mac-destination"
xcrun swiftc \
    -D VERIFY_STANDALONE \
    -I "$synccore_module_dir" \
    apps/macos/Sources/MacSettingsStore.swift \
    apps/macos/Sources/DestinationRootResolver.swift \
    apps/macos/Sources/DestinationBookmarkStore.swift \
    scripts/verify_mac_destination.swift \
    -o "$destination_test_binary"
"$destination_test_binary"

swift test --package-path packages/SyncCore
xcodegen generate

ios_test_device_id="$(
    xcrun simctl list devices available -j \
        | jq -r '[.devices[][] | select(.isAvailable and (.name | startswith("iPhone")))] | first | .udid // empty'
)"
test -n "$ios_test_device_id"

xcodebuild -quiet \
    -project iPhoneSync.xcodeproj \
    -scheme iPhoneSyncIOS \
    -destination "platform=iOS Simulator,id=$ios_test_device_id" \
    CODE_SIGNING_ALLOWED=NO \
    clean test

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
    -configuration Release \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build

test "$(plutil -extract BGTaskSchedulerPermittedIdentifiers.0 raw -o - apps/ios/Info.plist)" = "com.shuk.iphonesync.ios.scheduled-sync"
test "$(plutil -extract BGTaskSchedulerPermittedIdentifiers.1 raw -o - apps/ios/Info.plist)" = "com.shuk.iphonesync.ios.scheduled-sync.debug"
test "$(plutil -extract UIBackgroundModes.0 raw -o - apps/ios/Info.plist)" = "processing"
test "$(plutil -extract NSPhotoLibraryUsageDescription raw -o - apps/ios/Info.plist)" \
    = "Select albums, back up their original resources, and optionally delete fully backed-up photos after confirmation."
if plutil -extract NSPhotoLibraryAddUsageDescription raw -o - apps/ios/Info.plist \
    >/dev/null 2>&1; then
    exit 1
fi
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
rg -F 'PHAssetChangeRequest.deleteAssets' apps/ios/Sources/PhotoLibrarySource.swift >/dev/null
rg -F 'candidate.modificationDate == asset.modificationDate' apps/ios/Sources/PhotoLibrarySource.swift >/dev/null
rg -F 'case assetFinished(' apps/ios/Sources/PhotoLibrarySource.swift >/dev/null
rg -F 'guard store.isEnabled else { return }' apps/ios/Sources/DeleteAfterSync.swift >/dev/null
rg -F 'trigger == .automaticBackground' apps/ios/Sources/DeleteAfterSync.swift >/dev/null
rg -F 'parameters.includePeerToPeer = false' packages/SyncCore/Sources/SyncCore >/dev/null
rg -F 'TLS_PSK_WITH_AES_128_GCM_SHA256' packages/SyncCore/Sources/SyncCore/PSKTLSParameters.swift >/dev/null
rg -F 'private static let receiverRetryDelays: [UInt64] = [0, 1, 2, 4]' apps/ios/Sources/IOSSyncCoordinator.swift >/dev/null
rg -F 'UIApplication.openSettingsURLString' apps/ios/Sources/ContentView.swift >/dev/null
rg -F 'pairingExpiresAt' apps/ios/Sources/PairingView.swift >/dev/null
rg -F 'pairingError' apps/ios/Sources/PairingView.swift >/dev/null
rg -F 'cancelPairing' apps/ios/Sources/IOSSyncCoordinator.swift >/dev/null
rg -F 'var selectedAlbums: [PhotoAlbum]' apps/ios/Sources/IOSAppModel.swift >/dev/null
rg -F '.navigationTitle("Choose Albums")' apps/ios/Sources/AlbumPickerView.swift >/dev/null
rg -F 'func sync(albums: [PhotoAlbum])' apps/ios/Sources/IOSSyncCoordinator.swift >/dev/null
rg -F 'com.shuk.iphonesync.ios.scheduled-sync' apps/ios/Sources/AutomaticSyncScheduler.swift >/dev/null
rg -F 'using: .main' apps/ios/Sources/AutomaticSyncScheduler.swift >/dev/null
rg -F 'execution.worker?.cancel()' apps/ios/Sources/AutomaticSyncScheduler.swift >/dev/null
rg -F 'execution.forcedOutcome = .budgetExhausted' apps/ios/Sources/AutomaticSyncScheduler.swift >/dev/null
rg -F 'restoredRequestDate(' apps/ios/Sources/AutomaticSyncScheduler.swift >/dev/null
rg -F 'requestScheduler.pendingRequests()' apps/ios/Sources/AutomaticSyncScheduler.swift >/dev/null
rg -F 'guard !isSceneActive else { return }' apps/ios/Sources/IOSAppModel.swift >/dev/null
rg -F 'guard isSceneActive else { return }' apps/ios/Sources/IOSAppModel.swift >/dev/null
rg -F 'nextEligibleAt: self.automaticDebugSync.nextEligibleAt' apps/ios/Sources/IOSAppModel.swift >/dev/null
rg -F 'await automaticProductionScheduler.ensureScheduled()' apps/ios/Sources/IOSAppModel.swift >/dev/null
rg -F 'await automaticDebugScheduler.ensureScheduled()' apps/ios/Sources/IOSAppModel.swift >/dev/null
rg -F 'await activeClient.cancel()' apps/ios/Sources/IOSSyncCoordinator.swift >/dev/null
rg -F 'cancelDataRequest' apps/ios/Sources/PhotoLibrarySource.swift >/dev/null
rg -F 'defaultOpeningTimeout: Duration = .seconds(15)' packages/SyncCore/Sources/MacReceiverKit/SyncServerSession.swift >/dev/null
rg -F 'public static let receivingFolderName = "iPhoneSync"' packages/SyncCore/Sources/MacReceiverKit/DestinationWriter.swift >/dev/null
rg -F 'struct MacSettingsStore' apps/macos/Sources/MacSettingsStore.swift >/dev/null
rg -F 'var launchAtLoginRequested: Bool' apps/macos/Sources/MacSettingsStore.swift >/dev/null
rg -F 'FileManager.default.urls(' apps/macos/Sources/MacAppModel.swift >/dev/null
rg -F 'for: .downloadsDirectory' apps/macos/Sources/MacAppModel.swift >/dev/null
rg -F 'struct IOSOperationLogCard' apps/ios/Sources/ContentView.swift >/dev/null
rg -F 'sectionHeader("Operation Log")' apps/macos/Sources/SetupView.swift >/dev/null
rg -F 'public static let defaultCapacity = 500' packages/SyncCore/Sources/SyncCore/OperationLog.swift >/dev/null
rg -F 'onEvent: EventHandler? = nil' packages/SyncCore/Sources/MacReceiverKit/SyncServerSession.swift >/dev/null
rg -F 'operationLogBuffer.record(event)' apps/ios/Sources/IOSAppModel.swift >/dev/null
rg -F 'operationLogBuffer.record(event)' apps/macos/Sources/MacAppModel.swift >/dev/null
rg -F 'NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)' apps/macos/Sources/iPhoneSyncMacApp.swift >/dev/null
rg -F 'item.autosaveName = "com.shuk.iphonesync.statusItem"' apps/macos/Sources/iPhoneSyncMacApp.swift >/dev/null
rg -F 'statusItem.isVisible = true' apps/macos/Sources/iPhoneSyncMacApp.swift >/dev/null
rg -F 'item.observe(\.isVisible' apps/macos/Sources/iPhoneSyncMacApp.swift >/dev/null
rg -F 'maximumListenerRetryAttempts = 5' apps/macos/Sources/ReceiverController.swift >/dev/null
rg -F 'NSWorkspace.didWakeNotification' apps/macos/Sources/MacAppModel.swift >/dev/null
if rg -F 'MenuBarExtra(' apps/macos/Sources >/dev/null; then
    exit 1
fi
if rg -F 'UserDefaults.standard' apps/macos/Sources/MacAppModel.swift >/dev/null; then
    exit 1
fi
if rg -F 'var assets: [PHAsset]' apps/ios/Sources/PhotoLibrarySource.swift >/dev/null; then
    exit 1
fi
if sed -n '/func cancel()/,/^    }/p' apps/ios/Sources/IOSAppModel.swift \
    | rg -F 'state = .ready' >/dev/null; then
    exit 1
fi

git diff --check
git diff --cached --check
while IFS= read -r -d '' untracked_file; do
    untracked_check="$(
        git diff --no-index --check -- /dev/null "$untracked_file" 2>&1 || true
    )"
    if [[ -n "$untracked_check" ]]; then
        printf '%s\n' "$untracked_check" >&2
        exit 1
    fi
done < <(git ls-files --others --exclude-standard -z)

# === Windows 11 receiver (Electron + Node.js port) ===
# Skipped if the Windows port scaffolding is not present yet (pre-Phase 1
# state) or if node/npm is unavailable. The script is cross-platform; the
# electron-builder packaging step only runs on Windows MSYS shells.
if [[ -d "packages/SyncCore.Windows" && -d "apps/windows" ]]; then
    bash scripts/verify_windows.sh
fi
