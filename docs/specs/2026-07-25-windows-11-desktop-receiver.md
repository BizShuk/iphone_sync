# Windows 11 Desktop Receiver — 設計

> 狀態：Approved
> 日期：2026-07-25
> 對齊目標：`對齊 macOS app 功能、建立 Windows 11 桌面版`

## Context

`iphone_sync` 目前是 Apple-only monorepo：iOS sender + macOS menu-bar receiver + 共享 `SyncCore`/`MacReceiverKit` Swift package，傳輸走 Bonjour + TLS 1.2 PSK + binary framing + SHA-256，資料只在同 LAN 流動。

本計畫新增 Windows 11 desktop receiver，使用 Electron 32 + Node.js 22 + TypeScript 5 與既有 macOS receiver 對等。iPhone sender 透過 Bonjour 自動看見所有 `_iphonesync._tcp` 服務，由使用者在 iPhone 端挑選要同步到哪台電腦。Mac 與 Windows 共用同一份 wire protocol（`protocolVersion = 1`），iOS App 不需區分平台。

## Constraints

- **iOS sender 不變**：Apple-only 平台能力（PhotoKit、Local Network 授權、Bonjour browse API）維持原樣。
- **protocolVersion 不 bump**：iOS / Mac 互通不摩擦；receiver 對 iPhone 隱形，UX 靠使用者 `Forget iPhone` 切換。
- **Wire protocol 嚴格對齊**：40-byte header + `IPS1` magic + 1 MiB chunk + 16 MiB checkpoint + 64 KiB control cap + TLS 1.2 PSK（`TLS_PSK_WITH_AES_128_GCM_SHA256`）+ Curve25519 HKDF-derived 6-digit SAS。

## Approved Technical Choices

