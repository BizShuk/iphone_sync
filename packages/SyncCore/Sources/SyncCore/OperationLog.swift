import Foundation

public enum OperationLogLevel: String, Codable, CaseIterable, Sendable {
    case info
    case success
    case warning
    case error
}

public struct OperationLogEvent: Equatable, Sendable {
    public let level: OperationLogLevel
    public let category: String
    public let message: String

    public init(
        level: OperationLogLevel,
        category: String,
        message: String
    ) {
        self.level = level
        self.category = category
        self.message = message
    }
}

public struct OperationLogEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let level: OperationLogLevel
    public let category: String
    public let message: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        event: OperationLogEvent
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.level = event.level
        self.category = event.category
        self.message = event.message
    }
}

public struct OperationLogBuffer: Sendable {
    public static let defaultCapacity = 500

    public let capacity: Int
    public private(set) var entries: [OperationLogEntry]

    public init(
        capacity: Int = OperationLogBuffer.defaultCapacity,
        entries: [OperationLogEntry] = []
    ) {
        self.capacity = max(1, capacity)
        self.entries = Array(entries.prefix(max(1, capacity)))
    }

    @discardableResult
    public mutating func record(
        _ event: OperationLogEvent,
        occurredAt: Date = Date(),
        id: UUID = UUID()
    ) -> OperationLogEntry {
        let entry = OperationLogEntry(
            id: id,
            occurredAt: occurredAt,
            event: event
        )
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        return entry
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
