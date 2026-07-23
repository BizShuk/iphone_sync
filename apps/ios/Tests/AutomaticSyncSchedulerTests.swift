import BackgroundTasks
import Foundation
import SyncCore
import XCTest
@testable import iPhone_Sync

@MainActor
final class AutomaticSyncSchedulerTests: XCTestCase {
    func testRestoreKeepsMatchingPendingRequestWithoutResubmitting() async {
        let now = Date(timeIntervalSince1970: 1_774_300_000)
        let eligibleAt = now.addingTimeInterval(4 * 60)
        let pendingRequest = AutomaticSyncPendingRequest(
            identifier: AutomaticSyncScheduler.taskIdentifier,
            earliestBeginDate: eligibleAt
        )
        let requestScheduler = FakeAutomaticSyncRequestScheduler(
            pendingRequests: [pendingRequest]
        )
        let (scheduler, store, defaults) = makeScheduler(
            now: now,
            requestScheduler: requestScheduler
        )
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store.setEnabled(true)
        store.recordNextEligibleAt(eligibleAt)

        await scheduler.ensureScheduled()
        await scheduler.ensureScheduled()

        XCTAssertEqual(requestScheduler.submittedRequests, [])
        XCTAssertEqual(requestScheduler.cancelledIdentifiers, [])
        XCTAssertEqual(requestScheduler.pendingRequestSnapshots, [pendingRequest])
        XCTAssertEqual(store.snapshot.nextEligibleAt, eligibleAt)
    }

    func testRestoreSubmitsElapsedEligibilityOnlyOnce() async {
        let now = Date(timeIntervalSince1970: 1_774_300_000)
        let elapsedEligibility = now.addingTimeInterval(-4 * 60)
        let requestScheduler = FakeAutomaticSyncRequestScheduler()
        let (scheduler, store, defaults) = makeScheduler(
            now: now,
            requestScheduler: requestScheduler
        )
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store.setEnabled(true)
        store.recordNextEligibleAt(elapsedEligibility)

        await scheduler.ensureScheduled()
        await scheduler.ensureScheduled()

        XCTAssertEqual(
            requestScheduler.submittedRequests,
            [AutomaticSyncPendingRequest(
                identifier: AutomaticSyncScheduler.taskIdentifier,
                earliestBeginDate: elapsedEligibility
            )]
        )
        XCTAssertEqual(requestScheduler.cancelledIdentifiers, [])
        XCTAssertEqual(store.snapshot.nextEligibleAt, elapsedEligibility)
    }

    func testPendingRequestIsReplacedOnlyWhenDesiredEligibilityIsEarlier() {
        let desiredDate = Date(timeIntervalSince1970: 1_774_300_000)

        XCTAssertTrue(AutomaticSyncScheduler.shouldReplacePendingRequest(
            AutomaticSyncPendingRequest(
                identifier: AutomaticSyncScheduler.taskIdentifier,
                earliestBeginDate: desiredDate.addingTimeInterval(60)
            ),
            with: desiredDate
        ))
        XCTAssertFalse(AutomaticSyncScheduler.shouldReplacePendingRequest(
            AutomaticSyncPendingRequest(
                identifier: AutomaticSyncScheduler.taskIdentifier,
                earliestBeginDate: desiredDate.addingTimeInterval(-60)
            ),
            with: desiredDate
        ))
        XCTAssertFalse(AutomaticSyncScheduler.shouldReplacePendingRequest(
            AutomaticSyncPendingRequest(
                identifier: AutomaticSyncScheduler.taskIdentifier,
                earliestBeginDate: nil
            ),
            with: desiredDate
        ))
    }

    private var defaultsSuiteName: String {
        "AutomaticSyncSchedulerTests"
    }

    private func makeScheduler(
        now: Date,
        requestScheduler: FakeAutomaticSyncRequestScheduler
    ) -> (
        scheduler: AutomaticSyncScheduler,
        store: IOSAutomaticSyncStore,
        defaults: UserDefaults
    ) {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let store = IOSAutomaticSyncStore(defaults: defaults)
        let runtime = IOSSyncRuntime(environment: IOSSyncRuntimeEnvironment(
            hasFullPhotoAccess: { true },
            loadSelectedAlbums: { [] },
            hasPairedPeer: { true },
            sync: { _, _ in .zero },
            cancel: {}
        ))
        let scheduler = AutomaticSyncScheduler(
            runtime: runtime,
            store: store,
            policy: AutomaticSyncPolicy(
                cadence: .tenMinutes,
                calendar: Calendar(identifier: .gregorian)
            ),
            requestScheduler: requestScheduler,
            now: { now },
            onSnapshotChange: { _ in },
            onRunStateChange: { _ in }
        )
        return (scheduler, store, defaults)
    }
}

@MainActor
private final class FakeAutomaticSyncRequestScheduler:
    AutomaticSyncRequestScheduling {
    private(set) var submittedRequests: [AutomaticSyncPendingRequest] = []
    private(set) var cancelledIdentifiers: [String] = []
    private(set) var pendingRequestSnapshots: [AutomaticSyncPendingRequest]

    init(pendingRequests: [AutomaticSyncPendingRequest] = []) {
        pendingRequestSnapshots = pendingRequests
    }

    func submit(_ request: BGTaskRequest) throws {
        let snapshot = AutomaticSyncPendingRequest(
            identifier: request.identifier,
            earliestBeginDate: request.earliestBeginDate
        )
        submittedRequests.append(snapshot)
        pendingRequestSnapshots.removeAll {
            $0.identifier == request.identifier
        }
        pendingRequestSnapshots.append(snapshot)
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
        pendingRequestSnapshots.removeAll {
            $0.identifier == identifier
        }
    }

    func pendingRequests() async -> [AutomaticSyncPendingRequest] {
        pendingRequestSnapshots
    }
}
