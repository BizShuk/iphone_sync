# Multi-Receiver Sync

## Scope

一部 iPhone 可配對多台 receiver (Mac / Windows)，每台各自選來源相簿。Receiver 端
protocol、manifest 與 pairing 不變；所有變更在 iOS。升級不做 migration，
既有單一配對需重新配對。

## Contract

- 每台 receiver 一個 `ReceiverProfile` (`receiverID`, `displayName`, `albums`,
  `pairedAt`, `lastConnectedAt`, `lastCompletedAt`) 與一個 Keychain account
  `paired-peer.<receiverID>`。
- `lastConnectedAt`：receiver 接受 session 時更新，UI 顯示為 `Last connected`。
- `lastCompletedAt`：該 receiver 的所有已選相簿都完成時更新。
- Sync run 逐台執行，`lastCompletedAt` 最舊者優先；單台失敗不中斷其他台；
  全部失敗才回報 run 失敗。Automatic sync 仍是單一 30 分鐘 lane。
- Album cursor 以 `(receiverID, albumID)` 為 key；ledger 仍以 `sourceBindingID` 為 key。
- Forget 單台只清該台的 secret、ledger binding、cursors 與 registry 紀錄；
  forget 最後一台才關閉 Automatic Sync 與 Delete After Sync。

## Delete After Sync

```
required(asset) = receivers whose selected albums contain asset
stale(r)        = now - (r.lastCompletedAt ?? r.pairedAt) >= 14 days
confirmed(asset)= receivers recorded in AssetBackupRegistry (same modificationDate)
eligible(asset) = required ∩ confirmed ≠ ∅  AND  (required − stale) ⊆ confirmed
```

- 一台 receiver 只有在其所有已選相簿都成功時才寫入 registry；確認跨 run 累積。
- 理由：iPhone 看不到 receiver 端的 Reset Source、換 destination 或解除配對，
  所以以 14 天未完成同步作為「該台已不再接收」的代理訊號；但永遠至少要有一台
  required receiver 持有該 asset。
- 新增 receiver 或變更相簿會撤回 pending deletion，下一輪重新評估。
- 其餘 (foreground 確認、background 只排隊 + 通知、`modificationDate` 檢查) 沿用
  [Delete After Sync spec](2026-07-27-delete-after-sync.md)。
