# Mac Receiver

`iPhoneSyncMac` 是 macOS 14+ menu-bar receiver。第一次開啟 destination chooser 時預設顯示使用者的 `Downloads` 資料夾；使用者確認後 App 保存該 Finder destination。它顯示兩分鐘六位數配對碼，並以 Bonjour + Network.framework 將已配對 iPhone 的多相簿增量備份寫入 `iPhoneSync/` 底下，依儲存模式分派：預設為「相簿日期分類」(`iPhoneSync/<album>/<year>/<month>/`)，或「單一資料匣 (不分類)」(`iPhoneSync/<file>` )。

## Flow

```text
Choose Destination (defaults to Downloads on first use)
    └── Pair iPhone
    └── TLS receiver ready
        └── iPhoneSync → album folder / date folder or single folder → partial write → checkpoint → SHA-256 → atomic commit
```

## Boundaries

- Menu bar icon 由標準方形 AppKit `NSStatusItem` 持有，使用專屬 `com.shuk.iphonesync.statusItem` autosave name、保持 `isVisible = true`，並監看意外的隱藏狀態以立即恢復；原生 `NSMenu` 提供狀態、設定、配對、destination、忘記裝置與結束操作。
- Menu 與 Setup 顯示已配對 iPhone 的 `displayName` 與 app-specific `deviceID`；Setup 中的完整 ID 可複製。iOS public API 不提供硬體序號，因此 UI 不會把 `deviceID` 誤標為 serial number，也不會暴露 PSK identity。
- macOS 在 menu bar 空間不足時仍可能暫時遮蔽 status item；Setup 會提示使用者騰出一個位置，再按住 `Command` 將 iPhone Sync 拖近右側，後續位置由 autosave name 保存。
- Setup 使用 AppKit `NSWindow` 持有 SwiftUI `SetupView`，關閉後可由 menu bar 再次開啟；`Operation Log` 面板顯示 App、menu、settings、pairing、listener/recovery、session 與每個 resource lifecycle，保留本次 process 最新 500 筆並提供 `Copy All` / clear。
- Operation timeline 使用 levelled semantic events，不逐 chunk 記錄，並同步送入 Apple Unified Logging；panel 不包含 PSK、六位數 pairing code、cryptographic identity、source binding 或 content hash。
- App Sandbox 只授予 incoming/outgoing network、使用者選擇資料夾 read-write 與 app-scoped bookmark 權限。
- `MacSettingsStore` 統一管理 receiver ID、source binding、destination bookmark bytes 與 launch-at-login intent，並沿用既有 preference keys。
- `DestinationBookmarkStore` 專責 security-scoped bookmark encode/resolve；stale bookmark 會要求重新選擇。
- Paired peer secrets 留在 Keychain，album/resource state 留在 SwiftData；兩者不寫入 preferences。
- `Launch at Login` 首次預設啟用並由 `SMAppService.mainApp` 註冊；使用者關閉後 intent 仍會跨 App relaunch 與 Mac restart 保存。
- Setup window frame 與 menu-bar item position 使用 AppKit autosave。
- `ReceiverController` 一次只接受一個正常同步 connection。
- `ManifestStore` 以 SwiftData 保存一個 source binding 下的多個 album/folder mappings，以及 album-scoped resource checkpoint。
- `AlbumFolderPolicy` 保留一般相簿名稱，並將 path separator、控制字元與隱藏 path injection 轉成安全的單一資料夾名稱。
- `DestinationWriter` 固定先建立或重用 `iPhoneSync` receiving folder；`相簿日期分類` 模式會於其下建立相簿資料夾與日期子資料夾，`單一資料匣 (不分類)` 模式則直接寫入 `iPhoneSync` 根。任一同名項目若是檔案或 symlink，session 會拒絕並寫入 Operation Log。
- 已存在的真實寫入資料夾會安全重用且內容不刪除；`相簿日期分類` 模式下不同 album 若同名，依序使用 `名稱 (2)`、`名稱 (3)`，避免合併。
- `DestinationWriter` 不覆寫或刪除 committed user files；完整 SHA-256 驗證後才發布 final file。
- `Forget iPhone` 只刪除 Keychain trust；`Reset Source` 只建立新的 source binding，兩者都不刪除 Finder 檔案。

## Build

從 repo root 執行：

```bash
xcodegen generate
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

要實際保存 sandbox destination 權限與啟用 launch at login，必須在 Xcode 設定 development team 並以簽署 App 執行。完整 Mac restart 驗收仍需在實機登入週期執行。
