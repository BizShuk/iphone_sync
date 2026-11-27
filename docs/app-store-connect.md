# Photo Sync (iphone_sync) — App Store Connect Worksheet

Evidence date: 2026-11-27
Status: build 4 uploaded & metadata updated; pending build attachment, Release screenshots, and China compliance forms.

## 1. App Store Connect Parameters

| 欄位 | 值 | 佐證 / 備註 |
| --- | --- | --- |
| ASC App ID | `6800669029` | App Store Connect `/apps/6800669029` |
| Bundle ID | `com.shuk.iphonesync.ios` | `project.yml` (`iPhoneSyncIOS`) |
| SKU | `com.shuk.iphonesync.ios` | App Store Connect |
| App Name (≤30) | `Photo Sync 5` | 若衝突則保留 `Photo Sync` 改綴字 |
| Subtitle (≤30) | `Sync album to pc daily` | App Store Connect |
| Primary / Secondary Category | `UTILITIES / PHOTO_AND_VIDEO` | `LSApplicationCategoryType = public.app-category.utilities` |
| Age Rating | `4+` (`sharedLocation: false`, `datingAndRelationships: false`) | 已更新於 ASC |
| Content Rights | `DOES_NOT_USE_THIRD_PARTY_CONTENT` | Media originates from user's Photo Library |
| Copyright | `Copyright © 2026 BizShuk` | 與 `appstore/copyright.html` 一致 |
| License | `Apple Standard EULA` | — |
| EU DSA Trader Status | `Confirmed` | 已於 `https://appstoreconnect.apple.com/business` 完成 |

## 2. Version & Build Parameters

| 欄位 | 值 | 佐證 / 備註 |
| --- | --- | --- |
| Version / Build | `1.0.0 (4)` | `MARKETING_VERSION = 1.0.0`, build `4` (`VALID` in ASC, 待掛載至版本 1.0.0) |
| Minimum OS | `iOS 18.0` | `project.yml` `deploymentTarget` |
| Privacy Policy URL | `https://bizshuk.github.io/pkg/copyright/iphone_sync/privacy.html` | HTTP 200（canonical: `https://bizshuk.github.io/pkg/iphone_sync/privacy.html`） |
| Support / Marketing URL | `https://bizshuk.github.io/pkg/copyright/iphone_sync/index.html` | HTTP 200（canonical: `https://bizshuk.github.io/pkg/iphone_sync/index.html`） |
| Copyright URL | `https://bizshuk.github.io/pkg/copyright/iphone_sync/copyright.html` | HTTP 200（canonical: `https://bizshuk.github.io/pkg/iphone_sync/copyright.html`） |
| Central Issue Tracker | `https://github.com/bizshuk/bizshuk.github.io/issues` | — |
| Keywords (≤100) | `backup,album,photo,video,local network,wifi transfer,originals,raw,live photo,offline,private` | 93 字元 |
| Promotional Text (≤170) | `Back up the albums you choose to a computer you own over Wi-Fi. Original resources only, verified by SHA-256, and nothing ever leaves your local network.` | 153 字元 |

## 3. Compliance & Security Parameters

| 項目 | 值 | 佐證 / 備註 |
| --- | --- | --- |
| `ITSAppUsesNonExemptEncryption` | `false` | `project.yml` (僅使用 OS Network.framework TLS 1.2 PSK / CryptoKit / Security) |
| `PrivacyInfo.xcprivacy` | `apps/ios/Sources/PrivacyInfo.xcprivacy` | 宣告 `CA92.1` (`UserDefaults`) 與 `C617.1` (`FileTimestamp`) |
| 中國大陸安全性評估 (`SECURITYASF395E`) | `否` | 尚待於 ASC 合規頁填入 |
| 中國大陸 AIGC 聲明 (`AIGENERATEFD1DE`) | `否` | 尚待於 ASC 合規頁填入 |

## 4. App Review Parameters

| 項目 | 值 |
| --- | --- |
| Sign-in required | `false`（無帳號，LAN Bonjour + 6 位數配對碼） |
| Tested devices / OS | iPhone 17 Pro Max Simulator, paired physical iPhone (iOS 18+) |
| External services | None (local Wi-Fi Bonjour + user-owned Mac/Windows receiver from `https://github.com/BizShuk/iphone_sync/releases/latest`) |
| Regional behavior | Consistent across all regions; no regulated industry |
| Attachment | 選填（若審查員無第二台電腦，可附 Mac receiver 配對同步 demo 影片） |

## Privacy Policy

- Public introduction: `https://bizshuk.github.io/pkg/copyright/iphone_sync/index.html`
- Privacy Policy URL: `https://bizshuk.github.io/pkg/copyright/iphone_sync/privacy.html`
- Copyright URL: `https://bizshuk.github.io/pkg/copyright/iphone_sync/copyright.html`
- In-app link: `apps/ios/Sources/ContentView.swift` (`aboutZone` -> `Privacy Policy` & `Support`).

## Privacy Choices

- Album selection, local pairing, forgetting a receiver, optional Delete After Sync (default-off), and app uninstall.

## App Privacy

- Answer in ASC: `Data Not Collected`, `Tracking: No` (待於網頁端確認發布).

## Privacy Manifest

- `apps/ios/Sources/PrivacyInfo.xcprivacy` declares `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`) and `NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`), with `NSPrivacyTracking = false`.

## Support

- Support URL: `https://bizshuk.github.io/pkg/copyright/iphone_sync/index.html`
- Central issue tracker: `https://github.com/bizshuk/bizshuk.github.io/issues`

## Copyright

- `Copyright © 2026 BizShuk` (`appstore/copyright.html`).

## Content Rights

- All media originates from the user's own Photo Library; no third-party content bundled.

## License

- Apple Standard Licensed Application End User License Agreement (`appstore/copyright.html`).

## Account Deletion

- Not applicable: Photo Sync creates no developer-operated account.
