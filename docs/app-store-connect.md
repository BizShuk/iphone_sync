# iPhone Sync — App Store Connect Worksheet

Submission target: iOS sender `iPhoneSyncIOS` only. macOS / Windows receivers ship
through GitHub Release and are out of scope for this submission.

Evidence date: 2026-08-12
Status: source-backed draft. 3 hard blockers open (see §7) — do not submit.

Canonical sources: `project.yml` (all bundle values), `appstore/` (public policy
artifacts), live URL probes. Public wording lives in `appstore/privacy.md` and must
not be forked here.

## 1. App Information

| 欄位 | 值 | 佐證 | 狀態 |
| --- | --- | --- | --- |
| Name (≤30) | `Photo Sync` (10) | `project.yml` iOS target `CFBundleDisplayName` / `CFBundleName`；`ContentView.swift` `navigationTitle` | ⚠️ 需在 App Store Connect 確認名稱未被佔用 |
| Subtitle (≤30) | `Album backup over your LAN` (26) | `README.md:354` | ✅ |
| Bundle ID | `com.shuk.iphonesync.ios` | `project.yml:69` | ✅ |
| SKU | `iphone-sync-ios` | 內部識別 | ✅ |
| Primary Language | English (U.S.) | 無 `.lproj` / `.xcstrings` | ✅ |
| Primary Category | Utilities | `project.yml:121` `LSApplicationCategoryType` = `public.app-category.utilities` | ✅ |
| Secondary Category | Photo & Video | 產品判斷 | ✅ |
| Age Rating | 4+ | 無 UGC 分享、廣告、IAP、web browser | ✅ |
| License Agreement | Apple Standard EULA | `appstore/copyright.html`；無 custom EULA | ✅ |
| Copyright | `2026 BizShuk` | `appstore/copyright.html` | ⚠️ legal rights holder 未確認 |
| Content Rights | 不含第三方內容 | 媒體全部來自使用者自有 Photo Library | ✅ |
| Trader Status (EU DSA) | 決定中 | legal entity 決定，不可代填 | ⚠️ |

## 2. Version Information (1.0.0)

| 欄位 | 值 | 佐證 | 狀態 |
| --- | --- | --- | --- |
| Version | `1.0.0` | `project.yml:73` `MARKETING_VERSION` | ✅ |
| Build | `2` | `project.yml:74` `CURRENT_PROJECT_VERSION` | ✅ 首次上傳可用 |
| Minimum OS | iOS 18.0 | `project.yml:24` `deploymentTarget` | ✅ |
| Device | iPhone only, Portrait only | `project.yml:75` `TARGETED_DEVICE_FAMILY: 1`、`:58-60` | ✅ |
| Promotional Text (≤170) | 153 字元，見下 | 描述 shipped 行為 | ✅ |
| Keywords (≤100) | 93 字元，見下 | — | ✅ |
| Description (≤4000) | 2213 字元，見下 | 只描述 shipped 功能 | ⚠️ 引用不可達的 release page |
| What's New | 留空 | 首次發佈 | ✅ |
| Privacy Policy URL | `https://bizshuk.github.io/pkg/iphone_sync/privacy.html` | 2026-08-12 curl `200` | ✅ |
| Support URL | `https://bizshuk.github.io/pkg/iphone_sync/index.html` | 2026-08-12 curl `200` | ✅ |
| Marketing URL | 同 Support URL | 2026-08-12 curl `200` | ✅ |

Promotional Text:

```text
Back up the albums you choose to a computer you own over Wi-Fi. Original resources only, verified by SHA-256, and nothing ever leaves your local network.
```

Keywords:

```text
backup,album,photo,video,local network,wifi transfer,originals,raw,live photo,offline,private
```

Description — canonical 全文見 `README.md` §5.2。送審前必須把「the project's
release page」換成實際可公開存取的 URL。

## 3. App Privacy

| 問題 | 答案 | 佐證 | 狀態 |
| --- | --- | --- | --- |
| Data collected? | `No, we do not collect data from this app` | source scan：無 analytics / ads / crash SDK；無開發者伺服器 request | ✅ |
| Tracking? | `No` | 無 ATT、無 IDFA、無第三方 SDK | ✅ |
| Photos collected? | No | 媒體只在使用者自選、自持的 receiver 之間傳輸 | ✅ |
| Third-party processors | 無 | 僅 Apple 平台服務（PhotoKit、Bonjour、Keychain、BackgroundTasks） | ✅ |
| Privacy manifest 一致性 | — | 無 `PrivacyInfo.xcprivacy` | ❌ 見 §7 |
| 政策一致性 | 一致 | `appstore/privacy.md` §1 已改為 iPhone-only + macOS/Windows receiver，名稱同步為 `Photo Sync` | ✅ 待重新發佈站台 |
| App 內 policy link | 有 | `ContentView.swift` `aboutZone` → privacy.html / index.html | ✅ |

## 4. Export Compliance

| 欄位 | 值 | 佐證 | 狀態 |
| --- | --- | --- | --- |
| `ITSAppUsesNonExemptEncryption` | `false` | `project.yml:38`（iOS）、`:120`（macOS） | ✅ 已內嵌，不會逐次詢問 |
| 使用的加密 | 全部由 OS 提供 | Network.framework TLS 1.2 PSK、CryptoKit Curve25519 / SHA-256 / HKDF、Security.framework Keychain | ✅ |
| 自行實作演算法 | 無 | EAR Category 5 Part 2 豁免 | ✅ |

