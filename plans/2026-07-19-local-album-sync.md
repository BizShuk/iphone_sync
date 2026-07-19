# Local Album Sync Implementation Plan

> `For agentic workers:` REQUIRED SUB-SKILL: use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

`Goal:` Build a native iOS sender and native macOS menu-bar receiver that pair with a six-digit code and incrementally copy one local-only Photos album to a Finder folder over the same LAN.

`Architecture:` XcodeGen owns the Xcode project description. Both apps depend downward on local Swift package products: `SyncCore` owns contracts, framing, identity, hashing, pairing, Keychain, Bonjour and TLS-PSK transport; `MacReceiverKit` owns SwiftData manifest and crash-safe destination writes. Initial pairing uses unauthenticated TCP only to exchange ephemeral Curve25519 public material; the six-digit short authentication string authenticates that exchange, and the derived 256-bit secret becomes the TLS 1.3 PSK for every sync connection.

`Tech Stack:` Swift 6, SwiftUI, PhotoKit, Network.framework, CryptoKit, Security/Keychain, SwiftData, XcodeGen, XCTest.

## Global Constraints

- Deployment floors are iOS 17 and macOS 14.
- The iPhone app runs synchronization only while foregrounded and after `Sync Now`.
- One source album, one iPhone and one Mac are active at a time.
- The Mac never deletes or overwrites committed user files.
- PhotoKit requests always set `isNetworkAccessAllowed = false`.
- Full Access to Photos is required because Limited Access cannot guarantee complete album enumeration.
- Normal discovery uses `_iphonesync._tcp`; pairing uses `_iphonesync-pair._tcp` only during a two-minute pairing window.
- iPhone normal sync requires Wi-Fi and sets `includePeerToPeer = false`; there is no cellular, AirDrop, Bluetooth or Internet fallback.
- The six-digit code is never transmitted and is never used directly as an encryption key.
- Pairing derives a 256-bit PSK; normal sync uses TLS 1.3 with that PSK and identity.
- Control frames are at most 64 KiB; chunk frames are at most 1 MiB.
- Durable receive checkpoints occur every 16 MiB.
- Final destination publication is an atomic commit after size and SHA-256 verification.
- Album enumeration must handle 10,000 assets without loading media bytes or a complete wire inventory into memory.
- No third-party runtime dependency is allowed.
- The generated `.xcodeproj` is committed so building does not require XcodeGen after checkout.

---

## Planned File Map

```tree
iphone_sync/
├── project.yml
├── iPhoneSync.xcodeproj/
├── apps/
│   ├── ios/
│   │   ├── Info.plist
│   │   ├── iPhoneSync.entitlements
│   │   └── Sources/
│   │       ├── iPhoneSyncApp.swift
│   │       ├── IOSAppModel.swift
│   │       ├── AlbumSelectionStore.swift
│   │       ├── PhotoLibrarySource.swift
│   │       ├── IOSSyncCoordinator.swift
│   │       ├── ContentView.swift
│   │       ├── AlbumPickerView.swift
│   │       └── PairingView.swift
│   └── macos/
│       ├── Info.plist
│       ├── iPhoneSyncMac.entitlements
│       └── Sources/
│           ├── iPhoneSyncMacApp.swift
│           ├── MacAppModel.swift
│           ├── ReceiverController.swift
│           ├── DestinationBookmarkStore.swift
│           ├── MenuContentView.swift
│           └── SetupView.swift
├── packages/
│   └── SyncCore/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── SyncCore/
│       │   │   ├── SyncConstants.swift
│       │   │   ├── ResourceDescriptor.swift
│       │   │   ├── SyncMessage.swift
│       │   │   ├── FrameCodec.swift
│       │   │   ├── ResourceIdentity.swift
│       │   │   ├── FilenamePolicy.swift
│       │   │   ├── FileHasher.swift
│       │   │   ├── PairingCrypto.swift
│       │   │   ├── PairingProtocol.swift
│       │   │   ├── PairedPeer.swift
│       │   │   ├── KeychainSecretStore.swift
│       │   │   ├── PSKTLSParameters.swift
│       │   │   ├── FramedConnection.swift
│       │   │   ├── BonjourDiscovery.swift
│       │   │   ├── PairingClient.swift
│       │   │   ├── PairingServer.swift
│       │   │   └── SyncClient.swift
│       │   └── MacReceiverKit/
│       │       ├── TransferRecord.swift
│       │       ├── ManifestStore.swift
│       │       ├── DestinationWriter.swift
│       │       └── SyncServerSession.swift
│       └── Tests/
│           ├── SyncCoreTests/
│           │   ├── TestSupport.swift
│           │   ├── FrameCodecTests.swift
│           │   ├── IdentityAndFilenameTests.swift
│           │   ├── PairingCryptoTests.swift
│           │   └── PSKTransportTests.swift
│           └── MacReceiverKitTests/
│               ├── ReceiverHarness.swift
│               ├── ManifestStoreTests.swift
│               ├── DestinationWriterTests.swift
│               └── SyncRoundTripTests.swift
└── scripts/
    └── verify.sh
```

