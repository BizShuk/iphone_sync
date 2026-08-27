# 2026-08-27 Background Deletion Observability

## Outcome

使用者回報「同步後不會刪除」，實際是兩件事疊在一起：背景 automatic run
`按設計`只排隊不刪，而排隊留下的證據又全部消失，導致無法自我診斷。

- iOS `Operation Log` 由 `PersistentOperationLogStore` 落地為 App container 內的
  JSONL，啟動時還原最新 500 筆。背景 run 的事件不再隨 process 終止消失。
- 背景 run 留下 pending deletion 時，`PendingDeletionNotifier` 送出一則只含張數的
  local notification；完成刪除、關閉 toggle 或 `Forget` 時撤回。
- 啟用 `Delete After Sync` 時請求通知授權；被拒時排隊與刪除行為完全不變。
- `README.permission.md` 與技能 `references/permissions.md` 新增 `iPhone Notifications`
  一列；`docs/specs/2026-07-27-delete-after-sync.md` 補上通知與落地 log 的 contract。

## Durable Decisions

- 背景 automatic run `永遠不刪除` Photos assets：PhotoKit 的 change confirmation
  無法從 system-launched task 顯示。這是產品邊界，不是缺陷；提示層負責讓它可被察覺。
- 通知只是提示層：不得成為刪除的前置條件，不得攜帶 asset identifier，授權被拒時
  流程照舊。使用單一固定 identifier，永遠只有一則待確認提示。
- iOS operation timeline 必須落地。只存在記憶體的 timeline 讓 background sync 與
  pending deletion 都無從稽核——這是本次無法從 log 判斷根因的直接原因。
- 落地 log 沿用 500 筆上限，超過時 compaction 保留最新的；不得寫入 PSK、pairing
  code、identity、source binding、content hash 或 asset identifier。
- log 檔以 `completeUntilFirstUserAuthentication` 保護，讓裝置鎖定中被喚醒的
  background run 仍寫得進去。
- macOS receiver 是常駐 process，維持 in-memory buffer，不跟進落地。

## Verification

- `bash scripts/verify.sh` passed：
    - Swift package tests：`61/61`
    - iOS unit tests：`41/41`（+6 落地 log 與 pending 通知，-10 隨 Debug lane 移除）
    - Windows vitest：`49/49`
    - unsigned macOS build、generic iOS Simulator build、`Release` generic iOS device build
    - SyncCore.Windows 與 Windows Electron 兩個 TypeScript builds
    - generated plist、entitlement、local-only、deletion、notification 與 whitespace invariants
- 新增 source invariants：background enqueue 必須 `notifyPending`、刪除後必須
  `clearPending`、`IOSAppModel` 必須 load/append 落地 log、log 檔必須設定 file
  protection、`apps/ios` 不得出現 `aps-environment`。

## Debug Lane Removal

同日移除整條 Debug automatic-sync lane：畫面上的 `AUTOMATIC SYNC (DEBUG)` 卡片、
獨立的 10 分鐘 policy 與 store、`scheduled-sync.debug` task identifier、前景測試
迴圈，以及只被該迴圈使用的 `runForegroundAutomatic()` 與 `automaticForeground`
trigger。`AutomaticSyncPolicy` 收斂成單一 cadence，Swift 端的 `Production` 前綴一併
拿掉。

- `automaticSyncProduction` 這個 `UserDefaults` prefix `維持原名`，避免已安裝的
  App 遺失使用者的 automatic sync 意圖。
- verify 新增反向 invariant：`apps/ios` 與 `project.yml` 不得再出現
  `scheduled-sync.debug`，`BGTaskSchedulerPermittedIdentifiers` 只能有一個項目。
- 代價：實機驗證 automatic sync 只剩「充電 + 每 30 分鐘」這條路，沒有 10 分鐘快
  路徑。這是明確接受的取捨。

## Remaining Acceptance

- Signed 實體 iPhone：背景 run 送出提示通知、刪除後撤回、拒絕授權時行為不變。
- App process 被系統終止後重開，背景 run 的 `Operation Log` 事件仍可回查。
- 500 筆上限的 compaction 與 clear 在實機長期使用下的表現。
