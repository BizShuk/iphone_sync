# Multi-Receiver Sync — Implementation Plan

## Context

目前 iPhone 只能配對 `一台` receiver (Mac / Windows), 相簿選取是全域的, `Delete After Sync` 只看單一 receiver 的單次 run. 使用者要:

1. 一部 iPhone 配對 `多台` receiver, 每台各自選相簿.
2. 刪除條件: 一個 asset 必須被 `所有應該收到它的 receiver` 確認後, 才成為刪除候選並通知 (逐 asset 跨 run 累積).
3. 某台 receiver 連續 `14 天` 沒有完成同步 (iPhone 無法得知 receiver 端已 Reset Source / 換 destination / 解除配對), 對於 `至少已有一台其他 receiver 確認` 的 asset 就不再等它.
4. iPhone 上每台 receiver 顯示 host icon 與 `last connection time`.

Receiver 端 (macOS / Windows / MacReceiverKit / SyncCore.Windows) `不需改動`: 每台本來就有獨立的 `receiverID`, PSK, `sourceBindingID`, 並接受 iPhone 送來的任何 album. 變更全部在 iOS.

依 global principle 不做 migration: 升級後既有配對與相簿選取失效, 使用者需重新配對一次.

## Data Model (iOS)

| State | Owner (new / changed) | Persistence |
|---|---|---|
| 每台 receiver 的 `PairedPeer` | `ReceiverProfileStore` | Keychain account `paired-peer.<receiverID>` |
| 每台 receiver 的 profile: `receiverID`, `displayName`, `albums: [PhotoAlbum]`, `pairedAt`, `lastConnectedAt`, `lastCompletedAt` | `ReceiverProfileStore` | UserDefaults key `receiverProfiles` (JSON array) |
| 每個 asset 已被哪些 receiver 確認 `{assetID, modificationDate, receiverIDs}` | `AssetBackupRegistry` (new) | App container JSON `SyncedResources/asset-backups.json` |
| Album cursor | `AlbumSyncCursorStore` | key 改為 `(receiverID, albumID)` |
| Ledger | `SyncedResourceLedger` | 已以 `sourceBindingID` 為 key; 新增 `forget(sourceBindingID:)` |

- `lastConnectedAt`: TLS session `.accepted` 時更新, UI 顯示用.
- `lastCompletedAt`: 該 receiver 的所有已選相簿 pass 都成功時更新, staleness 判定用. 從未完成時以 `pairedAt` 為基準.
- 移除 `AlbumSelectionStore` 與全域 `selectedPhotoAlbums` key; `IOSAppModel.pairedPeer` 改為 `receivers: [ReceiverProfile]`.

## Deletion Eligibility (pure policy, 單獨檔案 `DeletionEligibilityPolicy.swift`)

```
required(asset) = { r ∈ profiles | r.albums ∩ albumsContaining(asset) ≠ ∅ }
stale(r)        = now - (r.lastCompletedAt ?? r.pairedAt) >= 14 days
confirmed(asset)= registry[asset].receiverIDs   (modificationDate 相同才算)
eligible(asset) = confirmed ≠ ∅  AND  (required − stale) ⊆ confirmed
```

- 相簿只設定在一台 receiver 時, 該台就是唯一 required; 它 stale 時 `confirmed ≠ ∅` 仍要求它曾確認過, 所以不會誤刪.
- `albumsContaining` 由 `PhotoLibrarySource` 新增的 `albumIDs(containing assetIDs:)` (`PHAssetCollection.fetchAssetCollectionsContaining`) 提供, 只在評估時查.
- Registry 寫入規則: 單一 receiver 的 run 全部相簿成功後, 以既有 `PhotoDeletionCandidateAccumulator` (該 receiver 內跨相簿 AND merge) 的 eligible 結果, 把 `receiverID` 加入 registry. 任一相簿失敗 / cancel / expiration -> 該 receiver 本輪不寫入. `modificationDate` 不同則該 entry 重置.
- Forget receiver: 從 registry 移除該 `receiverID`, 清該 binding 的 ledger 與該 receiver 的 cursors, 刪 Keychain item; 其他 receiver 不受影響. `Forget` 不再一律關閉 `Delete After Sync` 與 automatic sync, 只在最後一台被 forget 時才關閉並清 pending.
- 刪除 / resolve 後的 asset 從 registry 移除.

## Sync Run Flow

