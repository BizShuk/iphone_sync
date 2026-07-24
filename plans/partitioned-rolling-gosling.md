# Release Daily `.restore` 改用下一個設定時間

## Context

User 在 iOS 啟用 `Automatic Sync`，設定每日 `00:53` local，UI 卻顯示 `Next attempt: 20:34 (現在時間)` 而非明天 `00:53`。

根因：`AutomaticSyncPolicy.swift:73-75` 在 daily cadence 的 `.restore` 路徑刻意 `return now`，當今日尚未成功時把 `earliestBeginDate` 設成現在時間。這違反「Release request 最早為使用者設定的每日本地時間」的 canonical 契約，也跟 `.enabled` / `.completed` / `.needsAttention` 路徑不一致。

User 拍板：Release daily `.restore` 一律走 `nextDailyRun(now, hour:, minute:)`，不再回傳 `now`。Debug `.tenMinutes` 不動（其 persisted-elapsed 語意由 `restoredRequestDate` 獨立保留）。

## 變更清單

### 1. `apps/ios/Sources/AutomaticSyncPolicy.swift`（生產碼，1 處）

刪除 lines 73–75 的 `.restore → now()` 分支，讓 daily cadence 落到既有 `nextDailyRun`。

```swift
case .dailyAtLocalMidnight, .dailyAtLocalTime:
    if reason == .retry, !hasSuccessfulRunToday(lastSuccess, now: now) {
        return now.addingTimeInterval(Self.productionRetryInterval)
    }
    let components = dailyTimeComponents
    return nextDailyRun(after: now, hour: components.hour, minute: components.minute)
```

| Reason | 結果 |
|---|---|
| `.enabled` / `.completed` / `.needsAttention` | next configured local time（不變） |
| `.retry` 今日未成功 | `now + 1 hour`（不變） |
| `.retry` 今日已成功 | next configured local time（不變） |
| `.restore` | 一律 next configured local time（**改變**） |
| Debug `.tenMinutes` | `now + 10 minutes`（不變）；`restoredRequestDate` 仍保留 persisted date |

### 2. `apps/ios/Tests/AutomaticSyncPolicyTests.swift`（測試契約）

- 將 `testDailyCadenceRestoresImmediatelyUntilSuccessfulToday`（line 98–127）改寫為 `testDailyCadenceRestoresAtNextConfiguredLocalTimeRegardlessOfLastSuccess`，用 `(hour: 0, minute: 53)` 重現 user 情境（now = 7/23 20:34，期望 7/24 00:53）。
- 收緊 `testDailyRestoreIgnoresPersistedDateFromPreviousTimezone`（line 199–224）：`lastSuccess: nil`（走原本壞掉的 restore-now 路徑），明確 `XCTAssertNotEqual(restoredDate, now)` 與 `XCTAssertNotEqual(restoredDate, staleLosAngelesMidnight)`。
- Debug 系列三個測試不動。

### 3. `apps/ios/Tests/AutomaticSyncSchedulerTests.swift`（新增 scheduler 級覆蓋）

- `makeScheduler(...)` 加 `policy:` 參數，預設仍為 `.tenMinutes`（既有測試不需改）。
- 新增 `testDailyRestoreRecomputesElapsedEligibilityAtNextConfiguredLocalTime`：用 `.dailyAtLocalTime(hour: 0, minute: 53)` + gregorian LA calendar + 寫入 elapsed persisted date + 呼叫 `ensureScheduled()`，斷言 submit 的是 `7/24 00:53` 而非 `now` 或 elapsed date。

### 4. `apps/ios/Sources/AutomaticSyncScheduler.swift` / `IOSAppModel.swift` / `ContentView.swift` / SyncCore

不需修改。`Next attempt` 字串保留（spec 已自帶 hedge：「`Eligible after` 只呈現 submitted request 的 earliest date，不得解讀為 guaranteed next run」）。

### 5. `CLAUDE.md`（一句話補述）

在 line 9 現有的 reconcile 段落補一句，明確 Release restore 一律使用下一個設定時間：

> App lifecycle reconcile 會查詢既有 pending request，保留相同或更早的 eligibility；Release restore 重新計算 desired eligibility 時一律使用下一個使用者設定的本地時間，不因本日尚未成功而改用 now；Debug 保存的 eligibility 已到期時不會因重進 App 再延後 10 分鐘，foreground test 會立即嘗試。

### 6. spec / plan / README

- `docs/specs/2026-07-23-automatic-lan-sync.md` 已自帶 hedge，不需改。
- `plans/2026-07-23-automatic-lan-sync.md` 未明文承諾 restore-now，不需改。
- `README.md`、`apps/ios/README.md`、`docs/memory/2026-07-23-automatic-lan-sync.md`、`README.todo` 所有 restore-immediately 語意皆為 Debug-only，不需改。

## 驗證

```bash
# 1. 鎖定 iOS simulator，跑改寫後的 policy 與 scheduler 測試
IOS_TEST_DEVICE_ID="$(
    xcrun simctl list devices available -j \
        | jq -r '[.devices[][] | select(.isAvailable and (.name | startswith("iPhone")))] | first | .udid // empty'
)"
test -n "$IOS_TEST_DEVICE_ID"

xcodebuild -quiet \
    -project iPhoneSync.xcodeproj \
    -scheme iPhoneSyncIOS \
    -destination "platform=iOS Simulator,id=$IOS_TEST_DEVICE_ID" \
    -only-testing:iPhoneSyncIOSTests/AutomaticSyncPolicyTests \
    -only-testing:iPhoneSyncIOSTests/AutomaticSyncSchedulerTests \
    CODE_SIGNING_ALLOWED=NO \
    test
```

預期結果（修改前）：

- `testDailyCadenceRestoresAtNextConfiguredLocalTimeRegardlessOfLastSuccess` FAIL（前兩斷言拿 `now` 而非 7/24 00:53）
- `testDailyRestoreIgnoresPersistedDateFromPreviousTimezone` FAIL（`restoredDate == now`）
- `testDailyRestoreRecomputesElapsedEligibilityAtNextConfiguredLocalTime` FAIL

修改後三個測試全 PASS，`testDailyCadenceRetriesInOneHourUntilSuccessfulToday` 與 Debug 三個 restore 測試維持 PASS。

```bash
# 2. 完整 canonical gate
bash scripts/verify.sh
```

`verify.sh` 會跑 `xcodegen generate` 與三種 build；動工前後看 `git status --short` 與 `git diff --check` 確認 working tree 既有修改未被破壞。

## 風險

- `.retry` 分支必須留在 daily fallthrough 之前，否則 one-hour retry 變 next-day retry。`testDailyCadenceRetriesInOneHourUntilSuccessfulToday` 把關。
- 不得將 daily 與 `.tenMinutes` restore 邏輯合併；Debug 故意保留 elapsed persisted date。
- `nextDailyRun` 的 `todayRun <= now` 比較會把「等於 now」視為已過期、排到明天。屬既有契約，不在本次範圍。
- `scripts/verify.sh` 跑 `xcodegen` 後檢查 `git status --short`，避免生成檔覆蓋既有 uncommitted 變更。
