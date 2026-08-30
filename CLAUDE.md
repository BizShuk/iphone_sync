# iPhone Sync — Technical Context

## Current Status

MVP、`automatic-lan-sync`、`delete-after-sync` 與兩端 `operation-log-panels` 已實作：包含原生 iOS sender、原生 macOS menu-bar receiver、多相簿選取與對應資料夾、manual / automatic single-flight runtime、best-effort `BGProcessingTask` scheduling、opt-in foreground-confirmed Photos deletion、Mac receiver recovery、iOS / Mac semantic operation timeline、typed persistent settings、`SyncCore`/`MacReceiverKit` Swift package、XcodeGen project、edge-case tests 與 `scripts/verify.sh`。Canonical gate 已通過 64 個 Swift package tests、50 個 iOS unit tests、49 個 Windows vitest、unsigned Mac / generic iOS Simulator / `Release` generic iOS device builds、兩個 TypeScript builds、generated plist / entitlement / local-only / deletion invariants 與 whitespace checks。Signed physical-device deletion、background launch、expiration、overnight timing 與完整 LAN failure matrix 仍以 [README.todo](README.todo) 為準。

## Automatic LAN Sync

使用者 opt in `Automatic Sync` 後，iOS 若實際啟動 scheduled handler，runtime 才重新載入 prerequisites、透過 Bonjour 尋找 exact paired `receiverID`，並以保存的 PSK authentication。Cadence 固定為 `earliestBeginDate = now + 30 分鐘` 加上 `requiresExternalPower = false`：不要求充電，電池供電時一樣可能被啟動，成功與失敗以相同 interval 重新武裝，沒有指定時間、沒有每日配額、也沒有獨立的 retry interval。只有這`一條` automatic lane：沒有第二個 cadence、沒有第二個 task identifier、也沒有前景測試迴圈。`earliestBeginDate` 不是準時或必定執行保證。單次 run 不設 application budget，window 長度由 iOS 決定，`BGProcessingTask` expiration handler 是唯一上限；被中止時取消 outer operation 與 active client，未傳完的部分由 receiver checkpoint 續傳。Background launch 撞上進行中的 run 時略過該次 launch 並立刻重排下一個 interval。App lifecycle reconcile 會查詢既有 pending request，保留相同或更早的 eligibility；eligibility 是 relative interval 而非 wall-clock appointment，已到期的值不因重進 App 被往後推。單次 window 內不得重複付出已完成工作的成本：`SyncedResourceLedger` 保存每個已被 receiver 確認的 resource descriptor，下一輪先用它 offer、由 Mac 決定是否需要 bytes，只有 receiver 真的要才 export 與 hash；`AlbumSyncCursorStore` 保存每個相簿的續傳位置，被 expiration 中止的 pass 從中斷處接續，走完整個相簿才清除 cursor。`Sync Now` 保留為 immediate fallback。`BGTaskSchedulerPermittedIdentifiers` 必須包含唯一的 automatic sync identifier，否則 iOS 會以 `BGTaskSchedulerErrorDomain` code `3` 拒絕並回滾使用者意圖。Current contract 見 [automatic LAN sync spec](docs/specs/2026-07-23-automatic-lan-sync.md)，落地脈絡見 [implementation plan](plans/2026-07-23-automatic-lan-sync.md)。

## Product Invariants

