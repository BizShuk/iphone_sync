# iPhone Sync 完整權限目錄

`project.yml` 是權限宣告的唯一設定來源；`apps/*/Info.plist` 與 `*.entitlements` 均由 XcodeGen 產生。下表同時涵蓋使用者授權、必要宣告、macOS sandbox entitlement，以及專案依賴但不會出現獨立 prompt 的系統能力。

| Name | Description | What is it for in current project? |
| --- | --- | --- |
| `iPhone Photos Full Access` | iOS 使用者授權 (TCC)。App 以 `PHPhotoLibrary.requestAuthorization(for: .readWrite)` 請求，並以 `NSPhotoLibraryUsageDescription` 說明用途；目前只接受 `.authorized`，不接受 `.limited`。PhotoKit 的讀取 access level 名稱是 `.readWrite`，但本專案不會修改 Photos library。 | 列出使用者相簿並讀取所選相簿內全部本機 `PHAssetResource` 原始 bytes，確保完整備份。`isNetworkAccessAllowed = false`，不會為此下載 iCloud resource。 |
| `iPhone Local Network` | iOS 14+ 使用者授權 (TCC)。`NSLocalNetworkUsageDescription` 必須說明 LAN 存取目的。 | 讓前景 iOS App 透過 Bonjour 尋找已配對 Mac，並以 Network.framework 建立 pairing 與 sync TCP/TLS 連線。 |
| `iPhone Bonjour Services` | 必要 Info.plist 宣告，不是另一個獨立 prompt。`NSBonjourServices` 必須列出 `_iphonesync._tcp` 與 `_iphonesync-pair._tcp`。 | 允許 iPhone 瀏覽一般同步 receiver 與 120 秒暫時配對 service。 |
| `Mac Local Network` | macOS 15+ 使用者授權 (TCC)；macOS 14 沒有此 prompt。`NSLocalNetworkUsageDescription` 必須保留，讓支援版本顯示 receiver 的 LAN 用途。 | 讓 menu-bar receiver 在同一 LAN 上被 iPhone 發現、完成配對並接收原始資源。 |
| `Mac Bonjour Services` | 必要 Info.plist 宣告，不是另一個獨立 prompt。`NSBonjourServices` 列出 `_iphonesync._tcp` 與 `_iphonesync-pair._tcp`。 | 宣告 Mac 會發布的一般同步 service 與暫時配對 service。 |
| `Mac App Sandbox` | `com.apple.security.app-sandbox = true`。此 entitlement 啟用 macOS App Sandbox，其他檔案與網路能力必須逐項允許。 | 限制 receiver 只能存取自己的 App container，以及使用者選取的 destination、明確宣告的 LAN 能力與系統服務。 |
| `Mac Incoming Network Connections` | `com.apple.security.network.server = true`，允許 sandboxed App 監聽由其他電腦發起的連線。 | 讓 `NWListener` 接受 iPhone 的 pairing 與正常 sync TCP/TLS connection。 |
| `Mac Outgoing Network Connections` | `com.apple.security.network.client = true`，允許 sandboxed App 發起網路流量；Bonjour/mDNS 的雙向 UDP 行為通常需與 server entitlement 一起保留。 | 讓 receiver 發布並回應 Bonjour service，以及執行 session 所需的允許網路流量。 |
| `Mac User Selected File Read/Write` | `com.apple.security.files.user-selected.read-write = true`。使用者以 `NSOpenPanel` 選擇 folder 後，sandbox 才授予該位置的讀寫能力。 | 在選定 destination root 下建立或重用 `iPhoneSync/<album-folder>/`，寫入 partial、驗證後 atomic commit，且不取得 Full Disk Access。 |
| `Mac App-Scoped Security-Scoped Bookmarks` | `com.apple.security.files.bookmarks.app-scope = true`。App 將選取 URL 轉成 `.withSecurityScope` bookmark，解析後呼叫 `startAccessingSecurityScopedResource()`。 | 跨 App relaunch 與 Mac restart 保存 Finder destination capability，讓 receiver 可自動恢復至同一 folder。 |
| `Mac Launch at Login Approval` | 使用者可控制的 Login Item；不是 Info.plist privacy key 或 sandbox entitlement。App 以 `SMAppService.mainApp.register()` 請求，系統仍可拒絕或由使用者在 Login Items 關閉。 | 登入後自動啟動 menu-bar receiver，重新載入 bookmark、Keychain paired peer 與 SwiftData manifest。 |
| `App-Private Keychain Access` | iOS 與 macOS 使用標準 Keychain Services；不會出現獨立 privacy prompt。目前沒有跨 target 分享，因此不需要 `keychain-access-groups` entitlement。 | 各 App 分別保存 pairing 後的 256-bit PSK 與 opaque peer identity，不將 secret 寫入 `UserDefaults` 或 SwiftData。 |

## 刻意不要求的權限

- 不要求 `Full Disk Access`；Mac 只寫入使用者透過 `NSOpenPanel` 選取的 destination。
- 不要求 macOS Photos、Camera、Microphone、Contacts、Location、Bluetooth、Nearby Interaction 或 Network Extension。
- 不要求 iOS custom multicast entitlement；目前只使用 Bonjour API，沒有自訂 multicast socket。
- 不要求 iCloud Photos 或 background transfer；`isNetworkAccessAllowed = false`，iPhone 同步必須由使用者在前景觸發。
- 將 `UIRequiredDeviceCapabilities` 的 `wifi` / `arm64` 視為安裝相容性條件，不視為 privacy permission；`LSUIElement` 是 menu-bar App 行為，也不是 permission。

## Apple 官方參考

- [Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [PhotoKit privacy authorization](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)
- [macOS App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [User-selected file read/write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)
- [Security-scoped bookmark access](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
- [SMAppService registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)
