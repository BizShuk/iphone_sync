import Foundation
import MacReceiverKit
import SyncCore
import Testing

extension MacReceiverKitTestSuite {

@Test
func restartTruncatesBytesBeyondDurableCheckpoint() async throws {
    let bytes = Data(repeating: 1, count: 20_000_000)
    let harness = try ReceiverHarness(bytes: bytes)
    _ = try await harness.manifest.decision(for: harness.offer)
    _ = try await harness.writer.begin(harness.offer)

    try await harness.writer.append(bytes, offset: 0)
    try await harness.writer.checkpoint(at: SyncConstants.checkpointSize)
    await harness.simulateCrash()
    let recovered = try await harness.recover()

    #expect(recovered.offset == SyncConstants.checkpointSize)
    #expect(recovered.fileSize == SyncConstants.checkpointSize)
}

@Test
func existingDifferentFileIsNeverOverwritten() async throws {
    let existing = Data("user file".utf8)
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes, existingBytes: existing)
    _ = try await harness.manifest.decision(for: harness.offer)
    _ = try await harness.writer.begin(harness.offer)

    try await harness.writer.append(bytes, offset: 0)
    try await harness.writer.checkpoint()
    let committed = try await harness.writer.commit(expectedHash: harness.offer.descriptor.contentHash)

    #expect(try Data(contentsOf: harness.existingURL) == existing)
    #expect(committed != harness.existingURL)
    #expect(try Data(contentsOf: committed) == bytes)
}

@Test
func existingSameHashFileIsAdopted() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes, existingBytes: bytes)

    #expect(
        try await harness.writer.begin(harness.offer)
            == .adopted(relativePath: harness.expectedRelativePath)
    )
    #expect(try Data(contentsOf: harness.existingURL) == bytes)
    #expect(
        try await harness.manifest.decision(for: harness.offer)
            == .skip
    )
}

@Test
func destinationWriterRejectsOutOfOrderChunk() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
    _ = try await harness.writer.begin(harness.offer)

    await #expect(throws: DestinationWriterError.invalidOffset) {
        try await harness.writer.append(bytes, offset: 1)
    }
}

}
