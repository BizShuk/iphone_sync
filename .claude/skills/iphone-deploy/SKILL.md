---
name: iphone-deploy
description: Use when building, installing, or launching the tally app on a physical iPhone via command line. Triggers on "deploy to iPhone", "build for device", "install on phone", "實機安裝", "run on iPhone", "console log from device", or any request to get the app running on a real iPhone.
---

# iPhone 實機 CLI 部署

## Overview

完成一次 Apple ID、certificate 與自動簽章設定後，透過 `scripts/run_iphone.sh` 單一入口完成 xcodegen → archive → install → launch，全程不需再開啟 Xcode GUI。

## 前置條件（一次性）

- 機型：iPhone 15 Pro / Pro Max 以上（LiDAR + Apple Intelligence）
- 系統：iOS 26+
- 裝置設定：
  - `設定 → 隱私權與安全性 → 開發者模式` → 開啟，重開機
  - `設定 → Apple Intelligence 與 Siri` → 開啟，等模型下載完成
- 用線材接上 Mac，裝置上點「信任這部電腦」並輸入密碼
- Mac 需安裝 `xcodegen`（`brew install xcodegen`）

## 簽章設定（首次）

`project.yml` 不保存 signing team、identity 或 provisioning profile。實機需要簽章，請依以下步驟完成首次簽章註冊：

### 首次簽章設定（尚未在 Xcode 設定帳號或憑證時）

若本機尚未在 Xcode 登入 Apple ID、建立 Apple Development certificate 或啟用自動簽章，先使用 Xcode GUI 完成一次設定：

1. 執行 `xcodegen generate` 並在 Xcode 中打開專案：
   ```bash
   xcodegen generate && open tally.xcodeproj
   ```
2. 在 Xcode 內點擊左側 `tally` 專案圖示，選取 `tally` target，進入 `Signing & Capabilities` 頁籤。
3. 確認已勾選 `Automatically manage signing`，且 `Team` 已選取你的 Apple 帳號（若未登入，請依提示登入 `biz.shuk@gmail.com`）。
4. 在 Xcode 上方選擇你的實機 iPhone 作為目標裝置，並按下 `Cmd+R`（Run），讓 Xcode 建立或更新 provisioning profile。
5. 首次執行後，在 iPhone 裝置上進入：`設定 → 一般 → VPN 與裝置管理`，點選你的 Apple ID 並點擊「信任」。

完成上述設定後，或本機原本已有有效帳號、certificate 與 profile 時，即可直接在終端機使用 `./scripts/run_iphone.sh` 進行一鍵編譯與安裝。

免費簽章 app 7 天後過期時，重新執行 `./scripts/run_iphone.sh`；只有 Xcode 帳號或 certificate 失效時才需回到 GUI 修復設定。

### CLI 自動偵測

`run_iphone.sh` 先以 `security find-identity` 找出有效 Apple Development identity，再讀取對應 certificate subject 的 `OU` 作為 `DEVELOPMENT_TEAM`。identity 顯示名稱括號內的 10 碼識別碼不是 team ID。前提是已經在 Xcode 設定過至少一次簽章。

## Quick Reference

| 操作 | 命令 | 說明 |
|------|------|------|
| 完整部署 | `./scripts/run_iphone.sh` | build + install + launch |
| 僅建置 | `./scripts/run_iphone.sh --build-only` | archive 不需接裝置 |
| 附掛 console | `./scripts/run_iphone.sh --console` | 重啟 app + 即時 stdout/stderr |
| 說明 | `./scripts/run_iphone.sh --help` | 顯示所有選項 |

## 完整部署流程

```bash
# 1. 確認裝置已連線、解鎖、Developer Mode 開啟
# 2. 一行搞定
./scripts/run_iphone.sh
```

腳本自動執行：
1. `xcodegen generate` — 從 `project.yml` 產生 `.xcodeproj`
2. `security find-identity` + certificate subject `OU` — 自動偵測 signing team
3. `xcodebuild archive` — 建置 signed archive（Debug config）
4. `xcrun devicectl list devices` — 找到 connected + paired iPhone
5. `xcrun devicectl device install app` — 安裝 `.app`
6. `xcrun devicectl device process launch` — 啟動 app

## 環境變數覆寫

| 變數 | 預設值 | 用途 |
|------|--------|------|
| `DEVICE_UDID` | 自動偵測 | 多台 iPhone 時指定 |
| `DEVELOPMENT_TEAM` | keychain 偵測 | 覆寫 signing team ID |
| `CONFIGURATION` | `Debug` | Xcode build configuration |
| `BUILD_ROOT` | `build/iphone` | 建置輸出目錄 |
| `ALLOW_PROVISIONING_UPDATES` | `1` | 設 `0` 停用自動 provisioning |

## 查看即時 Log

部署後想看 app stdout/stderr：

```bash
./scripts/run_iphone.sh --console
```

這會 `--terminate-existing` 重啟 app 並附掛 console 輸出。

若只想看 log 不重啟，用 `Console.app` 或：

```bash
xcrun devicectl device info log --device <UDID>
```

## VS Code 整合

`.vscode/tasks.json` 已配置三個 task：

- `Tally: iPhone Build + Install + Launch`（預設 build task）
- `Tally: iPhone Build Only`
- `Tally: iPhone Console`

使用 `Cmd+Shift+B` 觸發預設 build task。

## 疑難排解

| 症狀 | 原因 | 解法 |
|------|------|------|
| `找不到 connected + paired iPhone` | 裝置未解鎖 / Developer Mode 未開 / USB 未連 | 解鎖裝置、確認 Developer Mode、重新插線 |
| `找到多台 paired iPhone` | 多裝置同時連線 | 設定 `DEVICE_UDID=<udid>` 指定 |
| `找不到 Apple Development signing identity` | 未在 Xcode 設定簽章 | 走「路徑 A」先在 Xcode GUI 設定一次 |
| `找到多組 Apple Development team` | keychain 有多組憑證 | 設定 `DEVELOPMENT_TEAM=<10碼ID>` |
| app 安裝後無法啟動 | 免費簽章未信任 | 裝置 `設定 → VPN 與裝置管理` → 信任 |
| app 7 天後無法開啟 | 免費簽章過期 | 重新執行 `./scripts/run_iphone.sh` |
| `xcodegen: command not found` | 未安裝 xcodegen | `brew install xcodegen` |
| archive 失敗 provisioning 錯誤 | 自動 provisioning 被停用 | 確認 `ALLOW_PROVISIONING_UPDATES` 非 `0` |

## 腳本架構

```
scripts/
├── run_iphone.sh          # 唯一入口：build/install/launch/console
└── test_run_iphone.sh     # stubbed shell contracts 測試
```

`run_iphone.sh` 的裝置選擇邏輯：
- `xcrun devicectl list devices --json-output` 取 JSON
- 以 `plutil` 逐一檢查 `deviceType=iPhone` + `platform=iOS` + `reality=physical` + `pairingState=paired` + ( `tunnelState=connected` 或 `transportType=wired` )
- 恰一台則自動選用；零台或多台則報錯

signing team 偵測邏輯：
- `security find-identity -v -p codesigning` 從 keychain 擷取
- 以 identity common name 找到對應 certificate
- `openssl x509` 從 RFC2253 subject 的 `OU` 取得 10 碼 team ID
- 不使用 identity 顯示名稱括號內的 certificate 識別碼
- 恰一組則自動使用；零組或多組則報錯
