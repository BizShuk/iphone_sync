# 2026-08-04 Release CI — macOS + Windows

## 交付 (Delivered)

- `scripts/package-mac.sh`：macOS universal（arm64 + x86_64）Release 打包單一入口，產 `iPhoneSync-Mac-<version>.dmg`（app + `Applications` symlink 拖曳安裝）與 `iPhoneSync-Mac-<version>.pkg`（雙擊安裝到 /Applications）。預設 ad-hoc 簽章 + 完整 sandbox entitlements；`MAC_SIGN_IDENTITY` / `MAC_NOTARY_*` / `MAC_INSTALLER_IDENTITY` env 提供後同一腳本升級 Developer ID + notarization + stapling。
- `.github/workflows/release.yml` 取代 `release-windows.yml`：`macos`（SyncCore tests + package-mac.sh）與 `windows`（vitest + electron-builder NSIS/portable）平行 build，單一 `publish` job 把 `.dmg` / `.pkg` / `.exe` 掛上同一個 GitHub Release；`v*` tag = public、`workflow_dispatch` = draft。tag 版本 stamp 進 macOS `MARKETING_VERSION` 與 Windows `package.json`。
- `.gitignore` 加入 `build/`（`verify.sh` 與 packaging 輸出目錄）。

## 決策與教訓 (Decisions & Lessons)

- **單一 publish job**：兩個 workflow 對同一 tag 各自 create release 會 race；build jobs 只上傳 artifacts，publish job 統一發佈。
- **SSLCipherSuite 架構差異**：`SSLCipherSuite` 在 Intel macOS 是 `UInt32`、arm64/iOS 是 `UInt16`，`tls_ciphersuite_t(rawValue:)` 收 `UInt16`。`PSKTLSParameters.swift` 原寫法只能在 arm64 編譯；`verify.sh` 只 build 當前架構所以從未暴露，第一次 universal build 才失敗。以 `UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)` 正規化修復，named constant 保留讓 source invariant grep 不變。
- **Notary 失敗語意**：credentials 存在但 notarytool 失敗必須讓 build fail；只有 credentials 不存在才可跳過並輸出訊息。
- **驗證時不可用 pipe 吞 exit code**：`bash script | tail` 讓第一次 build failure 看起來 exit 0；背景執行要直接跑腳本本身。

## 驗證 (Verified)

本機 `bash scripts/package-mac.sh` 通過：`lipo -archs` = `x86_64 arm64`、`codesign --verify --deep --strict`、entitlements 含 app-sandbox、`hdiutil verify`、DMG 內容、`pkgutil --payload-files`、pkg min OS 14.0。canonical gate `scripts/verify.sh` 通過。CI 實跑與乾淨實機安裝驗收仍在 README.todo。
