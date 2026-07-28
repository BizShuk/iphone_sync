---
name: os-permission
description: Audit and synchronize every iOS, macOS, and Windows permission, privacy usage key, Bonjour declaration, App Sandbox entitlement, persistent access grant, launch-at-login approval, Windows capability, and AppX manifest declaration required by iPhone Sync. Use when adding or changing Photos, local-network, Finder destination, Keychain, login-item, sandbox, Windows Firewall, capability, AppX manifest, or signing behavior; when a permission prompt or protected operation fails; or when references/permissions.md, README.permission.md, project.yml, electron-builder.yml, generated Info.plist files, entitlements, AppX manifest, and scripts/verify*.sh invariants must be kept consistent. Triggers on "permission audit", "權限稽核", "TCC", "privacy prompt", "entitlement", "usage description", "sandbox", "Windows capability", "AppX manifest", "Firewall rule", "安全範圍 bookmark", "launch at login".
---

# iPhone Sync 權限稽核

> 平台細節與統一目錄在 [`references/permissions.md`](references/permissions.md)。本檔只放跨平台共用原則與稽核流程。

## 核心規則

- 先完整閱讀專案根目錄的 `CLAUDE.md`、`README.md` 與 `README.permission.md`。
- 每次執行權限稽核或疑難排解時，完整讀取 [權限目錄](references/permissions.md)。
- 將設定檔視為 Info.plist / entitlements / AppX manifest 的單一設定來源：
  - iOS / macOS → `project.yml`（由 XcodeGen 產生 Info.plist 與 entitlements）
  - Windows → `apps/windows/electron-builder.yml` + `apps/windows/package.json` + AppX manifest（如需 Microsoft Store）
- 不要直接修改產生的 `apps/*/Info.plist` 或 `*.entitlements`。
- 依實際 API 使用判斷所需權限，不因預期中的未來功能預先增加能力。
- 保留最小權限原則；區分四個層級：
  1. 使用者授權（TCC prompt；iOS Photos、Local Network；macOS 15+ Local Network；Windows 第一次執行的 UAC 對話框）
  2. 必要宣告（iOS / macOS `NS*UsageDescription` 與 `NSBonjourServices`；Windows capability / AppX manifest；無獨立 prompt）
  3. 隔離 entitlement（macOS `com.apple.security.*`，app 啟動即生效；Windows 目前未啟用 AppContainer）
  4. 系統服務（Keychain、`SMAppService`、Bonjour、WinHTTP 等無 prompt 的能力）
- 維持 `references/permissions.md` 與 `README.permission.md` 表格格式：`Name` / `Description` / `What is it for in current project?`。

## 權限目錄

- 使用 [references/permissions.md](references/permissions.md) 作為技能內可重用的完整 iPhone、Mac 與 Windows 權限清單。
- 將 `README.permission.md` 作為專案根目錄內的使用者可見鏡像（目前以 iOS / macOS 為主，Windows 段尚未鏡像到 README，請一併補齊）。
- 以實際 API 與 `project.yml` / `electron-builder.yml` 為 authoritative source；權限變更時同步兩份清單，不讓其中一份單獨漂移。

## Target × Permission 矩陣

| 權限 / 宣告 | iOS App | macOS App | ControlCenter widget | Intents extension | Windows Electron |
|---|---|---|---|---|---|
| iPhone Photos Full Access（TCC） | ✅ | — | — | — | — |
| iOS Local Network（TCC） | ✅ | — | — | — | — |
| `NSLocalNetworkUsageDescription` | ✅ | ✅ | — | — | — |
| `NSPhotoLibraryUsageDescription` | ✅ | — | — | — | — |
| `NSBonjourServices` (`_iphonesync._tcp`, `_iphonesync-pair._tcp`) | ✅ | ✅ | — | — | — |
| `com.apple.security.app-sandbox` | — | ✅ | — | — | — |
| `com.apple.security.network.server` | — | ✅ | — | — | — |
| `com.apple.security.network.client` | — | ✅ | — | — | — |
| `com.apple.security.files.user-selected.read-write` | — | ✅ | — | — | — |
| `com.apple.security.files.bookmarks.app-scope` | — | ✅ | — | — | — |
| `BGTaskSchedulerPermittedIdentifiers` | ✅ | — | — | — | — |
| `UIBackgroundModes = processing` | ✅ | — | — | — | — |
| `NSAppTransportSecurity`（Bonjour cleartext LAN 必要） | ✅ | ✅ | — | — | — |
| Keychain Services（無 prompt） | ✅ | ✅ | — | — | Windows DPAPI |
| `SMAppService.mainApp`（無獨立 prompt，使用者可在 Login Items 關閉） | — | ✅ | — | — | — |
| Windows Firewall inbound rule（UDP 5353 + TCP sync port） | — | — | — | — | ⚠️ 預期需要，由 electron-builder 或 installer 設定 |
| Windows capability：`internetClient`、`privateNetworkClientServer` | — | — | — | — | ✅ AppX manifest 必備 |
| Windows Defender SmartScreen reputation | — | — | — | — | ⚠️ 第一次下載會跳出警告，靠 Authenticode / EV / Azure Trusted Signing 改善 |

