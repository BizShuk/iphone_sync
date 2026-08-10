# Release CI — macOS + Windows 一鍵安裝發佈

## 目標 (Goal)

一個 `v*` tag（或 `workflow_dispatch` draft）同時打包 macOS 與 Windows receiver 的一鍵安裝物，發佈到同一個 GitHub Release，使用者只需從 Release 頁面下載安裝。

## 決策 (Decisions)

| 議題 | 決策 | 理由 |
|---|---|---|
| Workflow 形態 | 單一 `.github/workflows/release.yml`：`macos` + `windows` build jobs → 單一 `publish` job | 兩個 workflow 對同一 tag 各自建立 Release 會 race；單一 publish job 確定性掛上全部資產 |
| macOS 產物 | `iPhoneSync-Mac-<version>.dmg`（拖曳安裝）+ `iPhoneSync-Mac-<version>.pkg`（雙擊安裝到 /Applications） | PKG 是 macOS 最接近 NSIS installer 的一鍵安裝；DMG 是慣例散佈形態，對應 Windows 的 installer + portable 雙產物 |
| macOS build | universal（arm64 + x86_64）Release，`generic/platform=macOS` | 部署目標 macOS 14+ 含 Intel 機種 |
| macOS 簽章 | 預設 ad-hoc（`--sign -`）+ 完整 sandbox entitlements；`MAC_SIGN_IDENTITY` / `MAC_NOTARY_*` / `MAC_INSTALLER_IDENTITY` env 提供後同一腳本升級 Developer ID + notarization + stapling | 簽署與公證方式尚未定案（README.todo）；CI 不依賴 secrets 即可運作，secrets 加入後不需改腳本 |
| 腳本歸屬 | `scripts/package-mac.sh` 為本機與 CI 共用單一入口 | 與 `verify.sh` 同哲學：CI 只是呼叫者，流程可在本機完整重現 |
| 版本 stamp | tag `vX.Y.Z` → macOS `MARKETING_VERSION=X.Y.Z` + `CFBundleVersion=run_number`；Windows `npm version X.Y.Z --no-git-tag-version` | Release 資產檔名與 bundle version 對應 tag，兩端一致 |
| Notary 失敗語意 | credentials 存在但 notarytool 失敗 → build fail；credentials 不存在 → 明確訊息後跳過 | 公證失敗不得被「跳過」訊息吞掉 |

## 附帶修正 (Side Fix)

`packages/SyncCore/Sources/SyncCore/PSKTLSParameters.swift`：`SSLCipherSuite` 在 Intel macOS 是 `UInt32`、arm64/iOS 是 `UInt16`，`tls_ciphersuite_t(rawValue:)` 需要 `UInt16`。原始碼只能在 arm64 編譯（`verify.sh` 只 build 當前架構所以未暴露）；以 `UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)` 正規化後 universal build 通過，named constant 保留給 `verify.sh` 的 source invariant grep。

## 驗證 (Verification)

- 本機執行 `bash scripts/package-mac.sh`：universal binary（`lipo -archs` = `x86_64 arm64`）、`codesign --verify --deep --strict` 通過、entitlements 含 app-sandbox、`hdiutil verify` 通過、DMG 內含 app + `Applications` symlink、`pkgutil --payload-files` 含完整 bundle、pkg min OS 14.0。
- `ruby -ryaml` 驗證 workflow YAML。
- `bash scripts/verify.sh` canonical gate。
- CI 實跑（`workflow_dispatch` → draft release）留待 push 後執行，見 README.todo 打包與發佈段。

## 已知邊界 (Boundaries)

- 未設定 secrets 時 mac 產物為 ad-hoc：首次開啟需 Gatekeeper bypass（macOS 15+ 需「系統設定 → 隱私權與安全性 → 強制打開」）。
- Windows 產物未簽 Authenticode，SmartScreen 可能警告。
- `publish` job 下載完整 windows artifact（含 win-unpacked debug 檔），只發佈頂層 `.exe` / `.dmg` / `.pkg`。
