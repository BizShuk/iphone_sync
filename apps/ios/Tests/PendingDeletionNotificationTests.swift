import Foundation
import SyncCore
import XCTest
@testable import iPhone_Sync

private actor NotifierProbe {
    private(set) var authorizationRequests = 0
    private(set) var notifiedCounts: [Int] = []
    private(set) var clearCount = 0

    func recordAuthorizationRequest() { authorizationRequests += 1 }
    func recordNotify(_ count: Int) { notifiedCounts.append(count) }
    func recordClear() { clearCount += 1 }
}

final class PendingDeletionNotificationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "PendingDeletionNotificationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testBackgroundRunNotifiesAboutPendingConfirmation() async {
        let probe = NotifierProbe()
        let controller = makeController(probe: probe)
        controller.setEnabled(true)

        await controller.handleSuccessfulSync(
            candidates: [candidate("asset-a"), candidate("asset-b")],
            trigger: .automaticBackground
        )

        let counts = await probe.notifiedCounts
        XCTAssertEqual(counts, [2])
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 2)
    }

    @MainActor
    func testForegroundRunDeletesWithoutNotifyingAndClearsThePrompt() async {
        let probe = NotifierProbe()
        let controller = makeController(probe: probe)
        controller.setEnabled(true)

        await controller.handleSuccessfulSync(
            candidates: [candidate("asset-a")],
            trigger: .manualForeground
        )

        let counts = await probe.notifiedCounts
        let clears = await probe.clearCount
        XCTAssertTrue(counts.isEmpty)
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(controller.snapshot.pendingAssetCount, 0)
    }

    @MainActor
    func testDisablingClearsThePromptAndEnablingAsksForAuthorization() async {
        let probe = NotifierProbe()
        let controller = makeController(probe: probe)

        controller.setEnabled(true)
        await waitUntil { await probe.authorizationRequests == 1 }
        controller.setEnabled(false)
        await waitUntil { await probe.clearCount == 1 }

        let requests = await probe.authorizationRequests
        let clears = await probe.clearCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(clears, 1)
    }

    /// `setEnabled` hands the notifier work to a detached task, so the probe is
    /// polled instead of assuming a single scheduler hop is enough.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the notifier probe to settle.")
    }

    @MainActor
    private func makeController(
        probe: NotifierProbe
    ) -> IOSPostSyncDeletionController {
        IOSPostSyncDeletionController(
            store: IOSDeleteAfterSyncStore(
                prefix: "deleteAfterSync",
                defaults: defaults
            ),
            deletionService: PhotoAssetDeletionService { candidates in
                let assetIDs = Set(candidates.map(\.assetLocalIdentifier))
                return PhotoAssetDeletionResult(
                    deletedAssetIDs: assetIDs,
                    skippedAssetIDs: []
                )
            },
            notifier: PendingDeletionNotifier(
                requestAuthorization: { await probe.recordAuthorizationRequest() },
                notifyPending: { await probe.recordNotify($0) },
                clearPending: { await probe.recordClear() }
            )
        )
    }

    private func candidate(_ assetID: String) -> PhotoDeletionCandidate {
        PhotoDeletionCandidate(
            assetLocalIdentifier: assetID,
            modificationDate: Date(timeIntervalSince1970: 42)
        )
    }
}