---

### Task 1: Project scaffold and wire contracts

`Files:`

- Create `project.yml`
- Create `packages/SyncCore/Package.swift`
- Create `packages/SyncCore/Sources/SyncCore/SyncConstants.swift`
- Create `packages/SyncCore/Sources/SyncCore/ResourceDescriptor.swift`
- Create `packages/SyncCore/Sources/SyncCore/SyncMessage.swift`
- Create `packages/SyncCore/Sources/SyncCore/FrameCodec.swift`
- Create `packages/SyncCore/Tests/SyncCoreTests/FrameCodecTests.swift`
- Modify `docs/specs/2026-07-19-local-album-sync-design.md`
- Modify `CLAUDE.md`

`Interfaces:`

- Produces `SyncConstants`, `ResourceDescriptor`, `ResourceOffer`, `SessionMessage`, `TransferDecision`, `TransferResult`, `SyncSummary`, `SyncControlMessage`, `FrameKind`, `SyncFrame`, and `FrameCodec` for every later task.
- `FrameCodec.encode(_:) -> Data` emits a 40-byte big-endian header plus raw payload.
- `FrameCodec.decodeHeader(_:) throws -> FrameHeader` validates magic, version and payload limits before allocation.

- [ ] `Step 1: Write the failing frame tests`

```swift
@Test func controlFrameRoundTrips() throws {
    let message = SyncControlMessage.session(.request(albumID: "album-1", albumName: "Camera", sourceBindingID: nil))
    let frame = try SyncFrame.control(message, requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let bytes = try FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeCompleteFrame(bytes)
    #expect(decoded == frame)
}

@Test func oversizedControlPayloadIsRejected() {
    let payload = Data(repeating: 0, count: SyncConstants.maximumControlPayload + 1)
    #expect(throws: FrameCodecError.payloadTooLarge) {
        try SyncFrame(kind: .session, requestID: UUID(), offset: 0, payload: payload)
    }
}
```

- [ ] `Step 2: Run the focused tests and verify RED`

Run: `swift test --package-path packages/SyncCore --filter FrameCodecTests`

Expected: compilation fails because `FrameCodec`, `SyncFrame`, and `SyncControlMessage` do not exist.

- [ ] `Step 3: Implement the contracts and fixed header codec`

Implement these exact limits and message cases:

```swift
public enum SyncConstants {
    public static let protocolVersion: UInt16 = 1
    public static let normalServiceType = "_iphonesync._tcp"
    public static let pairingServiceType = "_iphonesync-pair._tcp"
    public static let chunkSize = 1_048_576
    public static let checkpointSize: Int64 = 16_777_216
    public static let maximumControlPayload = 65_536
}

public enum SyncControlMessage: Codable, Equatable, Sendable {
    case session(SessionMessage)
    case offer(ResourceDescriptor)
    case decision(TransferDecision)
    case result(TransferResult)
}

public enum TransferDecision: Codable, Equatable, Sendable {
    case skip
    case start(offset: Int64)
    case resume(offset: Int64)
}

public struct SyncSummary: Codable, Equatable, Sendable {
    public var added: Int
    public var existing: Int
    public var notLocal: Int
    public var failed: Int
    public static let zero = SyncSummary(added: 0, existing: 0, notLocal: 0, failed: 0)
}
```

`FrameKind` raw values are `session = 1`, `offer = 2`, `decision = 3`, `chunk = 4`, and `result = 5`. Chunk payloads remain raw bytes; other frame payloads are JSON encoded control messages.

- [ ] `Step 4: Run package tests and verify GREEN`

Run: `swift test --package-path packages/SyncCore --filter FrameCodecTests`

Expected: all `FrameCodecTests` pass.

- [ ] `Step 5: Refine the security documentation`

Replace certificate-pinning language with the implemented two-stage contract: ephemeral Curve25519/SAS pairing over the temporary pairing service, followed by TLS 1.3 PSK on normal sync connections. Preserve the rule that the six-digit value never crosses the network.

- [ ] `Step 6: Generate the Xcode project and commit`

Run: `xcodegen generate`

Run: `git add project.yml iPhoneSync.xcodeproj packages/SyncCore docs/specs CLAUDE.md && git commit -m "feat: scaffold sync protocol"`

Expected: commit contains the generated project, package manifest, passing frame tests and synchronized docs.

---

### Task 2: Identity, filenames, hashing, pairing crypto and Keychain

`Files:`

- Create `packages/SyncCore/Sources/SyncCore/ResourceIdentity.swift`
- Create `packages/SyncCore/Sources/SyncCore/FilenamePolicy.swift`
- Create `packages/SyncCore/Sources/SyncCore/FileHasher.swift`
- Create `packages/SyncCore/Sources/SyncCore/PairingCrypto.swift`
- Create `packages/SyncCore/Sources/SyncCore/PairedPeer.swift`
- Create `packages/SyncCore/Sources/SyncCore/KeychainSecretStore.swift`
- Create `packages/SyncCore/Tests/SyncCoreTests/IdentityAndFilenameTests.swift`
- Create `packages/SyncCore/Tests/SyncCoreTests/PairingCryptoTests.swift`
- Create `packages/SyncCore/Tests/SyncCoreTests/TestSupport.swift`

`Interfaces:`

- `ResourceIdentity.make(sourceBindingID:descriptor:) -> String`
- `FilenamePolicy.relativePath(for:) throws -> String`
- `FileHasher.sha256(url:) throws -> String`
- `PairingCrypto.makeMaterial() -> PairingMaterial`
- `PairingCrypto.derive(local:peerPublicKey:transcript:) throws -> DerivedPairingSecret`
- `KeychainSecretStore.save(_:account:)`, `load(account:)`, and `delete(account:)`

- [ ] `Step 1: Write deterministic identity, path and crypto tests`