## 稽核流程

1. 盤點執行期存取點：
   - 搜尋 iOS / macOS API：`PHPhotoLibrary`、`PHAssetResourceManager`、`PHAuthorizationStatus`、`requestAuthorization`、`NWBrowser`、`NWListener`、`NWConnection`、`BonjourBrowser`、`BonjourListener`、`BackgroundTask`、`BGTaskScheduler`、`BGProcessingTask`、`SecItem`、`security-scoped`、`URL bookmark`、`NSOpenPanel`、`URL.bookmarkData`、`startAccessingSecurityScopedResource`、`SMAppService`、`NWListener`、`TLS_PSK_WITH_AES_128_GCM_SHA256`。
   - 搜尋 Windows API：`multicast-dns`、`dns-packet`、`tls.createServer`、`better-sqlite3`、`app.setLoginItemSettings`、`BrowserWindow`、`show: false`、`contextBridge`、`fs`、`path.resolve`。
   - 記錄每個存取點所屬 target、觸發時機、拒絕後的降級行為、是否需要重新授權。
2. 盤點宣告：
   - iOS / macOS：`project.yml` 的 `NS*UsageDescription`、`NSBonjourServices`、`BGTaskSchedulerPermittedIdentifiers`、`UIBackgroundModes`、`com.apple.security.*`、`NSExtensionPointIdentifier`。
   - Windows：`electron-builder.yml` 的 `win` block（certificate、icon、target）、`package.json` 的 `description` / `author` / `main`、未來 Microsoft Store 上架需要的 AppX manifest。
   - 以 `plutil -p` 比對 iOS / macOS 產生後的 Info.plist 與 entitlements 是否與 `project.yml` 一致。
3. 對照 `references/permissions.md` 與 `README.permission.md`：
   - 新增、修改或移除與程式行為不一致的列，並保持兩份清單同步。
   - 明確標示只是 Info.plist 宣告 / sandbox entitlement / Windows capability 而非獨立使用者權限的項目。
   - 記錄刻意不需要的高風險權限（Full Disk Access、Camera、Microphone、Location、Bluetooth、Nearby Interaction、Network Extension、macOS Photos、User Selected File 全開），避免日後誤加。
   - 確認 `BGTaskSchedulerPermittedIdentifiers` 同時包含 production 與 debug identifier；iOS 對未宣告的 identifier 會以 `BGTaskSchedulerErrorDomain` code `3` 拒絕並回滾使用者意圖。
4. 若權限設定需變更：
   - 只修改設定檔（`project.yml` / `electron-builder.yml`）。
   - 執行 `xcodegen generate`（Apple）或重新 `npm run dist`（Windows）讓產物更新。
   - 同步 `scripts/verify*.sh` 的 plist / entitlement / type-check invariants。
   - 同步本 skill 的 `references/permissions.md` 與 `README.permission.md`。
5. 完成驗證並回報 unsigned build 的限制。

## 快速檢查命令

```bash
# 程式端使用到的權限相關 API（Apple + Windows）
rg -n 'PHPhotoLibrary|PHAssetResourceManager|requestAuthorization|NWBrowser|NWListener|NWConnection|security-scoped|SecItem|SMAppService|BGTaskScheduler|BGProcessingTask|NSOpenPanel' apps/ios apps/macos packages/SyncCore
rg -n 'multicast-dns|dns-packet|tls\.createServer|setLoginItemSettings|contextBridge|startAccessingSecurityScopedResource' apps/windows packages/SyncCore.Windows

# 宣告端：Apple
rg -n 'NS.*UsageDescription|NSBonjourServices|com\.apple\.security|BGTaskSchedulerPermittedIdentifiers|UIBackgroundModes|AppSandbox' project.yml

# 宣告端：Windows
rg -n 'appId|productName|win:|nsis:|portable:|certificateFile|certificatePassword|capabilities' apps/windows/electron-builder.yml apps/windows/package.json

# 產生後的產物
plutil -p apps/ios/Info.plist
plutil -p apps/macos/Info.plist
plutil -p apps/ios/iPhoneSync.entitlements
plutil -p apps/macos/iPhoneSyncMac.entitlements
plutil -p apps/ios/ControlCenter/Info.plist 2>/dev/null

# 對齊 source 與產物
diff <(plutil -extract NSPhotoLibraryUsageDescription raw apps/ios/Info.plist) \
     <(plutil -extract NSPhotoLibraryUsageDescription raw project.yml | head -1)
```

設定或文件有變更時執行：

```bash
xcodegen generate
bash scripts/verify.sh
bash scripts/verify_windows.sh
```

## 常見問題對照

### iOS

| 症狀 | 權限層級 | 解法 |
|---|---|---|
| Photos prompt 沒出現 | `NSPhotoLibraryUsageDescription` 缺 | 在 `project.yml` 加 key，重新 `xcodegen generate` |
| Local Network prompt 沒出現 | `NSLocalNetworkUsageDescription` 缺 | 同上 |
| `NWBrowser` 取不到 service | `NSBonjourServices` 缺 `_iphonesync._tcp` | 在 `project.yml` 加上 `_iphonesync._tcp` + `_iphonesync-pair._tcp` |
| `BGProcessingTask` 馬上被拒絕（`BGTaskSchedulerErrorDomain` code `3`） | identifier 未在 `BGTaskSchedulerPermittedIdentifiers` 宣告 | 同時保留 production 與 debug identifier |