- iPhone sync 可由前景 `Sync Now` 手動觸發，或由使用者預先 opt in、再由 iOS best-effort 啟動 automatic run；background runtime 不得被描述為固定 cron。
- Automatic run 只有在 `iPhone Wi-Fi + exact paired receiverID Bonjour visible + TLS-PSK authentication` 同時成立時才傳輸；不得以 SSID、IP subnet 或 `requiresNetworkConnectivity` 取代此 gate。
- Automatic cadence 是固定的「每 30 分鐘嘗試一次」，不設 power gate（`requiresExternalPower = false`），且只有這一條 lane：不得由 App 讀取電池狀態，也不得重新引入充電條件、指定時間、每日配額、獨立 retry interval，或第二個 cadence / task identifier / 前景測試迴圈。
- Scheduled run 不得設定 application budget；window 長度由 iOS 決定，只有 expiration handler 是上限。已有 run 進行中時，新的 background launch 必須略過並重排，不得開第二條 connection。
- Scheduled run 用完 window 是預期結果，不是 handler 失敗：`budgetExhausted` 必須以 `setTaskCompleted(success: true)` 回報，否則 iOS 會逐步縮減本 app 的 background 額度。只有 `cancelled` 與真正的 internal failure 才回報失敗。
- 已被 receiver 確認過的 resource 必須先 offer 再決定是否 export：ledger 只保存 descriptor，`永遠不是` 完成狀態的 authoritative source，Mac manifest 才是。
- receiver 一旦 accept offer 就開始計 idle deadline，因此 offer 與第一個 chunk 之間`不得`插入 export 或 hash 這類長工作。本機檔案的 size / SHA-256 驗證一律在送出 offer `之前`完成；ledger offer 收到 `.transfer` 時丟掉該 entry 並以 retryable failure 結束，由下一輪正常 stage 重建，不得在 receiver 等待期間才去 export。
- ledger entry 以 destination `sourceBindingID` 為 key；`Forget` receiver 必須清空 ledger 與所有 album cursors。asset `modificationDate` 改變即失效。
- 同一時間只綁定一組使用者選取的來源相簿、一部 iPhone 與一部 Mac；來源相簿可多選。
- 使用者選擇的 Finder folder 是 destination root；若它是 symbolic link，選擇時先解析並保存實際 target folder。每個 album 的 resource 一律寫入 resolved root 的固定 `iPhoneSync` 容器下；`iPhoneSync` 容器、相簿資料夾與日期子資料夾若是 symbolic link，只要解析後是實際存在的資料夾就當一般資料夾使用（允許 target 位於 destination root 之外，實際寫入仍受 sandbox 授權限制），不解析為資料夾者拒絕。已存在的真實資料夾安全重用，同名的不同 album 以 `名稱 (2)`、`名稱 (3)` 穩定區分；檔案層級的 symlink 一律拒絕，維持絕不覆寫既有檔案。
- 同步只能新增，永不因來源變動刪除或覆寫 Mac 既有檔案。
- `Delete After Sync` 預設關閉；關閉時所有同步入口都不得 enqueue 或呼叫 Photos deletion，disable 與 forget receiver 會清除 pending deletion IDs。
- 刪除單位是整個 `PHAsset`。只有 asset 的每個本機 resource 在每個已選相簿 occurrence 都由 receiver 回覆 committed / already present，且完整 multi-album run 成功時才可成為 candidate；任何 not-local resource、failure、cancel 或 expiration 都必須保留 asset。
- Foreground run 可對 candidates 發出單一 PhotoKit change request；background run 只能保存 pending IDs，使用者回到 App 後以 `Delete N Synced Photos` 觸發 system confirmation。Receiver committed files 永不因來源刪除而改變。
- Background run 留下 pending deletion 時必須發出 local notification 告知`數量`；通知不得包含 asset identifier，也不得成為刪除的必要條件（授權被拒仍須照常排隊）。完成刪除、關閉 toggle 或 forget receiver 時撤回該通知。
- iOS operation timeline 必須落地保存並在啟動時還原。Background run 的 process 結束後事件不得消失，否則 automatic sync 與 pending deletion 皆無從稽核。timeline 仍受 500 筆上限，且不得寫入 PSK、pairing code、identity、source binding、content hash 或 asset identifier。
- iPhone 傳輸只能使用 Bonjour 可見的 Wi-Fi 區域網路；Mac listener 可位於同一 LAN 的 Wi-Fi 或 Ethernet。`includePeerToPeer` 固定為 `false`。
- PhotoKit resource request 固定使用 `isNetworkAccessAllowed = false`。
- Foreground run 進行中 iPhone 不得自動鎖定；scene 進入背景時必須先取得 background task assertion，讓 cancellation 真的關閉 TLS 連線後才結束執行。
- Receiver 對已開啟的 session 設有 idle deadline；停止送 frame 的 sender 必須被放棄，不得占住唯一的 active connection slot。續傳仍以 manifest checkpoint 為準。
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
├── .github/workflows/
│   └── release.yml              # macOS DMG/PKG + Windows NSIS/portable build → 同一個 GitHub Release
├── project.yml                  # XcodeGen canonical target/plist configuration
├── iPhoneSync.xcodeproj/        # committed generated project
├── apps/
│   ├── ios/
│   │   ├── Sources/             # PhotoKit、pairing、runtime、post-sync deletion、BG scheduler、persisted operation log、pending-deletion notification、sender UI
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
├── scripts/                     # verify.sh、verify-windows.sh、package-mac.sh、run-mac.sh、run-server.sh、run-simulator.sh、run-iphone.sh、release.sh
├── web/                         # 上手指南站的內容：index.html（自足單頁）+ nginx.conf
├── Dockerfile                   # 把 web/ 烤成 nginx image，部署在 liva（iphone-sync.shuks.dev）
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
| Session liveness | Receiver 15 秒 opening deadline + 45 秒 idle deadline；iOS foreground run 期間持有 idle-timer hold，背景化時以 background task assertion 完成關閉 |
| Automatic schedule | iOS `BGProcessingTask`; single lane, earliest `+30 minutes`, 不要求充電 (`requiresExternalPower = false`); pending request idempotent reconcile |
| Automatic runtime | `IOSSyncRuntime` single-flight + OS expiration（無 application budget）+ PhotoKit/discovery/active-client hard cancellation |
| Post-sync deletion | Default-off `Delete After Sync`; asset-level all-resource eligibility + persistent ID / `modificationDate` candidates + foreground `PHAssetChangeRequest.deleteAssets` confirmation + best-effort `UNUserNotificationCenter` pending prompt |
| Manifest | SwiftData in Mac App container |
| Destination | Resolved user-selected Finder root + fixed `iPhoneSync` folder + same-name album subfolder with security-scoped bookmark |
| Preferences | Typed `MacSettingsStore` backed by sandbox `UserDefaults` |
| Auto-start | `SMAppService.mainApp` with persistent requested intent |
| Operation diagnostics | Semantic events、latest 500 entries（iOS 跨啟動保存、macOS per process）、Apple Unified Logging |
| Desktop release packaging | 單一 `release.yml`：macOS universal (arm64 + x86_64) DMG + PKG via `scripts/package-mac.sh`（預設 ad-hoc，env 升級 Developer ID + notarization）；Windows NSIS + portable via electron-builder；同一 GitHub Release |

