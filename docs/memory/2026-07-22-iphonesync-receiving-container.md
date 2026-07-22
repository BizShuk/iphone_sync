# iPhoneSync Receiving Container

`Date:` 2026-07-22

## Decision

- 使用者選擇的 Finder folder 保持為 security-scoped destination root。
- receiver 固定先建立或重用 `iPhoneSync`，每個來源相簿再寫入 `iPhoneSync/<safe-album-name>/<year>/<month>/`。
- `iPhoneSync` 或 album 同名項目若為安全的真實資料夾，保留內容並直接重用；若為檔案、symlink 或不安全路徑，拒絕 session，錯誤由 Mac `Error Log` 顯示。
- 新 manifest `finalRelativePath` 以 selected folder 為基準並包含 `iPhoneSync/<album-folder>/`。
- 舊版 committed files 不搬移、不刪除；舊版 direct per-album 或 root-level `.partial` 可依 manifest ownership 搬入新階層續傳。

## Verification

- `MacReceiverKitTestSuite` focused run：`26 tests` passed。
- `bash scripts/verify.sh`：`48 tests` passed。
- unsigned `iPhoneSyncMac`、generic iOS Simulator 與 generic iOS device builds 全部成功。
- `git diff --check` 與 plist、entitlement、local-only、multi-album、receiving-folder invariants 全部通過。

## Remaining Acceptance

- 真實 Photos library 的完整多相簿同步仍需確認 Finder 輸出為 `<selected-folder>/iPhoneSync/<album-name>/`，保留於 [../../README.todo](../../README.todo)。
