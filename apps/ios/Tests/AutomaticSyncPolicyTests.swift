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

    func testTenMinuteCadenceSchedulesEveryReasonTenMinutesLater() {
        let policy = AutomaticSyncPolicy(cadence: .tenMinutes)
        let now = date(year: 2026, month: 7, day: 23, hour: 15, minute: 30)
        let expected = now.addingTimeInterval(10 * 60)

        for reason in allReasons {
            XCTAssertEqual(
                policy.nextRequestDate(after: now, reason: reason),
                expected,
                "Unexpected schedule for \(reason)"
            )
        }

        XCTAssertEqual(
            policy.foregroundTestDelay(after: now, nextEligibleAt: nil),
            .seconds(10 * 60)
        )
    }

    /// There is no daily quota and no wall-clock appointment: a successful run
    /// re-arms on exactly the same interval as a failed one, so the iPhone
    /// keeps checking while it stays on the charger.
    func testChargingCadenceSchedulesEveryReasonThirtyMinutesLater() {
        let policy = AutomaticSyncPolicy(cadence: .thirtyMinutesWhileCharging)
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

    func testOnlyTheChargingCadenceRequiresExternalPower() {
        XCTAssertTrue(
            AutomaticSyncPolicy(cadence: .thirtyMinutesWhileCharging)
                .requiresExternalPower
        )
        XCTAssertFalse(
            AutomaticSyncPolicy(cadence: .tenMinutes).requiresExternalPower
        )
    }

    func testChargingCadenceHasNoForegroundTestDelay() {
        let policy = AutomaticSyncPolicy(cadence: .thirtyMinutesWhileCharging)
        let now = date(year: 2026, month: 7, day: 23, hour: 15)

        XCTAssertNil(
            policy.foregroundTestDelay(
                after: now,
                nextEligibleAt: now.addingTimeInterval(-60)
            )
        )
    }

    func testRestorePreservesFutureEligibility() {
        let now = date(year: 2026, month: 7, day: 23, hour: 15)
        let persisted = now.addingTimeInterval(4 * 60)

        for cadence in [
            AutomaticSyncCadence.tenMinutes,
            .thirtyMinutesWhileCharging,
        ] {
            XCTAssertEqual(
                AutomaticSyncPolicy(cadence: cadence).restoredRequestDate(
                    after: now,
                    persistedDate: persisted
                ),
                persisted,
                "Unexpected restore for \(cadence)"
            )
        }
    }

    /// Eligibility is a relative interval, not an appointment, so reopening
    /// the app must not push an already elapsed request further away.
    func testRestorePreservesElapsedEligibilityWithoutPostponingIt() {
        let now = date(year: 2026, month: 7, day: 23, hour: 15)
        let persisted = now.addingTimeInterval(-4 * 60)

        for cadence in [
            AutomaticSyncCadence.tenMinutes,
            .thirtyMinutesWhileCharging,
        ] {
            XCTAssertEqual(
                AutomaticSyncPolicy(cadence: cadence).restoredRequestDate(
                    after: now,
                    persistedDate: persisted
                ),
                persisted,
                "Unexpected restore for \(cadence)"
            )
        }
    }

    func testRestoreWithoutPersistedDateSchedulesOneIntervalAhead() {
        let now = date(year: 2026, month: 7, day: 23, hour: 15)

        XCTAssertEqual(
            AutomaticSyncPolicy(cadence: .thirtyMinutesWhileCharging)
                .restoredRequestDate(after: now, persistedDate: nil),
            now.addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(
            AutomaticSyncPolicy(cadence: .tenMinutes)
                .restoredRequestDate(after: now, persistedDate: nil),
            now.addingTimeInterval(10 * 60)
        )
    }

    func testDebugForegroundDelayRunsElapsedEligibilityImmediately() {
        let policy = AutomaticSyncPolicy(cadence: .tenMinutes)
        let now = date(year: 2026, month: 7, day: 23, hour: 15)

        XCTAssertEqual(
            policy.foregroundTestDelay(
                after: now,
                nextEligibleAt: now.addingTimeInterval(-60)
            ),
            .zero
        )
        XCTAssertEqual(
            policy.foregroundTestDelay(
                after: now,
                nextEligibleAt: now.addingTimeInterval(4 * 60)
            ),
            .seconds(4 * 60)
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
