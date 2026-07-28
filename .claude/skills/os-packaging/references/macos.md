# macOS 打包細節

## Build for 本機（不需簽章即可跑，但會被 Gatekeeper 警告）

```bash
xcodegen generate
swift build --package-path packages/SyncCore

xcodebuild \
  -project iPhoneSync.xcodeproj \
  -scheme iPhoneSyncMac \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath build/derived \
  build

open "build/derived/Build/Products/Debug/iPhone Sync.app"
```

第一次執行若出現「無法打開，因為來自未識別的開發者」：

```bash
xattr -dr com.apple.quarantine "build/derived/Build/Products/Debug/iPhone Sync.app"
```

或在 Finder 右鍵 → 打開 → 跳出警告時按「打開」。

## 給別人用的 Developer ID 流程（必須公證）

```bash
TEAM=$(scripts/detect_team.sh)
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $3; exit}')

xcodebuild \
  -project iPhoneSync.xcodeproj \
  -scheme iPhoneSyncMac \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath build/iphone-sync-mac.xcarchive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" \
  archive

cat > ExportOptions-mac.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>${TEAM}</string>
  <key>signingStyle</key>
  <string>manual</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/iphone-sync-mac.xcarchive \
  -exportPath build/mac-export \
  -exportOptionsPlist ExportOptions-mac.plist

# 產出：build/mac-export/iPhone Sync.app
```

接著包成 `.dmg` 或 `.pkg`：

```bash
APP="build/mac-export/iPhone Sync.app"

# DMG
hdiutil create -volname "iPhone Sync" \
  -srcfolder "$APP" \
  -ov -format UDZO \
  build/iPhoneSync.dmg

# PKG（安裝到 /Applications）
mkdir -p build/pkg-root
cp -R "$APP" build/pkg-root/
productbuild --component "build/pkg-root/iPhone Sync.app" /Applications \
  build/iPhoneSync.pkg
```

最後公證 + 釘選：

```bash
# 把 notarytool 用的 App-Specific Password 存進 keychain（一次性）
xcrun notarytool store-credentials --keychain-profile iphone-sync-notary \
  --apple-id "<your-apple-id>" --team-id "$TEAM"

xcrun notarytool submit build/iPhoneSync.dmg \
  --keychain-profile iphone-sync-notary \
  --wait

xcrun stapler staple build/iPhoneSync.dmg

xcrun stapler validate build/iPhoneSync.dmg
spctl -a -vv -t install build/iPhoneSync.dmg
```

## Mac App Store

```bash
cat > ExportOptions-mas.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store</string>
  <key>teamID</key>
  <string>${TEAM}</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/iphone-sync-mac.xcarchive \
  -exportPath build/mac-store \
  -exportOptionsPlist ExportOptions-mas.plist

xcrun altool --upload-package build/mac-store/iPhone\ Sync.pkg \
  --type osx --keychain-profile iphone-sync-notary
```

## 安裝方式

```bash
# 1. Debug build
open "build/derived/Build/Products/Debug/iPhone Sync.app"

# 2. Release 匯出的 .app
cp -R "build/mac-export/iPhone Sync.app" /Applications/
open "/Applications/iPhone Sync.app"

# 3. DMG
open build/iPhoneSync.dmg

# 4. PKG
open build/iPhoneSync.pkg

# 5. Mac App Store
open "macappstore://apps.apple.com/app/<app-store-id>"
```

## macOS 特有特殊點

- `LSUIElement = true`：menu-bar app，沒有 Dock icon、不在 `⌘+Tab` 切換。啟動後只能在 menu bar 右上角看到 NSStatusItem。
- **App Sandbox 強制**：沒有 Full Disk Access 也不應要求；只能在 `NSOpenPanel` 選定的 folder 內讀寫，並透過 `security-scoped bookmark` 跨重啟保存 capability。
- **Hardened Runtime**：Developer ID 流程會自動啟用；不需額外設定。
- macOS 沒有「給定裝置跑」的概念（無 UDID 白名單）；簽章 + 公證決定能不能跑，不是哪台 Mac。
- macOS 14 不顯示 Local Network privacy prompt；macOS 15+ 才有。
- `SMAppService.mainApp` 是 Launch-at-login 的關鍵，登入後自動恢復 receiver；包裝不影響，但權限提示會在使用者設定的 Login Items 顯示。

## macOS 疑難排解

| 症狀 | 原因 | 解法 |
|---|---|---|
| archive 失敗，找不到 `iPhoneSyncMac` scheme | `project.yml` 變更後未重新 generate | `xcodegen generate` |
| `Could not find module 'SyncCore'` | swift package 沒編過 | `swift build --package-path packages/SyncCore` |
| App 啟動後沒有 menu bar 圖示 | 程式 crash 在 startup | `log stream --predicate 'subsystem == "com.shuk.iphonesync.mac"' --info` |
| 雙擊 `.dmg` 出現「app 已損毀」 | 沒公證或公證被拒 | `xcrun notarytool log <submission-id>` 看 Apple 回的 log |
| 公證失敗：`The binary uses an SDK older than the 11.0 SDK` | deployment target 過舊 | macOS 14 已遠高於 10.9，理論上不會遇到 |
| 安裝後寫不到選定的資料夾 | security-scoped bookmark 沒 startAccess | 檢查 `DestinationBookmarkStore` 啟動路徑 |
| 開啟 App 後看不到 Bonjour service 發布 | App Sandbox 阻擋 mDNS | 確認 entitlements 有 `network.server` / `network.client` |
| Apple Silicon 上 `codesign` 報 `not signed at all` | 重新包裝後沒重新簽 framework | `codesign --force --deep --sign "<identity>" <.app>` |

## 相關檔案

- [project.yml](../../../project.yml)
- [apps/macos/iPhoneSyncMac.entitlements](../../../apps/macos/iPhoneSyncMac.entitlements)
- [scripts/run_server.sh](../../../scripts/run_server.sh)
- [packages/SyncCore/Sources/MacReceiverKit](../../../packages/SyncCore/Sources/MacReceiverKit)