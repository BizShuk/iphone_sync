import XCTest
@testable import iPhone_Sync

final class AutomaticSyncPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private let allReasons: [AutomaticSyncScheduleReason] = [
        .enabled,
        .completed,
        .retry,
        .needsAttention,
        .restore,
    ]

    /// There is no daily quota and no wall-clock appointment: a successful run
    /// re-arms on exactly the same interval as a failed one, so the iPhone
    /// keeps checking while it stays on the charger.
    func testEveryReasonSchedulesThirtyMinutesLater() {
        let policy = AutomaticSyncPolicy()
        let now = date(year: 2026, month: 7, day: 23, hour: 20, minute: 34)
        let expected = now.addingTimeInterval(30 * 60)

        for reason in allReasons {
            XCTAssertEqual(
                policy.nextRequestDate(after: now, reason: reason),
                expected,
                "Unexpected schedule for \(reason)"
            )
        }
    }

    func testScheduleAlwaysRequiresExternalPower() {
        XCTAssertTrue(AutomaticSyncPolicy().requiresExternalPower)
    }

    func testRestorePreservesFutureEligibility() {
        let now = date(year: 2026, month: 7, day: 23, hour: 15)
        let persisted = now.addingTimeInterval(4 * 60)

        XCTAssertEqual(
            AutomaticSyncPolicy().restoredRequestDate(
                after: now,
                persistedDate: persisted
            ),
            persisted
        )
    }

    /// Eligibility is a relative interval, not an appointment, so reopening
    /// the app must not push an already elapsed request further away.
    func testRestorePreservesElapsedEligibilityWithoutPostponingIt() {
        let now = date(year: 2026, month: 7, day: 23, hour: 15)
        let persisted = now.addingTimeInterval(-4 * 60)

        XCTAssertEqual(
            AutomaticSyncPolicy().restoredRequestDate(
                after: now,
                persistedDate: persisted
            ),
            persisted
        )
    }

    func testRestoreWithoutPersistedDateSchedulesOneIntervalAhead() {
        let now = date(year: 2026, month: 7, day: 23, hour: 15)

        XCTAssertEqual(
            AutomaticSyncPolicy().restoredRequestDate(
                after: now,
                persistedDate: nil
            ),
            now.addingTimeInterval(30 * 60)
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
