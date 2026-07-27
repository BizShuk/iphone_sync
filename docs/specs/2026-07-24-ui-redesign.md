# iPhone Sync UI Redesign Spec

Status: `Proposal — design lead draft, pending user review and acceptance before implementation`

Date: `2026-07-24`

Scope: `Visual + interaction redesign of iPhoneSyncIOS and iPhoneSyncMac SwiftUI surfaces, without changing SyncCore / MacReceiverKit contracts or the wire protocol.`

Later extension: `2026-07-27` 的 [Delete After Sync 規格](2026-07-27-delete-after-sync.md) 在 iOS main view 新增獨立 `AFTER SYNC` destructive card；仍不改 wire protocol、receiver contract 或 entitlement，但 foreground deletion 會使用既有 Photos `.readWrite` authorization 的 system change confirmation。

## 1. Design Thesis

A wire-quiet signal.

The product is a personal, LAN-only photo backup tool. It lives in the menu bar, runs in the background, and only surfaces for setup, pairing, and a few seconds of sync progress. Cloud services shout (badges, notifications, gradients, brand color). This app should feel like a piece of office equipment: present, calm, never demanding attention.

The visual identity is derived from the subject's own materials:

- The wire (LAN cable, network frame, chunk boundary)
- The pairing code (six literal digits, the only numeric artifact a user reads)
- The directory tree (`iPhoneSync/Year/Month/`)
- The cryptographic primitives (SHA-256 hex digest, monospaced protocol names)

Not from cloud-app aesthetics, not from generic "developer tool" SF Symbol lookups, and not from any of the three AI-default looks (cream + terracotta, near-black + acid green, broadsheet hairlines).

## 2. Color Tokens

The light and dark modes are both first-class. Token names are stable across modes.

| Token | Light | Dark | Purpose |
|---|---|---|---|
| `wire` | `#1F2024` | `#E8E9EE` | Primary text, monospaced pairing code |
| `paper` | `#FAFBFC` | `#101113` | Card / form background |
| `frame` | `#E2E4E8` | `#26282C` | Hairline borders, separators, progress tracks |
| `signal` | `#FF6B35` | `#FF8559` | Accent — only on connection, active state, primary action |
| `verified` | `#3F8C5E` | `#5BA579` | Success / committed |
| `alert` | `#C84B3F` | `#E16B5F` | Errors, warnings |

Why this is not one of the three AI defaults:

- Not cream + terracotta. Base is paper-white / ink, not cream. Accent is signal-orange, not terracotta.
- Not near-black + acid green. Light mode is primary; accent is warm mid-saturation, not acid.
- Not broadsheet hairlines. Hairlines are functional (frame separators, progress tracks), not decorative. List density is software density.

Why the warm signal-orange `#FF6B35`: it reads as the LED on a network patch panel. iCloud uses blue gradients; we deliberately avoid that — this is a wired LAN, not the cloud.

Implementation: define once in `Theme/Tokens.swift` shared between both app targets. Use `Color("Wire")` asset catalog entries for light and dark variants, then expose `Tokens.wire` etc.

## 3. Typography

All three faces are Apple system fonts — no external dependency, no license risk, no font-loading code.

| Role | Face | Weight | Size (pt) | Use |
|---|---|---|---|---|
| Display title | SF Pro Rounded | Semibold | 28 | Page headings, Mac Setup title |
| Numeric display | SF Mono | Regular | 56 | Pairing code (signature element) |
| Section header | SF Pro Text | Medium | 13 | `Photos`, `Mac`, `Backup`, `Operation Log`, with letter-spacing +0.5 |
| Body | SF Pro Text | Regular | 15 | Default |
| Callout | SF Pro Text | Regular | 14 | Operation Log messages |
| Caption | SF Pro Text | Regular | 12 | Helper text, dates in lists |
| Numeric data | SF Mono | Medium | 13 | Counters, byte counts, device ID, hash prefixes |

Monospace earns its keep — there are real numeric identities in this product (pairing code, chunk offset, content hash prefix, byte counts). Pairing `SF Mono` with `SF Pro Rounded` for the page title creates a deliberate voice: friendly chrome around hard numeric ground truth.

## 4. Layout

### iOS Main (`ContentView`)

Reorganize the current `List` into three vertical zones. Keep `Form`/`List` containers but apply deliberate spacing and a custom card component for the wire strip.