```swift
@Test func resourceIdentityIsStableAndBindingScoped() {
    let descriptor = ResourceDescriptor.fixture(assetID: "asset", filename: "IMG_1.HEIC")
    #expect(ResourceIdentity.make(sourceBindingID: "A", descriptor: descriptor) == ResourceIdentity.make(sourceBindingID: "A", descriptor: descriptor))
    #expect(ResourceIdentity.make(sourceBindingID: "A", descriptor: descriptor) != ResourceIdentity.make(sourceBindingID: "B", descriptor: descriptor))
}

@Test func filenamePolicyRejectsTraversal() {
    #expect(throws: FilenamePolicyError.invalidFilename) {
        try FilenamePolicy.relativePath(originalFilename: "../secret", resourceID: String(repeating: "a", count: 64), role: nil, creationDate: .distantPast)
    }
}

@Test func bothSidesDeriveSameCodeAndPSK() throws {
    let mac = PairingCrypto.makeMaterial()
    let phone = PairingCrypto.makeMaterial()
    let transcript = PairingTranscript.fixture(mac: mac, phone: phone)
    let macSecret = try PairingCrypto.derive(local: mac, peerPublicKey: phone.publicKey, transcript: transcript)
    let phoneSecret = try PairingCrypto.derive(local: phone, peerPublicKey: mac.publicKey, transcript: transcript)
    #expect(macSecret.verificationCode == phoneSecret.verificationCode)
    #expect(macSecret.psk == phoneSecret.psk)
    #expect(macSecret.verificationCode.count == 6)
}
```

`TestSupport.swift` defines `ResourceDescriptor.fixture(...)` and `PairingTranscript.fixture(mac:phone:)` using fixed IDs, dates and nonces so every test reference above is concrete and deterministic.

- [ ] `Step 2: Run focused tests and verify RED`

Run: `swift test --package-path packages/SyncCore --filter IdentityAndFilenameTests && swift test --package-path packages/SyncCore --filter PairingCryptoTests`

Expected: compilation fails because the identity, filename and pairing APIs do not exist.

- [ ] `Step 3: Implement minimal production code`

Use SHA-256 over canonical UTF-8 fields separated by zero bytes for `resourceID`. Use `Curve25519.KeyAgreement`, HKDF-SHA256 and a transcript containing protocol version, receiver ID, both public keys and both 32-byte nonces. Derive separate labels `iphonesync-sas-v1`, `iphonesync-psk-v1`, `iphonesync-client-proof-v1`, and `iphonesync-server-proof-v1`. Render the first 20 SAS bits modulo 1,000,000 as a zero-padded six-digit string.

Keychain records use `kSecClassGenericPassword`, service `com.bizshuk.iphonesync`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and JSON-encoded `PairedPeer` values.

- [ ] `Step 4: Run focused and full package tests`

Run: `swift test --package-path packages/SyncCore`

Expected: all tests pass and no secret is printed by tests or production logs.

- [ ] `Step 5: Commit`

Run: `git add packages/SyncCore && git commit -m "feat: add sync identity and pairing crypto"`

---

### Task 3: TLS-PSK framed transport and Bonjour pairing

`Files:`

- Create `packages/SyncCore/Sources/SyncCore/PairingProtocol.swift`
- Create `packages/SyncCore/Sources/SyncCore/PSKTLSParameters.swift`
- Create `packages/SyncCore/Sources/SyncCore/FramedConnection.swift`
- Create `packages/SyncCore/Sources/SyncCore/BonjourDiscovery.swift`
- Create `packages/SyncCore/Sources/SyncCore/PairingClient.swift`
- Create `packages/SyncCore/Sources/SyncCore/PairingServer.swift`
- Create `packages/SyncCore/Tests/SyncCoreTests/PSKTransportTests.swift`
- Modify `packages/SyncCore/Tests/SyncCoreTests/TestSupport.swift`

`Interfaces:`

- `PSKTLSParameters.make(psk:identity:role:requireWiFi:) -> NWParameters`
- `FramedConnection.start() async throws`, `send(_:) async throws`, `receive() async throws`, and `cancel()`
- `PairingServer.open(window:displayName:onCode:onPaired:) async throws`
- `PairingClient.begin(endpoint:deviceName:) async throws -> PendingPairing`
- `PendingPairing.confirm(code:) async throws -> PairedPeer`
- `BonjourDiscovery` publishes `AsyncStream<[DiscoveredReceiver]>` for one service type.

- [ ] `Step 1: Write a TLS-PSK loopback test`

