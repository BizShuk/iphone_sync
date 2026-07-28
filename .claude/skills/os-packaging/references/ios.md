# iOS 打包細節

## Build for Simulator（不需簽章）

```bash
xcodegen generate

xcodebuild \
  -project iPhoneSync.xcodeproj \
  -scheme iPhoneSyncIOS \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath build/derived \
  build

# 產出：build/derived/Build/Products/Debug-iphonesimulator/iPhoneSync.app
# 內含主 app + ControlCenter widget + Intents extension，三個 target 被打包成單一 .app bundle
```

## Archive + ExportArchive（裝置）

```bash
TEAM=$(scripts/detect_team.sh)
PROFILE="iPhoneSyncDevelopment"

xcodebuild \
  -project iPhoneSync.xcodeproj \
  -scheme iPhoneSyncIOS \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath build/iphone-sync.xcarchive \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM" \
  archive

cat > ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>          <!-- development | ad-hoc | app-store | enterprise -->
  <string>development</string>
  <key>teamID</key>
  <string>${TEAM}</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.shuk.iphonesync.ios</key>
    <string>${PROFILE}</string>
    <key>com.shuk.iphonesync.ios.controlcenter</key>
    <string>${PROFILE}</string>
  </dict>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/iphone-sync.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist

# 產出：build/ipa/iPhoneSync.ipa
```

`ExportOptions.plist` 切換簽章類型時只改 `method`：

| method | 給誰 |
|---|---|
| `development` | 自己的 iPhone（最常見） |
| `ad-hoc` | 已註冊 UDID 的多支實機 |
| `app-store` | 上架 |
| `enterprise` | 企業 in-house（需 enterprise 帳號） |

## 安裝 + 啟動

```bash
UDID=$(xcrun devicectl list devices --json-output \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)["result"]["devices"]
print([x["deviceProperties"]["udid"]
       for x in d
       if x["deviceProperties"].get("deviceType")=="iPhone"
       and x["connectionProperties"].get("tunnelState")=="connected"][0])')

# 直接裝 .app
xcrun devicectl device install app --device "$UDID" \
  build/derived/Build/Products/Release-iphoneos/iPhoneSync.app

# 或裝 .ipa
xcrun devicectl device install app --device "$UDID" build/ipa/iPhoneSync.ipa

xcrun devicectl device process launch --device "$UDID" com.shuk.iphonesync.ios
```

## iOS 特有特殊點

- 三個 target 一起被打包成單一 `.app`：主 app、ControlCenter widget extension、AppShortcuts extension（`Sources/Intents/AppShortcutsProvider`）。Widget 與 Intents extension 在 `.app/PlugIns/` 子目錄裡。
- iOS 必須區分 Ad-hoc 與 Development，後者只能給自己已註冊的 device UDID。
- App Store 上架前需在 App Store Connect 建立 app record、screenshots、metadata。
- iPhone 15 Pro / Pro Max 以上才有 LiDAR 與 Apple Intelligence；若專案依賴這些 capability，archive / upload 時需在 manifest 註明。
- `BGTaskSchedulerPermittedIdentifiers` 必須同時包含 production 與 debug identifier；少了會被 iOS 以 `BGTaskSchedulerErrorDomain` code `3` 拒絕。
- PhotoKit 必須以 `isNetworkAccessAllowed = false` 取得 resource。

## iOS 疑難排解

| 症狀 | 原因 | 解法 |
|---|---|---|
| `找不到 connected iPhone` | 裝置未解鎖 / Developer Mode 未開 / 線材未接 | 解鎖、開 Developer Mode 重開機、重新插線 |
| `Provisioning profile ... doesn't include signingCertificate` | profile 與 certificate 不匹配 | Xcode → Signing & Capabilities → 取消再勾 Automating signing 重建 |
| archive 成功但 exportArchive 失敗 | `ExportOptions.plist` provisioningProfiles 對應不到 | Xcode 查實際 profile 名稱後填入 |
| 裝置無法啟動 app | 免費簽章未信任 | `設定 → 一般 → VPN 與裝置管理` → 點 Apple ID → 信任 |
| 7 天後 app 打不開 | 免費 Apple Development 簽章過期 | 重新跑 archive + install |

## 相關檔案

- [project.yml](../../../project.yml)
- [apps/ios/iPhoneSync.entitlements](../../../apps/ios/iPhoneSync.entitlements)
- [apps/ios/ControlCenter/Info.plist](../../../apps/ios/ControlCenter/Info.plist)
- [apps/ios/Sources/Intents/Info.plist](../../../apps/ios/Sources/Intents/Info.plist)
- [scripts/verify.sh](../../../scripts/verify.sh)