## Runtime Ownership

| State | Owner | Persistence |
|---|---|---|
| iPhone device ID、selected albums | iOS App | `UserDefaults` |
| Automatic enabled intent、last attempt/success/outcome、next eligible | `IOSAutomaticSyncStore` | iOS sandbox `UserDefaults` |
| Delete-after-sync enabled intent、pending asset ID / `modificationDate` snapshots | `IOSDeleteAfterSyncStore` | iOS sandbox `UserDefaults` |
| Active manual / automatic run ID | `IOSSyncRuntime` | transient only |
| Active PhotoKit deletion request | `IOSPostSyncDeletionController` | transient only |
| Paired peer PSK、opaque identity | 各 App | Keychain |
| Mac receiver ID、current source binding、launch intent | `MacSettingsStore` | sandbox `UserDefaults` |
| Destination capability | `DestinationBookmarkStore` + `MacSettingsStore` | security-scoped bookmark data in sandbox `UserDefaults` |
| Launch-at-login registration | `MacAppModel` | `SMAppService.mainApp` |
| Setup/status-item position | AppKit | `NSWindow` / `NSStatusItem` autosave |
| Source binding、album/folder mapping | `ManifestStore` | SwiftData `SourceRecord` + `AlbumRecord` |
| Album-scoped resource status、hash、size、checkpoint、final path | `ManifestStore` | SwiftData `TransferRecord` |
| Partial media bytes | `DestinationWriter` | destination `iPhoneSync/<safe-album-name>/<year>/<month>/<name>.partial` |
| 已由 receiver 確認的 resource descriptor | `SyncedResourceLedger` | App container 內的 append-only JSONL（compaction、`completeUntilFirstUserAuthentication`） |
| 每個相簿的續傳位置 | `AlbumSyncCursorStore` | App container 內的小型 JSON（批次寫入，pass 走完即清除） |
| iOS operation timeline | `PersistentOperationLogStore` + `IOSAppModel` | App container 內的 bounded JSONL log（最新 500 筆，跨啟動還原）+ Apple Unified Logging |
| macOS operation timeline | `MacAppModel` | bounded in-memory list（最新 500 筆）+ Apple Unified Logging |

Mac bootstrap 先依 `launchAtLoginRequested` reconcile `SMAppService`，再讀取 Keychain paired peer、解析 security-scoped destination bookmark、開啟 SwiftData store，最後在必要狀態齊全時自動啟動 receiver。Normal listener failure 使用 capped exponential backoff；Mac wake、network path recovery 與 pairing 關閉後會 reconcile listener，incoming connection 另有 opening deadline。既有 `receiverID`、`sourceBindingID` 與 `destinationBookmark` keys 保持不變，加入 typed store 不需要 migration。Pairing code、active session、last summary、Mac UI operation timeline 與 automatic active run ID 是 transient state，不得放入 durable preferences；iOS operation timeline 有自己的 on-disk log，同樣不進 preferences。

