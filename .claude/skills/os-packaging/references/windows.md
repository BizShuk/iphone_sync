# Windows 11 打包細節（Electron + electron-builder）

## Build for 本機開發

```bash
cd apps/windows

# 一次性：安裝依賴（會跑 postinstall 把 SyncCore.Windows 配置進來）
npm install

# Type-check + watch
npm run dev          # 等同 tsc -p tsconfig.json --watch
# 另一個 terminal：
npm start            # 等同 electron .
```

第一次啟動時 tray 圖示會出現在 Windows 11 system tray；沒有主視窗，是常駐型 receiver。

## 產生散佈 artifact

```bash
cd apps/windows

# 同時產 NSIS installer + portable .exe（x64）
npm run dist

# 或個別
npm run dist:nsis       # NSIS installer
npm run dist:portable   # portable .exe
```

產出在 `apps/windows/dist-installer/`：

```
iPhoneSync-Setup-1.0.0.exe        # NSIS installer
iPhoneSync-Portable-1.0.0.exe     # portable
```

預設行為：

- `asar: true`：將 `dist/` 與 JS 原始碼封進 `app.asar`；但 `better-sqlite3` 原生 binding 因 Electron ABI 解不解，必須 `asarUnpack` 解出。
- NSIS 選項：可選安裝目錄、建立桌面與開始功能表捷徑、`deleteAppDataOnUninstall: true`（解除安裝時清掉 AppData 內的 manifest 與 settings）。
- icon：`assets/icons/tray.ico`（NSIS installer 與 tray 都用它）。

## Authenticode 簽章（給別人 Windows 裝）

```bash
# 用 OV / EV certificate 與 signtool
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 \
  /f <pfx-path> /p <pfx-password> \
  "apps\windows\dist-installer\iPhoneSync-Setup-1.0.0.exe"

signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 \
  /as /f <pfx-path> /p <pfx-password> \
  "apps\windows\dist-installer\iPhoneSync-Portable-1.0.0.exe"
```

或在 `electron-builder.yml` 加 `win.certificateFile` / `win.certificatePassword`，讓 `npm run dist` 自動簽。

EV certificate 可直接通過 SmartScreen；OV certificate 第一次發佈需要累積 reputation，下載次數與時間夠後才不會跳警告。

## SmartScreen reputation

發佈初期用 OV 時，第一次下載可能跳出「Windows protected your PC」。可以：

- 透過 Microsoft 提交表單申請 reputation review（會問使用者是否同意）
- 改用 EV certificate（直接通過）
- 透過 Azure Trusted Signing（雲端 HSM + EV 等級）簽章

## 安裝與啟動

```bash
# NSIS installer（互動式）
"apps\windows\dist-installer\iPhoneSync-Setup-1.0.0.exe"
# 或 PowerShell 靜默安裝
Start-Process "apps\windows\dist-installer\iPhoneSync-Setup-1.0.0.exe" -ArgumentList "/S" -Wait

# Portable（解壓後雙擊 iPhoneSync-Portable-1.0.0.exe）
Expand-Archive "apps\windows\dist-installer\iPhoneSync-Portable-1.0.0.zip" -DestinationPath "$env:LOCALAPPDATA\iPhoneSync"

# 從開始功能表啟動（NSIS 安裝後）
# "iPhone Sync" → 點 tray icon 開 Setup / Pairing 視窗
```

## Windows 特有特殊點

- **無 App Sandbox 預設**：electron-builder 預設沒啟用 AppContainer；要不要 sandbox 是產品決定（目前專案未啟用）。
- **Bonjour via `multicast-dns`**：與 Apple 端的 `NWBrowser` / `NWListener` 通訊；Windows 不需要裝 Bonjour print service。
- **TLS-PSK via `tls.createServer`**：與 macOS `Network.framework` 等級的 cipher suite 由 Node.js `tls` 提供。
- **Manifest 與 settings 在 AppData**：SwiftData 等級的 persistence 在 Windows 端是 `better-sqlite3` + `~/AppData/Roaming/iPhoneSync/`；解除安裝時 `deleteAppDataOnUninstall: true` 會清掉。
- **Tray-only 行為**：沒有 main window；只有 tray icon、Setup 視窗、Pairing 視窗。Electron `BrowserWindow` 都用 `show: false` 直到使用者從 tray 開啟。
- **`auto-launch`**：Windows 端的「開機自動啟動」透過 Electron `app.setLoginItemSettings`（登錄檔 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`）；包裝不影響，但解除安裝後登錄檔殘留需手動清。
- **Cross-build**：在 macOS / Linux 上跑 `electron-builder --win nsis portable` 需要 Wine（macOS）或預先 build 的 Windows binary；專案用此方式開發與散佈。
- **Path 大小寫**：Windows 路徑不區分大小寫，但 Bonjour TXT record / TLS SNI 等 wire format 是 case-sensitive；部署時用 `path.resolve` 避免 Node `__dirname` 在不同 OS 出現不同字串。

## Windows 疑難排解

| 症狀 | 原因 | 解法 |
|---|---|---|
| `electron-builder` 找不到 | `npm install` 沒跑或被 lock 阻擋 | `cd apps/windows && npm install` |
| `better-sqlite3` 載入失敗 | ABI 與 Electron 不符 | `npm rebuild better-sqlite3` 或 `electron-rebuild` |
| 雙擊 `.exe` 出現「應用程式無法正確啟動 (0xc000007b)」 | 缺 Visual C++ Redistributable | 安裝 Microsoft Visual C++ Redistributable 2015-2022 |
| Windows Defender SmartScreen 警告 | 沒 Authenticode 簽章或 OV reputation 不足 | 改 EV certificate 或送 Microsoft reputation review |
| Bonjour 沒看到其他裝置 | Windows Firewall 阻擋 UDP 5353 | 在 `netsh advfirewall` 加 inbound/outbound 規則，或讓使用者允許 |
| 解除安裝後登錄檔殘留 | `app.setLoginItemSettings` 沒清 | 手動刪 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\iPhoneSync` |
| Electron 在 Wine 上 crash | Wine 版本太舊 | 用 wine-stable 9+ 或在 Windows 實機 build |
| `npm run dist` 卡在 `code-signing` | 沒給 `CSC_LINK` / `CSC_KEY_PASSWORD` 但 electron-builder 預設要求 | 設環境變數或暫時加 `--config.win.signtoolOptions.signingHashAlgorithms=null` |

## 相關檔案

- [apps/windows/package.json](../../../apps/windows/package.json)
- [apps/windows/electron-builder.yml](../../../apps/windows/electron-builder.yml)
- [apps/windows/tsconfig.json](../../../apps/windows/tsconfig.json)
- [apps/windows/src/main/](../../../apps/windows/src/main/)
- [packages/SyncCore.Windows/](../../../packages/SyncCore.Windows/)
- [scripts/verify_windows.sh](../../../scripts/verify_windows.sh)