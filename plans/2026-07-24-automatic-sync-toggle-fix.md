# Automatic Sync Toggle 修正計畫

## Context

目前未提交的 iOS automatic-sync redesign 在 `Debug` build 同時建立獨立的 `Debug` 與 `Production` scheduler：Debug 使用 `com.bizshuk.iphonesync.ios.scheduled-sync.debug`，Production 使用新建的 `...scheduled-sync.daily`。但 canonical `project.yml` 與產生的 `apps/ios/Info.plist` 仍只允許舊 identifier `com.bizshuk.iphonesync.ios.scheduled-sync`。

因此 Production toggle 提交 `BGProcessingTaskRequest` 時會收到 `BGTaskSchedulerErrorDomain` code `3`（identifier not permitted）；現有防禦邏輯隨即把 Production store 的 `isEnabled` 回滾為 `false`，表現為 toggle 無法保持開啟。Debug 看似正常不代表其 background request 正確：前景 10 分鐘測試 loop 與 registration/submission 差異可能掩蓋同一份 plist drift。

目標是修正 identifier contract，而不是移除錯誤回滾。Production scheduler 應重用既有正式 identifier，以延續舊版本 registration/pending request contract；只有 Debug scheduler 需要新增 identifier。

## Implementation

1. 在 `apps/ios/Tests/AutomaticSyncSchedulerTests.swift` 先建立 regression coverage：
   - Hosted iOS test 從 `Bundle.main` 讀取 `BGTaskSchedulerPermittedIdentifiers`，驗證實際 scheduler 使用的 Production legacy identifier 與 Debug identifier 都存在；目前應先失敗。
   - 擴充 `FakeAutomaticSyncRequestScheduler` 以注入 submit error，透過 `ensureScheduled()` 模擬 `BGTaskSchedulerErrorDomain` code `3`，鎖定現有正確行為：記錄 `.failed`、清除 `nextEligibleAt`、回滾 `isEnabled` 並取消該 identifier。

2. 在 `apps/ios/Sources/AutomaticSyncScheduler.swift` 與 `apps/ios/Sources/IOSAppModel.swift` 收斂 identifier ownership：
   - Production scheduler 改回使用既有 `AutomaticSyncScheduler.taskIdentifier` (`com.bizshuk.iphonesync.ios.scheduled-sync`)。
   - 保留獨立 `debugTaskIdentifier`；移除未發佈且不必要的 `dailyTaskIdentifier`。
   - 保留 code `3` rollback，不用 UI 假裝排程成功。
   - 在 `Release` 路徑不註冊或 reconcile 隱藏的 Debug scheduler，避免曾在 Debug store 開啟的 10 分鐘排程進入正式 build；`automaticSchedulerRegistered` 在 Debug 要求兩者成功，在 Release 只反映 Production registration。

3. 修正 canonical configuration：
   - 在 `project.yml` 的 `BGTaskSchedulerPermittedIdentifiers` 保留 legacy Production identifier並加入 Debug identifier。
   - 執行 `xcodegen generate`，讓 `apps/ios/Info.plist` 與 `iPhoneSync.xcodeproj/project.pbxproj` 由 canonical source 重新產生，不手改 generated files。

4. 更新 `scripts/verify.sh`：
   - 以集合方式驗證 plist 同時包含 Production 與 Debug identifiers，不再只驗證 index `0`。
   - 將舊單一 `automaticSync.nextEligibleAt` source invariant 改為目前雙 scheduler 的對應 invariant。
   - 保留既有 Debug unit tests與 Release generic-device compile gate。

5. 同步 automatic-sync canonical docs，使文件符合目前 redesign：
   - `README.md`
   - `CLAUDE.md`
   - `docs/specs/2026-07-23-automatic-lan-sync.md`
   - 說明 Debug build 額外顯示獨立 10 分鐘測試 scheduler、Production 使用可設定的每日本地時間；Release 不啟動 Debug scheduler；兩者仍只有 `earliestBeginDate`、不保證準時執行。
   - 不改動無關的 UI redesign、macOS 或 wire protocol 文件。

## Verification

1. 先執行新增的 targeted iOS tests，確認 plist regression test 在 config fix 前失敗、修正後通過。
2. 執行完整 `AutomaticSyncSchedulerTests` 與 `AutomaticSyncPolicyTests`。
3. 檢查產生後 `apps/ios/Info.plist` 的 permitted identifier 集合為 Production legacy + Debug。
4. 執行 `bash scripts/verify.sh`，確認 Swift package tests、iOS unit tests、macOS build、generic iOS Simulator build、`Release` generic iOS device build、plist/source invariants 與 whitespace checks 全部通過。
5. 最後檢查 working-tree diff，確保沒有覆寫目前既有的 UI redesign 修改；實機自然 background launch 仍屬既有 `README.todo` acceptance gate，不宣稱由 unsigned build 證明。

## Critical Files

- `project.yml`
- `apps/ios/Sources/AutomaticSyncScheduler.swift`
- `apps/ios/Sources/IOSAppModel.swift`
- `apps/ios/Tests/AutomaticSyncSchedulerTests.swift`
- `apps/ios/Info.plist`（generated）
- `iPhoneSync.xcodeproj/project.pbxproj`（generated）
- `scripts/verify.sh`
- `README.md`
- `CLAUDE.md`
- `docs/specs/2026-07-23-automatic-lan-sync.md`
