---
name: iphone-mac-permission
description: Audit and document every iOS and macOS permission, privacy usage key, Bonjour declaration, App Sandbox entitlement, persistent access grant, and launch-at-login approval required by iPhone Sync. Use when adding or changing Photos, local-network, Finder destination, Keychain, login-item, sandbox, or signing behavior; when a permission prompt or protected operation fails; or when references/permissions.md, README.permission.md, project.yml, generated Info.plist files, entitlements, and verification checks must be synchronized.
---

# iPhone Sync 權限稽核

## 核心規則

- 先完整閱讀專案根目錄的 `CLAUDE.md`、`README.md` 與 `README.permission.md`。
- 每次執行權限稽核或疑難排解時，完整讀取 [權限目錄](references/permissions.md)。
- 將 `project.yml` 視為 Info.plist 與 entitlements 的唯一設定來源；不要直接修改產生的 `apps/*/Info.plist` 或 `*.entitlements`。
- 依實際 API 使用判斷所需權限，不因預期中的未來功能預先增加能力。
- 保留最小權限原則；區分使用者授權、plist 宣告、sandbox entitlement，以及不需額外 prompt 的系統服務。
- 維持 `references/permissions.md` 與 `README.permission.md` 的三欄表格：`Name`、`Description`、`What is it for in current project?`。

## 權限目錄

- 使用 [references/permissions.md](references/permissions.md) 作為技能內可重用的完整 iPhone 與 Mac 權限清單。
- 將 `README.permission.md` 作為專案根目錄內的使用者可見鏡像。
- 以實際 API 與 `project.yml` 為 authoritative source；權限變更時同步兩份清單，不讓其中一份單獨漂移。

## 稽核流程

1. 盤點執行期存取點：
   - 搜尋 `PHPhotoLibrary`、`NWBrowser`、`NWListener`、`NWConnection`、`NSOpenPanel`、security-scoped bookmark、`SecItem` 與 `SMAppService`。
   - 記錄每個存取點所屬 target、觸發時機與拒絕後的行為。
2. 盤點宣告：
   - 檢查 `project.yml` 的 `NS*UsageDescription`、`NSBonjourServices` 與 target entitlements。
   - 以 `plutil -p` 比對產生後的 Info.plist 與 entitlements。
3. 對照 `references/permissions.md` 與 `README.permission.md`：
   - 新增、修改或移除與程式行為不一致的列，並保持兩份清單同步。
   - 明確標示只是宣告或隱含能力、而非獨立使用者權限的項目。
   - 記錄刻意不需要的高風險權限，避免日後誤加。
4. 若權限設定需變更：
   - 只修改 `project.yml`。
   - 執行 `xcodegen generate` 更新 committed project、Info.plist 與 entitlements。
   - 同步 `scripts/verify.sh` 的 plist/entitlement invariants。
5. 完成驗證並回報 unsigned build 的限制。

## 快速檢查

```bash
rg -n 'PHPhotoLibrary|NWBrowser|NWListener|NWConnection|NSOpenPanel|SecurityScoped|SecItem|SMAppService' apps packages
rg -n 'NS.*UsageDescription|NSBonjourServices|com\.apple\.security' project.yml apps
plutil -p apps/ios/Info.plist
plutil -p apps/macos/Info.plist
plutil -p apps/ios/iPhoneSync.entitlements
plutil -p apps/macos/iPhoneSyncMac.entitlements
```

設定或文件有變更時執行：

```bash
xcodegen generate
bash scripts/verify.sh
```

## 驗證邊界

- 將 `scripts/verify.sh` 視為靜態宣告與 unsigned build 驗證，不視為使用者已授權的證明。
- 在 signed 實體 iPhone 驗證 Photos 與 Local Network prompt、拒絕、重新開啟設定與再次嘗試。
- 在 signed macOS App 驗證 Local Network、Finder destination bookmark 與 Login Items 狀態；macOS 15+ 才有 Local Network privacy prompt。
- 不要求 Full Disk Access、macOS Photos、Camera、Microphone、Location、Bluetooth、custom multicast 或 Network Extension，除非實際產品功能與 canonical design 同步改變。
