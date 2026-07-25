# Windows 11 Desktop Receiver — 設計文件

> 狀態：Draft → Ready for approval
> 日期：2026-07-25
> 對齊目標：`對齊 macOS app 功能、建立 Windows 11 桌面版`

## Context

`iphone_sync` 目前是一個 Apple-only monorepo：iOS sender + macOS menu-bar receiver + 共享 `SyncCore`/`MacReceiverKit` Swift package，傳輸走 Bonjour + TLS 1.2 PSK + binary framing + SHA-256，所有資料只在同 LAN。

`goal` 設定為「對齊 macOS app 功能、建立 Windows 11 桌面版」。由於 iOS PhotoKit、`BGProcessingTask`、`BGTaskScheduler` 屬於 Apple-only 平台能力，iPhone sender 維持 iOS 不變；Windows 11 版是新增的 receiver family——以 Windows 11 桌面 App 形式提供對等接收能力，讓同一台 iPhone 可選擇把相簿同步到 Mac 或 Windows 11。

`protocolVersion` 維持 1（不 bump）。iOS sender 完全不需修改；Mac 與 Windows receiver 對 iPhone 隱形（用相同 TXT 格式），使用者可在兩個平台間切換並由配對（`Forget iPhone`）切換。

## Scope

### In scope（本計畫交付）

- Windows 11 desktop receiver App（x64、ARM64）
- 與 iPhone sender（version 1）雙向互通
- 對齊 macOS receiver 所有可移植功能
- 發佈：`exe`（`electron-builder` 產 portable installer + NSIS）為主；MSIX 列為 backlog
- `scripts/verify.sh` 新增 windows 子驗證
- canonical docs 同步（README、CLAUDE、permission、todo、terminology、specs）

### Out of scope（明確不做）

- Windows 版 iOS sender（iOS PhotoKit only）
- macOS / iOS 端任何 UI / protocol 變更（protocolVersion 不 bump）
- MSIX 封裝與 SmartScreen 信任（backlog）
- 公證 / Store 發佈
- Wi-Fi Direct / Bluetooth / 雲端 relay
- 多組 paired iPhone 或多個 destination 平行

## Approved Technical Choices（待 merge）

| Concern | macOS 既有 | Windows 11 對應 | 理由 |
|---|---|---|---|
| Runtime | Swift 6 + Swift 6 concurrency | **Node.js 22 LTS + TypeScript 5 + Electron 32** | Node 內建 `crypto.createSecureContext` 支援 PSK cipher；Electron 提供原生 tray + BrowserWindow + powerMonitor；TS 與 Swift 對應的可讀性高 |
| UI | SwiftUI / AppKit | Electron `BrowserWindow` + HTML/CSS/JS；Fluent UI 風格以 CSS 變數 + `@fluentui/web-components`（backlog） | Electron 跨平台、TS 與既有 Swift 測試向量容易對照 |
| Tray | `NSStatusItem` | Electron `Tray` + `Menu` | 直接對應；Win11 system tray 行為由 Electron 包辦 |
| 探索 | `NWListener.service` + `BonjourDiscovery` | `multicast-dns`（RFC 6762/6763） + `dns-packet`（TXT 編解碼） | mDNSResponder 在 Win11 內建；`multicast-dns` 是 Node 社群最普及的純 JS 實作 |
| Transport | `Network.framework` TCP + TLS-PSK | Node `tls.createServer({ ciphers: 'PSK-AES128-GCM-SHA256' })` + `pskCallback` | Node 22 `tls` 模組原生支援 PSK cipher 與 identity callback；不需 BouncyCastle |
| Pairing crypto | Security.framework Curve25519 + CryptoKit HKDF | Node `crypto.diffieHellman({ curve: 'x25519' })` + `crypto.hkdfSync('sha256', ...)` + `crypto.createHash('sha256')` | Node 22 內建 X25519 + HKDF + SHA-256；label 與 salt 流程與 Swift 版 1:1 |
| SAS | 六位數 short auth string | 同 | wire format 不變 |
| Manifest | SwiftData | `better-sqlite3`（同步 API） | schema 對應 `SourceRecord` / `AlbumRecord` / `TransferRecord`；同步 API 簡化 commit 流程 |
| Destination | security-scoped bookmark + `NSOpenPanel` | `dialog.showOpenDialog({ properties: ['openDirectory'] })` + path 持久化 | 不需 sandbox 等價物；使用 NSIS / electron-builder 預設目錄 |
| Persistent settings | sandbox `UserDefaults` | `%LOCALAPPDATA%\iPhoneSync\settings.json`（`app.getPath('userData')`） | 對齊既有 macOS app 設定格式 |
| Paired peer PSK | Keychain Services | Electron `safeStorage.encryptString`（Win 內部走 DPAPI） | user-scoped 防護 |
| Launch at login | `SMAppService.mainApp` | `app.setLoginItemSettings({ openAtLogin: true })` | Electron 內建 API；底下登錄 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |
| Operation Log | in-memory 500 + Apple Unified Logging | in-memory 500 + 串流到 `%LOCALAPPDATA%\iPhoneSync\logs\operations-<date>.jsonl` | 對齊既有容量與 semantic categories |
| Local Network / firewall | `NSLocalNetworkUsageDescription` | `New-NetFirewallRule -Direction Inbound -Protocol TCP -Action Allow`（首次啟動或安裝時） | Windows 對 LAN 連入需手動允許 inbound；electron-builder NSIS 可附 PowerShell 步驟 |
| Bonjour TXT | Apple `NWTXTRecord` | RFC 6763 TXT（`dns-packet` 解碼） | iOS 端解析相容 |
| Setup window | SwiftUI Form | Electron `BrowserWindow` + 表單 HTML；`sectionHeader("Status")` / `sectionHeader("Last Sync")` / `sectionHeader("Operation Log")` 三區段 | 對齊既有 setup layout |
| Path monitor | `NWPathMonitor` + `NSWorkspace.didWake` | `electron.powerMonitor` + `multicast-dns` `.NetworkChanged` event + `dnsServiceQuery` 重新 browse | 對齊既有 recovery trigger |
| Build pipeline | `xcodegen` + `xcodebuild` | `electron-builder --win --x64` 產 `.exe`（NSIS installer） | electron-builder 對 Windows portable + NSIS 最成熟 |