- `IOSSyncCoordinator.syncTransfer` 改為依 profiles 逐台執行, 排序 `lastCompletedAt` 最舊者優先 (背景 window 被中止時輪流前進). 每台: `discoverReceiver(id:)` -> 跑該台的 albums -> 更新 profile 時間 -> registry 寫入. 單台 `macNotFound` / 失敗不中斷其他台.
- 全部 receiver 跑完後, `IOSPostSyncDeletionController` 以 policy 從 registry 算出 eligible candidates, 沿用既有 foreground delete / background enqueue + `PendingDeletionNotifier` 流程.
- `IOSSyncRuntime` outcome 彙總: 至少一台 completed -> `.completed` / `.noChanges`; 全部不可見 -> `.deferred(.macUnavailable)`; expiration 仍是 `.budgetExhausted` (回報 success). Prerequisite 改為 `至少一台 receiver 有選相簿`.
- Automatic sync 仍是 `單一 lane` 30 分鐘, 不新增 task identifier.
- 配對: 新 receiver 新增 profile; 同 `receiverID` 重新配對則取代該 profile 的 peer, 保留 albums.

## UI (`ContentView`, `AlbumPickerView`)

- Receiver 清單: 每列 host icon (`laptopcomputer`), `displayName`, `Last connected <relative time>` (從未連線顯示 `Never`), 相簿摘要, `Choose Albums`, `Forget`.
- stale (>= 14 天) 時加標示 `Not synced for 14+ days — skipped in deletion check when another receiver has the photo`.
- `Add Receiver` 按鈕進入既有 `findMac()` / pairing 流程 (已配對時也可再找新的); `Sync Now` 一次同步全部.
- Operation log 事件帶 receiver `displayName`, 不含 identity / PSK / binding.

## Critical Files

- 新增: `apps/ios/Sources/ReceiverProfileStore.swift`, `AssetBackupRegistry.swift`, `DeletionEligibilityPolicy.swift`
- 移除: `apps/ios/Sources/AlbumSelectionStore.swift`
- 修改: `apps/ios/Sources/IOSSyncCoordinator.swift`, `IOSSyncRuntime.swift`, `DeleteAfterSync.swift`, `AlbumSyncCursorStore.swift`, `SyncedResourceLedger.swift`, `PhotoLibrarySource.swift`, `IOSAppModel.swift`, `ContentView.swift`, `AlbumPickerView.swift`
- 可重用: `PhotoDeletionCandidateAccumulator`, `discoverReceiverWithRetry`, `PendingDeletionNotifier`, `KeychainSecretStore`, `PairingClient`
- 文件: 新 spec `docs/specs/2026-11-18-multi-receiver.md`; 更新 `AGENTS.md` (Product Invariants "一部 iPhone 與一部 Mac" 改為多 receiver, Runtime Ownership 表, Delete After Sync 段), `README.md` domain flow, `docs/specs/2026-07-27-delete-after-sync.md` 標註被新 spec 取代的條目; `scripts/verify.sh` 若 grep 單一 `paired-peer` 或 `selectedPhotoAlbums` 則同步更新.

## Tests (`apps/ios/Tests`)

- `DeletionEligibilityPolicyTests`: 兩台都需要 / 只一台確認 -> 不可刪; 一台 stale + 另一台確認 -> 可刪; 唯一 required 且 stale 且未確認 -> 不可刪; modificationDate 改變 -> 不可刪; asset 只在一台的相簿 -> 只需該台.
- `AssetBackupRegistryTests`: 持久化還原, forget receiver, modificationDate 重置.
- `ReceiverProfileStoreTests`: 新增 / 取代 / forget 只影響單台, Keychain account 隔離.
- `AlbumSyncCursorStoreTests`: cursor 以 `(receiverID, albumID)` 隔離.
- `IOSSyncRuntimeTests`: 一台不可見一台成功 -> `.completed`; 全部不可見 -> `.deferred`.
- 既有 `DeleteAfterSyncTests` 改走 registry + policy.

## Verification

1. `bash scripts/verify.sh` -> 所有 Swift / iOS / Windows tests 與 invariants 通過.
2. `npm run dev:ios` (iPhone 17 Pro Max simulator) -> 首頁顯示 receiver 清單與 `Add Receiver`, 每列有 host icon 與 `Last connected Never`.
3. 實機: Mac 跑 `npm run dev:mac`, Windows 跑 `npm run dev:windows`, iPhone 分別配對並各選不同相簿 -> `Sync Now` 後兩邊 destination 各自只出現自己選的相簿, 兩列 `Last connected` 更新.
4. 開 `Delete After Sync`, 同一相簿設定在兩台, 關掉 Windows receiver 後 `Sync Now` -> 不出現刪除提示; 開回 Windows 再 `Sync Now` -> 出現 `Delete N Synced Photos`.
