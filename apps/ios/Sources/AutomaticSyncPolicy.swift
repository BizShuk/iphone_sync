import Foundation

enum AutomaticSyncCadence: Equatable, Sendable {
    case tenMinutes
    case dailyAtLocalMidnight
    case dailyAtLocalTime(hour: Int, minute: Int)
}

enum AutomaticSyncScheduleReason: Equatable, Sendable {
    case enabled
    case completed
    case retry
    case needsAttention
    case restore
}

struct AutomaticSyncPolicy: Sendable {
    static let debugInterval: TimeInterval = 10 * 60
    static let productionRetryInterval: TimeInterval = 60 * 60
    static let scheduledRunMaximumDuration: Duration = .seconds(8 * 60)
    static let productionDefaultHour = 0
    static let productionDefaultMinute = 0

    let cadence: AutomaticSyncCadence
    var calendar: Calendar

    init(
        cadence: AutomaticSyncCadence,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.cadence = cadence
        self.calendar = calendar
    }

    static var current: AutomaticSyncPolicy {
#if DEBUG
        AutomaticSyncPolicy(cadence: .tenMinutes)
#else
        AutomaticSyncPolicy(cadence: .dailyAtLocalTime(
            hour: productionDefaultHour,
            minute: productionDefaultMinute
        ))
#endif
    }

    func foregroundTestDelay(
        after now: Date,
        nextEligibleAt: Date?
    ) -> Duration? {
        guard cadence == .tenMinutes else { return nil }
        let eligibleAt = nextEligibleAt
            ?? now.addingTimeInterval(Self.debugInterval)
        return .seconds(max(0, eligibleAt.timeIntervalSince(now)))
    }

    func hasSuccessfulRunToday(_ lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return false }
        return calendar.isDate(lastSuccess, inSameDayAs: now)
    }

    func nextRequestDate(
        after now: Date,
        lastSuccess: Date?,
        reason: AutomaticSyncScheduleReason
    ) -> Date {
        switch cadence {
        case .tenMinutes:
            return now.addingTimeInterval(Self.debugInterval)
        case .dailyAtLocalMidnight, .dailyAtLocalTime:
            if reason == .retry, !hasSuccessfulRunToday(lastSuccess, now: now) {
                return now.addingTimeInterval(Self.productionRetryInterval)
            }
            if reason == .restore, !hasSuccessfulRunToday(lastSuccess, now: now) {
                return now
            }
            let components = dailyTimeComponents
            return nextDailyRun(after: now, hour: components.hour, minute: components.minute)
        }
    }

    func restoredRequestDate(
        after now: Date,
        lastSuccess: Date?,
        persistedDate: Date?
    ) -> Date {
        switch cadence {
        case .tenMinutes:
            if let persistedDate {
                return persistedDate
            }
            return nextRequestDate(
                after: now,
                lastSuccess: lastSuccess,
                reason: .restore
            )
        case .dailyAtLocalMidnight, .dailyAtLocalTime:
            // A persisted absolute date was calculated in the previous local
            // timezone. Recompute daily scheduling whenever the app wakes.
            return nextRequestDate(
                after: now,
                lastSuccess: lastSuccess,
                reason: .restore
            )
        }
    }

    var isDailyCadence: Bool {
        switch cadence {
        case .dailyAtLocalMidnight, .dailyAtLocalTime:
            return true
        case .tenMinutes:
            return false
        }
    }

    var dailyTimeComponents: (hour: Int, minute: Int) {
        switch cadence {
        case .tenMinutes:
            return (0, 0)
        case .dailyAtLocalMidnight:
            return (0, 0)
        case let .dailyAtLocalTime(hour, minute):
            return (
                max(0, min(23, hour)),
                max(0, min(59, minute))
            )
        }
    }

    private func nextDailyRun(after now: Date, hour: Int, minute: Int) -> Date {
        let calendar = self.calendar
        let todayStart = calendar.startOfDay(for: now)
        let todayRun = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: todayStart
        ) ?? now
        if todayRun <= now {
            return calendar.date(
                byAdding: .day,
                value: 1,
                to: todayRun
            ) ?? now.addingTimeInterval(24 * 60 * 60)
        }
        return todayRun
    }
}