## Wire Protocol Compatibility（不變動）

來源：`packages/SyncCore/Sources/SyncCore/`（`SyncConstants.swift:1-10`、`FrameCodec.swift:69-92`、`BonjourDiscovery.swift:12-23`、`PairingProtocol.swift`、`PairingCrypto.swift`、`SyncMessage.swift`）。

| 欄位 | 既有（SyncCore） | Windows 11 對應 | 備註 |
|---|---|---|---|
| Service type | `_iphonesync._tcp`（normal）、`_iphonesync-pair._tcp`（pairing） | 同（透過 `multicast-dns` over `_local.`） | iOS sender 沿用 browse |
| TXT keys | `id`, `name`, `version`, `pairing` | 同（**不**新增 `family`，protocolVersion 不 bump） | iOS 端 `BonjourDiscovery.swift:12-23` 嚴格解析 `version == UInt16(1)` |
| protocolVersion | `UInt16 = 1` | 同 | 不 bump；iOS / Mac / Win 三端互通零摩擦 |
| TLS 版本 | `min == max == .TLSv12` | Node `tls.createServer` 強制 TLS 1.2（`minVersion: 'TLSv1.2', maxVersion: 'TLSv1.2'`） | |
| Cipher | `TLS_PSK_WITH_AES_128_GCM_SHA256` | Node `tls` 原生 PSK cipher（OpenSSL 後端） | RFC 5487/5489 |
| Frame magic | `0x49 0x50 0x53 0x31`（`"IPS1"`） | 同 | `FrameCodec.swift:79` |
| Frame header | **40 bytes** big-endian：magic(4) + version(2) + kind(1) + reserved(1) + requestID UUID(16) + offset(8) + payloadLength(8) | 同 | 對應 `FrameCodec.swift:69-92` |
| Frame kinds | `session=1, offer=2, decision=3, chunk=4, result=5` | 同 | `FrameCodec.swift:3-9` |
| Pairing wire | 4-byte length prefix + JSON payload | 同 | `PairingProtocol.swift:92-127` |
| Chunk size | 1 MiB | 同 | |
| Control frame cap | 64 KiB | 同 | header 解碼時即檢查 |
| Checkpoint | 16 MiB | 同 | |
| Pairing window | 120 秒 | 同 | `setTimeout` |
| SAS | 6 位數字 zero-padded，HKDF 3-byte output | 同 | `PairingCrypto.swift:122-129` |
| HKDF labels | `iphonesync-sas-v1` / `-psk-v1` / `-identity-v1` / `-client-proof-v1` / `-server-proof-v1` | 同 | `-v1` suffix 保留 |
| Curve25519 transcript | length-prefixed fields：protocolVersion + receiverID + initiatorPubKey + receiverPubKey + initiatorNonce + receiverNonce；SHA256 over canonical；salt = transcriptHash | 同（`Buffer.concat([u16BE, u32BE+id, u32BE+pubKey, ...])`） | 跨平台必須 byte-for-byte 一致 |
| Nonce | 32-byte per side | `crypto.randomBytes(32)` | |
| PSK identity | HKDF 派生 32 bytes | 同 | 對應 `SettingsStore` `pairedPeer` JSON |
| Resume | offer → decision `skip`/`start`/`resume(offset)` → chunk → result `committed`/`failed` | 同 | receiver partial file `<name>.partial` |
| Integrity retry | 第一次 mismatch `retryable=true`；第二次終止 session | 同 | `SyncServerSession.swift` `integrityFailureLimitExceeded` |
| Error codes | `authentication, destinationUnavailable, diskFull, integrity, invalidFrame, protocolMismatch, unknown` | 同 | `SyncMessage.swift:32-40` |
| Resource descriptor | `assetLocalIdentifier, resourceType, originalFilename, duplicateOrdinal, contentHash (lowercase hex SHA-256), expectedSize, creationDate?, role` | 同 | `ResourceDescriptor.swift` |
| Filename policy | 拒絕 `.`、`..`、`.` 開頭、`/`、`\`、control；resourceID 必須 64-char hex；role 限 `[A-Za-z0-9_-]` | 同 | `FilenamePolicy.swift:1-84` |
| Filename layout | `<YYYY>/<MM>/<stem>__<prefix><role?>.ext` | 字串值不變；路徑拼裝用 `path.join`（Win 用 `\`） | `finalRelativePath` 在 manifest 與 wire 上仍以 `/` 表示 |
| `requireWiFi` | discovery true / client true / server false | server 不卡 WiFi；client 仍由 iPhone 卡 | |
| `includePeerToPeer` | `false` | 自動滿足 | |
| TCP | `noDelay=true`, `enableKeepalive=true` | Node `net.createServer({ noDelay: true, keepAlive: true })` | |

### 訊息序列（既有，無變更）

```
Pairing (separate service _iphonesync-pair._tcp, 120s window):
  C → S: Hello { deviceID, displayName, publicKey, nonce }   (length-prefix JSON)
  S → C: Hello { deviceID, displayName, publicKey, nonce }
  S → C: 显示 SAS 6-digit (in-app only, not on wire)
  C → S: Confirm { proof }
  S → C: Accepted { proof, pskIdentity }