| Concern | macOS 既有 | Windows 11 對應 |
|---|---|---|
| Runtime | Swift 6 / Swift 6 concurrency | Node.js 22 LTS + TypeScript 5 + Electron 32 |
| UI | SwiftUI / AppKit | Electron `BrowserWindow` + HTML/CSS/JS（Fluent 風格 CSS 變數） |
| Tray | `NSStatusItem` | Electron `Tray` + `Menu` |
| 探索 | `NWListener.service` + `BonjourDiscovery` | `multicast-dns` + `dns-packet` |
| Transport | `Network.framework` TCP + TLS-PSK | Node `tls.createServer({ ciphers: 'PSK-AES128-GCM-SHA256', pskCallback })` |
| Pairing crypto | Security.framework Curve25519 + CryptoKit HKDF | `crypto.diffieHellman({ curve: 'x25519' })` + `crypto.hkdfSync` |
| Manifest | SwiftData | `better-sqlite3` |
| Destination | security-scoped bookmark + `NSOpenPanel` | `dialog.showOpenDialog({ properties: ['openDirectory'] })` + path 持久化 |
| Persistent settings | sandbox `UserDefaults` | `%LOCALAPPDATA%\iPhoneSync\settings.json` |
| Paired peer PSK | Keychain Services | Electron `safeStorage`（內部走 DPAPI） |
| Launch at login | `SMAppService.mainApp` | `app.setLoginItemSettings({ openAtLogin: true })` |
| Operation Log | in-memory 500 + Apple Unified Logging | in-memory 500 + JSONL files at `%LOCALAPPDATA%\iPhoneSync\logs\` |
| File watcher | `NWPathMonitor` + `NSWorkspace.didWake` | `powerMonitor.on('resume')` + `networkInterfaces()` polling |
| Build pipeline | `xcodegen` + `xcodebuild` | `electron-builder --win nsis portable` |

## Wire Protocol (不變動)

| 欄位 | 值 |
|---|---|
| Service type | `_iphonesync._tcp` (normal), `_iphonesync-pair._tcp` (pairing) |
| TXT keys | `id`, `name`, `version`, `pairing` |
| protocolVersion | `1`（不 bump） |
| TLS version | 1.2 only |
| Cipher | `TLS_PSK_WITH_AES_128_GCM_SHA256` |
| Frame magic | `0x49 0x50 0x53 0x31` (`"IPS1"`) |
| Frame header | 40 bytes big-endian（magic(4) + version(2) + kind(1) + reserved(1) + UUID(16) + offset(8) + payloadLen(8)） |
| Frame kinds | `session=1, offer=2, decision=3, chunk=4, result=5` |
| Pairing wire | 4-byte length prefix + JSON |
| Chunk size | 1 MiB |
| Control frame cap | 64 KiB |
| Checkpoint | 16 MiB |
| Pairing window | 120 seconds |
| SAS | 6-digit, derived from HKDF label `iphonesync-sas-v1` |
| HKDF labels | `iphonesync-{sas,psk,identity,client-proof,server-proof}-v1` |
| Curve25519 transcript | length-prefixed SHA-256 over protocolVersion + receiverID + initiatorPub + receiverPub + initiatorNonce + receiverNonce |
| PSK identity | 32 bytes derived via HKDF |
| Resume | offer → decision `skip`/`start`/`resume(offset)` → chunk → result `committed`/`failed` |
| Integrity retry | 第一次 mismatch `retryable=true`; 第二次 terminate session |
| Error codes | `authentication, destinationUnavailable, diskFull, integrity, invalidFrame, protocolMismatch, unknown` |
| Filename layout | `<YYYY>/<MM>/<stem>__<prefix>[<role>].<ext>` |
| Storage modes | `albumDate` / `albumOnly` / `flat` |

## Project Layout

```text
iphone_sync/
├── apps/
│   ├── ios/                       # iOS sender (Apple-only)
│   ├── macos/                     # macOS receiver (Swift)
│   └── windows/                   # Windows 11 receiver (Electron + Node.js)
│       ├── src/
│       │   ├── main/
│       │   │   ├── main.ts            # Electron entry
│       │   │   ├── model-root.ts      # Facade: settings + destination + manifest + pairing + receiver
│       │   │   ├── tray.ts            # Tray icon + menu
│       │   │   ├── setup-window.ts    # Setup BrowserWindow
│       │   │   ├── pairing-window.ts  # Pairing BrowserWindow
│       │   │   ├── auto-launch.ts     # Electron setLoginItemSettings
│       │   │   ├── recovery.ts        # powerMonitor + network polling
│       │   │   └── ipc.ts             # IPC handlers
│       │   ├── preload/preload.ts     # contextBridge
│       │   └── renderer/
│       │       ├── setup.html         # Status / Last Sync / Operation Log
│       │       ├── pairing.html       # 6-digit SAS + countdown
│       │       ├── setup.ts
│       │       ├── pairing.ts
│       │       └── app.css            # Fluent design tokens
│       ├── assets/icons/tray.ico
│       ├── package.json
│       ├── tsconfig.json
│       ├── electron-builder.yml
│       └── README.md
├── packages/
│   ├── SyncCore/                  # Swift (Mac)
│   └── SyncCore.Windows/          # Node.js/TypeScript port of SyncCore + MacReceiverKit
│       ├── src/
│       │   ├── protocol/
│       │   ├── crypto/
│       │   ├── discovery/
│       │   ├── pairing/
│       │   ├── receiver/
│       │   ├── persistence/
│       │   └── logging/
│       └── tests/
│           ├── frame-codec.spec.ts
│           ├── pairing-crypto.spec.ts
│           ├── pairing-protocol.spec.ts
│           ├── pairing-server.spec.ts
│           ├── identity-filename.spec.ts
│           ├── operation-log.spec.ts
│           ├── protocol-messages.spec.ts
│           ├── file-hasher.spec.ts
│           ├── manifest-store.spec.ts
│           ├── destination-writer.spec.ts
│           └── helpers/
```

## File mapping (macOS ↔ Windows)

| macOS / Swift | Windows / TypeScript |
|---|---|
| `apps/macos/Sources/iPhoneSyncMacApp.swift` | `apps/windows/src/main/main.ts` |
| `apps/macos/Sources/MacAppDelegate.swift` | `apps/windows/src/main/main.ts` |
| `apps/macos/Sources/MacAppModel.swift` | `apps/windows/src/main/model-root.ts` |
| `apps/macos/Sources/ReceiverController.swift` | `packages/SyncCore.Windows/src/receiver/receiver-controller.ts` |
| `apps/macos/Sources/SetupView.swift` | `apps/windows/src/renderer/setup.html` + `setup.ts` |
| `apps/macos/Sources/MacSettingsStore.swift` | `packages/SyncCore.Windows/src/persistence/settings-store.ts` |
| `apps/macos/Sources/DestinationBookmarkStore.swift` | `packages/SyncCore.Windows/src/persistence/destination-store.ts` |
| `packages/SyncCore/Sources/SyncCore/FrameCodec.swift` | `packages/SyncCore.Windows/src/protocol/frame-codec.ts` |
| `packages/SyncCore/Sources/SyncCore/FramedConnection.swift` | `packages/SyncCore.Windows/src/protocol/framed-connection.ts` |
| `packages/SyncCore/Sources/SyncCore/SyncMessage.swift` | `packages/SyncCore.Windows/src/protocol/messages.ts` |
| `packages/SyncCore/Sources/SyncCore/ResourceIdentity.swift` | `packages/SyncCore.Windows/src/protocol/resource.ts` |
| `packages/SyncCore/Sources/SyncCore/FilenamePolicy.swift` | `packages/SyncCore.Windows/src/protocol/filename-policy.ts` |
| `packages/SyncCore/Sources/SyncCore/PairingCrypto.swift` | `packages/SyncCore.Windows/src/crypto/pairing-crypto.ts` |
| `packages/SyncCore/Sources/SyncCore/PairingProtocol.swift` | `packages/SyncCore.Windows/src/pairing/pairing-protocol.ts` |
| `packages/SyncCore/Sources/SyncCore/PairingServer.swift` | `packages/SyncCore.Windows/src/pairing/pairing-server.ts` |
| `packages/SyncCore/Sources/SyncCore/PSKTLSParameters.swift` | `packages/SyncCore.Windows/src/crypto/tls-psk-server.ts` |
| `packages/SyncCore/Sources/SyncCore/BonjourDiscovery.swift` | `packages/SyncCore.Windows/src/discovery/bonjour-browse.ts` |
| `packages/SyncCore/Sources/SyncCore/KeychainSecretStore.swift` | `packages/SyncCore.Windows/src/persistence/secret-store.ts` |
| `packages/SyncCore/Sources/SyncCore/OperationLog.swift` | `packages/SyncCore.Windows/src/logging/operation-log.ts` |
| `packages/SyncCore/Sources/SyncCore/DestinationStorageMode.swift` | `packages/SyncCore.Windows/src/receiver/destination-storage-mode.ts` |
| `packages/SyncCore/Sources/MacReceiverKit/ManifestStore.swift` | `packages/SyncCore.Windows/src/receiver/manifest-store.ts` |
| `packages/SyncCore/Sources/MacReceiverKit/DestinationWriter.swift` | `packages/SyncCore.Windows/src/receiver/destination-writer.ts` |
| `packages/SyncCore/Sources/MacReceiverKit/AlbumFolderPolicy.swift` | `packages/SyncCore.Windows/src/receiver/album-folder-policy.ts` |
| `packages/SyncCore/Sources/MacReceiverKit/SyncServerSession.swift` | `packages/SyncCore.Windows/src/receiver/sync-server-session.ts` |

## Build & Verify

`scripts/verify.sh` 新增 Windows 區段：

```bash
if [[ -d "packages/SyncCore.Windows" && -d "apps/windows" ]]; then
  bash scripts/verify_windows.sh