```swift
@Test func tlsPSKLoopbackTransfersAFrame() async throws {
    let psk = Data(repeating: 0x42, count: 32)
    let identity = Data("phone-1".utf8)
    let listener = try NWListener(using: PSKTLSParameters.make(psk: psk, identity: identity, role: .server, requireWiFi: false))
    let port = try await TestListener.start(listener)
    let client = FramedConnection(NWConnection(host: "127.0.0.1", port: port, using: PSKTLSParameters.make(psk: psk, identity: identity, role: .client, requireWiFi: false)))
    try await client.start()
    try await client.send(.control(.result(.sessionCompleted(.zero)), requestID: UUID()))
#expect(try await TestListener.receivedFrame() != nil)
}
```

Add a `TestListener` actor to `TestSupport.swift`. It starts an `NWListener` on `.any`, exposes the selected port only after `.ready`, wraps the accepted connection in `FramedConnection`, and stores the first received frame for `receivedFrame()`.

- [ ] `Step 2: Run the transport test and verify RED`

Run: `swift test --package-path packages/SyncCore --filter PSKTransportTests`

Expected: compilation fails because PSK and framed network types do not exist.

- [ ] `Step 3: Implement TLS 1.3 PSK parameters and exact-length receives`

Use `NWProtocolTLS.Options`, `sec_protocol_options_add_pre_shared_key`, `sec_protocol_options_set_min_tls_protocol_version(..., .TLSv13)`, TCP no-delay and connection state continuations. Client parameters set `requiredInterfaceType = .wifi` only when `requireWiFi` is true and always set `includePeerToPeer = false`.

`FramedConnection.receive()` first reads exactly 40 bytes, validates the header, and then reads exactly declared payload bytes. EOF before completion is `FramedConnectionError.truncatedFrame`.

- [ ] `Step 4: Implement the temporary pairing service`

Pairing uses length-prefixed JSON messages `hello`, `confirm`, `accepted`, and `rejected`. `confirm` carries only an HMAC proof, never the numeric code. Mac pairing closes after 120 seconds, one active connection or a successful pair. iPhone closes its connection after five local code mismatches.

- [ ] `Step 5: Run transport tests five times`

Run: `for run in 1 2 3 4 5; do swift test --package-path packages/SyncCore --filter PSKTransportTests || exit 1; done`

Expected: all five runs pass, proving the TLS-PSK handshake is not a one-off race.

- [ ] `Step 6: Commit`

Run: `git add packages/SyncCore && git commit -m "feat: add secure local transport"`

---

### Task 4: Crash-safe manifest, destination writer and round-trip sync engine

`Files:`

- Create `packages/SyncCore/Sources/MacReceiverKit/TransferRecord.swift`
- Create `packages/SyncCore/Sources/MacReceiverKit/ManifestStore.swift`
- Create `packages/SyncCore/Sources/MacReceiverKit/DestinationWriter.swift`
- Create `packages/SyncCore/Sources/MacReceiverKit/SyncServerSession.swift`
- Create `packages/SyncCore/Sources/SyncCore/SyncClient.swift`
- Create `packages/SyncCore/Tests/MacReceiverKitTests/ManifestStoreTests.swift`
- Create `packages/SyncCore/Tests/MacReceiverKitTests/DestinationWriterTests.swift`
- Create `packages/SyncCore/Tests/MacReceiverKitTests/SyncRoundTripTests.swift`
- Create `packages/SyncCore/Tests/MacReceiverKitTests/ReceiverHarness.swift`

`Interfaces:`

- `ManifestStore.decision(for:) async throws -> TransferDecision`
- `ManifestStore.recordCheckpoint(resourceID:offset:) async throws`
- `ManifestStore.commit(resourceID:relativePath:) async throws`
- `DestinationWriter.begin(_:)`, `append(_:offset:)`, `checkpoint()`, `commit(expectedHash:)`, and `abort()`
- `SyncServerSession.run(connection:) async throws`
- `SyncClient.openSession(albumID:albumName:sourceBindingID:)`, `sendResource(_:fileURL:)`, and `finish()`