Normal sync (_iphonesync._tcp, post-TLS-PSK):
  C → S: OpenSession { albumID, albumName, sourceBindingID? }   (.session.request)
  S → C: Accept { sourceBindingID }                              (.session.accepted)
  C ↔ S: for each resource: Offer → Decision → N×Chunk → Result
  S → C: Complete { added, existing, notLocal, failed }         (.result.sessionCompleted)
```

## Receiver Lifecycle（與 iOS client 互動完整流程）

來源：`packages/SyncCore/Sources/MacReceiverKit/SyncServerSession.swift`、`ManifestStore.swift`、`DestinationWriter.swift`、`AlbumFolderPolicy.swift`、`apps/ios/Sources/.../SyncClient.swift`、`IOSSyncCoordinator.swift`。

### Opening Deadline

`SyncServerSession.run` 啟動 `SessionOpeningDeadline`（actor-based，三態 `pending → accepted | timedOut`），同時 spawn 15 秒 timeout task。第一個 frame 必須是 `.session(.request(albumID, albumName, requestedBinding))`，否則 → `protocolViolation`；binding 不符 → `sourceBindingMismatch`；逾時 → `openingTimedOut` 並 `connection.destroy()`。

### Binding 規則

- 第一次 sync：iOS 端 `peer.sourceBindingID == nil`，receiver 端 `acceptSession` 自動 `nextSourceBindingID` 並透過 `.session(.accepted(sourceBindingID))` 回傳；iOS 端 `IOSSyncCoordinator` 把新 binding 寫回 Keychain (`PairedPeer`)。
- 之後 sync：iOS 帶的 `requestedBindingID` 必須等於 receiver 端持久化的 `sourceBindingID`，否則拒絕。

### Resource Offer → Decision → Commit 完整子流程

```
offer(offer):
  writer.begin(offer) →
    .adopted(relativePath)        → decision(.skip), summary.existing++
    .transfer(offset, relPath)    →
      offset==0  → decision(.start(0))
      offset>0   → decision(.resume(offset))
      receiveBytes() 嚴格檢查 kind/requestID/offset/non-empty payload
      每 16 MiB → writer.checkpoint(at:)
      writer.commit(expectedHash) → SHA-256 驗證 → atomic rename → result(.committed)
        第一次 integrityMismatch → result(.failed integrity retryable:true) + 不計入 failed
        第二次 integrityMismatch → result(.failed integrity retryable:false) + integrityFailureLimitExceeded throw
        其他 writer error → result(.failed destinationUnavailable) + sessionRejected throw
