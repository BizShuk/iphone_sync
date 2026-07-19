# Mac Receiver

`iPhoneSyncMac` 是 macOS 14+ menu-bar receiver。它保存使用者選擇的 Finder destination、顯示兩分鐘六位數配對碼，並以 Bonjour + Network.framework 接收已配對 iPhone 的增量備份。

## Flow

```text
Choose Destination
└── Pair iPhone
    └── TLS receiver ready
        └── partial write → checkpoint → SHA-256 → atomic commit
```

## Boundaries

- App Sandbox 只授予 incoming/outgoing network、使用者選擇資料夾 read-write 與 app-scoped bookmark 權限。
- `DestinationBookmarkStore` 保存 security-scoped bookmark；stale bookmark 會要求重新選擇。
- `ReceiverController` 一次只接受一個正常同步 connection。
- `ManifestStore` 以 SwiftData 保存 source/album binding 與 resource checkpoint。
- `DestinationWriter` 不覆寫或刪除 committed user files；完整 SHA-256 驗證後才發布 final file。
- `Forget iPhone` 只刪除 Keychain trust；`Reset Source` 只建立新的 source binding，兩者都不刪除 Finder 檔案。

## Build

從 repo root 執行：

```bash
xcodegen generate
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

要實際保存 sandbox destination 權限與啟用 launch at login，必須在 Xcode 設定 development team 並以簽署 App 執行。