- [ ] `Step 1: Write manifest and destination RED tests`

```swift
@Test func restartTruncatesBytesBeyondDurableCheckpoint() async throws {
    let harness = try ReceiverHarness()
    try await harness.writer.append(Data(repeating: 1, count: 20_000_000), offset: 0)
    try await harness.writer.checkpoint(at: 16_777_216)
    try harness.simulateCrash()
    let recovered = try await harness.recover()
    #expect(recovered.offset == 16_777_216)
    #expect(recovered.fileSize == 16_777_216)
}

@Test func existingDifferentFileIsNeverOverwritten() async throws {
    let harness = try ReceiverHarness(existingBytes: Data("user file".utf8))
    let committed = try await harness.receive(Data("photo".utf8))
    #expect(try Data(contentsOf: harness.existingURL) == Data("user file".utf8))
    #expect(committed != harness.existingURL)
}
```

`ReceiverHarness.swift` creates a unique `FileManager.temporaryDirectory` child, an in-memory SwiftData `ModelContainer`, `ManifestStore`, and `DestinationWriter`. `simulateCrash()` closes the handle without committing; `recover()` returns the reconciled manifest offset and actual partial-file size. `deinit` removes only that unique temporary directory.

- [ ] `Step 2: Run focused tests and verify RED`

Run: `swift test --package-path packages/SyncCore --filter MacReceiverKitTests`

Expected: compilation fails because receiver types do not exist.

- [ ] `Step 3: Implement SwiftData manifest and safe file lifecycle`

Use an injected `ModelContainer` so tests use `ModelConfiguration(isStoredInMemoryOnly: true)`. A transfer record contains source binding, resource ID, content hash, expected size, confirmed offset, status, final relative path and update time.

Write only to `<final-name>.partial`. At each 16 MiB boundary call `FileHandle.synchronize()`, then persist the offset in one SwiftData transaction. Recovery truncates bytes past the manifest offset. Commit verifies size and SHA-256, synchronizes, closes, resolves path collisions by expanding the resource ID prefix, and uses `FileManager.moveItem` without replacing an existing file.

- [ ] `Step 4: Implement client/server message flow`

`session.request` receives or creates the source binding. For each `offer`, the server returns `skip`, `start(0)` or `resume(offset)`. Chunks must arrive at the exact expected offset. When expected size is reached, the server hashes, commits and returns `committed`. A finished session returns immutable counts for added, existing, not-local and failed.

- [ ] `Step 5: Run all package tests`

Run: `swift test --package-path packages/SyncCore`

Expected: all protocol, crypto, TLS, manifest, destination and round-trip tests pass.

- [ ] `Step 6: Commit`

Run: `git add packages/SyncCore && git commit -m "feat: add resumable receiver engine"`

---

### Task 5: Native macOS menu-bar receiver

`Files:`

- Create `apps/macos/Info.plist`
- Create `apps/macos/iPhoneSyncMac.entitlements`
- Create `apps/macos/Sources/iPhoneSyncMacApp.swift`
- Create `apps/macos/Sources/MacAppModel.swift`
- Create `apps/macos/Sources/ReceiverController.swift`
- Create `apps/macos/Sources/DestinationBookmarkStore.swift`
- Create `apps/macos/Sources/MenuContentView.swift`
- Create `apps/macos/Sources/SetupView.swift`
- Modify `project.yml`

`Interfaces:`

- `MacAppModel.chooseDestination()`, `openPairingWindow()`, `forgetPhone()`, `resetSource()`, `startReceiverIfReady()`, and `stopReceiver()`
- `ReceiverController` owns the pairing listener and normal TLS listener but delegates bytes and manifest operations to package types.

- [ ] `Step 1: Add the macOS target before implementation and verify RED`

