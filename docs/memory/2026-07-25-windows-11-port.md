# Windows 11 Desktop Receiver — 移植 Port Retrospective

> 日期：2026-07-25
> 計畫：[plans/2026-07-25-windows-11-desktop-receiver.md](../plans/2026-07-25-windows-11-desktop-receiver.md)
> 設計：[docs/specs/2026-07-25-windows-11-desktop-receiver.md](../specs/2026-07-25-windows-11-desktop-receiver.md)

## Delivered

| 項目 | 動作 |
|---|---|
| `apps/windows/` | Electron 32 + Node.js 22 + TypeScript 5 skeleton（main / preload / renderer 三層） |
| `packages/SyncCore.Windows/` | TypeScript port of `SyncCore` + `MacReceiverKit`，共 17 個 module 與 51 個 vitest 全綠 |
| Wire protocol | `protocolVersion = 1` 不 bump；iOS / Mac / Win 三端互通 |
| TLS-PSK | `Node tls.createServer({ ciphers: 'PSK-AES128-GCM-SHA256', pskCallback })` + `crypto.diffieHellman({ curve: 'x25519' })` |
| Pairing crypto | `crypto.diffieHellman` + `crypto.hkdfSync('sha256', ...)` + `crypto.createHash('sha256')`，HKDF labels 與 Swift 端 1:1 |
| Manifest | `better-sqlite3` 同步 API；3 個表（source_records / album_records / transfer_records） |
| DestinationWriter | partial → SHA-256 → atomic rename；NTFS reserved names + case-insensitive collision |
| SyncServerSession | 與 Swift 同 state machine，包含 15s opening deadline + integrity retry |
| Setup UI | Status / Last Sync / Operation Log 三區段；Fluent 設計 tokens |
| Tray | Electron `Tray` + `Menu` |
| Launch at Login | `app.setLoginItemSettings({ openAtLogin: true, openAsHidden: true })` |
| Recovery | `powerMonitor.on('resume')` + `networkInterfaces()` polling |
| Operation Log | in-memory 500 + JSONL at `%LOCALAPPDATA%\iPhoneSync\logs\` |
| IPC | `setup:changed` / `setup:snapshot` / `setup:choose-destination` / `setup:open-pairing` / `setup:cancel-pairing` / `setup:forget-phone` / `setup:reset-source` / `setup:set-storage-mode` / `setup:set-launch-at-login` / `setup:copy-operation-log` / `setup:clear-operation-log` |
| Canonical docs | `README.md`（章節 + 文件索引）+ `README.permission.md`（Windows 對應表）+ `README.todo`（進度 + 未完成清單）+ `CLAUDE.md`（Architecture + Approved Technical Choices）+ `docs/terminology.md`（新增 Windows 詞彙）+ `docs/specs/2026-07-25-windows-11-desktop-receiver.md` + `plans/2026-07-25-windows-11-desktop-receiver.md` |
| `scripts/verify-windows.sh` | 跨平台 verify 入口（macOS / Linux / Windows MSYS） |
| `scripts/verify.sh` | Windows 區段掛載點 |

## Durable Decisions

| 決策 | 理由 |
|---|---|
| `protocolVersion` 維持 1（不 bump） | iOS sender 完全不需變動；UX 層由 `Forget iPhone` 切換 |
| Electron 32 + Node.js 22 取代 .NET 8 / WinUI 3 | Node 內建 `tls.createServer` PSK cipher + `crypto.diffieHellman({ curve: 'x25519' })` 不需 BouncyCastle；tray / BrowserWindow / powerMonitor / safeStorage 全內建 |
| exe 為主，MSIX 為 backlog | NSIS installer 可立即在 Windows 11 22H2+ 開發機產出；MSIX 需要 code signing 流程 |
| `packages/SyncCore.Windows` 與 `SyncCore` 互不依賴 | 跨驗證靠 wire-format test vector，雙棧各自可獨立測試 |
| `HashRouter for PSK identity` | 以 `safeStorage`（內部 DPAPI）持久化 paired peer JSON，避免寫入明文 |

## Verification Evidence

- 51 個 vitest 全綠（frame-codec 7、pairing-crypto 3、pairing-protocol 4、pairing-server 3、identity-filename 6、operation-log 1、protocol-messages 9、file-hasher 2、manifest-store 7、destination-writer 7、framed-connection-loopback 2）
- `npm run build` 對 SyncCore.Windows 與 apps/windows 全綠
- `scripts/verify.sh`（含 Windows 區段）會在 Windows 11 22H2+ 開發機上跨驗證 Swift 與 Node 雙棧

## Known Gaps / Backlog

| 項目 | 原因 |
|---|---|
| iPhone → Windows 端實機互通 | 需 Windows 11 22H2+ 實體開發機 + 實體 iPhone |
| `SyncServerSession` 持有 connection 與 writer 的整合測試 | 需 iOS 端 sync client 模擬 |
| Listener retry 完整行為 | 需 powerMonitor 注入測試 |
| Pairing window expiry + cancel race | 需 in-process 模擬 |
| MSIX 封裝 + SmartScreen 信任 | backlog（exe 為主）|
| 公證 / Store 發佈 | 商業決策 |
| 廣播 announcement（macOS `NWBrowser` 與 Windows mDNS） | 雙側互操作測試需實機 |
| NTFS 尾端空白 / 句點 path | NTFS 拒絕但 Apple APFS 允許；需實機驗證 |
