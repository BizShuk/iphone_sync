# Local Album Sync MVP Retrospective

Date: `2026-07-19`

Status: `Automated MVP verification complete; live-device acceptance pending`

## Delivered

- 原生 iOS 17+ foreground sender 與 macOS 14+ menu-bar receiver。
- 一個 Photos 相簿 → 一個 Finder destination 的單向增量備份。
- PhotoKit local-only original resource staging，固定 `isNetworkAccessAllowed = false`。
- Bonjour discovery、ephemeral Curve25519 + six-digit SAS pairing、Keychain trust 與 TLS 1.2 static PSK normal transport。
- 1 MiB framed chunks、16 MiB durable checkpoint、SwiftData manifest、SHA-256 verification 與 non-overwriting atomic commit。
- Source/album binding、wrong-PSK/proof、pairing expiry、malformed frame、resume、collision 與 integrity retry guards。

## Durable Decisions

- `project.yml` 是 Xcode project、Info.plist 與 entitlements 的 canonical source。直接編輯 generated plist/entitlement 會在下次 `xcodegen generate` 被覆寫。
- Normal transport 固定 TLS 1.2 `TLS_PSK_WITH_AES_128_GCM_SHA256`。開發期間在目前 Apple SDK/runtime 實測，public static-PSK API 強制 TLS 1.3 無法完成 handshake，因此沒有宣稱 TLS 1.3 或建立未加密 fallback。
- Mac Sandbox entitlement 必須同時包含 app sandbox、network client/server、user-selected read-write 與 app-scoped bookmark。
- Swift Testing 會並行執行 global tests；多個 in-memory SwiftData `ModelContainer` 同時初始化曾在 Core Data cached-model compression 觸發 `SIGSEGV`。所有 `MacReceiverKit` tests 現集中於 `@Suite(.serialized)`，其餘 protocol/crypto tests 保持並行。
- Cancel 不會提早把 UI 切回 ready；目前 resource 安全結束後，原同步 task 才恢復可再次同步。
- Pairing sheet 顯示 local timeout 與 mismatch feedback；dismiss 或 background 會取消 pending pairing channel。
- `PHFetchResult` 依 index 逐筆讀取 asset，不複製完整 asset inventory。

## Verification Evidence

開發環境：

```text
Xcode 26.5 (17F42)
XcodeGen 2.46.0
Apple Swift 6.3.2
```

Canonical command：

```bash
bash scripts/verify.sh
```

結果：

- Swift package：`32 tests in 1 suite`，全部通過。
- 為確認 SwiftData test isolation，另連續執行完整 package suite 五次，五次皆通過。
- `iPhoneSyncMac`：macOS clean unsigned build 通過。
- `iPhoneSyncIOS`：generic iOS Simulator clean unsigned build 通過。
- `iPhoneSyncIOS`：generic iOS device unsigned build 通過。
- Generated plist、Bonjour service declarations、Mac Sandbox entitlements、local-only source invariants 與 `git diff --check` 通過。

## Verification Boundary

`CODE_SIGNING_ALLOWED=NO` 只證明 source、target 與 platform compilation。這次沒有安裝到實體 iPhone、授予 Photos/Local Network 權限或使用真實 Photos library；Wi-Fi/Ethernet、iCloud-only resource、RAW/Live Photo/large video、sleep/VPN/router isolation 與 interruption behavior 仍須依 [../../README.todo](../../README.todo) 實機驗收。

本紀錄不包含照片 metadata、Finder destination、裝置識別碼、配對碼或 PSK。
