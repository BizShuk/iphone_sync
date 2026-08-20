import Foundation

enum AutomaticSyncCadence: Equatable, Sendable {
    case tenMinutes
    case thirtyMinutesWhileCharging
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
    static let productionInterval: TimeInterval = 30 * 60

    let cadence: AutomaticSyncCadence

    init(cadence: AutomaticSyncCadence) {
        self.cadence = cadence
    }

    /// Every launch is one attempt and nothing more. There is no daily quota
    /// and no wall-clock appointment, so the request is always re-armed the
    /// same fixed interval ahead, whatever the previous outcome was.
    var interval: TimeInterval {
        switch cadence {
        case .tenMinutes:
            Self.debugInterval
        case .thirtyMinutesWhileCharging:
            Self.productionInterval
        }
    }

    /// Charging is the gate that makes iOS willing to grant long processing
    /// windows, so the production cadence asks for it and accepts that the
    /// iPhone simply does not sync while running on battery. The debug lane
    /// stays power-free so the launch path can be tested without a cable.
    var requiresExternalPower: Bool {
        switch cadence {
        case .tenMinutes:
            false
        case .thirtyMinutesWhileCharging:
            true
        }
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
