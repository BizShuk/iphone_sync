# iPhone Sync — Windows 11 Receiver

Electron 32 + Node.js 22 desktop receiver. Mirrors the macOS menu-bar
receiver's behaviour so the iPhone Sync iOS app can pair with either a Mac
or a Windows 11 machine without any change on the iOS side.

## Status

Skeleton only (Phase 1). Pairing, discovery, TLS-PSK transport, manifest,
destination writer, and full UI are scheduled in
[Phase 2–7 of the plan](../plans/2026-07-25-windows-11-desktop-receiver.md).

## Daily Flow

1. Launch the installed app. The icon appears in the Windows system tray.
2. Open **Setup** from the tray menu.
3. Click **Choose Destination** and pick a folder. The path is saved to
   `%LOCALAPPDATA%\iPhoneSync\settings.json`.
4. Click **Pair iPhone**. The pairing window shows a six-digit SAS with a
   two-minute countdown.
5. On the iPhone, open iPhone Sync → Mac → **Find Mac**, choose the Windows
   receiver, and enter the SAS. Pairing is complete.
6. Trigger **Sync Now** on the iPhone. Files are written to
   `<destination>\iPhoneSync\<album>\<year>\<month>\<file>`.

## Storage Modes

| Mode | Path |
|---|---|
| `Album / Year / Month` (default) | `<destination>\iPhoneSync\<album>\<year>\<month>\<file>` |
| `Album` | `<destination>\iPhoneSync\<album>\<file>` |
| `Single Folder` | `<destination>\iPhoneSync\<file>` |

## Launch at Login

Controlled by the toggle in the Setup window. Internally uses Electron's
`app.setLoginItemSettings({ openAtLogin: true, openAsHidden: true })`, which
registers an entry under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

## Network Gate

The Windows 11 receiver publishes `_iphonesync._tcp` and
`_iphonesync-pair._tcp` over `multicast-dns`. iPhone Sync on the iOS side
browses the same service types and connects via
`TLS_PSK_WITH_AES_128_GCM_SHA256`. The first time the app runs, Windows
Firewall prompts the user to allow the inbound connection — accept it.

## Operation Log

In-memory 500 entries, mirrored to
`%LOCALAPPDATA%\iPhoneSync\logs\operations-<YYYY-MM-DD>.jsonl`. The Setup
window supports **Copy All** and **Clear**.

## Build

```bash
# from repo root — works on any host (macOS / Linux / Windows)
(cd packages/SyncCore.Windows && npm ci && npm test && npm run build)
(cd apps/windows && npm ci && npm run build)

# Windows-only: produce NSIS installer + portable .exe.
# NOTE: electron-builder invokes the Windows `signtool` binary; this step
# only works on Windows hosts because the macOS / Linux `app-builder-bin`
# cannot execute Windows native signing tools.
(cd apps/windows && npm run dist)
```

`scripts/verify-windows.sh` runs the build + tests on macOS / Linux / Windows
MSYS, and only invokes `npm run dist` on Windows MSYS shells.

## Architecture

`apps/windows/src/main/` mirrors `apps/macos/Sources/`:
- `main.ts` ≈ `iPhoneSyncMacApp.swift` + `MacAppDelegate`
- `model-root.ts` ≈ `MacAppModel.swift`
- `tray.ts` ≈ `NSStatusItem` setup
- `setup-window.ts` / `setup.html` ≈ `SetupView.swift`
- `pairing-window.ts` / `pairing.html` ≈ `PairingCodeDisplay`
- `auto-launch.ts` ≈ `SMAppService.mainApp`
- `recovery.ts` ≈ `NWPathMonitor` + `NSWorkspace.didWake`

`packages/SyncCore.Windows/src/` mirrors `packages/SyncCore/Sources/`:
- `protocol/` ≈ `SyncCore/{SyncConstants,FrameCodec,FramedConnection,SyncMessage}.swift`
- `crypto/` ≈ `SyncCore/{PairingCrypto,FileHasher,PSKTLSParameters}.swift`
- `discovery/` ≈ `BonjourDiscovery.swift`
- `pairing/` ≈ `PairingServer.swift`
- `receiver/` ≈ `MacReceiverKit/*.swift`
- `persistence/` ≈ `MacSettingsStore` + `DestinationBookmarkStore` + `KeychainSecretStore`
- `logging/` ≈ `OperationLog.swift`

## Wire Protocol

Identical to the macOS receiver. `protocolVersion = 1`; the iOS sender is
unchanged. See `packages/SyncCore.Windows/src/protocol/constants.ts` for the
single source of truth and `plans/2026-07-25-windows-11-desktop-receiver.md`
for the rationale.