Generate then build:

```bash
xcodegen generate
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: build fails because the Mac source and plist files do not exist.

- [ ] `Step 2: Implement sandbox configuration and bookmark persistence`

Entitlements contain App Sandbox, incoming/outgoing network and user-selected read-write file access. `Info.plist` contains `LSUIElement`, `NSLocalNetworkUsageDescription`, the application category and display name. Bookmark data is security-scoped and detects stale bookmarks.

- [ ] `Step 3: Implement model and controller`

The model presents states `needsDestination`, `needsPairing`, `ready`, `pairing(code,expiresAt)`, `receiving(progress)`, and `error(message)`. Pairing success writes `PairedPeer` to Keychain, closes the pairing listener and starts the TLS-PSK receiver. Forgetting a phone stops the listener and deletes only trust material; it does not delete files or manifests.

- [ ] `Step 4: Implement menu and setup UI`

`MenuBarExtra` shows status, `Open Setup`, `Pair New iPhone`, `Choose Destination`, `Forget iPhone` and `Quit`. `SetupView` displays destination, paired phone, six-digit code, pairing expiry and last sync summary. `Launch at Login` uses `SMAppService.mainApp` and surfaces errors without forcing the setting.

- [ ] `Step 5: Build macOS twice`

Run: `xcodegen generate && xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO clean build && xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

Expected: both builds succeed.

- [ ] `Step 6: Commit`

Run: `git add project.yml iPhoneSync.xcodeproj apps/macos && git commit -m "feat: add mac receiver app"`

---

### Task 6: iOS PhotoKit sender and foreground UI

`Files:`

- Create `apps/ios/Info.plist`
- Create `apps/ios/iPhoneSync.entitlements`
- Create `apps/ios/Sources/iPhoneSyncApp.swift`
- Create `apps/ios/Sources/IOSAppModel.swift`
- Create `apps/ios/Sources/AlbumSelectionStore.swift`
- Create `apps/ios/Sources/PhotoLibrarySource.swift`
- Create `apps/ios/Sources/IOSSyncCoordinator.swift`
- Create `apps/ios/Sources/ContentView.swift`
- Create `apps/ios/Sources/AlbumPickerView.swift`
- Create `apps/ios/Sources/PairingView.swift`
- Modify `project.yml`

`Interfaces:`

- `PhotoLibrarySource.requestFullAccess() async -> PHAuthorizationStatus`
- `PhotoLibrarySource.albums() -> [PhotoAlbum]`
- `PhotoLibrarySource.resources(albumID:) -> AsyncThrowingStream<StagedPhotoResource, Error>`
- `IOSSyncCoordinator.pair(endpoint:code:)`, `sync(album:)`, and `cancel()`
- `IOSAppModel` exposes setup, discovery, pairing, syncing and summary state to SwiftUI.

- [ ] `Step 1: Add the iOS target before source and verify RED`

Run: `xcodegen generate && xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: build fails because iOS source and plist files do not exist.

- [ ] `Step 2: Implement PhotoKit authorization, album enumeration and staging`

Request `.readWrite`; treat `.limited` as insufficient for full-album guarantees. Enumerate user albums by localized title, then assets oldest first. For every `PHAssetResource`, write exactly one temporary file with `PHAssetResourceRequestOptions.isNetworkAccessAllowed = false`. Map `PHPhotosError.networkAccessRequired` to `skippedNotLocal`; propagate no-space and permission failures. Clean the staging file in `defer` after committed, skipped or failed handling.

- [ ] `Step 3: Implement pairing and sync coordinator`

Browse `_iphonesync-pair._tcp` for setup and `_iphonesync._tcp` for normal sync. Match the stored receiver ID from Bonjour TXT data. Pairing compares the typed six-digit value locally. Sync opens a TLS-PSK session, receives the source binding, stages one resource, offers it, seeks to resume offset, sends 1 MiB chunks and updates progress. Cancellation stops adding resources, finishes the current send operation and closes the connection.

- [ ] `Step 4: Implement SwiftUI flow`

The main screen shows source album, paired Mac, connection state, last summary, `Sync Now`, current resource/byte progress and `Cancel`. Setup requests Photos before album selection and Local Network only after `Find Mac`. Pairing accepts exactly six decimal digits and shows expiry/failure states. Entering background requests coordinator cancellation and preserves Mac partial state.

- [ ] `Step 5: Build iOS for simulator and generic device`

Run: `xcodegen generate && xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO clean build && xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: both unsigned builds succeed.

