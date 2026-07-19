# iPhone Sync — Technical Context

## Current Status

MVP 已實作於 `feat/local-album-sync`：包含原生 iOS sender、原生 macOS menu-bar receiver、`SyncCore`/`MacReceiverKit` Swift package、XcodeGen project、edge-case tests 與 `scripts/verify.sh`。自動驗證只證明 package tests 與 unsigned builds；實體裝置、真實 Photos library 與真實 LAN 驗收仍以 [README.todo](README.todo) 為準。

## Product Invariants

- iPhone 必須由使用者在前景手動觸發同步。
- 同一時間只綁定一個來源相簿、一部 iPhone 與一部 Mac。
- 同步只能新增，永不因來源變動刪除或覆寫 Mac 既有檔案。
- iPhone 傳輸只能使用 Bonjour 可見的 Wi-Fi 區域網路；Mac listener 可位於同一 LAN 的 Wi-Fi 或 Ethernet。`includePeerToPeer` 固定為 `false`。
- PhotoKit resource request 固定使用 `isNetworkAccessAllowed = false`。
- Mac manifest 是完成狀態與續傳 offset 的 authoritative source。
- cryptographic `deviceIdentity`、backup `sourceBindingID`、logical `resourceID` 與 byte-level `contentHash` 不得混用。
- 六位數代碼只做 short authentication string 驗證，絕不能直接作為 encryption key 或在網路上傳送；驗證成功後導出的 256-bit secret 才能作為 TLS 1.2 PSK。
- 第一個 integrity mismatch 可重傳一次；同一 resource 第二次 mismatch 必須回覆不可重試並終止 session。

## Actual Architecture

```tree
iphone_sync/
├── project.yml                  # XcodeGen canonical target/plist configuration
├── iPhoneSync.xcodeproj/        # committed generated project
├── apps/
│   ├── ios/
│   │   ├── Sources/             # PhotoKit、album selection、pairing、sender UI
│   │   ├── Info.plist           # generated from project.yml
│   │   └── iPhoneSync.entitlements
│   └── macos/
│       ├── Sources/             # menu bar receiver、pairing、Finder writes
│       ├── Info.plist           # generated from project.yml
│       └── iPhoneSyncMac.entitlements
├── packages/
│   └── SyncCore/
│       ├── Sources/SyncCore/    # contracts、crypto、framing、Bonjour、TLS、client
│       ├── Sources/MacReceiverKit/ # SwiftData manifest、safe writer、server
│       └── Tests/
├── docs/
│   ├── memory/
│   └── specs/
├── plans/
├── scripts/verify.sh
├── README.md
├── CLAUDE.md
├── AGENTS.md -> CLAUDE.md
└── README.todo
```

依賴方向：

```text
apps/ios ───────────────→ SyncCore
apps/macos ─────────────→ SyncCore + MacReceiverKit
MacReceiverKit ─────────→ SyncCore
```

`apps/ios` 與 `apps/macos` 不得互相 import。`SyncCore` 不得依賴 `MacReceiverKit` 或任一 App target；`MacReceiverKit` 不得依賴 App target。

## Approved Technical Choices

| Concern | Choice |
|---|---|
| Platforms | iOS 17+、macOS 14+、Swift 6 |
| Discovery | Bonjour `_iphonesync._tcp` |
| Transport | Network.framework TCP + TLS 1.2 PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`) |
| Pairing | Temporary TCP + ephemeral Curve25519 + six-digit SAS |
| Source | PhotoKit `PHAssetResourceManager` with network access disabled |
| Framing | Fixed binary header、JSON control payload、raw chunk payload |
| Chunk size | 1 MiB |
| Integrity | SHA-256 |
| Resume checkpoint | 16 MiB durable checkpoint |
| Manifest | SwiftData in Mac App container |
| Destination | User-selected Finder folder with security-scoped bookmark |

## Runtime Ownership

| State | Owner | Persistence |
|---|---|---|
| iPhone device ID、selected album | iOS App | `UserDefaults` |
| Paired peer PSK、opaque identity、source binding | 各 App | Keychain |
| Mac receiver ID、current source binding | macOS App | `UserDefaults` |
| Destination capability | macOS App | security-scoped bookmark |
| Album/source binding | `ManifestStore` | SwiftData `SourceRecord` |
| Resource status、hash、size、checkpoint、final path | `ManifestStore` | SwiftData `TransferRecord` |
| Partial media bytes | `DestinationWriter` | destination `<name>.partial` |

同一 `sourceBindingID` 一旦綁定 album ID，後續不同 album 必須拒絕。使用者在 Mac 明確執行 `Reset Source` 或更換 destination 時才產生新的 binding；既有 committed Finder files 不刪除。

## Build and Verification

`project.yml` 是 Xcode project、兩個 Info.plist 與 entitlements 的 canonical source。不要直接修改產生後的 `apps/*/Info.plist` 或 `*.entitlements`；修改 `project.yml` 後執行：

```bash
xcodegen generate
```

完整非破壞性驗證：

```bash
bash scripts/verify.sh
```

個別 package 驗證：

```bash
swift test --package-path packages/SyncCore
```

驗證腳本使用 `CODE_SIGNING_ALLOWED=NO` 建置 `iPhoneSyncMac`、generic iOS Simulator 與 generic iOS device。它不安裝 App、不授予 Photos/Local Network 權限，也不證明實體裝置可同步。

## Security Notes

- Temporary pairing service 為 `_iphonesync-pair._tcp`，配對視窗為 120 秒且一次只接受一條連線。
- Normal sync service 為 `_iphonesync._tcp`；只有 TLS handshake 完成後才解析 sync frame。
- TLS minimum/maximum 固定 1.2，cipher suite 固定 `TLS_PSK_WITH_AES_128_GCM_SHA256`。Apple public static-PSK API 在目前支援 runtime 強制 TLS 1.3 時無法完成 handshake，因此不可把此實作描述為 TLS 1.3。
- Control frame 上限 64 KiB，chunk 上限 1 MiB，durable checkpoint 為 16 MiB。
- Receiver 先驗證 frame、offset、expected size 與 SHA-256，完成後才以不覆寫方式 atomic commit。

## Canonical Documentation

- 業務定義與 domain flow：[README.md](README.md)
- 核准設計：[docs/specs/2026-07-19-local-album-sync-design.md](docs/specs/2026-07-19-local-album-sync-design.md)
- 實作計畫：[plans/2026-07-19-local-album-sync.md](plans/2026-07-19-local-album-sync.md)
- 待辦：[README.todo](README.todo)
- 歷史操作與決策：[docs/memory/README.md](docs/memory/README.md)

結構、business scope 或技術決策變更時，必須同步上述 canonical files。
