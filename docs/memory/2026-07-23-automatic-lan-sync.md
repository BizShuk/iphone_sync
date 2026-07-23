# Automatic LAN Sync

`Date:` 2026-07-23

`Status:` Implemented；automated tests/builds/source invariants 已通過，signed physical-device background 與 Mac recovery behavior acceptance remains pending。

## Outcome

- iPhone 已配對後可 opt in `Automatic Sync`。每次 automatic run 重新以 Bonjour 尋找 exact paired `receiverID`，再建立 TLS-PSK connection；不保存 IP、`NWEndpoint` 或常駐 socket。
- Debug policy 的 request 最早為 `+10 minutes`，Release 最早為下一個 local midnight。兩者都是 `earliestBeginDate`，不代表 iOS 會準時執行。
- Lifecycle restore 會查詢同 identifier 的 pending request，保留相同或更早的 eligibility；Debug 已到期的 persisted request 不會因重進 App 再延後，foreground test 會立即嘗試。
- `Sync Now` 與 automatic handler 共用 `IOSSyncRuntime`，任一時間只允許一個 run。Release 同一 local day 已成功時，晚到或重複 handler 不再傳輸。
- `BGProcessingTask` registration 在 `iPhoneSyncApp.init()` 完成，adapter 固定於 main queue 管理 non-Sendable `BGTask`，並以 execution gate 保證 completion 只發生一次。
- Photos staging 改用 `requestData`；expiration 或 user cancellation 會呼叫 `cancelDataRequest`、關閉並刪除 partial staging file，同時取消 Bonjour 與 active `SyncClient`。
- Mac normal listener 具 capped retry，並於 wake、network path recovery 與 pairing 關閉後恢復；未驗證的 opening connection 有 15 秒 deadline。

## Durable Decisions

- 「同網路」的 gate 固定為 `iPhone Wi-Fi + paired Bonjour ID visible + TLS-PSK success`，不比較 SSID 或 subnet。
- Automatic intent 預設關閉；typed iOS `UserDefaults` 只保存 enablement、attempt/success/outcome 與 next eligible time。Pairing secret 仍在 Keychain。
- 關閉 Automatic intent 會取消 pending request 與 active automatic run，不刪除 pairing、selected albums 或 Mac manifest / partial。
- OS expiration、application budget 與 internal failure 會保存 outcome 並 bounded retry；Photos/albums/pairing/TLS 問題要求使用者處理，不自動 repair 或重新 pairing。
- Runtime 以 injected `IOSSyncRuntimeEnvironment` 提供 deterministic single-flight、cancellation 與 failure-classification tests。
- `UIBackgroundModes = processing` 與 permitted identifier 是 Info.plist declarations，不是 privacy prompt 或 entitlement。

## Verification

`bash scripts/verify.sh` 於 2026-07-23 最終通過：

- `51` 個 `SyncCore` / `MacReceiverKit` tests。
- `30` 個 iOS unit tests，包含 pending-request idempotence 與 elapsed Debug eligibility。
- unsigned macOS、generic iOS Simulator、`Release` generic iOS device builds。
- generated plist、sandbox entitlement、background-task、local-only、hard-cancellation 與 receiver-recovery invariants。
- tracked、staged 與 untracked whitespace checks。

另以 iPhone 17 Pro Simulator 啟動 App，確認 setup 畫面包含 disabled-by-prerequisite 的 opt-in switch、cadence、Background App Refresh 與 automatic diagnostics。

`receiver-recovery invariants` 主要是 source-string checks 加 unsigned compilation；valid-PSK half-open opening deadline 有 package behavior test，但 listener retry、wake/path 與 pairing recovery 尚無完整 behavior tests。iOS runtime tests 涵蓋 single-flight / cancellation，但不模擬 `BGProcessingTask` 的 OS launch、expiration、single completion 或 disable race。

## Remaining Acceptance

Simulator 與 unsigned build 不證明 iOS 會授予 background runtime。仍需 signed iPhone / Mac 驗證 simulated launch/expiration、same/different LAN、sleep/wake、listener recovery、large-resource resume 與 overnight actual-launch delay。
