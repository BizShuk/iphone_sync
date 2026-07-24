# iPhone Sender

`iPhoneSyncIOS` 是 iOS 18+ local-only sender。它取得 Photos Full Access、保存多個相簿選擇、透過 Bonjour 發現 Mac，完成六位數 SAS pairing 後，可由 `Sync Now` 立即同步，或在使用者 opt in 後由 `BGProcessingTask` best-effort 觸發 automatic sync。另提供 1x1 `Sync Now` shortcut（Shortcuts / Siri，`SyncNowShortcuts`）與 Control Center control widget（`iPhoneSyncControlCenter`）作為快速入口；兩者共用 `SyncNowIntent`，僅在已配對且滿足執行先決條件時觸發。

## Flow

```text
Photos authorization
└── multi-album selection
    └── Find Mac
        └── six-digit pairing
            └── Sync Now / Automatic Sync
                └── single-flight runtime
                    └── paired Bonjour receiver → TLS-PSK
                        └── each album → local-only stage → hash → offer → chunk → cleanup
```

## Boundaries

- `PhotoLibrarySource` 固定使用 `isNetworkAccessAllowed = false`；iCloud-only resource 只計入 skipped，不觸發下載。
- `IOSSyncCoordinator` 只在 Wi-Fi 上尋找與連線，固定 `includePeerToPeer = false`，且只接受 exact paired `receiverID`；PSK handshake 才完成 authentication。
- 一次只 staging 一個 resource；收到 committed/skipped/failed 後清理 temporary file。
- 每個 album 使用獨立 sync session；摘要在 iPhone 合併顯示，進度同時顯示目前 album 與 resource。
- Manual 與 automatic run 共用 single-flight runtime；同一時間只允許一個 sync。Budget、scene cancellation 或 expiration 會取消 PhotoKit `requestData` staging、Bonjour discovery 與 active client，並清理未交付的 iPhone temporary file；後續 run 由 Mac checkpoint `resume`。
- `Automatic Sync` 預設關閉。Debug background request 最早為 `now + 10 minutes`；Release request 最早為下一個 local midnight。`earliestBeginDate` 只限制不得更早，實際啟動由 iOS 決定，可能晚很多。
- Startup 與 scene transition 只在實際 lifecycle 變化時 reconcile；scheduler 查詢同 identifier 的 pending request，保留相同或更早的 request，只在新目標更早時 replacement submit。Debug 已到期的 persisted eligibility 保持到期，不因重進 App 改成新的 `now + 10 minutes`。
- Debug foreground test 使用保存的 `Eligible after`：已到期時回到前景立即嘗試，未到期只等待剩餘時間。離開前景會取消 foreground timer，但不取消 system pending request。
- Automatic handler 重新載入 Photos authorization、相簿選擇與 Keychain paired peer；若 paired Mac 不符合「Wi-Fi + paired Bonjour service 可見 + TLS-PSK 成功」gate，便記錄 outcome 並重新排程，不自動 pairing。
- Automatic UI 顯示 opt-in toggle、cadence、`Background App Refresh`、last attempt/success/outcome 與 `Eligible after`；後者是 earliest request，不是 next guaranteed run。
- 主畫面的 `Operation Log` section 顯示最新三筆並可展開全部 timeline；App、Photos、album selection、pairing、discovery、scheduler、manual / automatic run、session 與每個 resource lifecycle 都產生 levelled event，最多保留本次 process 最新 500 筆並可清除。
- Operation timeline 不逐 chunk 記錄，避免大型媒體造成 log flood；相同事件會送入 Apple Unified Logging。Panel 可顯示 album / resource 名稱與 destination-relative path，但不包含 PSK、六位數 pairing code、cryptographic identity、source binding 或 content hash。
- `Sync Now` 保留為 deterministic fallback；manual run 進入背景時會取消，system-launched automatic run 則由 `BGProcessingTask` lifecycle 管理。
- Pairing sheet 顯示本地兩分鐘 timeout 與錯誤/剩餘嘗試；取消或進入背景會關閉 pending pairing channel。
- Pairing PSK 與 source binding 存入 Keychain；多個相簿 local identifier，以及 automatic enablement、last attempt/success/outcome、next eligible time 存入 typed `UserDefaults` stores。Endpoint、active connection 與 resource offset 不會持久化。

## Build

從 repo root 執行：

```bash
xcodegen generate
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Unsigned build 不會測試 Photos/Local Network permission 或真實裝置資料。實機驗收項目見 [../../README.todo](../../README.todo)。
