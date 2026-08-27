import Foundation
import SyncCore

/// Durable JSONL mirror of the in-memory `OperationLogBuffer`.
///
/// Scheduled runs execute in a process iOS suspends and usually terminates
/// shortly afterwards, so an in-memory-only timeline silently loses every
/// event a background sync recorded — including the warning that fully
/// backed-up photos are waiting for foreground deletion confirmation. This
/// store appends each entry to disk and reloads the newest ones at launch so
/// background behaviour stays auditable.
final class PersistentOperationLogStore: @unchecked Sendable {
    private struct StoredEntry: Codable {
        let id: UUID
        let occurredAt: Date
        let level: OperationLogLevel
        let category: String
        let message: String
    }

    private let fileURL: URL
    private let capacity: Int
    private let queue = DispatchQueue(
        label: "com.shuk.iphonesync.ios.operation-log"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var appendsSinceCompaction = 0

    init(
        fileURL: URL = PersistentOperationLogStore.defaultFileURL(),
        capacity: Int = OperationLogBuffer.defaultCapacity
    ) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OperationLog", isDirectory: true)
            .appendingPathComponent("operation-log.jsonl", isDirectory: false)
    }

    /// Newest first, matching the in-memory buffer ordering.
    func loadEntries() -> [OperationLogEntry] {
        queue.sync { newestFirstEntries() }
    }

    func append(_ entry: OperationLogEntry) {
        let stored = StoredEntry(
            id: entry.id,
            occurredAt: entry.occurredAt,
            level: entry.level,
            category: entry.category,
            message: entry.message
        )
        queue.async { [self] in
            guard var line = try? encoder.encode(stored) else { return }
            line.append(0x0A)
            write(line)
            appendsSinceCompaction += 1
            if appendsSinceCompaction >= capacity {
                compact()
            }
        }
    }

    func clear() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: fileURL)
            appendsSinceCompaction = 0
        }
    }

    /// Waits for every queued write, so callers that must observe a fully
    /// flushed file (tests, teardown) do not race the serial queue.
    func flush() {
        queue.sync {}
    }

    private func newestFirstEntries() -> [OperationLogEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let entries = data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> StoredEntry? in
                try? decoder.decode(StoredEntry.self, from: Data(line))
            }
            .map { stored in
                OperationLogEntry(
                    id: stored.id,
                    occurredAt: stored.occurredAt,
                    event: OperationLogEvent(
                        level: stored.level,
                        category: stored.category,
                        message: stored.message
                    )
                )
            }
        return Array(
            entries.sorted { $0.occurredAt > $1.occurredAt }.prefix(capacity)
        )
    }

    /// Rewrites the file with the newest `capacity` entries in chronological
    /// order so later appends stay ordered and the file cannot grow forever.
    private func compact() {
        appendsSinceCompaction = 0
        let retained = newestFirstEntries().reversed()
        guard !retained.isEmpty else { return }
        var payload = Data()
        for entry in retained {
            let stored = StoredEntry(
                id: entry.id,
                occurredAt: entry.occurredAt,
                level: entry.level,
                category: entry.category,
                message: entry.message
            )
            guard var line = try? encoder.encode(stored) else { continue }
            line.append(0x0A)
            payload.append(line)
        }
        createFile(contents: payload)
    }

    private func write(_ data: Data) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            createFile(contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return }
        try? handle.write(contentsOf: data)
    }

    private func createFile(contents: Data) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: contents,
            attributes: [
                // Scheduled runs can start while the device is locked; the log
                // must stay writable after the first unlock since boot.
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
    }
}