同一 `sourceBindingID` 代表一部 iPhone 對一個 destination 的來源集合，可登錄多個 album ID；不同 binding 仍必須拒絕。`AlbumRecord` 保存每個 album 的穩定 destination folder，`TransferRecord` 以 album scope 區分同一 PhotoKit resource 出現在多個相簿的完成狀態。使用者在 Mac 明確執行 `Reset Source` 或更換 destination 時才產生新的 binding；既有 committed Finder files 不刪除。

`SyncServerSession` 通過 source/album binding 後，才由 `DestinationWriter.prepareAlbumDirectory(named:)` 建立或重用固定 `iPhoneSync` 容器及相簿子資料夾。一般相簿名稱原樣保留；斜線、反斜線、控制字元與隱藏 path injection 由 `AlbumFolderPolicy` 轉為安全的單一 path component。Manifest 的 `finalRelativePath` 以使用者選擇的 destination root 為基準，格式為 `iPhoneSync/<album-folder>/<resource-path>`。舊版 committed path 保留原位；舊版未完成的 per-album partial 可安全搬入新容器續傳。Session 透過 optional event callback 回報 open / accept / complete 與 resource offer / receive / resume / skip / commit / fail；不逐 chunk 產生 UI event。

`PhotoLibrarySource` 在每個 asset 的 resource stream 結尾回報 asset-level completeness 與 `modificationDate`；`PhotoDeletionCandidateAccumulator` 對同一 asset 在多個 selected albums 的結果做 AND merge，版本在 run 中改變即失去資格。`IOSPostSyncDeletionController` 只在整個 run 成功後讀取 default-off intent：foreground 以單一 `performChanges` batch 請求刪除，system-launched background run 則將 ID / modification snapshot 保存為 pending。刪除前重新 fetch 並比對 `modificationDate`，同步後又被編輯的 asset 必須保留。關閉功能或忘記 receiver 會清 pending 並撤回提示通知；background enqueue 另發一則只含數量的 local notification，授權被拒時流程不變。operation log 只記數量，不記 asset local identifiers，並由 `PersistentOperationLogStore` 落地保存，讓背景 run 的事件在 process 結束後仍可回查。Current contract 見 [Delete After Sync spec](docs/specs/2026-07-27-delete-after-sync.md)。

## Build and Verification

`project.yml` 是 Xcode project、兩個 Info.plist 與 entitlements 的 canonical source。不要直接修改產生後的 `apps/*/Info.plist` 或 `*.entitlements`；修改 `project.yml` 後執行：

```bash
xcodegen generate
```

統一任務入口（`npm run` 可探索）：

```bash
npm run dev:ios          # iOS Simulator 建置、安裝、啟動
npm run dev:mac          # macOS receiver（Debug，從 build 目錄啟動）
npm run dev:windows      # Windows receiver
npm run deploy:ios       # 實機 archive、安裝、啟動
npm run deploy:mac       # 本機安裝：Release build → /Applications → 啟動
npm run build:mac        # 本機 macOS 散佈：universal DMG + PKG
npm run release:ios      # App Store：archive → export .ipa → upload
npm run release:site     # 產品頁上架 bizshuk.github.io
```

頂層 `dev` / `test` / `build` / `deploy` / `release` / `lint` / `clean` / `destroy`
一律平行 fan out 同名第二層；日常只改一端時直接叫具體元件（`dev:ios`），
腳本與 CI 也一律引用具體元件，不引用聚合名稱。
`dev:mac` 與 `deploy:mac` 的差別是產物落點：前者跑 `build/` 裡的 Debug build，
用於改一行看一次；後者把 Release build 裝進 `/Applications`，是實際長期使用的那一份。
`deploy:*` 是裝到實機／`/Applications`，`release:*` 才是對外通路；本機 macOS 打包是
`build:mac`。`release:ios` 的前置條件
（App Store Connect app record 與 distribution 憑證）`尚未齊備`，未設定
`DEVELOPMENT_TEAM` / `ASC_KEY_ID` / `ASC_ISSUER_ID` 時會在 archive 前失敗。

完整非破壞性驗證：

```bash
bash scripts/verify.sh           # macOS + iOS + Windows 端 SyncCore.Windows tests + invariants
```

個別 package 驗證：

```bash
swift test --package-path packages/SyncCore
bash scripts/verify-windows.sh   # SyncCore.Windows 49 vitest + 兩 build + source invariants
```

Windows 11 開發機：

```bash
(cd packages/SyncCore.Windows && npm ci && npm run build)
(cd apps/windows && npm ci && npm run build && npm run dist)
```

macOS 打包（本機與 CI 共用同一腳本）：

```bash
bash scripts/package-mac.sh      # universal Release build → build/mac-dist/iPhoneSync-Mac-<version>.{dmg,pkg}
bash scripts/run-mac.sh          # Release build → /Applications/iPhone Sync.app → 啟動（不產生 DMG/PKG）
```

