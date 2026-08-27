import Foundation
import SyncCore
import XCTest
@testable import iPhone_Sync

final class PersistentOperationLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PersistentOperationLogTests.\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testEntriesSurviveAnewStoreAndStayNewestFirst() {
        let store = makeStore(capacity: 10)
        store.append(entry("first", secondsAgo: 30))
        store.append(entry("second", secondsAgo: 20))
        store.append(entry("third", secondsAgo: 10))
        store.flush()

        let restored = makeStore(capacity: 10).loadEntries()

        XCTAssertEqual(restored.map(\.message), ["third", "second", "first"])
        XCTAssertEqual(restored.map(\.category), ["Sync", "Sync", "Sync"])
        XCTAssertEqual(restored.first?.level, .warning)
    }

    func testCompactionKeepsTheNewestEntriesWithinCapacity() throws {
        let store = makeStore(capacity: 3)
        for index in 0..<9 {
            store.append(entry("event-\(index)", secondsAgo: Double(100 - index)))
        }
        store.flush()

        XCTAssertEqual(
            store.loadEntries().map(\.message),
            ["event-8", "event-7", "event-6"]
        )
        let lines = try XCTUnwrap(String(contentsOf: fileURL, encoding: .utf8))
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
    }

    func testClearRemovesEveryPersistedEntry() {
        let store = makeStore(capacity: 10)
        store.append(entry("kept", secondsAgo: 5))
        store.flush()

        store.clear()
        store.flush()

        XCTAssertTrue(store.loadEntries().isEmpty)
        XCTAssertTrue(makeStore(capacity: 10).loadEntries().isEmpty)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("operation-log.jsonl", isDirectory: false)
    }

    private func makeStore(capacity: Int) -> PersistentOperationLogStore {
        PersistentOperationLogStore(fileURL: fileURL, capacity: capacity)
    }

    private func entry(_ message: String, secondsAgo: Double) -> OperationLogEntry {
        OperationLogEntry(
            occurredAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo),
            event: OperationLogEvent(
                level: .warning,
                category: "Sync",
                message: message
            )
        )
    }
}
