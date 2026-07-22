# Persistent Mac Settings

`Date:` 2026-07-22

## Decision

- 不建立單一 plaintext settings file；依資料敏感度與 owner 使用 Apple 原生持久層。
- `MacSettingsStore` 統一管理 sandbox `UserDefaults` 中的 `receiverID`、`sourceBindingID`、`destinationBookmark` 與 `launchAtLoginRequested`，並沿用前三個既有 keys。
- Paired peer PSK 與 opaque identity 留在 Keychain；album mappings、completed records 與 checkpoints 留在 SwiftData。
- `launchAtLoginRequested` 首次預設為 `true`，使用者關閉後保存 `false`；bootstrap 以此 reconcile `SMAppService.mainApp`。
- Setup window 與 status item geometry 使用 AppKit autosave。
- Pairing code、active connection、last summary 與 Setup bounded error list 維持 transient；敏感資料不寫入 preferences。

## Verified Runtime State

- App relaunch 前後 `receiverID` 維持 `41D0F1E1-9730-46D6-89B0-D6298DE9FA99`。
- App relaunch 前後 `sourceBindingID` 維持 `8DEBAFC7-6D0E-4FAA-9E7A-82CF32DCF491`。
- destination bookmark、paired-peer Keychain item 與 SwiftData store 均存在並在 relaunch 後載入。
- `launchAtLoginRequested = true`；App runtime 回報 `SMAppServiceStatus(rawValue: 1)`，Xcode SDK `SMAppService.h` 定義 raw value `1` 為 `SMAppServiceStatusEnabled`。
- receiver 以新 build 重新啟動，PID `25752`。

## Verification

- Isolated `MacSettingsStore` test 模擬第二個 store instance，確認 IDs、bookmark、launch intent 與 source reset behavior 持久化。
- `bash scripts/verify.sh` 通過：`48 tests`、unsigned macOS build、generic iOS Simulator build、generic iOS device build、settings/invariant checks 與 `git diff --check`。

## Remaining Acceptance

- 未擅自重新啟動使用者的 Mac；完整 logout/restart 後自動啟動與 Ready listener 驗收保留於 [../../README.todo](../../README.todo)。