```text
┌─ iPhone Sync ──────────────────────────────┐
│                                            │
│  Source                                    │
│  ┌──────────────────────────────────────┐  │
│  │ 📷 4 albums · 12,481 photos         │  │
│  │    Selected from Camera Roll, ...    │  │
│  └──────────────────────────────────────┘  │
│  ┌──────────────────────────────────────┐  │
│  │ 🖥  Pair iMac-2 · same Wi-Fi         │  │
│  └──────────────────────────────────────┘  │
│                                            │
│  Backup                                    │
│  ┌──────────────────────────────────────┐  │
│  │          [ Sync Now ]                │  │
│  │  ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢  4 of 17       │  │
│  │  Camera Roll / IMG_1042.HEIC         │  │
│  └──────────────────────────────────────┘  │
│                                            │
│  Automatic Sync                         ›  │ ← inline expand
│  Operation Log                           › │
└────────────────────────────────────────────┘
```

- Sync button is full-width inside its card, 56pt tall, `signal` background, white label, `.disabled` → `frame` background.
- Progress is rendered as **numeric counts first** (`4 of 17`), with a thin `frame`-colored track behind. The number is the truth; the bar is decoration.
- `Automatic Sync` collapses to one row by default and expands inline (no separate sheet).
- `Operation Log` shows the latest three entries directly in the main list (kept from current design), plus a `View all` row.

### Mac Setup (`SetupView`)

Three zones in a `Form` with `grouped` style. No re-architecture of the AppKit window itself.

```text
┌─ iPhone Sync Setup ────────────────────────┐
│                                            │
│  Status                                    │
│  🖥  Paired: Lisa's iPhone 17 Pro         │
│  ◐  Ready                                  │
│                                            │
│  Backup                                    │
│  Destination                               │
│  ~/Downloads/                              │
│     └ iPhoneSync/        ← mono           │
│                                            │
│  [ Choose Destination ]  [ Pair iPhone ]   │
│  [ Reset Source ]                          │
│                                            │
│  Last Sync                                 │
│  Added 12 · Already 8 · Not local 0 · 0 fail│
│                                            │
│  Operation Log                          ⟳  │
│  ┌──────────────────────────────────────┐  │
│  │ 14:22  Manual Sync                  │  │
│  │        Completed: 12 added, ...      │  │
│  │ 14:21  Discovery                   │  │
│  │        Found paired Mac.            │  │
│  └──────────────────────────────────────┘  │
│                                            │
│  System                                    │
│  Launch at Login  [ON]                     │
│  Forget Paired iPhone   (destructive)     │
└────────────────────────────────────────────┘
```

- Destination path renders the user-selected folder in `body`, then a sub-line `└ iPhoneSync/` in `numeric data` (mono, secondary) — mirrors the literal directory tree the receiver creates.
- Operation log rows reverse: timestamp left, category above message, level glyph on the right. The current layout puts the timestamp right-aligned; reading flow is bad.

### Menu bar (macOS)

Replace the generic SF Symbol `iphone.and.arrow.forward` with a custom template asset. Two glyph states:

- **Idle**: outline pair shape (iPhone on left, Mac on right, hairline gap). 14×14pt, `wire` color.
- **Receiving**: same outline, right half filled with `signal` color.

This glyph encodes *paired endpoints* in a single mark — the subject of the product. Implementation: `Assets.xcassets/MenuBarIcon.imageset/` with two PDF templates.

```text
idle     ◯ · ◯       receiving   ◯ · ●
```

## 5. Signature Element — The Pairing Window

The single memorable moment of the entire product is the moment a user reads a six-digit number on one device and types it into the other. That moment currently uses `system(.title)` monospaced — fine, but generic. The redesign frames it deliberately.

### Mac side — when pairing window is open

```text
┌────────────────────────────────────┐
│                                    │
│  PAIRING CODE                      │ ← caption, +0.5 spacing, secondary
│                                    │
│  ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐  │
│  │ 4│ │ 9│ │ 2│ │ 0│ │ 1│ │ 7│  │ ← 56pt SF Mono, wire color
│  └──┘ └──┘ └──┘ └──┘ └──┘ └──┘  │
│                                    │
│  Verify on iPhone — code never     │ ← callout
│  travels.                          │
│                                    │
│  ─────  01:42  ─────               │ ← mono countdown
│                                    │
│  attempts  ● ● ○ ○ ○              │ ← 5-dot indicator, mono
│                                    │
└────────────────────────────────────┘
```

- The six digits are individually framed cells with 1pt `frame` borders. The Mac-side rendering is a live, ticking countdown.
- The "code never travels" copy is one line, always visible. Not a tooltip.
- The 5-dot attempt indicator fills in as wrong codes are entered (lives on iOS side, mirrored count down on Mac).

### iOS side — code entry

Replace the single `TextField` with six separate monospaced digit cells:

```text
┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐
│4 │ │9 │ │2 │ │  │ │  │ │  │   ← 36×44pt each, focus = signal border
└──┘ └──┘ └──┘ └──┘ └──┘ └──┘
```