### macOS

| 症狀 | 權限層級 | 解法 |
|---|---|---|
| 15+ 看不到 Local Network prompt | `com.apple.security.network.server/client` 缺，或 `NSLocalNetworkUsageDescription` 缺 | 兩者都要保留；macOS 14 不顯示此 prompt |
| Mac receiver 寫不到選定資料夾 | 缺 `com.apple.security.files.user-selected.read-write` | 在 `project.yml` 加 entitlement |
| Mac 重啟後 destination capability 失效 | 缺 `com.apple.security.files.bookmarks.app-scope` | 同上；以 `URL.bookmarkData(options: .withSecurityScope)` 存 |
| `SMAppService.register()` 失敗 | 系統政策或 macOS 拒絕 | 檢查 Login Items；使用者可在 `系統設定 → 一般 → 登入項目` 手動關閉 |
| App 重啟後 Keychain 讀不到 | 缺 `keychain-access-groups` | 目前各 App 獨立，無跨 target 需求；若日後加入再評估 |

### Windows

| 症狀 | 權限層級 | 解法 |
|---|---|---|
| `multicast-dns` 沒看到其他裝置 | Windows Firewall 阻擋 UDP 5353 | NSIS installer 加 `netsh advfirewall` 規則，或手動允許 |
| Node `tls.createServer` 無法監聽 | AppContainer 沒宣告 `privateNetworkClientServer` capability | 設定 AppX manifest，或暫不啟用 AppContainer |
| App 開機後沒自動啟動 | `app.setLoginItemSettings` 沒設 | 在 Setup 視窗寫入 `HKCU\...\Run`，NSIS `deleteAppDataOnUninstall` 解安時清乾淨 |
| SmartScreen 警告 | 沒 Authenticode 或 OV reputation 不足 | 改 EV certificate 或送 Microsoft reputation review |
| 解除安裝後 `HKCU\Run\iPhoneSync` 殘留 | uninstaller 沒清登錄檔 | NSIS `deleteAppDataOnUninstall: true` 不會清 HKCU；改寫 custom NSIS script |
| 使用者選定的 folder 寫不到 | AppContainer 隔離或 UAC 拒絕 | 預設未啟用 AppContainer；若日後啟用，需 capability + 重新走 picker |

## 驗證邊界

- `scripts/verify.sh` 與 `scripts/verify_windows.sh` 只驗證靜態宣告（plist / entitlement / TypeScript type-check / unsigned build），不代表使用者已授權或 capability 在 runtime 成功。
- 在 signed 實體 iPhone 驗證 Photos 與 Local Network prompt、拒絕後的降級、`設定` 中重新授權後再次嘗試。
- 在 signed macOS App 驗證 Local Network（macOS 15+）、Finder destination bookmark 跨重啟、Login Items 開關狀態。
- 在 signed Windows 11 驗證 SmartScreen 警告、第一次執行的 UAC、Firewall inbound rule、解除安裝後登錄檔是否清乾淨。
- 不要求 Full Disk Access、macOS Photos、Camera、Microphone、Contacts、Location、Bluetooth、Nearby Interaction、custom multicast 或 Network Extension，除非實際產品功能與 canonical design 同步改變。
- iOS / macOS / Windows 變更後務必重跑對應的 `scripts/verify*.sh`，確認 generated artifacts 與 source 一致。

## 同步檢查清單

任何權限變更後，逐項確認：

- [ ] 對應平台的設定檔已修改（`project.yml` / `electron-builder.yml`）
- [ ] `xcodegen generate` 已執行（Apple）
- [ ] `apps/ios/Info.plist`、`apps/macos/Info.plist` 與各 extension `Info.plist` / entitlements 與 source 一致
- [ ] `apps/windows/dist/` 與 `electron-builder.yml` 一致
- [ ] `bash scripts/verify.sh` 通過
- [ ] `bash scripts/verify_windows.sh` 通過
- [ ] `.claude/skills/os-permission/references/permissions.md` 已同步
- [ ] `README.permission.md` 已同步（Windows 段也補齊）
- [ ] `CLAUDE.md` 的 product invariants 未被新權限破壞
- [ ] `README.todo` 中相關驗證項目（如實機 background launch、Bonjour + TLS-PSK 行為測試）仍維持原列

## 相關檔案

- [權限目錄](references/permissions.md) — 完整 iPhone、Mac 與 Windows 權限清單
- [README.permission.md](../../README.permission.md) — 使用者可見鏡像
- [project.yml](../../project.yml) — iOS / macOS Info.plist / entitlements 設定來源
- [apps/windows/electron-builder.yml](../../apps/windows/electron-builder.yml) — Windows 包裝設定
- [apps/windows/package.json](../../apps/windows/package.json) — Windows app metadata
- [CLAUDE.md](../../CLAUDE.md) — product invariants 與 architecture