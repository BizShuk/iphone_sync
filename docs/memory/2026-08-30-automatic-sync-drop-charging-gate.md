# 2026-08-30 Automatic Sync 移除充電條件

## Outcome

`Automatic Sync` 的 background request 不再要求外接電源。
`BGProcessingTaskRequest.requiresExternalPower` 由 `true` 改為固定 `false`，
`AutomaticSyncPolicy` 不再持有 power gate；cadence 仍是單一 lane 的
`earliestBeginDate = now + 30 分鐘`，成功與失敗以相同 interval 重新武裝。

App 內文案同步更新：`Cadence` 由 `Every 30 minutes while charging` 改為
`Every 30 minutes`，timing alert 改為說明電池供電時一樣會嘗試。

## Durable Decisions

- power condition 仍`不由 App 判斷`：既不讀 `UIDevice.batteryState`，也不做
  App 端的電量門檻。移除的是交給 iOS 的那個 flag，不是改由 App 接手。
- 只有一條 automatic lane 的約束不變：沒有第二個 cadence、沒有第二個 task
  identifier、沒有前景測試迴圈。
- 代價：`requiresExternalPower = false` 讓 iOS 更可能給短窗或延後啟動，
  單次 window 走不完時依賴既有的 `SyncedResourceLedger` 與
  `AlbumSyncCursorStore` 續傳，不得改回充電條件來換長窗。

## Evidence

- `xcodebuild test -scheme iPhoneSyncIOS`（iPhone 17 Pro, iOS 26.5）49 tests 全過，
  含 `testRestoreKeepsElapsedEligibilityAndNeverAsksForExternalPower`。
- 實機「拔電下 iOS 是否仍啟動 request」的驗收仍列在 `README.todo`。
