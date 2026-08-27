import Foundation

enum AutomaticSyncScheduleReason: Equatable, Sendable {
    case enabled
    case completed
    case retry
    case needsAttention
    case restore
}

struct AutomaticSyncPolicy: Sendable {
    static let interval: TimeInterval = 30 * 60

    /// Every launch is one attempt and nothing more. There is no daily quota
    /// and no wall-clock appointment, so the request is always re-armed the
    /// same fixed interval ahead, whatever the previous outcome was.
    var interval: TimeInterval { Self.interval }

    /// Charging is the gate that makes iOS willing to grant long processing
    /// windows, so the schedule asks for it and accepts that the iPhone
    /// simply does not sync while running on battery.
    var requiresExternalPower: Bool { true }

    func nextRequestDate(
        after now: Date,
        reason: AutomaticSyncScheduleReason
    ) -> Date {
        now.addingTimeInterval(interval)
    }

    /// A persisted eligibility is a relative interval, not a wall-clock
    /// appointment, so re-entering the app must never postpone it. An elapsed
    /// date stays elapsed and the next launch happens as soon as iOS allows.
    func restoredRequestDate(
        after now: Date,
        persistedDate: Date?
    ) -> Date {
        if let persistedDate {
            return persistedDate
        }
        return nextRequestDate(after: now, reason: .restore)
    }
}
