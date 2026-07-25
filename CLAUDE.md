# iPhone Sync — Technical Context

## Current Status

MVP、`automatic-lan-sync` 與兩端 `operation-log-panels` 已實作：包含原生 iOS sender、原生 macOS menu-bar receiver、多相簿選取與對應資料夾、manual / automatic single-flight runtime、best-effort `BGProcessingTask` scheduling、Mac receiver recovery、iOS / Mac semantic operation timeline、typed persistent settings、`SyncCore`/`MacReceiverKit` Swift package、XcodeGen project、edge-case tests 與 `scripts/verify.sh`。Canonical gate 已通過 51 個 Swift package tests、30 個 iOS unit tests、unsigned Mac / generic iOS Simulator / `Release` generic iOS device builds、generated plist / entitlement / local-only invariants 與 whitespace checks。Signed physical-device background launch、expiration、overnight timing 與完整 LAN failure matrix 仍以 [README.todo](README.todo) 為準。

## Automatic LAN Sync

使用者 opt in `Automatic Sync` 後，iOS 若實際啟動 scheduled handler，runtime 才重新載入 prerequisites、透過 Bonjour 尋找 exact paired `receiverID`，並以保存的 PSK authentication。Release request 最早為使用者設定的每日本地時間（預設 local midnight）；Debug 額外暴露獨立的 10 分鐘測試 scheduler，僅在 `#if DEBUG` 建置下註冊與 reconcile。兩者均為 `earliestBeginDate`，不是準時或必定執行保證。App lifecycle reconcile 會查詢既有 pending request，保留相同或更早的 eligibility；Release restore 重新計算 desired eligibility 時一律使用下一個使用者設定的本地時間，不因本日尚未成功而改用 now；Debug 保存的 eligibility 已到期時不會因重進 App 再延後 10 分鐘，foreground test 會立即嘗試。`Sync Now` 保留為 immediate fallback。`BGTaskSchedulerPermittedIdentifiers` 同時包含 production 與 debug identifier，防止 iOS 以 `BGTaskSchedulerErrorDomain` code `3` 拒絕尚未宣告的 identifier 並回滾使用者意圖。Current contract 見 [automatic LAN sync spec](docs/specs/2026-07-23-automatic-lan-sync.md)，落地脈絡見 [implementation plan](plans/2026-07-23-automatic-lan-sync.md)。

## Product Invariants