Auto-advance focus on digit entry, backspace on empty returns to previous cell. Numeric keypad keyboard. The shape of the input on iOS mirrors the shape of the display on Mac — they are reading and writing the same artifact.

## 6. Operation Log — Tightened Layout

Current layout uses `info.circle.fill` / `checkmark.circle.fill` / etc. in the default Apple colors (blue / green / orange / red). The redesign keeps the same semantic levels but:

- Renders the level glyph as a 12pt circle, `frame` outline by default, filled in `verified` / `alert` only when not `.info`
- Timestamp column is left-aligned, monospaced, fixed width — easier to scan than the current right-aligned date
- Category is the row title (not the message)
- The `Copy All` and `Clear` actions move to the top of the panel as small ghost buttons
- Maximum 500 entries per process (unchanged); the panel renders a sticky footer `Keeps latest 500 for this run.`

## 7. Copy Voice

Quietly precise. Not chatty, not corporate.

| Surface | Current | Redesign |
|---|---|---|
| Sync button label | `Sync Now` | `Sync Now` (unchanged — correct verb) |
| Empty pairing state | `Not paired` | `Choose a Mac on the same Wi-Fi to begin.` |
| Pairing code caption | (none) | `Verify on iPhone — code never travels.` |
| Last sync | `Added 12 / Already present 8 / ...` | `Added 12, already present 8, not local 0, failed 0.` (sentence, periods) |
| Permission denied | `Open Settings` | `Local network denied. Settings → iPhone Sync → Local Network.` |
| Album count | `4 selected` | `4 albums · 12,481 photos` (added total) |
| iCloud-only skip | counted silently | shown in summary: `not local 14` |

## 8. Motion

Two small, deliberate moments. No page-load orchestrations, no parallax, no hover effects.

1. **Connection arrive** (Mac menu bar only): when Bonjour finds the paired Mac, the right half of the menu bar glyph fills from outline to `signal` over 220ms ease-out. No badge, no notification. Respect `Reduce Motion`: skip the fill, snap to final state.
2. **Chunk tick** (both apps during sync): the bytes counter ticks at 1 MiB chunk boundaries rather than animating smoothly. The user sees the protocol's actual increments. The "honest wire" feel.

## 9. Quality Floor

- Light + dark mode parity for every token
- Dynamic Type supported everywhere except the pairing code (which stays `SF Mono` at its fixed 56pt — legibility over resize)
- VoiceOver: every status glyph has an `accessibilityLabel`; counts read as full words ("12 added, 8 already present, 0 not on iPhone, 0 failed")
- Reduce Motion: chunk tick becomes static, connection-fill animation removed
- Keyboard: pairing code input is keyboard-type `.numberPad`, focus-trap with `UIAccessibility.post(notification: .screenChanged, ...)` on cell change
- Mac menu bar template image must remain single-color template rendering (no color in the asset itself — tint via `setTintColor`)

## 10. Out of Scope

- No changes to SyncCore / MacReceiverKit contracts
- No changes to the wire protocol, pairing crypto, manifest schema, or destination writer
- No new dependencies
- No rebranding of the product name `iPhone Sync`
- No new privacy prompts or entitlements
- No SwiftUI → UIKit migration; current SwiftUI containers are kept
- No new assets beyond the menu bar template (other glyphs remain SF Symbols)

## 11. Implementation Sequencing

1. Add `apps/ios/Sources/Theme/Tokens.swift` and `apps/macos/Sources/Theme/Tokens.swift` (or extract into a shared Swift package product added to `SyncCore` as a non-platform module — but keep it App-target-local for now to avoid cross-target coupling)
2. Replace SF Symbol usage in `iPhoneSyncMacApp` menu-bar status with custom template image
3. Apply tokens to `SetupView` typography, spacing, Operation Log layout
4. Apply tokens to `ContentView` card components and zone structure
5. Replace pairing code display on Mac with the framed six-cell component
6. Replace pairing code input on iOS with the six-cell input component
7. Wire chunk-tick motion via existing progress callback (no protocol change — just stop smoothing on the display)
8. Update operation log glyphs + layout
9. Add accessibility labels
10. Run `bash scripts/verify.sh` to confirm no regressions

## 12. Acceptance

- All existing 51 + 30 tests still pass
- Both apps build unsigned in `verify.sh`
- The pairing code moment on Mac and iOS visually mirrors the same six-cell artifact
- The menu bar glyph is no longer the default `iphone.and.arrow.forward`
- Both apps use the same color tokens (light + dark)
- Reduce Motion is respected
- No private keys, codes, or content hashes are rendered in any new view
