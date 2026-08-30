import BackgroundTasks
import Foundation
import SyncCore
import XCTest
@testable import iPhone_Sync

@MainActor
final class AutomaticSyncSchedulerTests: XCTestCase {
    func testAppInfoPlistPermitsOnlyTheAutomaticSyncTaskIdentifier() throws {
        let permittedIdentifiers = try XCTUnwrap(
            Bundle.main.object(
                forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
            ) as? [String]
        )

        XCTAssertEqual(
            permittedIdentifiers,
            [AutomaticSyncScheduler.taskIdentifier]
        )
    }

    func testNotPermittedSubmissionDisablesAutomaticSync() async {
        let now = Date(timeIntervalSince1970: 1_774_300_000)
        let requestScheduler = FakeAutomaticSyncRequestScheduler(
            submitError: NSError(
                domain: "BGTaskSchedulerErrorDomain",
                code: 3
            )
        )
        let (scheduler, store, defaults) = makeScheduler(
            now: now,
            requestScheduler: requestScheduler
        )
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store.setEnabled(true)

        await scheduler.ensureScheduled()

        XCTAssertFalse(store.snapshot.isEnabled)
        XCTAssertEqual(store.snapshot.lastOutcome, .failed)
        XCTAssertNil(store.snapshot.nextEligibleAt)
        XCTAssertEqual(
            requestScheduler.cancelledIdentifiers,
            [AutomaticSyncScheduler.taskIdentifier]
        )
    }

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

    /// The cadence never recomputes a wall-clock appointment, so an elapsed
    /// eligibility survives an app relaunch untouched and iOS gets to launch
    /// as soon as it allows, with or without external power.
    func testRestoreKeepsElapsedEligibilityAndNeverAsksForExternalPower() async {
        let now = Date(timeIntervalSince1970: 1_774_300_000)
        let elapsedDate = now.addingTimeInterval(-4 * 60)
        let requestScheduler = FakeAutomaticSyncRequestScheduler()
        let (scheduler, store, defaults) = makeScheduler(
            now: now,
            requestScheduler: requestScheduler,
        )
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store.setEnabled(true)
        store.recordNextEligibleAt(elapsedDate)

        await scheduler.ensureScheduled()

        XCTAssertEqual(
            requestScheduler.submittedRequests.map(\.earliestBeginDate),
            [elapsedDate]
        )
        XCTAssertEqual(requestScheduler.submittedExternalPowerFlags, [false])
        XCTAssertEqual(requestScheduler.submittedNetworkFlags, [true])
        XCTAssertEqual(requestScheduler.cancelledIdentifiers, [])
        XCTAssertEqual(store.snapshot.nextEligibleAt, elapsedDate)
    }

    private var defaultsSuiteName: String {
        "AutomaticSyncSchedulerTests"
    }

    private func makeScheduler(
        now: Date,
        requestScheduler: FakeAutomaticSyncRequestScheduler,
        policy: AutomaticSyncPolicy = AutomaticSyncPolicy()
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
            sync: { _, _, _ in .zero },
            cancel: {}
        ))
        let scheduler = AutomaticSyncScheduler(
            runtime: runtime,
            store: store,
            policy: policy,
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
    private(set) var submittedExternalPowerFlags: [Bool] = []
    private(set) var submittedNetworkFlags: [Bool] = []
    private(set) var cancelledIdentifiers: [String] = []
    private(set) var pendingRequestSnapshots: [AutomaticSyncPendingRequest]
    private let submitError: Error?

    init(
        pendingRequests: [AutomaticSyncPendingRequest] = [],
        submitError: Error? = nil
    ) {
        pendingRequestSnapshots = pendingRequests
        self.submitError = submitError
    }

    func submit(_ request: BGTaskRequest) throws {
        if let submitError {
            throw submitError
        }
        let snapshot = AutomaticSyncPendingRequest(
            identifier: request.identifier,
            earliestBeginDate: request.earliestBeginDate
        )
        submittedRequests.append(snapshot)
        if let processingRequest = request as? BGProcessingTaskRequest {
            submittedExternalPowerFlags.append(
                processingRequest.requiresExternalPower
            )
            submittedNetworkFlags.append(
                processingRequest.requiresNetworkConnectivity
            )
        }
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