```

### Manifest Schema（SQLite 對應）

| 實體 | PK | 索引 | 備註 |
|---|---|---|---|
| `source_records` | `source_binding_id TEXT PRIMARY KEY` | — | `album_id` / `album_name` 為 legacy seed，`created_at` / `updated_at` |
| `album_records` | `album_binding_key TEXT PRIMARY KEY`（SHA256 hex of `"album" \|\| sourceBindingID \|\| albumID` length-prefix canonical） | — | `destination_folder_name` 經 `AlbumFolderPolicy` 處理 |
| `transfer_records` | `resource_id TEXT PRIMARY KEY`（SHA256 hex of `"transfer" \|\| sourceBindingID \|\| albumID \|\| logicalResourceID`） | `(source_binding_id, album_id)` | `logical_resource_id = ResourceIdentity.make(...)`；`status ∈ {pending, transferring, committed, failed}` |

Manifest 主要 mutation：`acceptSession`、`decision(for:)`（skip / start / resume）、`recordCheckpoint`、`commit`、`reset`、`snapshot`、`nextDestinationFolderName`、`migrateLegacyAlbumIfNeeded`。

### DestinationWriter 安全規則

| 規則 | Node + Win32 對應 |
|---|---|
| `active == nil` 才允許新 transfer | 單一 mutex（`async-mutex`） |
| `prepareAlbumDirectory`：路徑必須在 `destinationRoot` 內 | `path.resolve` 正規化後前綴比對（NTFS case-insensitive 用 `String.equalsIgnoreCase`） |
| 拒絕 symlink | `fs.lstat(...).isSymbolicLink()` 或 `fs.readlink` 對應 reparse |
| 已存在位置不是目錄即拒絕 | `fs.stat(...).isDirectory()` |
| partial file `<name>.partial` | 沿用同名 |
| `previousAlbumPartialURL` / `legacyPartialURL` → 新 partial 自動搬遷 | `fs.rename`（Node 內部走 `MoveFileEx`） |
| `commit`：`fdatasync` + SHA-256 + `fs.rename` 原子提交 | `fh.sync()` + `fs.rename`（POSIX-style atomic on NTFS） |
| `setAttributes([.creationDate, .modificationDate])` | `fs.utimes`（Node 內部 `SetFileTime`） |
| NTFS 保留名 `CON / PRN / AUX / NUL / COM1..9 / LPT1..9` | `AlbumFolderPolicy.folderName` 之後套 `ReservedNameFilter` |
| NTFS case-insensitive 衝突 | `OrdinalIgnoreCase` 比較 albumRecord `destinationFolderName` 集合 |
| 長路徑 `\\?\` prefix | 超過 MAX_PATH（260）時自動套用 `\\?\` 前綴（Node fs 不會自動套，需自寫 util） |
| SHA-256 | `crypto.createHash('sha256')` |
| 寫入嚴格 offset 連續 | `write(buffer, offset)` 後 `nextOffset += buffer.length` |

### Storage Mode Layout

| Mode | 路徑格式 |
|---|---|
| `.albumDate` | `<destinationRoot>/iPhoneSync/<albumFolder>/<year>/<month>/<file>` |
| `.albumOnly` | `<destinationRoot>/iPhoneSync/<albumFolder>/<file>` |
| `.flat` | `<destinationRoot>/iPhoneSync/<file>` |

`finalRelativePath` 在 manifest 與 wire 上仍以 `/` 表示（NTFS 接受 `/`）。

### AlbumFolderPolicy 規則（Node 版需擴充）

1. 空字串 / 全空白 → `Untitled Album`
2. `/` `\` control characters (U+0000..U+001F、U+007F..U+009F) → `_`
3. 等於 `.` / `..` 或以 `.` 開頭 → 開頭插入 `_`
4. **NTFS 保留名**：`/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i` 匹配（去除副檔名前）→ 在開頭插入 `_`
5. **NTFS 尾端**：名稱結尾為 `.` 或 ` ` → 截掉並補 `_`
6. 衝突命名：`<safe-name> (2)`、`(3)` … `(10000)`；之後 fallback 為 `(UUID)`
7. NTFS case-insensitive：`localeCompare(..., undefined, { sensitivity: 'accent' })` 比對 `albumRecords.destinationFolderName`

### iOS Client → Receiver 識別（同步契約）

- Service type：sync 模式 `_iphonesync._tcp`；pairing 模式 `_iphonesync-pair._tcp`
- TXT `id` exact match：`receiver.id == peer.id`
- `version == UInt16(1)` 已於 `BonjourDiscovery` 過濾；Win receiver 必須讓 TXT `version=1`
- `requireWiFi = true`、`includePeerToPeer = false`（`multicast-dns` 預設不過 AWDL）
- Retry 排程：`[0, 1, 2, 4]` 秒；首次 8 秒 timeout

### Resource Lifecycle Events（Mac Operation Log 對應）

| Event | Category | Level | 觸發 |
|---|---|---|---|
| `Opening album "<name>"` | Session | info | 收到 `.session(.request)` 並通過 binding 驗證 |
| `Rejected album "<name>": source binding mismatch` | Session | error | binding 不符 |
| `Could not prepare album "<name>": <err>` | Destination | error | `prepareAlbumDirectory` 失敗 |
| `Accepted album "<name>" in folder "<folder>"` | Session | success | send `.session(.accepted)` 之前 |
| `Offered "<name>" (<size> bytes)` | Resource | info | 收到 `.offer` |
| `Skipped "<name>"; already present` | Resource | info | `writer.begin` 回 `.adopted` |
| `Receiving "<name>"` | Resource | info | `.decision(.start)` 之前 |
| `Resuming "<name>" at byte <off>` | Resource | info | `.decision(.resume)` 之前 |
| `Committed "<name>" to "<path>"` | Resource | success | SHA-256 通過、`rename` 完成 |
| `Failed "<name>": <msg> Retrying once.` | Resource | warning | 第一次 integrity 失敗 |
| `Failed "<name>": <msg>` | Resource | error | 其他錯誤或第二次 integrity 失敗 |
| `Completed: <added> added, <existing> already present, <notLocal> not local, <failed> failed.` | Session | success | 收到 `.session(.finished)` |

Win receiver 必須以同一張表產生事件，UI 文案 / category / level 一致。

## Project Layout

```text
iphone_sync/
├── apps/
│   ├── ios/                       # iOS sender (Apple-only)
│   ├── macos/                     # macOS receiver (Swift)
│   └── windows/                   # ← NEW: Windows 11 receiver (Electron + Node.js)
│       ├── src/
│       │   ├── main/
│       │   │   ├── main.ts            # Electron app entry
│       │   │   ├── ipc.ts             # IPC channels
│       │   │   ├── tray.ts            # Tray icon + menu
│       │   │   ├── setup-window.ts   # BrowserWindow
│       │   │   ├── auto-launch.ts     # Login item
│       │   │   ├── pairing-window.ts  # SAS display
│       │   │   └── recovery.ts        # powerMonitor + mDNS reconcile
│       │   ├── preload/
│       │   │   └── preload.ts         # contextBridge
│       │   └── renderer/
│       │       ├── setup.html         # Status / Last Sync / Operation Log 三區段
│       │       ├── pairing.html       # 六位數 SAS + 倒數
│       │       └── app.css            # Fluent 風格 + design tokens
│       ├── assets/
│       │   ├── tray.ico
│       │   └── icons/
│       ├── package.json
│       ├── tsconfig.json
│       ├── electron-builder.yml       # NSIS + portable 設定
│       └── README.md
├── packages/
│   ├── SyncCore/                  # Swift (Mac)
│   └── SyncCore.Windows/          # ← NEW: Node.js/TypeScript port of SyncCore + MacReceiverKit
│       ├── src/
│       │   ├── protocol/
│       │   │   ├── constants.ts           # SyncConstants mirror
│       │   │   ├── frame-codec.ts         # 40-byte header + magic + JSON
│       │   │   ├── framed-connection.ts   # 封裝 net.Socket
│       │   │   ├── messages.ts            # SyncMessage union + codable
│       │   │   ├── resource.ts            # ResourceDescriptor / Identity
│       │   │   └── filename-policy.ts     # 含 NTFS 擴充
│       │   ├── crypto/
│       │   │   ├── pairing-crypto.ts      # Curve25519 + HKDF labels
│       │   │   ├── file-hasher.ts         # SHA-256 streaming
│       │   │   └── tls-psk-server.ts      # Node tls.createServer PSK
│       │   ├── discovery/
│       │   │   ├── bonjour-browse.ts      # multicast-dns browse + TXT parse
│       │   │   └── bonjour-advertise.ts   # TXT encoding
│       │   ├── pairing/
│       │   │   └── pairing-server.ts      # 120s window + 5 attempts + 单连線
│       │   ├── receiver/
│       │   │   ├── sync-server-session.ts # 與 Swift 同 state machine
│       │   │   ├── manifest-store.ts      # better-sqlite3
│       │   │   ├── destination-writer.ts  # partial + atomic rename
│       │   │   ├── album-folder-policy.ts # 含 NTFS reserved/case-insensitive
│       │   │   └── receiver-controller.ts # listener lifecycle + retry
│       │   ├── persistence/
│       │   │   ├── settings-store.ts      # userData/settings.json
│       │   │   ├── destination-store.ts   # 持久化 path + modified time
│       │   │   └── secret-store.ts       # safeStorage encrypt
│       │   ├── logging/
│       │   │   ├── operation-log.ts      # 500 buffer
│       │   │   └── operation-logger.ts    # 串流到 JSONL
│       │   └── errors.ts
│       ├── tests/
│       │   ├── frame-codec.spec.ts
│       │   ├── pairing-crypto.spec.ts
│       │   ├── pairing-protocol.spec.ts
│       │   ├── identity-filename.spec.ts
│       │   ├── operation-log.spec.ts
│       │   ├── tls-psk.spec.ts
│       │   ├── manifest-store.spec.ts
│       │   ├── sync-round-trip.spec.ts
│       │   ├── destination-writer.spec.ts
│       │   └── helpers/
│       │       ├── receiver-harness.ts
│       │       └── resource-descriptor-fixture.ts
│       ├── package.json
│       ├── tsconfig.json
│       └── vitest.config.ts
└── scripts/
    ├── verify.sh                  # 擴充 windows 區段
    ├── verify_mac_settings.swift
    ├── run_server.sh
    ├── run_iphone.sh
    └── verify_windows.sh          # ← NEW: 純 Node/Electron 入口