fi
```

`scripts/verify_windows.sh` 跨平台跑：

1. `npm ci` + `npm test` 與 `npm run build`（macOS / Linux / Windows MSYS）
2. source-string invariant grep（HKDF labels、`"IPS1"` magic、`TLS_PSK_WITH_AES_128_GCM_SHA256`、`iPhoneSync` container 等）
3. Windows-only：`npm run dist`（electron-builder NSIS + portable）

## Contract verification (Node 端 ↔ Swift 端)

51 個 SyncCore.Windows tests 對應既有 Swift 51 個 package tests + 30 個 iOS unit tests + 30 個 MacReceiverKit tests。Curve25519 transcript hash、HKDF labels、frame header、PSK cipher 等 wire-format 細節雙側通過即視為互通。

## Risks

- Node `tls.createServer` PSK cipher (`PSK-AES128-GCM-SHA256`) 在 Windows OpenSSL backend 與 Apple `Network.framework` 完全互通可能遇到差異；Phase 3 早期做最小互通測試，必要時改 cipher suite 別名。
- `electron-builder` 對 Windows code signing 在 2026 是否仍免費或需 EV certificate：先做 unsigned NSIS。
- `multicast-dns` 在 Windows 11 22H2 / 23H2 / 24H2 mDNSResponder 互動可能偶發查詢失敗，需 retry。
- `electron-store` v10 對 ESM-only 的限制：v9 或自寫 settings.json 較穩定。

## Backlog

- MSIX 封裝 + SmartScreen 信任
- 公證 / Store 發佈
- iOS sender 顯示 receiver family（需 protocolVersion bump，本計畫不做）
