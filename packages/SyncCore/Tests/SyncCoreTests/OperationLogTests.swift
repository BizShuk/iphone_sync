import Foundation
import SyncCore
import Testing

@Test
func operationLogBufferKeepsNewestEntriesAndClears() {
    var buffer = OperationLogBuffer(capacity: 2)
    let firstID = UUID()
    let secondID = UUID()
    let thirdID = UUID()

    buffer.record(
        OperationLogEvent(
            level: .info,
            category: "Sync",
            message: "First"
        ),
        occurredAt: Date(timeIntervalSince1970: 1),
        id: firstID
    )
    buffer.record(
        OperationLogEvent(
            level: .warning,
            category: "Sync",
            message: "Second"
        ),
        occurredAt: Date(timeIntervalSince1970: 2),
        id: secondID
    )
    buffer.record(
        OperationLogEvent(
            level: .success,
            category: "Sync",
            message: "Third"
        ),
        occurredAt: Date(timeIntervalSince1970: 3),
        id: thirdID
    )

    #expect(buffer.entries.map(\.id) == [thirdID, secondID])
    #expect(buffer.entries.map(\.level) == [.success, .warning])
    #expect(buffer.entries.map(\.message) == ["Third", "Second"])

    buffer.clear()
    #expect(buffer.entries.isEmpty)
}
