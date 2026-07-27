# 2026-07-27 Delete After Sync

## Outcome

完成 iOS default-off `Delete After Sync`：

- 主畫面新增 `AFTER SYNC` destructive card、enable warning、toggle、pending count 與 foreground delete button。
- `IOSDeleteAfterSyncStore` 保存 enabled intent 與 fully backed-up pending Photos asset ID / `modificationDate` snapshots；disable 或 forget receiver 會清 pending。
- `PhotoLibrarySource` 在 resource stream 末端回報 asset-level completeness；`PhotoDeletionCandidateAccumulator` 對跨 selected albums 的同一 asset 做 AND merge。
- 只有 multi-album run 完整成功後才處理 candidates。Foreground run 使用 `PHAssetChangeRequest.deleteAssets`，background run 只 enqueue，避免在 system-launched task 嘗試顯示 Photos change confirmation。
- `NSPhotoLibraryUsageDescription`、permission catalog、canonical docs、source invariants 與 live-device TODO 已同步。

## Durable Decisions

- 刪除單位是整個 `PHAsset`，不是單一 resource 或 album membership。
- 任一 resource not-local、failed、cancelled、expired 或未在每個 selected album occurrence confirmed，整個 asset 保留。
- Receiver committed files 與 manifest 不因來源 deletion 改變；這不是 deletion propagation。
- PhotoKit deletion failure / user cancellation 保留 pending candidates，讓使用者可再嘗試。
- Candidate 在刪除前重新 fetch；`modificationDate` 與 sync snapshot 不同時保留 asset，避免誤刪同步後的新編輯版本。
- 不可刪或已不存在的 asset 解析 pending state 後保留現況並記 warning。
- Operation Log 只記 asset count，不保存或顯示 local identifiers。

## Verification

- Focused iOS Simulator tests：`41/41` passed，沒有新增 Swift warnings。
- `bash scripts/verify.sh` passed：
    - Swift package tests：`54/54`
    - iOS unit tests：`41/41`
    - Windows vitest：`49/49`
    - unsigned macOS build
    - generic iOS Simulator build
    - `Release` generic iOS device build
    - SyncCore.Windows 與 Windows Electron 兩個 TypeScript builds
    - generated plist、entitlement、local-only、deletion 與 whitespace invariants
- iPhone 17 Pro / iOS 26.5 Simulator screenshot confirmed the default-off card is visible without truncation or layout collision.

## Remaining Acceptance

- Signed physical-device Photos deletion allow / cancel。
- Live Photo、RAW+JPEG、adjustment-data 與 iCloud-only mixed-resource deletion boundary。
- `iCloud Photos` 跨裝置 propagation 與 `Recently Deleted` behavior。
- Background pending queue 經 App termination / relaunch 後的 foreground confirmation。
- 大批量與不可刪 asset behavior。
