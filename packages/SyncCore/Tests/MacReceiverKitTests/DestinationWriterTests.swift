import Foundation
import MacReceiverKit
import SyncCore
import Testing

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