```

依賴方向：

```text
apps/windows ────────────→ SyncCore.Windows
SyncCore.Windows ─────────→ (僅 Node 22 + npm，零 Apple binding)
```

`SyncCore.Windows` 不得 `require` `SyncCore` 或任何 Apple-only package；反之亦然。Wire protocol 雙向相容靠既有測試向量驗證（Swift 端 51 個 tests + C#/Node 端對等 tests 必須在兩側都通過）。

### 主要 npm 依賴

- `electron@^32`：runtime + UI
- `better-sqlite3@^11`：同步 SQLite
- `multicast-dns@^7`：RFC 6762 mDNS browse + respond
- `dns-packet@^5`：TXT 編解碼
- `electron-store@^10`：包裝 settings.json（仍可選用 plain JSON）
- `commander@^12`（CLI 模式可選）
- `vitest@^2`：tests
- `electron-builder@^25`：exe/NSIS packaging

開發依賴：`typescript@^5`、`@types/node@^22`、`@types/better-sqlite3`。

## Build & Verify

### 工具鏈

- Node.js 22 LTS
- npm 10+
- Electron 32（devDep）
- electron-builder 25
- Windows 11 22H2+ 開發機（產 NSIS installer 需 Windows；macOS / Linux 上可 build portable .exe 透過 Wine，但不驗證簽署）
- 可選：`signtool`（產 NSIS 後驗證 code signing）

### `scripts/verify.sh` 新增 windows 區段

```bash
# ...既有 iOS + macOS 步驟...

