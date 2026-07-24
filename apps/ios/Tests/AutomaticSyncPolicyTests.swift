import XCTest
@testable import iPhone_Sync

final class AutomaticSyncPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    func testTenMinuteCadenceSchedulesEveryReasonTenMinutesLater() {
        let policy = AutomaticSyncPolicy(cadence: .tenMinutes, calendar: calendar)
        let now = date(year: 2026, month: 7, day: 23, hour: 15, minute: 30)
        let expected = now.addingTimeInterval(10 * 60)
        let reasons: [AutomaticSyncScheduleReason] = [
            .enabled,
            .completed,
            .retry,
            .needsAttention,
            .restore,
        ]

        for reason in reasons {
            XCTAssertEqual(
                policy.nextRequestDate(after: now, lastSuccess: nil, reason: reason),
                expected,
                "Unexpected schedule for \(reason)"
            )
        }

        XCTAssertEqual(
            policy.foregroundTestDelay(
                after: now,
                nextEligibleAt: nil
            ),
            .seconds(10 * 60)
        )
    }

    func testDailyCadenceUsesNextLocalMidnightForNormalScheduling() {
        let policy = AutomaticSyncPolicy(
            cadence: .dailyAtLocalMidnight,
            calendar: calendar
        )
        let now = date(year: 2026, month: 7, day: 23, hour: 15, minute: 30)
        let nextMidnight = date(year: 2026, month: 7, day: 24)

        for reason in [
            AutomaticSyncScheduleReason.enabled,
            .completed,
            .needsAttention,
        ] {
            XCTAssertEqual(
                policy.nextRequestDate(after: now, lastSuccess: nil, reason: reason),
                nextMidnight,
                "Unexpected schedule for \(reason)"
            )
        }

        XCTAssertNil(policy.foregroundTestDelay(
            after: now,
            nextEligibleAt: nextMidnight
        ))
    }

    func testDailyCadenceRetriesInOneHourUntilSuccessfulToday() {
        let policy = AutomaticSyncPolicy(
            cadence: .dailyAtLocalMidnight,
            calendar: calendar
        )
        let now = date(year: 2026, month: 7, day: 23, hour: 15, minute: 30)
        let previousDay = date(year: 2026, month: 7, day: 22, hour: 23, minute: 59)
        let successfulToday = date(year: 2026, month: 7, day: 23, hour: 8)

        XCTAssertEqual(
            policy.nextRequestDate(after: now, lastSuccess: nil, reason: .retry),
            now.addingTimeInterval(60 * 60)
        )
        XCTAssertEqual(
            policy.nextRequestDate(
                after: now,
                lastSuccess: previousDay,
                reason: .retry
            ),
            now.addingTimeInterval(60 * 60)
        )
        XCTAssertEqual(
            policy.nextRequestDate(
                after: now,
                lastSuccess: successfulToday,
                reason: .retry
            ),
            date(year: 2026, month: 7, day: 24)
        )
    }

    func testDailyCadenceRestoresAtNextConfiguredLocalTimeRegardlessOfLastSuccess() {
        let policy = AutomaticSyncPolicy(
            cadence: .dailyAtLocalTime(hour: 0, minute: 53),
            calendar: calendar
        )
        let now = date(year: 2026, month: 7, day: 23, hour: 20, minute: 34)
        let previousDay = date(year: 2026, month: 7, day: 22, hour: 23, minute: 59)
        let successfulToday = date(year: 2026, month: 7, day: 23, hour: 8)
        let nextConfiguredTime = date(year: 2026, month: 7, day: 24, hour: 0, minute: 53)

        XCTAssertEqual(
            policy.nextRequestDate(after: now, lastSuccess: nil, reason: .restore),
            nextConfiguredTime
        )
        XCTAssertEqual(
            policy.nextRequestDate(
                after: now,
                lastSuccess: previousDay,
                reason: .restore
            ),
            nextConfiguredTime
        )
        XCTAssertEqual(
            policy.nextRequestDate(
                after: now,
                lastSuccess: successfulToday,
                reason: .restore
            ),
            nextConfiguredTime
        )
    }

    func testSuccessfulRunTodayUsesLocalCalendarDay() {
        let policy = AutomaticSyncPolicy(
            cadence: .dailyAtLocalMidnight,
            calendar: calendar
        )
        let now = date(year: 2026, month: 7, day: 23, hour: 15, minute: 30)

        XCTAssertFalse(policy.hasSuccessfulRunToday(nil, now: now))
        XCTAssertFalse(
            policy.hasSuccessfulRunToday(
                date(year: 2026, month: 7, day: 22, hour: 23, minute: 59),
                now: now
            )
        )
        XCTAssertTrue(
            policy.hasSuccessfulRunToday(
                date(year: 2026, month: 7, day: 23),
                now: now
            )
        )
        XCTAssertFalse(
            policy.hasSuccessfulRunToday(
                date(year: 2026, month: 7, day: 24),
                now: now
            )
        )
    }

    func testNextMidnightUsesCalendarAcrossDaylightSavingChange() {
        let policy = AutomaticSyncPolicy(
            cadence: .dailyAtLocalMidnight,
            calendar: calendar
        )
        let now = date(year: 2026, month: 3, day: 8, hour: 1, minute: 30)

        let next = policy.nextRequestDate(
            after: now,
            lastSuccess: nil,
            reason: .completed
        )

        XCTAssertEqual(next, date(year: 2026, month: 3, day: 9))
        XCTAssertEqual(next.timeIntervalSince(now), 21.5 * 60 * 60)
    }

    func testNextMidnightRecomputesForInjectedTimezone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 23,
            hour: 18
        ))!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        let losAngelesNext = AutomaticSyncPolicy(
            cadence: .dailyAtLocalMidnight,
            calendar: calendar
        ).nextRequestDate(after: instant, lastSuccess: nil, reason: .completed)
        let tokyoNext = AutomaticSyncPolicy(
            cadence: .dailyAtLocalMidnight,
            calendar: tokyo
        ).nextRequestDate(after: instant, lastSuccess: nil, reason: .completed)

        XCTAssertEqual(losAngelesNext.timeIntervalSince(instant), 13 * 60 * 60)
        XCTAssertEqual(tokyoNext.timeIntervalSince(instant), 21 * 60 * 60)
    }

    func testDailyRestoreIgnoresPersistedDateFromPreviousTimezone() {
        var utc = Calendar(identifier: .gregorian)
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = utc.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 23,
            hour: 18
        ))!
        let staleLosAngelesMidnight = now.addingTimeInterval(13 * 60 * 60)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.locale = Locale(identifier: "en_US_POSIX")
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let policy = AutomaticSyncPolicy(
            cadence: .dailyAtLocalMidnight,
            calendar: tokyo
        )
        let nextTokyoMidnight = tokyo.date(from: DateComponents(
            timeZone: tokyo.timeZone,
            year: 2026,
            month: 7,
            day: 25
        ))!

        let restoredDate = policy.restoredRequestDate(
            after: now,
            lastSuccess: nil,
            persistedDate: staleLosAngelesMidnight
        )

        XCTAssertEqual(restoredDate, nextTokyoMidnight)
        XCTAssertNotEqual(restoredDate, staleLosAngelesMidnight)
        XCTAssertNotEqual(restoredDate, now)
    }

    func testDebugRestorePreservesFutureEligibility() {
        let policy = AutomaticSyncPolicy(
            cadence: .tenMinutes,
            calendar: calendar
        )
        let now = date(year: 2026, month: 7, day: 23, hour: 15)
        let persisted = now.addingTimeInterval(4 * 60)

        XCTAssertEqual(
            policy.restoredRequestDate(
                after: now,
                lastSuccess: nil,
                persistedDate: persisted
            ),
            persisted
        )
    }

    func testDebugRestorePreservesElapsedEligibilityWithoutPostponingIt() {
        let policy = AutomaticSyncPolicy(
            cadence: .tenMinutes,
            calendar: calendar
        )
        let now = date(year: 2026, month: 7, day: 23, hour: 15)
        let persisted = now.addingTimeInterval(-4 * 60)

        XCTAssertEqual(
            policy.restoredRequestDate(
                after: now,
                lastSuccess: nil,
                persistedDate: persisted
            ),
            persisted
        )
    }

    func testDebugForegroundDelayRunsElapsedEligibilityImmediately() {
        let policy = AutomaticSyncPolicy(
            cadence: .tenMinutes,
            calendar: calendar
        )
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