## 5. Assets

送審前一律跑 `bash scripts/prepare-screenshots.sh`：移除 alpha channel（App Store
Connect 拒收帶 alpha 的截圖）並驗證尺寸。`--check` 只驗證不改檔，適合送審前 gate。

| 資產 | 規格 | 實測 | 狀態 |
| --- | --- | --- | --- |
| 6.9" `appstore/preview/iphone-page.png` | 1320×2868、無 alpha、Release 畫面 | 1320×2868、alpha 已移除；畫面仍是舊 Debug build（含 `AUTOMATIC SYNC (DEBUG)` 卡片、舊名稱） | ❌ 待重拍 |
| 6.9" `appstore/preview/iphone-operation-log.png` | 同上 | 1320×2868、alpha 已移除；內容來自 Debug build（三筆重複 scheduler 事件反映 debug + production 雙 scheduler） | ❌ 待重拍 |
| 6.5" `iphone-page-6.5.png` | 1284×2778 | 同 6.9"，alpha 已移除 | ❌ 待重拍 |
| 6.5" `iphone-operation-log-6.5.png` | 1284×2778 | 同 6.9"，alpha 已移除 | ❌ 待重拍 |
| App Icon `appstore/app-icon.png` | 1024×1024、不透明 | 1024×1024、hasAlpha no | ✅ |
| Bundled icon | asset catalog | `apps/ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` | ✅ |
| App Preview 影片 | 選填 | 未製作；腳本見 `README.md` §1 | ✅ 可略 |
| `appstore/preview/mac-receiver.png` | — | 666×362，非 App Store 尺寸，僅供 intro page；不受 prepare 腳本處理 | ✅ 不送審 |

重拍條件（Release build 已驗證此三點成立）：標題顯示 `Photo Sync`、
`AUTOMATIC SYNC (DEBUG)` 卡片不存在、底部出現 `About` 區的 Privacy Policy link。
需要在已配對 iPhone 上拍才會呈現 `Paired`／已選相簿的實際狀態。

## 6. App Review Information

Sign-in required：否。Demo account 留空。Contact 送審時直接填，不寫入 repo。

Notes 草稿見 `README.md` §5.6；送審前必須補上可公開存取的 receiver 下載 URL。

## 7. Pre-submission Gaps

| 項目 | 嚴重度 | 下一步 |
| --- | --- | --- |
| 截圖仍是舊 Debug build 畫面 | ❌ Guideline 2.3 | 用 Release build 在已配對 iPhone 重拍四張，再跑 `scripts/prepare-screenshots.sh` |
| 缺 `PrivacyInfo.xcprivacy` | ❌ ITMS-91053 | 宣告 `CA92.1`（`UserDefaults`，13 處）與 `C617.1`（`attributesOfItem`，`apps/ios/Sources/PhotoLibrarySource.swift:449`、`packages/SyncCore/Sources/SyncCore/SyncClient.swift:59`） |
| Receiver 下載 URL 不可公開存取 | ❌ Guideline 2.1 | `github.com/bizshuk/iphone_sync` releases API 回 404（repo 非公開）；改用可公開 URL 或公開 repo，再回填 description 與 review notes |
| 公開 policy 站台尚未重新發佈 | ⚠️ | `appstore/*.html` 已改名為 `Photo Sync`，但 `bizshuk.github.io` 上的頁面仍是舊版；送審前重新發佈並 curl 實測 |
| ASC API key / distribution 憑證未備 | ⚠️ | Keychain 只有 `Apple Development`；`DEVELOPMENT_TEAM` / `ASC_KEY_ID` / `ASC_ISSUER_ID` 皆未設定，`npm run release` 會在 archive 前失敗 |
| App Store Name 可用性未確認 | ⚠️ | `Photo Sync` 需在 App Store Connect 佔用時才知道是否唯一；備案：`Photo Sync LAN`、`LAN Album Backup` |
| Trader Status、legal rights holder | ⚠️ | 由 legal entity 決定 |
| macOS / Windows receiver 仍名為 `iPhone Sync` | ⚠️ | 不在 App Store 送審範圍（GitHub Release 散佈），但對外一致性上建議一併改名 |
| 實機驗收未完成 | ⚠️ | `README.todo`：signed device deletion、background launch、LAN failure matrix |

### 本輪已解決

- App 名稱移除 Apple 商標：`Photo Sync`（`CFBundleDisplayName` / `CFBundleName` /
  navigation title / extension 名稱同步；`PRODUCT_NAME` 維持 `iPhone Sync` 以免
  動到既有建置路徑與腳本）。Release simulator build 已驗證標題與 DEBUG 卡片狀態。
- 四張截圖的 alpha channel 已移除（RGB 逐點無損，僅圓角透明處落為黑色，
  深色 UI 上無可見差異）。
- iOS UI 新增 `About` 區，內含 Privacy Policy 與 Support 連結及版本號。
- `appstore/privacy.md` / `privacy.html` 裝置範圍改為 iPhone-only + macOS/Windows
  receiver，並與新名稱一致。
