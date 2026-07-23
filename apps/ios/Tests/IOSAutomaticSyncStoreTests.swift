import XCTest
@testable import iPhone_Sync

final class IOSAutomaticSyncStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "IOSAutomaticSyncStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testNewStoreDefaultsToDisabledAndNeverRun() {
        let snapshot = IOSAutomaticSyncStore(defaults: defaults).snapshot

        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertNil(snapshot.lastAttemptAt)
        XCTAssertNil(snapshot.lastSuccessAt)
        XCTAssertEqual(snapshot.lastOutcome, .neverRun)
        XCTAssertNil(snapshot.lastMessage)
        XCTAssertNil(snapshot.nextEligibleAt)
    }

    func testStatePersistsAcrossStoreInstances() {
        let attemptAt = Date(timeIntervalSince1970: 1_774_320_000)
        let successAt = attemptAt.addingTimeInterval(42)
        let nextEligibleAt = successAt.addingTimeInterval(10 * 60)
        let firstStore = IOSAutomaticSyncStore(defaults: defaults)

        firstStore.setEnabled(true)
        firstStore.recordAttempt(at: attemptAt)
        firstStore.recordOutcome(
            .completed,
            message: "Synced 3 items.",
            at: successAt,
            successful: true
        )
        firstStore.recordNextEligibleAt(nextEligibleAt)

        let snapshot = IOSAutomaticSyncStore(defaults: defaults).snapshot
        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertEqual(snapshot.lastAttemptAt, attemptAt)
        XCTAssertEqual(snapshot.lastSuccessAt, successAt)
        XCTAssertEqual(snapshot.lastOutcome, .completed)
        XCTAssertEqual(snapshot.lastMessage, "Synced 3 items.")
        XCTAssertEqual(snapshot.nextEligibleAt, nextEligibleAt)
    }

    func testFailedOutcomeDoesNotOverwriteLastSuccess() {
        let successAt = Date(timeIntervalSince1970: 1_774_320_000)
        let failureAt = successAt.addingTimeInterval(60)
        let store = IOSAutomaticSyncStore(defaults: defaults)

        store.recordOutcome(
            .completed,
            message: "Initial success",
            at: successAt,
            successful: true
        )
        store.recordOutcome(
            .macUnavailable,
            message: "Paired Mac is unavailable.",
            at: failureAt,
            successful: false
        )

        let snapshot = store.snapshot
        XCTAssertEqual(snapshot.lastSuccessAt, successAt)
        XCTAssertEqual(snapshot.lastOutcome, .macUnavailable)
        XCTAssertEqual(snapshot.lastMessage, "Paired Mac is unavailable.")
    }

    func testEmptyMessageAndDisabledStateClearTransientFields() {
        let store = IOSAutomaticSyncStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_774_320_000)

        store.setEnabled(true)
        store.recordOutcome(
            .needsUserAction,
            message: "Open the app.",
            at: date,
            successful: false
        )
        store.recordNextEligibleAt(date)
        store.recordOutcome(
            .noChanges,
            message: "",
            at: date,
            successful: true
        )
        store.setEnabled(false)

        let snapshot = store.snapshot
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.lastSuccessAt, date)
        XCTAssertEqual(snapshot.lastOutcome, .noChanges)
        XCTAssertNil(snapshot.lastMessage)
        XCTAssertNil(snapshot.nextEligibleAt)
    }
}
