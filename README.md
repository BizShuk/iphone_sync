# iPhone Sync

`iPhone Sync` 是一套原生 iPhone 與 Mac 個人媒體備份工具。使用者在 iPhone 前景手動觸發同步，將一個或多個指定 Photos 相簿中尚未備份、且已存在 iPhone 本機的完整原始資源，單向增量傳送至已配對 Mac 的 Finder destination；receiver 固定先使用 `iPhoneSync` 資料夾，再為每個來源相簿建立對應子資料夾。

## 業務定義 (Business Definition)

- 來源固定為一部 iPhone 上由使用者選取的一個或多個 Photos 相簿。
- 目的地固定為一部已配對 Mac 上的 Finder folder；Mac 實際寫入 `<selected-folder>/iPhoneSync/<album-name>/`，並安全建立或重用固定容器與各相簿資料夾。
- 兩個不同相簿若名稱相同，第一個使用原名，後續穩定使用 `名稱 (2)`、`名稱 (3)`，不會合併兩個相簿。
- 同步只新增；iPhone 刪除不會傳播至 Mac，也不覆寫 Mac 的既有不同內容。
- 傳輸只使用同一區域網路，不使用 AirDrop、Bluetooth、Internet relay 或雲端服務。
- 備份保留 PhotoKit 提供的原始 resource bytes，包括 RAW、影片、Live Photo components 與 adjustment data。
- 不在 iPhone 本機的 iCloud Photos resource 會被跳過，App 不會自動下載。

## Domain Flow

```mermaid
flowchart LR
    A["iPhone Photos 相簿（可多選）"] -->|"PhotoKit local-only"| B["iOS App"]
    B -->|"Bonjour discovery"| C["Network.framework TLS 1.2 PSK"]
    C -->|"1 MiB framed chunks"| D["macOS receiver"]
    D -->|"partial + SHA-256 + atomic commit"| E["Finder / iPhoneSync / 相簿名稱 / 年 / 月"]
    D -->|"completed + 16 MiB checkpoint"| F["SwiftData manifest"]
```

## 使用方式

1. 在 Mac App 選擇目的資料夾，再開啟兩分鐘配對視窗。
2. 在 iPhone 授予 Photos Full Access、選擇一個或多個相簿，再按 `Find Mac`。
3. 選擇同一 LAN 上的 Mac，輸入 Mac 顯示的六位數配對碼。
4. 在 iPhone 按下 `Sync Now`，同步期間保持 App 在前景。
5. iPhone 逐一同步已選相簿；Mac 先建立或重用 `iPhoneSync`，再為每個相簿建立或重用對應子資料夾，驗證每個 resource 後才寫入；再次同步只傳新增或未完成內容。

若 `iPhoneSync` 或對應相簿資料夾已是安全的真實資料夾，Mac 會直接重用且保留全部既有內容；若同名項目是檔案、symlink 或不安全路徑，session 會拒絕。Mac Setup 的 `Error Log` 面板會保留本次執行期間最近 100 筆 receiver、pairing、destination、bookmark 與 launch-at-login 錯誤，可複製或清除。

iPhone 必須使用 Wi-Fi；Mac 可使用同一 LAN 的 Wi-Fi 或 Ethernet。Bonjour 若被 guest network、VLAN、VPN 或 router client isolation 阻擋，App 不會繞過網路限制。

## 建置與執行

需求：Xcode 26、Swift 6 與 XcodeGen。

```bash
xcodegen generate
open iPhoneSync.xcodeproj
```

在 Xcode 為 `iPhoneSyncMac` 與 `iPhoneSyncIOS` 選擇同一開發團隊後：

1. 先在 Mac 執行 `iPhoneSyncMac`，從選單列開啟 `Open Setup`。
2. 選擇 Finder destination 並按 `Pair iPhone`。
3. 在實體 iPhone 執行 `iPhoneSyncIOS`，完成授權、相簿選擇與配對。

也可以從專案根目錄以 Terminal 啟動 Mac receiver：

```bash
./scripts/run_server.sh
```

此腳本會重新產生 Xcode project、建置 `iPhoneSyncMac`，並直接開啟 Setup 視窗；首次使用請選擇 destination 並完成配對。App 仍會在 menu bar 提供 receiver 狀態。

`project.yml` 是 Xcode target、Info.plist 與 entitlements 設定的唯一來源；變更後必須重新執行 `xcodegen generate`。產生的 `iPhoneSync.xcodeproj`、Info.plist 與 entitlements 已提交，checkout 後不必先安裝 XcodeGen 即可直接開啟。

## 驗證

```bash
bash scripts/verify.sh
```

驗證入口會執行 Swift package tests、重新產生 Xcode project、建置 macOS、iOS Simulator 與 generic iOS device targets、檢查 plist/entitlements/local-only invariants，以及執行 `git diff --check`。建置使用 `CODE_SIGNING_ALLOWED=NO`，因此不等同實體裝置驗收。

## 持久化設定 (Persistent Settings)

Mac 設定依資料敏感度使用 Apple 原生持久層，不集中到一個可讀檔案：

| Data | Persistent Store |
|---|---|
| receiver ID、source binding、launch-at-login intent | sandbox `UserDefaults`，由 `MacSettingsStore` 統一管理 |
| Finder destination permission | security-scoped bookmark in sandbox preferences |
| paired iPhone PSK、opaque identity | login Keychain |
| album mappings、完成狀態、續傳 checkpoint | SwiftData in App container `Application Support` |
| 開機自動執行 | `SMAppService.mainApp` login item registration |
| Setup window size/position、menu-bar item position | AppKit autosave |

`Launch at Login` 首次預設啟用，使用者關閉後會保存該選擇。App 於登入後啟動時會重新載入 destination bookmark、paired peer 與 manifest，條件完整便自動恢復 receiver。六位數 pairing code、active connection 與當次 UI error state 是 transient runtime state，不跨重啟保存。

## 安全與資料邊界

- 初次配對使用 ephemeral Curve25519 key agreement；六位數僅作 short authentication string (SAS)，不會透過網路傳送，也不是加密金鑰。
- 配對成功後的 256-bit secret 與 opaque identity 存入 Keychain，正常同步使用 TLS 1.2 static PSK。
- iPhone discovery 與連線固定 `includePeerToPeer = false`，不走 Bluetooth/AWDL fallback。
- PhotoKit request 固定 `isNetworkAccessAllowed = false`，不因同步而觸發 iCloud 下載。
- Mac 以 security-scoped bookmark 保存所選 Finder folder 權限；固定 `iPhoneSync` 容器、每個相簿的穩定資料夾對應、完成狀態與續傳 offset 存於 App container 的 SwiftData manifest。

## 專案狀態

MVP 程式、多相簿選取與對應資料夾、Mac error log、typed persistent settings、edge-case tests、兩個原生 App targets 與 canonical verification 已完成。自動驗證涵蓋 unsigned builds；實體 iPhone、真實 Photos library、完整 Mac restart 與網路故障情境仍列於 [README.todo](README.todo)，不得將 unsigned build 視為實機成功。

完整設計見 [local album sync design](docs/specs/2026-07-19-local-album-sync-design.md)，技術結構見 [CLAUDE.md](CLAUDE.md)。