# === Windows 11 (Node/Electron port) ===
if command -v node >/dev/null && command -v npm >/dev/null; then
  # SyncCore.Windows unit tests (vitest)
  (cd packages/SyncCore.Windows && npm ci --no-audit --no-fund && npm test)

  # TypeScript build
  (cd packages/SyncCore.Windows && npm run build)
  (cd apps/windows && npm ci --no-audit --no-fund && npm run build)

  # Source-string invariants (Windows port side)
  rg -F '"IPS1"' packages/SyncCore.Windows/src/protocol/frame-codec.ts
  rg -F 'iphonesync-sas-v1' packages/SyncCore.Windows/src/crypto/pairing-crypto.ts
  rg -F 'iphonesync-psk-v1' packages/SyncCore.Windows/src/crypto/pairing-crypto.ts
  rg -F 'iphonesync-identity-v1' packages/SyncCore.Windows/src/crypto/pairing-crypto.ts
  rg -F 'iphonesync-client-proof-v1' packages/SyncCore.Windows/src/crypto/pairing-crypto.ts
  rg -F 'iphonesync-server-proof-v1' packages/SyncCore.Windows/src/crypto/pairing-crypto.ts
  rg -F 'receivingFolderName' apps/windows/src/renderer/setup.html
  rg -F '"iPhoneSync"' packages/SyncCore.Windows/src/receiver/destination-writer.ts
  rg -F '.partial' packages/SyncCore.Windows/src/receiver/destination-writer.ts
  rg -F '"_iphonesync._tcp"' packages/SyncCore.Windows/src/discovery/bonjour-advertise.ts
  rg -F '"_iphonesync-pair._tcp"' packages/SyncCore.Windows/src/discovery/bonjour-advertise.ts
  rg -F 'PSK-AES128-GCM-SHA256' packages/SyncCore.Windows/src/crypto/tls-psk-server.ts
  rg -F 'TLS_PSK_WITH_AES_128_GCM_SHA256' apps/windows/src/main/pairing-window.ts
  rg -F '120' packages/SyncCore.Windows/src/pairing/pairing-server.ts
  rg -F '15' packages/SyncCore.Windows/src/receiver/sync-server-session.ts  # opening timeout
  rg -F 'launchAtLoginRequested' apps/windows/src/main/auto-launch.ts
fi

# Windows-only packaging step (must be on Windows for NSIS)
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == CYGWIN* || "$(uname -s)" == MSYS* ]]; then
  (cd apps/windows && npm run dist)   # electron-builder --win nsis + portable
