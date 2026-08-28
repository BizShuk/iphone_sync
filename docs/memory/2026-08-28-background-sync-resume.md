# 2026-08-28 Background Sync Resume

## Outcome

使用者回報 `Last success` 停在前一晚、而每個 background window 都以
`The scheduled batch reached its time budget and will resume later.` 收尾。
根因不是排程，而是`每一輪都重做已完成的工作`：

- 相簿以 `creationDate` 升冪走訪，每一輪都從最舊的 asset 重新開始。
- 每個 resource 在問 Mac 之前就已被完整 export 到暫存檔並算完 SHA-256，
  已同步過的照片因此每輪重付一次全額成本，五分鐘的 window 走不到新照片。
- foreground `Sync Now` 沒有 expiration，所以只有手動同步能推進 `Last success`。

修正：

- `SyncClient` 拆出 `offerResource` 與 `sendResourceBody`；offer 不再需要先有 bytes。
- `SyncedResourceLedger` 保存每個已被 receiver 確認的 `ResourceDescriptor`，
  下一輪直接用它 offer；receiver 回 `.skip` 就完全不必碰檔案。
- `AlbumSyncCursorStore` 保存每個相簿的續傳位置，被中止的 pass 從中斷處接續。
- `budgetExhausted` 改以 `setTaskCompleted(success: true)` 回報。

## Durable Decisions

- ledger `只是 cache`，Mac manifest 仍是完成狀態的 authoritative source。
  流程一律是「先 offer、由 receiver 決定」，ledger 不得用來略過 receiver 的判斷；
  這讓 `Delete After Sync` 的前提（每個 resource 都由 receiver 當場確認）不變。
- ledger key 含 destination `sourceBindingID`，並以 asset `modificationDate` 失效；
  `Forget` receiver 一併清空 ledger 與 album cursors。
- receiver `accept offer 的那一刻就開始計 45 秒 idle deadline`。offer 與第一個 chunk
  之間不得插入 export 或 SHA-256 這類長工作——大型 `.MOV` 的 hash 就足以超時，
  Mac 端會以 `FramedConnectionError`（truncated frame）記錄失敗。
  因此本機檔案驗證一律在 offer `之前`完成；ledger offer 收到 `.transfer` 時只丟掉
  entry 並以 retryable failure 結束，由下一輪正常 stage 重建。
  這是本次第一版改動踩到的坑：把驗證移到 offer 之後，等於用大檔案的 hash 時間
  去撞 receiver 的 idle deadline。
- album cursor 只在`本次 pass` 內有效，走完相簿即清除，下一輪重新完整走訪，
  才不會漏掉之後匯入的舊日期照片。
- 用完 iOS 給的 window 是預期結果，不是 handler 失敗。以 `success: false` 回報會讓
  iOS 縮減本 app 的 background 額度，使問題自我惡化。

## Verification

- `bash scripts/verify.sh` passed：
    - Swift package tests：`64/64`（+3：offer-only skip、receiver 遺失檔案回報 `.transfer`、offer 前先驗證本機檔案）
    - iOS unit tests：`50/50`（+9：ledger 五項、cursor 四項）
    - Windows vitest：`49/49`
    - unsigned macOS build、generic iOS Simulator build、`Release` generic iOS device build
    - generated plist、entitlement、local-only、deletion 與 whitespace invariants
- 新增 source invariants：album walk 必須支援 `resumingAfter`、coordinator 必須先
  `confirmedDescriptor` 再 `offerResource`、`sendResource` 必須在 offer 前驗證本機
  檔案、走完相簿必須清 cursor、`Forget` 必須清 ledger、兩個 store 都必須設定 file
  protection。
- `尚未`在實機驗證：真實 background launch 下的續傳與 `Last success` 推進，
  仍以 [README.todo](../../README.todo) 為準。
