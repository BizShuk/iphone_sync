import BackgroundTasks
import Foundation
import SyncCore
import XCTest
@testable import iPhone_Sync

@MainActor
final class AutomaticSyncSchedulerTests: XCTestCase {
    func testAppInfoPlistPermitsProductionAndDebugTaskIdentifiers() throws {
        let permittedIdentifiers = try XCTUnwrap(
            Bundle.main.object(
                forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
            ) as? [String]
        )

        XCTAssertTrue(Set([
            AutomaticSyncScheduler.taskIdentifier,
            AutomaticSyncScheduler.debugTaskIdentifier,
        ]).isSubset(of: Set(permittedIdentifiers)))
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

    func testDailyRestoreRecomputesElapsedEligibilityAtNextConfiguredLocalTime() async {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        gregorian.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let now = gregorian.date(from: DateComponents(
            timeZone: gregorian.timeZone,
            year: 2026,
            month: 7,
            day: 23,
            hour: 20,
            minute: 34
        ))!
        let elapsedDate = now.addingTimeInterval(-4 * 60)
        let expectedNextDailyRun = gregorian.date(from: DateComponents(
            timeZone: gregorian.timeZone,
            year: 2026,
            month: 7,
            day: 24,
            hour: 0,
            minute: 53
        ))!
        let requestScheduler = FakeAutomaticSyncRequestScheduler()
        let (scheduler, store, defaults) = makeScheduler(
            now: now,
            requestScheduler: requestScheduler,
            policy: AutomaticSyncPolicy(
                cadence: .dailyAtLocalTime(hour: 0, minute: 53),
                calendar: gregorian
            )
        )
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        store.setEnabled(true)
        store.recordNextEligibleAt(elapsedDate)

        await scheduler.ensureScheduled()

        XCTAssertEqual(
            requestScheduler.submittedRequests,
            [AutomaticSyncPendingRequest(
                identifier: AutomaticSyncScheduler.taskIdentifier,
                earliestBeginDate: expectedNextDailyRun
            )]
        )
        XCTAssertEqual(requestScheduler.cancelledIdentifiers, [])
        XCTAssertEqual(store.snapshot.nextEligibleAt, expectedNextDailyRun)
        XCTAssertNotEqual(store.snapshot.nextEligibleAt, elapsedDate)
        XCTAssertNotEqual(store.snapshot.nextEligibleAt, now)
    }

    private var defaultsSuiteName: String {
        "AutomaticSyncSchedulerTests"
    }

    private func makeScheduler(
        now: Date,
        requestScheduler: FakeAutomaticSyncRequestScheduler,
        policy: AutomaticSyncPolicy = AutomaticSyncPolicy(
            cadence: .tenMinutes,
            calendar: Calendar(identifier: .gregorian)
        )
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