fi
```

> macOS 上 `node` 與 `npm` 應可用，所以 source-invariant + unit test 階段可在 Mac 開發機跑；NSIS packaging 必須在 Windows 上執行。

### 跨平台測試向量對齊（必跑）

Windows port 必須跑完以下測試向量且與 Swift 既有測試結果一致：

| 既有 Swift Test | 對應 Node/Vitest Test |
|---|---|
| `PairingCryptoTests.bothSidesDeriveSameCodePSKAndProofs` | `…bothSidesDeriveSameCodePSKAndProofs` |
| `PairingCryptoTests.transcriptTamperingChangesDerivedSecret` | `…transcriptTamperingChangesDerivedSecret` |
| `FrameCodecTests.controlFrameRoundTrips` | `…controlFrameRoundTrips` |
| `FrameCodecTests.malformedMagicIsRejected` | `…malformedMagicIsRejected` |
| `FrameCodecTests.unsupportedProtocolVersionIsRejected` | `…unsupportedProtocolVersionIsRejected` |
| `FrameCodecTests.oversizedControlPayloadIsRejected` | `…oversizedControlPayloadIsRejected` |
| `FrameCodecTests.oversizedChunkIsRejected` | `…oversizedChunkIsRejected` |
| `FrameCodecTests.truncatedFrameIsRejected` | `…truncatedFrameIsRejected` |
| `IdentityAndFilenameTests.resourceIdentityIsStableAndBindingScoped` | `…resourceIdentityIsStableAndBindingScoped` |
| `IdentityAndFilenameTests.filenamePolicyRejectsTraversal` | `…filenamePolicyRejectsTraversal` |
| `IdentityAndFilenameTests.filenamePolicyGroupsByUTCMonthAndKeepsRole` | `…filenamePolicyGroupsByUTCMonthAndKeepsRole` |
| `IdentityAndFilenameTests.fileHasherMatchesKnownSHA256` | `…fileHasherMatchesKnownSHA256` |
| `OperationLogTests.operationLogBufferKeepsNewestEntriesAndClears` | `…operationLogBufferKeepsNewestEntriesAndClears` |
| `PSKTransportTests.tlsPSKLoopbackTransfersAFrame` | `…tlsPskLoopbackTransfersAFrame` |
| `PSKTransportTests.wrongPSKFailsTLSHandshake` | `…wrongPskFailsTlsHandshake` |
| `PairingProtocolTests.pairingConfirmationWireMessageContainsProofButNoCode` | `…pairingConfirmationWireMessageContainsProofButNoCode` |
| `PairingProtocolTests.expiredPairingWindowClosesListener` | `…expiredPairingWindowClosesListener` |
| `ManifestStoreTests.manifestStartsResumesAndSkipsCommittedResource` | `…manifestStartsResumesAndSkipsCommittedResource` |
| `ManifestStoreTests.duplicateAlbumNamesReceiveStableDistinctFolderNames` | `…duplicateAlbumNamesReceiveStableDistinctFolderNames` |
| `ManifestStoreTests.manifestRejectsAnUnknownSourceBinding` | `…manifestRejectsAnUnknownSourceBinding` |
| `SyncRoundTripTests.validPSKHalfOpenSessionTimesOutBeforeAcceptance` | `…validPskHalfOpenSessionTimesOutBeforeAcceptance` |
| `SyncRoundTripTests.roundTripSecondSyncSkipsCommittedResource` | `…roundTripSecondSyncSkipsCommittedResource` |
| `SyncRoundTripTests.sameResourceInMultipleAlbumsCreatesCorrespondingFolders` | `…sameResourceInMultipleAlbumsCreatesCorrespondingFolders` |
| `SyncRoundTripTests.unavailableAlbumFolderRejectsSessionWithUsefulReceiverError` | `…unavailableAlbumFolderRejectsSessionWithUsefulReceiverError` |
| `SyncRoundTripTests.secondIntegrityFailureIsNotRetryable` | `…secondIntegrityFailureIsNotRetryable` |
| `DestinationWriterTests.restartTruncatesBytesBeyondDurableCheckpoint` | `…restartTruncatesBytesBeyondDurableCheckpoint` |
| `DestinationWriterTests.existingDifferentFileIsNeverOverwritten` | `…existingDifferentFileIsNeverOverwritten` |
| `DestinationWriterTests.existingSameHashFileIsAdopted` | `…existingSameHashFileIsAdopted` |
| `DestinationWriterTests.albumFolderUsesSourceNameAndSanitizesPathInjection` | `…albumFolderUsesSourceNameAndSanitizesPathInjection` |
| `DestinationWriterTests.receivingFolderIsCreatedBeforeAlbumFolder` | `…receivingFolderIsCreatedBeforeAlbumFolder` |
| `DestinationWriterTests.existingAlbumNameThatIsAFileIsRejected` | `…existingAlbumNameThatIsAFileIsRejected` |
| `DestinationWriterTests.receivingFolderNameThatIsAFileIsRejected` | `…receivingFolderNameThatIsAFileIsRejected` |
| `DestinationWriterTests.legacyRootPartialMovesIntoAlbumFolderAndResumes` | `…legacyRootPartialMovesIntoAlbumFolderAndResumes` |
| `DestinationWriterTests.previousAlbumPartialMovesIntoReceivingFolderAndResumes` | `…previousAlbumPartialMovesIntoReceivingFolderAndResumes` |
| `DestinationWriterTests.albumOnlyModeWritesFileDirectlyUnderAlbum` | `…albumOnlyModeWritesFileDirectlyUnderAlbum` |
| `DestinationWriterTests.flatModeWritesFileDirectlyUnderReceivingFolder` | `…flatModeWritesFileDirectlyUnderReceivingFolder` |

> 完整 51 個 Swift package tests（含 BonjourDiscovery、PairingCrypto、PairingProtocol、PSKTransport）+ 30 個 iOS unit tests + 30 個 MacReceiverKit tests（已拆為 ManifestStore / SyncRoundTrip / DestinationWriter）必須在 Node 端對等測試中**同樣通過**。

### 既有測試盲區（Windows port 應一併補齊）

從既有 Swift tests 觀察到的盲區，於 Windows port 實作時順手補對等測試（避免新平台繼承同樣缺口）：

- Listener retry 完整行為（in-process fake 注入 `powerMonitor` `suspend` / `resume` 與 `multicast-dns` `NetworkChanged`）
- Pairing window expiry + cancel race
- `pairingLoopbackRejectsLocalMismatchThenCreatesSameTrust` 第 5 次錯後關窗路徑
- 多 role 矩陣 `FilenamePolicy.relativePath(..., role: ...)`

> 此階段補的測試對應回到 Mac receiver 也應補上同樣 case，並於 `docs/memory/2026-07-25-windows-11-port.md` 紀錄雙側補齊進度。

## Implementation Phases

### Phase 1：建立 skeleton 與 verify 入口

- `apps/windows/` 與 `packages/SyncCore.Windows/` 目錄結構（見 Project Layout）
- `package.json` + `tsconfig.json` + `electron-builder.yml`
- `Program.cs`-like Electron `main.ts`：app.whenReady → bootstrap → tray icon skeleton（不接 listener）
- `scripts/verify_windows.sh` + `scripts/verify.sh` 擴充
- `README.md` 新增「Windows 11 receiver」章節並 reference 本文件

### Phase 2：SyncCore.Windows 對齊既有測試向量

移植 `FrameCodec`、`PairingCrypto`、`PairingProtocol`、`ResourceDescriptor`、`ResourceIdentity`、`FilenamePolicy`、`FileHasher`、`OperationLog`、`DestinationStorageMode` 為 TypeScript，對應 vitest 覆蓋既有 Swift test 的所有 case。

### Phase 3：Receiver 核心

- `BonjourBrowse`（`multicast-dns`）解析 `_iphonesync._tcp` 與 `_iphonesync-pair._tcp` TXT
- `BonjourAdvertise` 對 `TXT({ id, name, version: '1', pairing: '0' })` 廣告
- `TlsPskServer`：`tls.createServer({ ciphers: 'PSK-AES128-GCM-SHA256', pskCallback })` 監聽動態 port
- `PairingServer`：120s window、SAS 顯示 callback、單連線保護、5 次 attempt
- `ReceiverController`：listener lifecycle、retry、recovery

### Phase 4：Session 與 writer

- `SyncServerSession`：與 Swift 版同 state machine
- `ManifestStore`：better-sqlite3 + 同 schema
- `DestinationWriter`：partial → SHA-256 → atomic rename；含 NTFS reserved/case-insensitive 擴充

### Phase 5：Setup UI 與 tray

- `SetupWindow`（Electron `BrowserWindow` + `setup.html`）：三區段（Status / Last Sync / Operation Log）
- `PairingWindow`（`pairing.html`）：六位數 SAS + 兩分鐘倒數
- `TrayController`：`Tray` + `Menu` (Open Setup / Pair New iPhone / Choose Destination / Quit)
- `AutoLaunchService`：`app.setLoginItemSettings({ openAtLogin: ... })`
- `Recovery`：`powerMonitor.on('resume')` + `multicast-dns` 的 `NetworkChanged` → reconcile

### Phase 6：Operation Log 整合

- `OperationLogBuffer`（500 cap）
- 串流到 `%LOCALAPPDATA%\iPhoneSync\logs\operations-<date>.jsonl`
- Setup 面板顯示、Copy All（`clipboard.writeText`）、Clear

### Phase 7：Canonical docs 同步

| 檔案 | 動作 |
|---|---|
| `README.md` | 第 1 節新增「`iPhone Sync` 第二接收端：Windows 11」子節；第 3.2 節 Mac 端設定旁新增 3.2b Windows 11 端設定；第 4 節文件索引新增 `docs/specs/2026-07-25-windows-11-desktop-receiver.md` |
| `README.permission.md` | 新增 Windows 11 capability / Firewall / Launch at Login / DPAPI 對應表 |
| `README.todo` | 新增「Windows 11 receiver」章節（與既有 Automatic LAN Sync 平行） |
| `CLAUDE.md` | Approved Technical Choices 新增 Windows 11 列；Build and Verification 新增 `bash scripts/verify.sh` Windows 區段說明；Canonical Documentation 新增 Windows spec 連結 |
| `apps/windows/README.md`（新） | Windows 11 receiver flow、boundaries、tools |
| `docs/specs/2026-07-25-windows-11-desktop-receiver.md`（新） | 從本 plan file 精煉歸檔 |
| `docs/terminology.md` | 新增 Windows 11 端詞彙（`iPhoneSync container`、`NTFS reparse point` 等） |
| `docs/memory/2026-07-25-windows-11-port.md`（新） | port 完成後 retrospective |
| `scripts/verify_windows.sh`（新） | Windows verify 入口 |
| `packages/SyncCore/README.md` | 新增「Cross-platform Test Vectors」一節指向 Node 對等測試 |

### Phase 8：Backlog（首發後補）

- MSIX 封裝：透過 `electron-builder --win appx` + `electron-windows-store` 套件；需 SmartScreen 信任
- 公證 / Store 發佈
- 多 receiver family UI 顯示（若未來 bump protocolVersion 才需要）

## Verification（end-to-end）

1. 開發機：Windows 11 22H2+、`npm test`（SyncCore.Windows）全綠、`npm run build` 成功、`npm run dist` 產 NSIS installer。
2. 模擬器：以 `Windows Sandbox` 或 Hyper-V 開乾淨 Windows 11 安裝 receiver，驗證：
   - 啟動後 tray icon 出現於 system tray
   - `Choose Destination` 開啟 folder picker 並持久化
   - `Pair iPhone` 顯示六位數 SAS 與兩分鐘倒數
   - Auto-launch 勾選後重啟 Windows，receiver 自動啟動
3. 互通：iPhone（iOS 18+，已配對 Mac receiver）→ Mac 端 `Forget iPhone` → Windows 端 `Pair iPhone`，執行 `Sync Now`，驗證檔案落到 Windows destination，operation log 顯示 `Added / Already / Not local / Failed`。
4. Recovery：拔除 Wi-Fi、重新插上；或 `powerMonitor` suspend / resume；listener 自動 reconcile。
5. Storage mode：切換 `Album / Year / Month` 與 `Single Folder`，驗證既有 committed 檔案不動。
6. Auto-launch：勾選後重啟 Windows，receiver 自動啟動並恢復 destination / pairing / manifest。

## Risks & Open Questions

- Node `tls.createServer` 的 PSK cipher 在 Windows OpenSSL backend 上是否與 Apple `Network.framework` 完全互通：Phase 3 早期做最小互通測試（iPhone 連線 Windows receiver），必要時改 cipher suite 名稱（Node 可能用 `TLS_PSK_WITH_AES_128_GCM_SHA256` 而非 `PSK-AES128-GCM-SHA256` 別名）。
- `electron-builder` 對 Windows code signing 在 2026 是否仍免費或需要 EV certificate：先做 unsigned NSIS，後續簽署另議。
- `multicast-dns` 在 Windows 11 22H2 / 23H2 / 24H2 的 mDNSResponder 互動可能偶發查詢失敗，需 retry。
- `electron-store` v10 對 ESM-only 的限制：v9 或自寫 settings.json 較穩定。

## README.md reference（待離開 plan mode 後執行）

在 `README.md` 第 4 節「文件索引 (Documentation Index)」表格新增：

```markdown
| [`docs/specs/2026-07-25-windows-11-desktop-receiver.md`](docs/specs/2026-07-25-windows-11-desktop-receiver.md) | Windows 11 desktop receiver 設計與移植進度 |
```

並在 `README.md` 第 1 節「業務定義」新增「`iPhone Sync` 第二接收端：Windows 11」子節；第 3.2 節旁新增 3.2b Windows 11 端設定段落。
