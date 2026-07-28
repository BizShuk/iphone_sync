---
name: os-packaging
description: Build, sign, package, notarize, and install the iPhone Sync iOS app, macOS menu-bar receiver, or Windows 11 Electron receiver into a distributable bundle (.app, .ipa, .pkg, .dmg, .exe, .xcarchive, NSIS installer, portable .exe) for Simulator, generic device, development device, ad-hoc, Developer ID, App Store Connect, Mac App Store, Microsoft Store, or sideload distribution. Use when the user asks "how to pack ios app in single bundle to install", "how to pack mac app", "build IPA", "export IPA", "notarize", "DMG", "package installer", "export .pkg", "electron-builder", "NSIS installer", "portable exe", "Authenticode", "Mac 上打包", "封裝 iOS", "封裝 Mac", "封裝 Windows", "實機打包", or any question about producing an installable iOS, macOS, or Windows artifact for iphone_sync. References break out iOS, macOS, and Windows specifics; this main file only carries shared rules and the scenario matrix.
---

# iOS / macOS / Windows App 打包

> 平台細節在 [`references/ios.md`](references/ios.md)、[`references/macos.md`](references/macos.md)、[`references/windows.md`](references/windows.md)。本檔只放跨平台共用原則與決策矩陣。

## 適用情境（先決定要哪一種）

| 目標 | iOS 產出 | macOS 產出 | Windows 產出 |
|---|---|---|---|
| 本機開發 / 跑起來看 | `Debug-iphonesimulator/iPhoneSync.app` | `Debug/iPhone Sync.app` | `dist/` 直接 `electron .` |
| Source contract 驗證（不安裝） | generic iOS device `.app` | generic macOS `.app` | `tsc` type-check + `vitest` |
| 自己的裝置跑 | signed `.app` 或 `.ipa` | signed `.app` | 直接跑 portable `.exe` |
| 給特定裝置跑（白名單） | signed `.ipa`（UDID） | — | — |
| 散佈到別人的 Mac / Windows | — | `.dmg` 或 `.pkg` + 公證 + stapler | NSIS installer / portable `.exe`，Authenticode 簽章 |
| App Store 上架 | signed `.ipa` | `.pkg` | MSIX（Microsoft Store）或 sideload |

`scripts/verify.sh` 與 `scripts/verify_windows.sh` 已涵蓋 source contract 驗證；本 skill 處理其餘情境。

## 前置條件（一次性）

### Apple 端（iOS / macOS 共同）

- 已執行 `xcodegen generate` 至少一次；之後每次改 `project.yml` 都要重跑。
- macOS 上已安裝 `xcodegen`（`brew install xcodegen`）、`jq`、`plutil`。
- 已在 Xcode GUI 完成一次 Apple ID 登入 + 自動簽章設定（用 Xcode 開 `iPhoneSync.xcodeproj`、選實機、`Cmd+R` 一次）。
- iOS 實機端：解鎖、`設定 → 隱私權與安全性 → 開發者模式` 開啟並重開機。
- macOS 散佈用：Developer ID Application certificate（透過 Xcode → Accounts → Manage Certificates 申請），以及 App Store Connect 的 App-Specific Password 給 `notarytool`。

### Windows 端

- Windows 11 22H2+ 開發機；或 macOS / Linux 跑 Wine + electron-builder cross-build。
- Node.js 22 LTS 與 `npm install` 過一次（會跑 `postinstall` 把 SyncCore.Windows 模組配置好）。
- 散佈用 Authenticode code-signing certificate（OV / EV），以及 Azure Trusted Signing account。
- 不需 `project.yml`；Windows target 設定在 `apps/windows/electron-builder.yml`。

`project.yml`（iOS / macOS）不保存 signing team / identity / provisioning profile；它只決定 Info.plist 與 entitlements 的內容。

## 專案專屬事實

| 面向 | iOS | macOS | Windows |
|---|---|---|---|
| Bundle / App ID | `com.shuk.iphonesync.ios` | `com.shuk.iphonesync.mac` | `com.shuk.iphonesync.windows` |
| 部署目標 | iOS 18+ | macOS 14+ | Windows 11 22H2+ |
| Tech stack | Swift 6 + SwiftUI + UIKit | Swift 6 + AppKit | Node.js 22 + TypeScript 5 + Electron 32 |
| Targets | `iPhoneSyncIOS`、`iPhoneSyncControlCenter`、Intents extension | `iPhoneSyncMac` | single Electron main |
| Schemes | `iPhoneSyncIOS`、`iPhoneSyncIOSTests` | `iPhoneSyncMac`（XcodeGen 自動） | — |
| Entitlements | `apps/ios/iPhoneSync.entitlements` | `apps/macos/iPhoneSyncMac.entitlements` | electron-builder.yml `win` block |
| App Sandbox / 隔離 | — | 強制 | 預設未啟用 |
| 依賴套件 | `SyncCore` | `SyncCore` + `MacReceiverKit` | `@iphonesync/synccore-windows` |
| 啟動入口 | 主 app icon / Control widget / Shortcut / BG task | menu-bar icon（`LSUIElement = true`） | tray icon |
| 啟動指令 | `xcrun devicectl device process launch` | `bash scripts/run_server.sh` | `npm start` 或 `electron .` |