預設 ad-hoc 簽章；設定 `MAC_SIGN_IDENTITY`（Developer ID Application）加上 `MAC_NOTARY_PROFILE` 或 `MAC_NOTARY_APPLE_ID`/`MAC_NOTARY_TEAM_ID`/`MAC_NOTARY_PASSWORD` 後，同一腳本升級為 Developer ID 簽章 + notarization + stapling；`MAC_INSTALLER_IDENTITY` 另外簽 PKG。

GitHub Actions 自動 release：
- `.github/workflows/release.yml` 同一次 run：`macos-latest` 跑 SyncCore package tests + `scripts/package-mac.sh`（DMG + PKG）、`windows-latest` 跑 vitest + `npm run dist`（NSIS + portable），最後由單一 `publish` job 把 `.dmg` / `.pkg` / `.exe` 掛上同一個 GitHub Release（`v*` tag = public、workflow_dispatch = draft）。
- `v*` tag 版本會 stamp 進 macOS `MARKETING_VERSION`/`CFBundleVersion` 與 Windows `package.json`，兩端 artifact 檔名一致對應 tag。

驗證腳本使用 `CODE_SIGNING_ALLOWED=NO` 建置 `iPhoneSyncMac`、generic iOS Simulator 與 `Release` generic iOS device；Release build 必須編譯 production cadence 分支。腳本也檢查 `BGTaskSchedulerPermittedIdentifiers`、`UIBackgroundModes = processing`、PhotoKit deletion usage string、default-off guard、hard-cancellation、Mac recovery 與兩端 Operation Log source invariants。這些 checks 證明 source contract 與 platform compilation，不是 Photos system confirmation、listener recovery、OS launch/expiration 或 signed network behavior tests。

## Security Notes

- Temporary pairing service 為 `_iphonesync-pair._tcp`，配對視窗為 120 秒且一次只接受一條連線。
- Normal sync service 為 `_iphonesync._tcp`；只有 TLS handshake 完成後才解析 sync frame。
- TLS minimum/maximum 固定 1.2，cipher suite 固定 `TLS_PSK_WITH_AES_128_GCM_SHA256`。Apple public static-PSK API 在目前支援 runtime 強制 TLS 1.3 時無法完成 handshake，因此不可把此實作描述為 TLS 1.3。
- Control frame 上限 64 KiB，chunk 上限 1 MiB，durable checkpoint 為 16 MiB。
- 已開啟的 session 若 45 秒沒有新 frame（iPhone 鎖定、App 被 suspend、LAN 中斷），receiver 主動關閉連線並釋出 session slot。
- Receiver 先驗證 frame、offset、expected size 與 SHA-256，完成後才以不覆寫方式 atomic commit。
- `Delete After Sync` 不改變 receiver；iPhone 只在全部 local resources 已由 authoritative manifest confirmed 後請求 Photos library deletion。若使用 iCloud Photos，使用者確認文案必須提示 deletion 可能同步到其他裝置。

## Canonical Documentation

- 業務定義與 domain flow：[README.md](README.md)
- 權限與能力盤點：[README.permission.md](README.permission.md)
- 歷史 MVP 設計：[docs/specs/2026-07-19-local-album-sync-design.md](docs/specs/2026-07-19-local-album-sync-design.md)
- Current automatic sync 規格：[docs/specs/2026-07-23-automatic-lan-sync.md](docs/specs/2026-07-23-automatic-lan-sync.md)
- Delete After Sync 規格：[docs/specs/2026-07-27-delete-after-sync.md](docs/specs/2026-07-27-delete-after-sync.md)
- 實作計畫：[plans/2026-07-19-local-album-sync.md](plans/2026-07-19-local-album-sync.md)
- Automatic LAN Sync 實作計畫：[plans/2026-07-23-automatic-lan-sync.md](plans/2026-07-23-automatic-lan-sync.md)
- Operation Log Panels 架構計畫：[plans/2026-07-23-operation-log-panels.md](plans/2026-07-23-operation-log-panels.md)
- 待辦：[README.todo](README.todo)
- 對外上手指南站：[web/index.html](web/index.html)，image 由本 repo 根目錄的 `Dockerfile` 建，服務定義在 `platform/inf/hosts/liva/docker-compose.yml`
- Background sync 續傳與 ledger：[docs/memory/2026-08-28-background-sync-resume.md](docs/memory/2026-08-28-background-sync-resume.md)
- 歷史操作與決策：[docs/memory/README.md](docs/memory/README.md)

結構、business scope 或技術決策變更時，必須同步上述 canonical files。