- [ ] `Step 6: Commit`

Run: `git add project.yml iPhoneSync.xcodeproj apps/ios && git commit -m "feat: add iphone album sender"`

---

### Task 7: Edge-case tests, verification script and documentation sync

`Files:`

- Extend `packages/SyncCore/Tests/SyncCoreTests/FrameCodecTests.swift`
- Extend `packages/SyncCore/Tests/SyncCoreTests/PairingCryptoTests.swift`
- Extend `packages/SyncCore/Tests/MacReceiverKitTests/SyncRoundTripTests.swift`
- Create `scripts/verify.sh`
- Modify `README.md`
- Modify `CLAUDE.md`
- Modify `README.todo`
- Create `docs/memory/2026-07-19-local-album-sync-mvp.md`

`Interfaces:`

- `scripts/verify.sh` becomes the canonical non-destructive verification entry point.

- [ ] `Step 1: Add RED edge-case tests`

Add concrete tests for malformed magic, unsupported version, control payload 65,537 bytes, chunk payload 1,048,577 bytes, truncated frame, out-of-order chunk, wrong PSK, wrong pairing proof, expired pairing, resume from 16 MiB, same-path same-hash adoption, same-path different-hash non-overwrite and second integrity failure.

- [ ] `Step 2: Run tests and confirm at least one new RED assertion`

Run: `swift test --package-path packages/SyncCore`

Expected: at least one new test fails before the missing guard or behavior is implemented.

- [ ] `Step 3: Implement only the missing guards and rerun GREEN`

Run: `swift test --package-path packages/SyncCore`

Expected: all package tests pass.

- [ ] `Step 4: Create canonical verification script`

```bash
#!/usr/bin/env bash
set -euo pipefail

swift test --package-path packages/SyncCore
xcodegen generate
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhoneSync.xcodeproj -scheme iPhoneSyncIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

- [ ] `Step 5: Synchronize canonical documentation`

README documents setup, build and local-only behavior. CLAUDE replaces planned structure with actual structure and records TLS-PSK. README.todo moves completed MVP items to Archive and leaves only live-device acceptance items that cannot be proven without the user's iPhone and Photos library. The memory entry records verified commands, implementation deviations and operational limitations without claiming live-device success.

- [ ] `Step 6: Run full verification`

Run: `bash scripts/verify.sh`

Expected: package tests and all three unsigned builds succeed; `git diff --check` reports no errors.

- [ ] `Step 7: Run consistency and doc checks`

Run: `rg -n 'certificate pin|self-signed|DeviceDiscoveryUI|AirDrop|Bluetooth|isNetworkAccessAllowed|includePeerToPeer|1 MiB|16 MiB' README.md CLAUDE.md docs plans packages apps`

Expected: no obsolete certificate-pinning design remains; local-only, PSK, chunk and checkpoint contracts agree everywhere.

- [ ] `Step 8: Commit final verified state`

Run: `git add README.md CLAUDE.md README.todo docs/memory scripts packages apps project.yml iPhoneSync.xcodeproj && git commit -m "docs: finalize local album sync mvp"`

- [ ] `Step 9: Verify repository state after commit`

Run: `git status --short --branch && git log --oneline --decorate -8`

Expected: clean `main` worktree with the documentation commit at HEAD.
