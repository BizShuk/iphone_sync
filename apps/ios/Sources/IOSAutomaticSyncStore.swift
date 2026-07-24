import Foundation

enum AutomaticSyncOutcomeCode: String, Codable, Equatable, Sendable {
    case neverRun
    case completed
    case noChanges
    case macUnavailable
    case networkUnavailable
    case alreadyRunning
    case alreadyCompletedToday
    case photosAccessRequired
    case albumsRequired
    case pairingRequired
    case budgetExhausted
    case cancelled
    case needsUserAction
    case failed
}

struct IOSAutomaticSyncSnapshot: Equatable, Sendable {
    var isEnabled: Bool
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastOutcome: AutomaticSyncOutcomeCode
    var lastMessage: String?
    var nextEligibleAt: Date?
}

struct IOSAutomaticSyncStore: @unchecked Sendable {
    private enum Key {
        static let enabled = "enabled"
        static let lastAttemptAt = "lastAttemptAt"
        static let lastSuccessAt = "lastSuccessAt"
        static let lastOutcome = "lastOutcome"
        static let lastMessage = "lastMessage"
        static let nextEligibleAt = "nextEligibleAt"
        static let dailyHour = "daily.hour"
        static let dailyMinute = "daily.minute"
    }

    private let defaults: UserDefaults
    private let prefix: String

    init(
        prefix: String = "automaticSync",
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.prefix = prefix
    }

    var snapshot: IOSAutomaticSyncSnapshot {
        let keyPrefix = "\(prefix)."
        return IOSAutomaticSyncSnapshot(
            isEnabled: defaults.bool(forKey: keyPrefix + Key.enabled),
            lastAttemptAt: defaults.object(forKey: keyPrefix + Key.lastAttemptAt) as? Date,
            lastSuccessAt: defaults.object(forKey: keyPrefix + Key.lastSuccessAt) as? Date,
            lastOutcome: defaults.string(forKey: keyPrefix + Key.lastOutcome)
                .flatMap(AutomaticSyncOutcomeCode.init(rawValue:))
                ?? .neverRun,
            lastMessage: defaults.string(forKey: keyPrefix + Key.lastMessage),
            nextEligibleAt: defaults.object(forKey: keyPrefix + Key.nextEligibleAt) as? Date
        )
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "\(prefix).\(Key.enabled)")
        if !enabled {
            defaults.removeObject(forKey: "\(prefix).\(Key.nextEligibleAt)")
        }
    }

    func recordAttempt(at date: Date) {
        defaults.set(date, forKey: "\(prefix).\(Key.lastAttemptAt)")
    }

    func recordOutcome(
        _ outcome: AutomaticSyncOutcomeCode,
        message: String?,
        at date: Date,
        successful: Bool
    ) {
        defaults.set(outcome.rawValue, forKey: "\(prefix).\(Key.lastOutcome)")
        if let message, !message.isEmpty {
            defaults.set(message, forKey: "\(prefix).\(Key.lastMessage)")
        } else {
            defaults.removeObject(forKey: "\(prefix).\(Key.lastMessage)")
        }
        if successful {
            defaults.set(date, forKey: "\(prefix).\(Key.lastSuccessAt)")
        }
    }

    func recordNextEligibleAt(_ date: Date?) {
        if let date {
            defaults.set(date, forKey: "\(prefix).\(Key.nextEligibleAt)")
        } else {
            defaults.removeObject(forKey: "\(prefix).\(Key.nextEligibleAt)")
        }
    }

    func setDailySyncTime(hour: Int, minute: Int) {
        let normalizedHour = max(0, min(23, hour))
        let normalizedMinute = max(0, min(59, minute))
        defaults.set(normalizedHour, forKey: "\(prefix).\(Key.dailyHour)")
        defaults.set(normalizedMinute, forKey: "\(prefix).\(Key.dailyMinute)")
    }

    var dailyHour: Int {
        defaults.integer(forKey: "\(prefix).\(Key.dailyHour)")
    }

    var dailyMinute: Int {
        defaults.integer(forKey: "\(prefix).\(Key.dailyMinute)")
    }
}
