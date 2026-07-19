# iPhone Sender

`iPhoneSyncIOS` 是前景手動同步的 iOS 17+ sender。它取得 Photos Full Access、保存一個相簿選擇、透過 Bonjour 發現 Mac，完成六位數 SAS 配對後，將本機原始 PhotoKit resources 逐一 staging 並傳送。

## Flow

```text
Photos authorization
└── album selection
    └── Find Mac
        └── six-digit pairing
            └── Sync Now
                └── local-only stage → hash → offer → chunk → cleanup
```

## Boundaries

- `PhotoLibrarySource` 固定使用 `isNetworkAccessAllowed = false`；iCloud-only resource 只計入 skipped，不觸發下載。
- `IOSSyncCoordinator` 只在 Wi-Fi 上尋找與連線，並固定 `includePeerToPeer = false`。
- 一次只 staging 一個 resource；收到 committed/skipped/failed 後清理 temporary file。
- App 進入背景時停止排入新 resource，下一次由使用者重新按 `Sync Now`。
- Pairing sheet 顯示本地兩分鐘 timeout 與錯誤/剩餘嘗試；取消或進入背景會關閉 pending pairing channel。
- Pairing PSK 與 source binding 存入 Keychain；相簿 local identifier 存入 `UserDefaults`。

## Build

從 repo root 執行：

```bash
xcodegen generate
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Unsigned build 不會測試 Photos/Local Network permission 或真實裝置資料。實機驗收項目見 [../../README.todo](../../README.todo)。