- iPhone sync 可由前景 `Sync Now` 手動觸發，或由使用者預先 opt in、再由 iOS best-effort 啟動 automatic run；background runtime 不得被描述為固定 cron。
- Automatic run 只有在 `iPhone Wi-Fi + exact paired receiverID Bonjour visible + TLS-PSK authentication` 同時成立時才傳輸；不得以 SSID、IP subnet 或 `requiresNetworkConnectivity` 取代此 gate。
- 同一時間只綁定一組使用者選取的來源相簿、一部 iPhone 與一部 Mac；來源相簿可多選。
- 使用者選擇的 Finder folder 是 destination root；每個 album 的 resource 一律寫入固定 `iPhoneSync` 容器下的對應安全子資料夾。已存在的真實資料夾安全重用，同名的不同 album 以 `名稱 (2)`、`名稱 (3)` 穩定區分。
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
├── .agents/skills/
│   └── iphone-mac-permission/ # permission audit and synchronization workflow
│       ├── SKILL.md
│       └── references/permissions.md
├── project.yml                  # XcodeGen canonical target/plist configuration
├── iPhoneSync.xcodeproj/        # committed generated project
├── apps/
│   ├── ios/
│   │   ├── Sources/             # PhotoKit、pairing、runtime、BG scheduler、operation panel、sender UI
│   │   ├── Sources/Intents/     # AppShortcutsProvider for the 1x1 Sync Now shortcut
│   │   ├── Shared/              # SyncNowIntent + Darwin bridge shared with the extension
│   │   ├── ControlCenter/       # iPhoneSyncControlCenter control widget extension
│   │   ├── Tests/               # automatic schedule policy、persistent state、runtime tests
│   │   ├── Info.plist           # generated from project.yml
│   │   └── iPhoneSync.entitlements
│   ├── macos/
│   │   ├── Sources/             # NSStatusItem receiver、pairing、Finder writes、operation panel
│   │   ├── Info.plist           # generated from project.yml
│   │   └── iPhoneSyncMac.entitlements
│   └── windows/                 # Windows 11 receiver (Electron + Node.js)
│       ├── src/main/            # main.ts, model-root.ts, tray.ts, setup-window.ts, pairing-window.ts, auto-launch.ts, recovery.ts, ipc.ts
│       ├── src/preload/         # preload.ts (contextBridge)
│       ├── src/renderer/        # setup.html, pairing.html, app.css, setup.ts, pairing.ts
│       ├── assets/icons/        # tray.ico
│       ├── package.json
│       ├── tsconfig.json
│       └── electron-builder.yml
├── packages/
│   ├── SyncCore/
│   │   ├── Sources/SyncCore/    # contracts、crypto、framing、Bonjour、TLS、client、operation buffer
│   │   ├── Sources/MacReceiverKit/ # SwiftData manifest、safe writer、server + operation events
│   │   └── Tests/
│   └── SyncCore.Windows/        # TypeScript port of SyncCore + MacReceiverKit
│       ├── src/protocol/        # constants, frame-codec, framed-connection, messages, resource, filename-policy
│       ├── src/crypto/          # pairing-crypto, file-hasher, tls-psk-server
│       ├── src/discovery/       # bonjour-browse, bonjour-advertise
│       ├── src/pairing/         # pairing-server, pairing-protocol
│       ├── src/receiver/        # sync-server-session, manifest-store, destination-writer, album-folder-policy, receiver-controller, destination-storage-mode
│       ├── src/persistence/     # settings-store, destination-store, secret-store
│       ├── src/logging/         # operation-log, operation-logger
│       └── tests/               # vitest specs covering all Swift tests
├── docs/
│   ├── memory/
│   └── specs/
├── plans/
├── scripts/verify.sh
├── README.md
├── README.permission.md         # iOS/macOS permissions and purpose
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
| Platforms | iOS 18+、macOS 14+、Windows 11 22H2+（Swift 6 for Apple、Node.js 22 LTS + TypeScript 5 + Electron 32 for Windows） |
| Discovery | Bonjour `_iphonesync._tcp`（macOS `NWBrowser`、Windows `multicast-dns`） |
| Transport | Network.framework TCP + TLS 1.2 PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`) on Apple; Node `tls.createServer` PSK on Windows |
| Pairing | Temporary TCP + ephemeral Curve25519 + six-digit SAS |
| Source | PhotoKit `PHAssetResourceManager.requestData` with network access disabled and cancellable staging |
| Framing | Fixed binary header、JSON control payload、raw chunk payload |
| Chunk size | 1 MiB |
| Integrity | SHA-256 |
| Resume checkpoint | 16 MiB durable checkpoint |
| Automatic schedule | iOS `BGProcessingTask`; Release earliest 由使用者設定的每日本地時間（預設 local midnight），Debug earliest `+10 minutes` 並由獨立 identifier 註冊；pending request idempotent reconcile |
| Automatic runtime | `IOSSyncRuntime` single-flight + 8-minute application budget + PhotoKit/discovery/active-client hard cancellation |
| Manifest | SwiftData in Mac App container |
| Destination | User-selected Finder root + fixed `iPhoneSync` folder + same-name album subfolder with security-scoped bookmark |
| Preferences | Typed `MacSettingsStore` backed by sandbox `UserDefaults` |
| Auto-start | `SMAppService.mainApp` with persistent requested intent |
| Operation diagnostics | Semantic events、latest 500 entries per App process、Apple Unified Logging |

## Runtime Ownership

| State | Owner | Persistence |
|---|---|---|
| iPhone device ID、selected albums | iOS App | `UserDefaults` |
| Automatic enabled intent、last attempt/success/outcome、next eligible | `IOSAutomaticSyncStore` | iOS sandbox `UserDefaults` |
| Active manual / automatic run ID | `IOSSyncRuntime` | transient only |
| Paired peer PSK、opaque identity | 各 App | Keychain |
| Mac receiver ID、current source binding、launch intent | `MacSettingsStore` | sandbox `UserDefaults` |
| Destination capability | `DestinationBookmarkStore` + `MacSettingsStore` | security-scoped bookmark data in sandbox `UserDefaults` |
| Launch-at-login registration | `MacAppModel` | `SMAppService.mainApp` |
| Setup/status-item position | AppKit | `NSWindow` / `NSStatusItem` autosave |
| Source binding、album/folder mapping | `ManifestStore` | SwiftData `SourceRecord` + `AlbumRecord` |
| Album-scoped resource status、hash、size、checkpoint、final path | `ManifestStore` | SwiftData `TransferRecord` |
| Partial media bytes | `DestinationWriter` | destination `iPhoneSync/<safe-album-name>/<year>/<month>/<name>.partial` |
| iOS / macOS operation timeline | 各 App model | bounded in-memory list（最新 500 筆）+ Apple Unified Logging |

Mac bootstrap 先依 `launchAtLoginRequested` reconcile `SMAppService`，再讀取 Keychain paired peer、解析 security-scoped destination bookmark、開啟 SwiftData store，最後在必要狀態齊全時自動啟動 receiver。Normal listener failure 使用 capped exponential backoff；Mac wake、network path recovery 與 pairing 關閉後會 reconcile listener，incoming connection 另有 opening deadline。既有 `receiverID`、`sourceBindingID` 與 `destinationBookmark` keys 保持不變，加入 typed store 不需要 migration。Pairing code、active session、last summary、兩端 UI operation timeline 與 automatic active run ID 是 transient state，不得放入 durable preferences。

同一 `sourceBindingID` 代表一部 iPhone 對一個 destination 的來源集合，可登錄多個 album ID；不同 binding 仍必須拒絕。`AlbumRecord` 保存每個 album 的穩定 destination folder，`TransferRecord` 以 album scope 區分同一 PhotoKit resource 出現在多個相簿的完成狀態。使用者在 Mac 明確執行 `Reset Source` 或更換 destination 時才產生新的 binding；既有 committed Finder files 不刪除。

`SyncServerSession` 通過 source/album binding 後，才由 `DestinationWriter.prepareAlbumDirectory(named:)` 建立或重用固定 `iPhoneSync` 容器及相簿子資料夾。一般相簿名稱原樣保留；斜線、反斜線、控制字元與隱藏 path injection 由 `AlbumFolderPolicy` 轉為安全的單一 path component。Manifest 的 `finalRelativePath` 以使用者選擇的 destination root 為基準，格式為 `iPhoneSync/<album-folder>/<resource-path>`。舊版 committed path 保留原位；舊版未完成的 per-album partial 可安全搬入新容器續傳。Session 透過 optional event callback 回報 open / accept / complete 與 resource offer / receive / resume / skip / commit / fail；不逐 chunk 產生 UI event。

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

驗證腳本使用 `CODE_SIGNING_ALLOWED=NO` 建置 `iPhoneSyncMac`、generic iOS Simulator 與 `Release` generic iOS device；Release build 必須編譯 production cadence 分支。腳本也檢查 `BGTaskSchedulerPermittedIdentifiers`、`UIBackgroundModes = processing`、hard-cancellation、Mac recovery 與兩端 Operation Log source invariants。這些 Mac/BG checks 證明 source contract 與 platform compilation，不是 listener recovery、OS launch/expiration 或 signed network behavior tests。

## Security Notes

- Temporary pairing service 為 `_iphonesync-pair._tcp`，配對視窗為 120 秒且一次只接受一條連線。
- Normal sync service 為 `_iphonesync._tcp`；只有 TLS handshake 完成後才解析 sync frame。
- TLS minimum/maximum 固定 1.2，cipher suite 固定 `TLS_PSK_WITH_AES_128_GCM_SHA256`。Apple public static-PSK API 在目前支援 runtime 強制 TLS 1.3 時無法完成 handshake，因此不可把此實作描述為 TLS 1.3。
- Control frame 上限 64 KiB，chunk 上限 1 MiB，durable checkpoint 為 16 MiB。
- Receiver 先驗證 frame、offset、expected size 與 SHA-256，完成後才以不覆寫方式 atomic commit。

## Canonical Documentation

- 業務定義與 domain flow：[README.md](README.md)
- 權限與能力盤點：[README.permission.md](README.permission.md)
- 歷史 MVP 設計：[docs/specs/2026-07-19-local-album-sync-design.md](docs/specs/2026-07-19-local-album-sync-design.md)
- Current automatic sync 規格：[docs/specs/2026-07-23-automatic-lan-sync.md](docs/specs/2026-07-23-automatic-lan-sync.md)
- 實作計畫：[plans/2026-07-19-local-album-sync.md](plans/2026-07-19-local-album-sync.md)
- Automatic LAN Sync 實作計畫：[plans/2026-07-23-automatic-lan-sync.md](plans/2026-07-23-automatic-lan-sync.md)
- Operation Log Panels 架構計畫：[plans/2026-07-23-operation-log-panels.md](plans/2026-07-23-operation-log-panels.md)
- 待辦：[README.todo](README.todo)
- 歷史操作與決策：[docs/memory/README.md](docs/memory/README.md)

結構、business scope 或技術決策變更時，必須同步上述 canonical files。
