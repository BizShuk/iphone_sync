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
        static let enabled = "automaticSync.enabled"
        static let lastAttemptAt = "automaticSync.lastAttemptAt"
        static let lastSuccessAt = "automaticSync.lastSuccessAt"
        static let lastOutcome = "automaticSync.lastOutcome"
        static let lastMessage = "automaticSync.lastMessage"
        static let nextEligibleAt = "automaticSync.nextEligibleAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var snapshot: IOSAutomaticSyncSnapshot {
        IOSAutomaticSyncSnapshot(
            isEnabled: defaults.bool(forKey: Key.enabled),
            lastAttemptAt: defaults.object(forKey: Key.lastAttemptAt) as? Date,
            lastSuccessAt: defaults.object(forKey: Key.lastSuccessAt) as? Date,
            lastOutcome: defaults.string(forKey: Key.lastOutcome)
                .flatMap(AutomaticSyncOutcomeCode.init(rawValue:))
                ?? .neverRun,
            lastMessage: defaults.string(forKey: Key.lastMessage),
            nextEligibleAt: defaults.object(forKey: Key.nextEligibleAt) as? Date
        )
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.enabled)
        if !enabled {
            defaults.removeObject(forKey: Key.nextEligibleAt)
        }
    }

    func recordAttempt(at date: Date) {
        defaults.set(date, forKey: Key.lastAttemptAt)
    }

    func recordOutcome(
        _ outcome: AutomaticSyncOutcomeCode,
        message: String?,
        at date: Date,
        successful: Bool
    ) {
        defaults.set(outcome.rawValue, forKey: Key.lastOutcome)
        if let message, !message.isEmpty {
            defaults.set(message, forKey: Key.lastMessage)
        } else {
            defaults.removeObject(forKey: Key.lastMessage)
        }
        if successful {
            defaults.set(date, forKey: Key.lastSuccessAt)
        }
    }

    func recordNextEligibleAt(_ date: Date?) {
        if let date {
            defaults.set(date, forKey: Key.nextEligibleAt)
        } else {
            defaults.removeObject(forKey: Key.nextEligibleAt)
        }
    }
}
