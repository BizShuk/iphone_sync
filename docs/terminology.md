# 術語表 (Terminology)

## iPhone Sync 跨平台 (iPhone Sync Cross-platform)

| 術語 (Term) | 英文 (English) | 定義 (Definition) | 出處 (Source) |
| --- | --- | --- | --- |
| 通訊協定版本 | `protocolVersion` | 寫進 frame header 與 TXT `version` 的 `UInt16`，等於 `SyncConstants.protocolVersion` | `packages/SyncCore/Sources/SyncCore/SyncConstants.swift:4`、`packages/SyncCore.Windows/src/protocol/constants.ts` |
| Frame magic | `IPS1` | 40-byte header 前 4 bytes (`0x49 0x50 0x53 0x31`)；wire-format 偵錯標記 | `packages/SyncCore/Sources/SyncCore/FrameCodec.swift:79` |
| iPhoneSync 容器 | `iPhoneSync` | destination root 下的固定 receiving folder；任何 receiver 都必須用此名稱 | `packages/SyncCore/Sources/SyncCore/SyncConstants.swift:10` |
| Partial 檔 | `.partial` | receiver 端接收時的暫存檔附檔名；`MoveFileEx` / `rename` 原子提交到 final 檔名 | `packages/SyncCore/Sources/SyncCore/SyncConstants.swift` |
| 配對視窗 | `pairing window` | 120 秒配對 server 開窗時間；單連線保護 + 5 次 SAS 嘗試 | `packages/SyncCore/Sources/SyncCore/PairingServer.swift:24` |
| SAS | `Short Authentication String` | 6 位數字驗證碼，由 HKDF `iphonesync-sas-v1` 標籤派生 | `packages/SyncCore/Sources/SyncCore/PairingCrypto.swift:122-129` |
| HKDF labels | `hkdfLabels` | SAS / PSK / identity / client-proof / server-proof 五個標籤，帶 `-v1` suffix 預留升級 | `packages/SyncCore.Windows/src/protocol/constants.ts` |
| TLS PSK cipher | `TLS_PSK_WITH_AES_128_GCM_SHA256` | Node 端 OpenSSL 別名 `PSK-AES128-GCM-SHA256`；RFC 5487/5489 | `packages/SyncCore.Windows/src/protocol/constants.ts` |
| 續傳決策 | `TransferDecision` | `skip` / `start(offset)` / `resume(offset)` | `packages/SyncCore/Sources/SyncCore/SyncMessage.swift:10-14` |
| 第一個 integrity mismatch | `integrityFailureLimitExceeded` | 第一次 mismatch `retryable=true`；第二次 terminate session | `packages/SyncCore/Sources/MacReceiverKit/SyncServerSession.swift` |

## Windows 11 端 (Windows 11 Receiver)

| 術語 | 英文 | 定義 | 出處 |
| --- | --- | --- | --- |
| 桌面應用 | `desktop app` | Electron 32 + Node.js 22 + TypeScript 5 | `docs/specs/2026-07-25-windows-11-desktop-receiver.md` |
| User Data 目錄 | `userData` | `%LOCALAPPDATA%\iPhoneSync\`；`app.getPath('userData')` 取得 | `apps/windows/src/main/model-root.ts` |
| SafeStorage | `safeStorage` | Electron 內部走 Windows DPAPI；`encryptString` / `decryptString` | `packages/SyncCore.Windows/src/persistence/secret-store.ts` |
| Logs 目錄 | `logsDir` | `%LOCALAPPDATA%\iPhoneSync\logs\` 下的 `operations-YYYY-MM-DD.jsonl` | `packages/SyncCore.Windows/src/logging/operation-logger.ts` |
| WinUI 介面 | `UI` | Electron `BrowserWindow` + HTML/CSS；Fluent 風格 CSS 變數 | `apps/windows/src/renderer/app.css` |
| 配對視窗 | `PairingWindow` | Electron `BrowserWindow`（360×240, fixed）顯示 6 位數 SAS 與倒數 | `apps/windows/src/main/pairing-window.ts` |
| 系統匣 | `system tray` | Electron `Tray` + `Menu`；Win11 menu-bar 等價物 | `apps/windows/src/main/tray.ts` |
| 開機自動啟動 | `Launch at Login` | `app.setLoginItemSettings({ openAtLogin: true, openAsHidden: true })` 底層為 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | `apps/windows/src/main/auto-launch.ts` |
| 防火牆規則 | `firewall` | `New-NetFirewallRule -Direction Inbound -Protocol TCP -Action Allow` | `README.permission.md` |
| Multicast DNS | `multicast-dns` | RFC 6762/6763 over `_local.`；`multicast-dns` npm 套件 | `packages/SyncCore.Windows/src/discovery/bonjour-browse.ts` |
| NTFS reparse point | `NTFS reparse point` | `FILE_ATTRIBUTE_REPARSE_POINT`；對應 macOS `resourceValuesForKeys: [.isSymbolicLinkKey]` | `packages/SyncCore.Windows/src/receiver/destination-writer.ts` |
| NTFS 保留名 | `NTFS reserved names` | `CON / PRN / AUX / NUL / COM1..9 / LPT1..9`；AlbumFolderPolicy 必須拒絕 | `packages/SyncCore.Windows/src/protocol/filename-policy.ts` |
| 長路徑 | `\\?\` | 超過 MAX_PATH（260）時套用 `\\?\` prefix | `packages/SyncCore.Windows/src/receiver/destination-writer.ts` |
| NSIS installer | `NSIS` | electron-builder 預設 Windows installer 格式 | `apps/windows/electron-builder.yml` |
| Portable .exe | `portable` | 單一 .exe 免安裝；後備選項 | `apps/windows/electron-builder.yml` |
| MSIX | `MSIX` | Windows 11 app package；backlog 項目 | `apps/windows/electron-builder.yml` |
| IPv6 multicast | `224.0.0.251` | mDNS group；對應 macOS `NWBrowser` 預設 | `packages/SyncCore.Windows/src/discovery/bonjour-browse.ts` |
| 配對服務 | `_iphonesync-pair._tcp` | 配對階段 listener 的 Bonjour service type；獨立 port | `packages/SyncCore.Windows/src/protocol/constants.ts` |
| 同步服務 | `_iphonesync._tcp` | 正常同步 listener 的 Bonjour service type | `packages/SyncCore.Windows/src/protocol/constants.ts` |

## 縮寫 (Abbreviations)

| 縮寫 | 全稱 | 說明 |
| --- | --- | --- |
| TLS | Transport Layer Security | TLS 1.2 PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`) |
| PSK | Pre-Shared Key | 32-byte HKDF-derived secret used as TLS-PSK |
| HKDF | HMAC-based Key Derivation Function | RFC 5869；HKDF-SHA256 |
| SAS | Short Authentication String | 6-digit verification code |
| mDNS | Multicast DNS | RFC 6762 |
| DNS-SD | DNS-based Service Discovery | RFC 6763 |
| ACL | Access Control List | NTFS 權限 |
| DPAPI | Data Protection API | Windows 內建加密 API |
| NSIS | Nullsoft Scriptable Install System | Windows installer |
| MSIX | Microsoft Store Installer Package | Windows 11 app package |
| DDL | Dynamic-link library | Win32 API |
| IPC | Inter-Process Communication | Electron contextBridge |
| UI | User Interface | renderer |
| DNS | Domain Name System | mDNS over `_local.` |
| RFC | Request for Comments | mDNS / DNS-SD / TLS-PSK |
| ASCII | American Standard Code for Information Interchange | wire-format encoding |
