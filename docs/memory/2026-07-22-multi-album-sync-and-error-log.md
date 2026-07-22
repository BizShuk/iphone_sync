# Multi-album Sync and Error Log

Date: `2026-07-22`

Status: `Automated verification complete; live-device acceptance pending`

## Delivered

- iPhone album picker 支援多選、取消與 `Done` 儲存；`UserDefaults` 會把舊版單一 `selectedPhotoAlbum` 自動遷移成 `selectedPhotoAlbums`。
- `IOSSyncCoordinator` 依已選相簿逐一建立 TLS session，顯示目前 album/resource progress，並將所有 album summaries 合併回主畫面。
- 同一 Mac `sourceBindingID` 可登錄多個 albums；`AlbumRecord` 保存穩定的 album-to-folder mapping，`TransferRecord` 以 album scope 保存同一 logical resource 在不同相簿的獨立完成與續傳狀態。
- 每個 album 使用安全化相簿名稱建立或重用 destination folder。不同 albums 若名稱相同，依序使用 `名稱`、`名稱 (2)`、`名稱 (3)`，避免合併。
- 已存在的真實資料夾會安全重用且不清除內容；同名項目若是檔案或 symlink 則拒絕 session，不覆寫或繞過。
- Mac Setup 新增 `Error Log` panel，收集 receiver、pairing、destination、startup、menu-bar 與 launch-at-login errors，保留最近 100 筆，可複製或清除。

## Durable Decisions

- `sourceBindingID` 現代表一部 iPhone 對一個 destination 的來源集合，而不是單一 album；不同 binding 仍必須拒絕。
- Wire-level `resourceID` 算法不加入 album ID，避免改變既有 Finder filenames。Mac 另以 `(sourceBindingID, albumID, logicalResourceID)` 導出 persisted album-scoped manifest key。
- 舊版 `SourceRecord` 的 album fields 保留作 migration seed；第一次接受新版 session 時建立 `AlbumRecord`，並把 legacy `TransferRecord` 轉入原 album scope，保留 logical ID、checkpoint 與 final path。
- Legacy root-level partial 只允許原 legacy album 搬入自己的 folder；其他新 album 不得取用或截斷該 partial。
- Album folder mapping 在首次接受後保持穩定；之後 album rename 不會移動、刪除或合併既有 Finder files。
- Existing directory reuse 是正常流程，不寫入 error log；不安全或不可用的 destination 才回覆 `destination-unavailable` 並進入 Mac error panel。
- Error panel 是 bounded in-memory state，不跨 App launch 保存；unified logging 不公開動態錯誤內容，且不得加入配對碼、PSK、完整檔名或照片 metadata。

## Verification Evidence

執行：

```bash
bash scripts/verify.sh
```

結果：

- Swift package：`44 tests in 1 suite`，全部通過。
- `iPhoneSyncMac`：macOS clean unsigned build 通過。
- `iPhoneSyncIOS`：generic iOS Simulator clean unsigned build 通過。
- `iPhoneSyncIOS`：generic iOS device unsigned build 通過。
- Generated plist/project、entitlements、local-only source、multi-album/error-log invariants 與 `git diff --check` 通過。
- 新增覆蓋：same resource cross-album round trip、duplicate album folder suffix、existing folder reuse、file conflict rejection 與 useful receiver error、legacy record migration，以及 legacy partial ownership。

## Verification Boundary

尚未在實體 iPhone、真實 Photos library 與使用者 Finder destination 驗證多選操作、逐相簿連線、相簿同名/改名、既有資料夾或 error-log UI。相關驗收保留於 [../../README.todo](../../README.todo)。
