# iPhone Sync 權限 (Permissions)

`project.yml` 是權限宣告的唯一來源；`apps/*/Info.plist` 與 `*.entitlements` 均由 XcodeGen 產生。技能內對應目錄為 [references/permissions.md](.agents/skills/iphone-mac-permission/references/permissions.md)，兩份清單必須同步。下表同時涵蓋使用者授權、必要宣告、macOS sandbox entitlement，以及專案依賴但不會出現獨立 prompt 的系統能力。

| Name | Description | What is it for in current project? |
| --- | --- | --- |
| `iPhone Photos Full Access` | iOS 使用者授權 (TCC)。App 以 `PHPhotoLibrary.requestAuthorization(for: .readWrite)` 請求，並以 `NSPhotoLibraryUsageDescription` 說明備份與 optional deletion 用途；只接受 `.authorized`，不接受 `.limited`。啟用 `Delete After Sync` 後，PhotoKit 對每個 foreground deletion batch 另顯示 library change confirmation；不需額外 entitlement 或 usage key。 | 列出所選相簿內全部本機 `PHAssetResource` 原始 bytes。`isNetworkAccessAllowed = false`，不下載 iCloud resource。只有所有本機 resource 均被 receiver 確認 committed / already present 的 asset 才可送入 `PHAssetChangeRequest.deleteAssets`；toggle 預設關閉，background run 只保存待刪 ID / `modificationDate` snapshot，foreground 刪除前版本不符即保留。 |
| `iPhone Local Network` | iOS 14+ 使用者授權 (TCC)。`NSLocalNetworkUsageDescription` 必須說明 LAN 存取目的；首次授權仍須在使用者可操作的前景流程完成。 | 讓前景手動同步或 system-granted automatic run 透過 Bonjour 尋找已配對 Mac，並以 Network.framework 建立 sync TCP/TLS 連線；pairing 只在前景執行。 |
| `iPhone Bonjour Services` | 必要 Info.plist 宣告，不是另一個獨立 prompt。`NSBonjourServices` 必須列出 `_iphonesync._tcp` 與 `_iphonesync-pair._tcp`。 | 允許 iPhone 瀏覽一般同步 receiver 與 120 秒暫時配對 service。 |
| `iPhone Background Processing` | `UIBackgroundModes = processing` 與 `BGTaskSchedulerPermittedIdentifiers` 是 Info.plist capability declarations，不是 privacy prompt，也不是 sandbox entitlement。 | 允許 iOS 以 `BGProcessingTask` 提供 automatic sync 的 best-effort 執行機會。只有一個 identifier、一條 cadence：最早為 `+30 minutes`，不要求充電；實際啟動時間由系統決定。 |
| `iPhone Notifications` | iOS 使用者授權 (TCC)。啟用 `Delete After Sync` 時以 `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound])` 請求；不需 Info.plist usage key 或 entitlement（只用 local notification，沒有 remote push、沒有 `aps-environment`）。使用者拒絕時整條刪除流程不變，只是少了提示。 | 背景 automatic run 無法顯示 PhotoKit 的刪除確認框，只能把候選 asset 排入 pending queue。授權後以單一固定 identifier 的 local notification 告知有幾張照片等待前景確認；使用者完成刪除、關閉 toggle 或忘記 Mac 時撤回該通知。 |
| `Mac Local Network` | macOS 15+ 使用者授權 (TCC)；macOS 14 沒有此 prompt。`NSLocalNetworkUsageDescription` 必須保留，讓支援版本顯示 receiver 的 LAN 用途。 | 讓 menu-bar receiver 在同一 LAN 上被 iPhone 發現、完成配對並接收原始資源。 |
| `Mac Bonjour Services` | 必要 Info.plist 宣告，不是另一個獨立 prompt。`NSBonjourServices` 列出 `_iphonesync._tcp` 與 `_iphonesync-pair._tcp`。 | 宣告 Mac 會發布的一般同步 service 與暫時配對 service。 |
| `Mac App Sandbox` | `com.apple.security.app-sandbox = true`。此 entitlement 啟用 macOS App Sandbox，其他檔案與網路能力必須逐項允許。 | 限制 receiver 只能存取自己的 App container，以及使用者選取的 destination、明確宣告的 LAN 能力與系統服務。 |
| `Mac Incoming Network Connections` | `com.apple.security.network.server = true`，允許 sandboxed App 監聽由其他電腦發起的連線。 | 讓 `NWListener` 接受 iPhone 的 pairing 與正常 sync TCP/TLS connection。 |
| `Mac Outgoing Network Connections` | `com.apple.security.network.client = true`，允許 sandboxed App 發起網路流量；Bonjour/mDNS 的雙向 UDP 行為通常需與 server entitlement 一起保留。 | 讓 receiver 發布並回應 Bonjour service，以及執行 session 所需的允許網路流量。 |
| `Mac User Selected File Read/Write` | `com.apple.security.files.user-selected.read-write = true`。使用者以 `NSOpenPanel` 選擇 folder 後，sandbox 才授予該位置的讀寫能力；第一次開啟 chooser 時預設顯示 `Downloads`，仍需使用者確認。 | 若 destination root 是 symbolic link，先固定解析實際 target；再於 resolved root 下建立或重用 `iPhoneSync/<album-folder>/`，寫入 partial、驗證後 atomic commit，且不取得 Full Disk Access。 |
| `Mac App-Scoped Security-Scoped Bookmarks` | `com.apple.security.files.bookmarks.app-scope = true`。App 將選取 URL 轉成 `.withSecurityScope` bookmark，解析後呼叫 `startAccessingSecurityScopedResource()`。 | 跨 App relaunch 與 Mac restart 保存 resolved Finder destination capability，而不是保存 symbolic-link path，讓 receiver 自動恢復至同一實際 folder。 |
| `Mac Launch at Login Approval` | 使用者可控制的 Login Item；不是 Info.plist privacy key 或 sandbox entitlement。App 以 `SMAppService.mainApp.register()` 請求，系統仍可拒絕或由使用者在 Login Items 關閉。 | 登入後自動啟動 menu-bar receiver，重新載入 bookmark、Keychain paired peer 與 SwiftData manifest。 |
| `App-Private Keychain Access` | iOS 與 macOS 使用標準 Keychain Services；不會出現獨立 privacy prompt。目前沒有跨 target 分享，因此不需要 `keychain-access-groups` entitlement。 | 各 App 分別保存 pairing 後的 256-bit PSK 與 opaque peer identity，不將 secret 寫入 `UserDefaults` 或 SwiftData。 |

