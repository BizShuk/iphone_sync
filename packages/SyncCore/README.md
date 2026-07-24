# SyncCore

此 Swift 6 package 提供 iOS sender 與 macOS receiver 共用的純區域網路同步元件，deployment floors 為 iOS 18 與 macOS 14，沒有第三方 runtime dependency。

## Products

| Product | Responsibility |
|---|---|
| `SyncCore` | wire contracts、frame codec、identity、SHA-256、pairing、Keychain、Bonjour、TLS 1.2 PSK、sync client、bounded operation log values |
| `MacReceiverKit` | SwiftData manifest、multi-album/folder mapping、album-scoped checkpoint、`iPhoneSync` receiving folder、safe album/single-root layout、crash-safe destination writer、sync server session events |

依賴方向固定為：

```text
MacReceiverKit → SyncCore
```

兩個 products 都不得依賴 App targets。`MacReceiverKit` 只由 macOS target 使用。

## Protocol Limits

- Control payload：64 KiB。
- Raw chunk：1 MiB。
- Durable receive checkpoint：16 MiB。
- Integrity：SHA-256。
- Normal transport：TLS 1.2 `TLS_PSK_WITH_AES_128_GCM_SHA256`。
- Discovery：`_iphonesync._tcp`；temporary pairing：`_iphonesync-pair._tcp`。

## Tests

```bash
swift test --package-path packages/SyncCore
```

Tests 使用 Swift Testing，涵蓋 framing、identity、crypto、Keychain、TLS loopback、wrong PSK/proof、pairing expiry、bounded operation buffer、SwiftData manifest、multi-album resource scope、`iPhoneSync` container、duplicate/existing album folders、legacy partial/record migration、checkpoint recovery、destination collision、client/server round trip 與 server operation event sequence。
