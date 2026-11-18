import Foundation
import SyncCore
import XCTest
@testable import iPhone_Sync

final class DeleteAfterSyncTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "DeleteAfterSyncTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeleteAfterSyncTests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testStoreDefaultsToDisabledWithNoPendingAssets() {
        let snapshot = makeStore().snapshot

        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.pendingAssetCount, 0)
        XCTAssertFalse(snapshot.isDeleting)
    }

    func testStorePersistsCandidatesAndDisablingClearsThem() {
        let store = makeStore()
        store.setEnabled(true)
        store.replacePending([candidate("asset-b"), candidate("asset-a")])

        let restored = makeStore()
        XCTAssertTrue(restored.snapshot.isEnabled)
        XCTAssertEqual(restored.pendingAssetIDs, ["asset-a", "asset-b"])
        XCTAssertEqual(
            restored.pendingCandidates,
            [candidate("asset-a"), candidate("asset-b")]
        )

        restored.setEnabled(false)

        XCTAssertFalse(makeStore().snapshot.isEnabled)
        XCTAssertTrue(makeStore().pendingAssetIDs.isEmpty)
    }

    func testCandidateAccumulatorRequiresEveryAlbumOccurrenceToBeComplete() {
        var firstAlbum = PhotoDeletionCandidateAccumulator()
        firstAlbum.record(
            assetLocalIdentifier: "complete",
            modificationDate: Date(timeIntervalSince1970: 100),
            fullyBackedUp: true
        )
        firstAlbum.record(
            assetLocalIdentifier: "duplicate",
            modificationDate: Date(timeIntervalSince1970: 200),
            fullyBackedUp: true
        )
        firstAlbum.record(
            assetLocalIdentifier: "not-local",
            modificationDate: Date(timeIntervalSince1970: 300),
            fullyBackedUp: false
        )

        var secondAlbum = PhotoDeletionCandidateAccumulator()
        secondAlbum.record(
            assetLocalIdentifier: "duplicate",
            modificationDate: Date(timeIntervalSince1970: 200),
            fullyBackedUp: false
        )
        firstAlbum.merge(secondAlbum)

        XCTAssertEqual(
            firstAlbum.eligibleCandidates,
            [PhotoDeletionCandidate(
                assetLocalIdentifier: "complete",
                modificationDate: Date(timeIntervalSince1970: 100)
            )]
        )
    }

    func testCandidateAccumulatorRejectsAssetChangedBetweenAlbums() {
        var candidates = PhotoDeletionCandidateAccumulator()
        candidates.record(
            assetLocalIdentifier: "changed",
            modificationDate: Date(timeIntervalSince1970: 100),
            fullyBackedUp: true
        )
        candidates.record(
            assetLocalIdentifier: "changed",
            modificationDate: Date(timeIntervalSince1970: 101),
            fullyBackedUp: true
        )

        XCTAssertTrue(candidates.eligibleCandidates.isEmpty)
    }

    @MainActor
    func testDisabledControllerNeverQueuesOrDeletes() async {
        let probe = PhotoDeletionProbe()
        let controller = makeController(probe: probe)

        await controller.handleSuccessfulSync(
            confirmations: ["receiver": [candidate("asset")]],
            trigger: .manualForeground
        )

        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 0)
    }

    @MainActor
    func testBackgroundSyncQueuesUntilForegroundDeletionIsRequested() async {
        let probe = PhotoDeletionProbe()
        let controller = makeController(probe: probe)
        controller.setEnabled(true)

        await controller.handleSuccessfulSync(
            confirmations: ["receiver": [candidate("asset-a"), candidate("asset-b")]],
            trigger: .automaticBackground
        )

        var callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 2)

        await controller.deletePendingAssets()

        callCount = await probe.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 0)
    }

    @MainActor
    func testForegroundSyncDeletesEligibleAssetsImmediately() async {
        let probe = PhotoDeletionProbe()
        let controller = makeController(probe: probe)
        controller.setEnabled(true)

        await controller.handleSuccessfulSync(
            confirmations: ["receiver": [candidate("asset")]],
            trigger: .manualForeground
        )

        let requestedIDs = await probe.lastRequestedAssetIDs
        XCTAssertEqual(requestedIDs, ["asset"])
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 0)
    }

    @MainActor
    func testDeletionFailureKeepsCandidatesPendingForRetry() async {
        let controller = IOSPostSyncDeletionController(
            store: makeStore(),
            registry: makeRegistry(),
            eligibilityInput: Self.singleReceiverInput,
            deletionService: PhotoAssetDeletionService { _ in
                throw TestDeletionError.rejected
            }
        )
        controller.setEnabled(true)

        await controller.handleSuccessfulSync(
            confirmations: ["receiver": [candidate("asset")]],
            trigger: .manualForeground
        )

        XCTAssertEqual(controller.snapshot.pendingAssetCount, 1)
        XCTAssertFalse(controller.snapshot.isDeleting)
    }

    /// Until every receiver whose albums contain the asset confirms it, the
    /// asset is not offered for deletion, even across runs.
    @MainActor
    func testAssetWaitsForEveryRequiredReceiverAcrossRuns() async {
        let probe = PhotoDeletionProbe()
        let controller = IOSPostSyncDeletionController(
            store: makeStore(),
            registry: makeRegistry(),
            eligibilityInput: {
                DeletionEligibilityInput(
                    profiles: [
                        Self.profile("mac", albumIDs: ["album"]),
                        Self.profile("pc", albumIDs: ["album"]),
                    ],
                    assetIDsByAlbumID: ["album": ["asset"]]
                )
            },
            deletionService: PhotoAssetDeletionService { candidates in
                let assetIDs = Set(candidates.map(\.assetLocalIdentifier))
                await probe.record(assetIDs)
                return PhotoAssetDeletionResult(
                    deletedAssetIDs: assetIDs,
                    skippedAssetIDs: []
                )
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        controller.setEnabled(true)

        await controller.handleSuccessfulSync(
            confirmations: ["mac": [candidate("asset")]],
            trigger: .automaticBackground
        )
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 0)

        await controller.handleSuccessfulSync(
            confirmations: ["pc": [candidate("asset")]],
            trigger: .automaticBackground
        )
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 1)
    }

    @MainActor
    func testInvalidatePendingWithdrawsQueuedDeletions() async {
        let controller = makeController(probe: PhotoDeletionProbe())
        controller.setEnabled(true)
        await controller.handleSuccessfulSync(
            confirmations: ["receiver": [candidate("asset")]],
            trigger: .automaticBackground
        )
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 1)

        controller.invalidatePending()

        XCTAssertEqual(controller.snapshot.pendingAssetCount, 0)
    }

    private static let singleReceiverInput: @Sendable () async throws
        -> DeletionEligibilityInput = {
        DeletionEligibilityInput(
            profiles: [profile("receiver", albumIDs: ["album"])],
            assetIDsByAlbumID: ["album": ["asset", "asset-a", "asset-b"]]
        )
    }

    nonisolated private static func profile(
        _ id: String,
        albumIDs: [String]
    ) -> ReceiverProfile {
        ReceiverProfile(
            id: id,
            displayName: id,
            albums: albumIDs.map { PhotoAlbum(id: $0, title: $0, assetCount: 1) },
            pairedAt: Date(timeIntervalSince1970: 0),
            lastConnectedAt: nil,
            lastCompletedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeRegistry() -> AssetBackupRegistry {
        AssetBackupRegistry(
            fileURL: directory.appendingPathComponent("asset-backups.json")
        )
    }

    private func makeStore() -> IOSDeleteAfterSyncStore {
        IOSDeleteAfterSyncStore(defaults: defaults)
    }

    @MainActor
    private func makeController(
        probe: PhotoDeletionProbe
    ) -> IOSPostSyncDeletionController {
        IOSPostSyncDeletionController(
            store: makeStore(),
            registry: makeRegistry(),
            eligibilityInput: Self.singleReceiverInput,
            deletionService: PhotoAssetDeletionService { candidates in
                let assetIDs = Set(candidates.map(\.assetLocalIdentifier))
                await probe.record(assetIDs)
                return PhotoAssetDeletionResult(
                    deletedAssetIDs: assetIDs,
                    skippedAssetIDs: []
                )
            }
        )
    }

    private func candidate(_ assetLocalIdentifier: String) -> PhotoDeletionCandidate {
        PhotoDeletionCandidate(
            assetLocalIdentifier: assetLocalIdentifier,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
    }
}

private enum TestDeletionError: Error {
    case rejected
}

private actor PhotoDeletionProbe {
    private(set) var callCount = 0
    private(set) var lastRequestedAssetIDs: Set<String> = []

    func record(_ assetIDs: Set<String>) {
        callCount += 1
        lastRequestedAssetIDs = assetIDs
    }
}
