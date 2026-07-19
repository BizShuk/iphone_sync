# iPhone Sync — Technical Context

## Current Status

本 repo 目前只有核准後的設計文件與工作區必要介面；尚未建立 Xcode workspace、App targets 或 Swift package。不得將規格中的 planned structure 誤認為已存在的程式碼。

## Product Invariants

- iPhone 必須由使用者在前景手動觸發同步。
- 同一時間只綁定一個來源相簿、一部 iPhone 與一部 Mac。
- 同步只能新增，永不因來源變動刪除或覆寫 Mac 既有檔案。
- 傳輸只能使用 Bonjour 可見的區域網路；`includePeerToPeer` 固定為 `false`。
- PhotoKit resource request 固定使用 `isNetworkAccessAllowed = false`。
- Mac manifest 是完成狀態與續傳 offset 的 authoritative source。
- cryptographic `deviceIdentity`、backup `sourceBindingID`、logical `resourceID` 與 byte-level `contentHash` 不得混用。
- 六位數代碼只做 short authentication string 驗證，絕不能直接作為 encryption key 或在網路上傳送；驗證成功後導出的 256-bit secret 才能作為 TLS 1.3 PSK。

## Planned Architecture

```tree
iphone_sync/
├── apps/
│   ├── ios/                 # PhotoKit、album selection、sender UI
│   └── macos/               # menu bar receiver、pairing、Finder writes
├── packages/
│   └── SyncCore/            # wire protocol、identity、framing、hashing
├── docs/
│   ├── memory/
│   └── specs/
├── plans/
├── README.md
├── CLAUDE.md
├── AGENTS.md -> CLAUDE.md
└── README.todo
```

`apps/ios` 與 `apps/macos` 不得互相 import；兩者只能向下依賴 `packages/SyncCore`。`SyncCore` 不得依賴任何 App target。

## Approved Technical Choices

| Concern | Choice |
|---|---|
| Platforms | iOS 17+、macOS 14+、Swift 6 |
| Discovery | Bonjour `_iphonesync._tcp` |
| Transport | Network.framework TCP + TLS 1.3 PSK |
| Pairing | Temporary TCP + ephemeral Curve25519 + six-digit SAS |
| Source | PhotoKit `PHAssetResourceManager` with network access disabled |
| Framing | Fixed binary header、JSON control payload、raw chunk payload |
| Chunk size | 1 MiB |
| Integrity | SHA-256 |
| Resume checkpoint | 16 MiB durable checkpoint |
| Manifest | SwiftData in Mac App container |
| Destination | User-selected Finder folder with security-scoped bookmark |

## Canonical Documentation

- 業務定義與 domain flow：[README.md](README.md)
- 核准設計：[docs/specs/2026-07-19-local-album-sync-design.md](docs/specs/2026-07-19-local-album-sync-design.md)
- 待辦：[README.todo](README.todo)
- 歷史操作與決策：[docs/memory/README.md](docs/memory/README.md)

結構、business scope 或技術決策變更時，必須同步上述 canonical files。
