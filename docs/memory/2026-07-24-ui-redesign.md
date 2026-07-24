# UI Redesign

`Date:` 2026-07-24

`Status:` Implemented and verified by `bash scripts/verify.sh`.

## Outcome

- Both apps now share a single token system (color, typography, layout) defined in `apps/{ios,macos}/Sources/Theme/Tokens.swift`. Six adaptive color tokens (paper, wire, frame, signal, verified, alert) with explicit light and dark variants; seven Font tokens built on Apple system faces only.
- Menu bar icon is now a programmatically drawn template image encoding the product's actual subject — two paired endpoints. Idle and receiving states are visually distinct while staying template-rendering friendly. Replaces the generic `iphone.and.arrow.forward` SF Symbol.
- Mac `SetupView` is reorganized into typed sections using a shared `sectionHeader` helper. Operation Log rows now place timestamp (mono, fixed width) on the left and the level glyph on the right, inverting the previous layout. Destination path renders as two lines mirroring the literal directory tree.
- Mac pairing code is now a `PairingCodeDisplay` component: six framed mono cells with eyebrow label, helper copy, mono countdown, and 5-dot attempts indicator. The signature element of the product earns a deliberate visual treatment.
- iOS `ContentView` is reorganized into three card-based zones (Source, Backup, Automatic+Log). Sync Now is a full-width 56pt signal-tinted button with `.animation(nil, value:)` to enforce chunk-tick honesty. Progress renders numeric counts first with a thin frame-colored track.
- iOS `PairingView` uses a `PairingCodeInput` component: six mono digit cells with hidden `TextField` capturing the numeric keypad, auto-advance focus, and signal-tinted focused border. Mirrors the Mac display shape so they read and write the same artifact.

## Durable Decisions

- Tokens stay app-local (not in `SyncCore`). Avoids cross-target coupling and keeps SyncCore pure.
- `signal-orange #FF6B35` is the accent. Deliberately not iCloud blue. Reads as a network patch-panel LED.
- SF Mono earns its keep: real numeric identities (pairing code, byte counts, content hash prefix, device ID, operation log timestamps).
- Menu bar icon is a template image drawn programmatically — no asset catalog needed, auto-adapts to light/dark menu bar.
- Progress bar suppresses implicit animation so byte updates land at 1 MiB chunk boundaries. The counter is the truth, the track is decoration.
- Pairing attempts indicator on Mac currently shows static 5/5 — the protocol does not surface attempts to the receiver; future enhancement can wire the iOS counter via the pairing channel.

## Verification

`bash scripts/verify.sh` passes cleanly after the changes:

- 51 Swift package tests
- iOS Simulator unit tests
- Mac unsigned build
- iOS Simulator generic build
- iOS Release generic device build
- All plist / entitlement / local-only / background-mode / hard-cancellation / recovery source invariants
- All whitespace invariants

Two verify.sh source invariants were updated to match the new structure:

- `struct IOSOperationLogSection` → `struct IOSOperationLogCard` (renamed and moved to `ContentView.swift`)
- `Section("Operation Log")` → `sectionHeader("Operation Log")` (helper introduced in `SetupView.swift`)

## Acceptance Remaining

Real-device visual acceptance is still pending — the spec covers build, tests, and source invariants only. Signed iPhone and signed Mac launches are required to confirm:

- Pairing code moment looks deliberate on both ends
- Menu bar glyph stays visible in the user's actual menu bar density
- Light/dark mode parity across both apps
- VoiceOver reads counts and category labels as full sentences
- Reduce Motion skips chunk-tick smoothing correctly