共同：

- 同一份 Bonjour 宣告（`_iphonesync._tcp` + `_iphonesync-pair._tcp`）。
- 同一份 cryptographic identity framework（Curve25519 + TLS 1.2 PSK + SHA-256 integrity）。
- iOS / macOS 共享同一個 Apple Developer signing team。
- Windows 與 Apple 兩端獨立，不共享 certificate / store。

## 偵測 Apple signing team（CLI 自動）

不是用 `security find-identity` 顯示名稱括號內的識別碼，而是讀 certificate subject 的 `OU`：

```bash
scripts/detect_team.sh
```

或一行版：

```bash
security find-identity -v -p codesigning \
  | awk '/Apple Development/{print $3}' \
  | head -1 \
  | xargs -I{} security find-certificate -p -c "{}" /Library/Keychains/System.keychain \
  | openssl x509 -noout -subject -nameopt RFC2253 \
  | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p'
```

零組或多組結果時回到 Xcode GUI 設定一次。Windows 端不適用此腳本；改用 `signtool` 或 Azure Trusted Signing。

## Quick Reference

| 操作 | iOS | macOS | Windows |
|---|---|---|---|
| 本機 build | `xcodebuild ... -destination "generic/platform=iOS Simulator"` | `xcodebuild ... -destination "platform=macOS"` | `npm run dev`（tsc watch）+ `npm start` |
| Source contract 驗證 | `bash scripts/verify.sh` | 同 | `bash scripts/verify_windows.sh` |
| Archive / 包裝 | `xcodebuild ... archive -archivePath build/iphone-sync.xcarchive` | `xcodebuild ... archive -archivePath build/iphone-sync-mac.xcarchive` | `npm run dist`（electron-builder NSIS + portable） |
| 匯出 / 散佈 artifact | `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist` → `.ipa` | `xcodebuild -exportArchive ...` → `.app` + `hdiutil` / `productbuild` | electron-builder 直接產 `.exe` installer + portable |
| 公證 / 簽章 | App Store Connect（自動） | `xcrun notarytool submit ... --wait` + `xcrun stapler staple ...` | `signtool sign /fd SHA256 /tr ...` + SmartScreen reputation |
| 安裝到裝置 | `xcrun devicectl device install app --device <UDID> <path>` | `cp -R` / `open` / DMG 雙擊 / PKG 雙擊 | 雙擊 `.exe` installer；或解壓 portable `.exe` |
| 啟動 app | `xcrun devicectl device process launch --device <UDID> com.shuk.iphonesync.ios` | `bash scripts/run_server.sh` | `npm start` 或從 Start menu |
| 即時 log | `xcrun devicectl device info log --device <UDID>` | `log stream --predicate 'subsystem == "com.shuk.iphonesync.mac"'` | Windows Event Viewer / VSCode attach / `console.log` |

詳細步驟與 `ExportOptions.plist` 模板在：

- [references/ios.md](references/ios.md)
- [references/macos.md](references/macos.md)
- [references/windows.md](references/windows.md)

## 同步檢查清單

任何打包設定變更後，逐項確認：

- [ ] 對應平台的設定檔已修改（`project.yml` / `electron-builder.yml`）
- [ ] 必要時已重跑 `xcodegen generate`（Apple）或 `npm install`（Windows）
- [ ] `apps/<platform>/` 下產生的 Info.plist / entitlements / assets 與 source 一致
- [ ] 對應的 `scripts/verify*.sh` 通過
- [ ] 本機 build / 模擬器 / electron dev server 啟動成功
- [ ] Release artifact 能在目標裝置上安裝並啟動
- [ ] 若要散佈：公證 / Authenticode 簽章成功
- [ ] `.claude/skills/os-permission/`、`README.permission.md` 與本檔同步更新

## 相關檔案

- [project.yml](../../project.yml) — iOS / macOS Info.plist 與 entitlements 唯一來源
- [apps/windows/electron-builder.yml](../../apps/windows/electron-builder.yml) — Windows 包裝設定
- [apps/windows/package.json](../../apps/windows/package.json) — Windows app metadata 與 npm scripts
- [apps/ios/iPhoneSync.entitlements](../../apps/ios/iPhoneSync.entitlements) — iOS 簽章對象
- [apps/macos/iPhoneSyncMac.entitlements](../../apps/macos/iPhoneSyncMac.entitlements) — macOS App Sandbox + 必要能力
- [scripts/verify.sh](../../scripts/verify.sh) — Apple source contract 驗證
- [scripts/verify_windows.sh](../../scripts/verify_windows.sh) — Windows source contract 驗證
- [scripts/run_server.sh](../../scripts/run_server.sh) — Mac 日常啟動入口
- [.claude/skills/os-permission/](../os-permission/SKILL.md) — 跨平台權限稽核
- [README.permission.md](../../README.permission.md) — iOS / macOS 權限盤點
- [CLAUDE.md](../../CLAUDE.md) — 專案技術脈絡
- [README.todo](../../README.todo) — 實機背景行為驗證待辦