## 刻意不要求的權限

- 不要求 `Full Disk Access`；Mac 只寫入使用者透過 `NSOpenPanel` 選取的 destination。
- 不要求 macOS Photos、Camera、Microphone、Contacts、Location、Bluetooth、Nearby Interaction 或 Network Extension。
- 不要求 iOS custom multicast entitlement；目前只使用 Bonjour API，沒有自訂 multicast socket。
- 不要求 iCloud Photos、background `URLSession` 或 PhotoKit Background Resource Upload；`isNetworkAccessAllowed = false`。Automatic sync 使用既有 local-only transport，並只在 iOS 實際啟動 `BGProcessingTask` 且同網路 gate 通過時傳輸。
- 不要求 `NSPhotoLibraryAddUsageDescription`；目前使用完整 `.readWrite` access 讀取既有資產，optional deletion 仍由同一 `NSPhotoLibraryUsageDescription` 與 PhotoKit change confirmation 管理。
- `UIRequiredDeviceCapabilities` 的 `wifi` / `arm64` 是安裝相容性條件，不是 privacy permission；`LSUIElement` 是 menu-bar App 行為，也不是 permission。

## Windows 11 對應 (Windows 11 Receiver)

| Name | 說明 | 對應實作 |
|---|---|---|
| Windows Local Network | Windows 對 LAN 連入需手動允許 `New-NetFirewallRule -Direction Inbound -Protocol TCP -Action Allow` | Electron `app.setLoginItemSettings` + 手動 firewall 提示 |
| Windows Firewall | 首次啟動時須放行入站 TCP；NSIS installer 可附 `netsh advfirewall firewall add rule` 步驟 | `apps/windows/electron-builder.yml` |
| Windows DPAPI | 透過 Electron `safeStorage` 內部走 Windows DPAPI 加密 paired peer PSK | `safeStorage.encryptString` / `decryptString` |
| Windows Launch at Login | `app.setLoginItemSettings({ openAtLogin: true, openAsHidden: true })` 註冊於 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | Electron `app` API |
| Windows Open Folder | `dialog.showOpenDialog({ properties: ['openDirectory'] })` 取代 `NSOpenPanel`；不需 sandbox 等價物 | Electron `dialog` API |
| Windows Menu Bar | `Tray` + `Menu` 取代 `NSStatusItem`；維持 system tray 行為 | Electron `Tray` API |
| Windows Bonjour | `multicast-dns` 透過 RFC 6762/6763 over `_local.` | `packages/SyncCore.Windows/src/discovery/bonjour-*.ts` |

## 驗證

```bash
xcodegen generate
bash scripts/verify.sh
```

Unsigned build 只能驗證 plist、entitlements 與編譯，不會授予或證明 Photos、Local Network、Finder destination 或 Login Item 權限，也不證明 iOS 會啟動 `BGProcessingTask`。這些項目必須用 signed 實體 iPhone 與 signed macOS App 驗收。

Windows 11 端的 `scripts/verify-windows.sh` 跑 vitest + source invariant grep + electron-builder `npm run dist`；NSIS installer 需在 Windows 11 22H2+ 開發機執行，後續 signed 走 `electron-builder` signtool 流程。

## Apple 官方參考

- [Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [Background task earliest begin date](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)
- [PhotoKit privacy authorization](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)
- [Requesting changes to the photo library](https://developer.apple.com/documentation/photokit/requesting-changes-to-the-photo-library)
- [Delete photos on iPhone or iPad](https://support.apple.com/104967)
- [macOS App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [User-selected file read/write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)
- [Security-scoped bookmark access](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
- [SMAppService registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)
