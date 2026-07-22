# Same-name Album Destination Folder

Date: `2026-07-22`

Status: `Automated verification complete; live-device acceptance pending`

## Delivered

- 使用者選擇的 Finder folder 現為接收根目錄；session 通過 source binding 後，Mac 先建立來源相簿同名子資料夾。
- `DestinationWriter` 將 final 與 partial resource 寫入 `<receiving-root>/<safe-album-name>/<year>/<month>/`。
- `AlbumFolderPolicy` 原樣保留一般相簿名稱；斜線、反斜線與控制字元替換為 `_`，前導 `.` 加上 `_`，空白名稱使用 `Untitled Album`。
- Manifest 的 `finalRelativePath` 以接收根目錄為基準並包含相簿資料夾名稱。
- 舊版 root-level `.partial` 會搬入相簿子資料夾並依 durable checkpoint 續傳；舊版 committed 檔案仍在原位置採納，不搬移或刪除。

## Durable Decisions

- 相簿資料夾只在 album/source binding 驗證成功後建立，錯誤來源不得在 destination 建立額外資料夾。
- 相簿名稱是已配對 iPhone 傳入的 path component，仍須做 traversal、symlink 與 hidden-path 防護。
- Add-only invariant 優先於資料夾整理；新結構不追溯搬移 committed user files。

## Verification Evidence

執行：

```bash
bash scripts/verify.sh
swift test --package-path packages/SyncCore
```

結果：

- 完整 canonical verification 通過：Swift package tests、macOS unsigned build、iOS Simulator unsigned build、generic iOS device unsigned build、plist/entitlement/source invariants 與 `git diff --check`。
- 最終 package suite 為 `36 tests in 1 suite`，涵蓋 same-name folder、unsafe album-name sanitization、round trip path、legacy partial migration 與 legacy committed adoption。

## Verification Boundary

尚未在實體 iPhone 與真實 Photos library 驗證 Finder 實際輸出；同名相簿資料夾的實機驗收保留於 [../../README.todo](../../README.todo)。
