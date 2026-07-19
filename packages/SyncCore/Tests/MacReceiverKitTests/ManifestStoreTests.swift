import MacReceiverKit
import SwiftData
import SyncCore
import Testing

@Test
func manifestStartsResumesAndSkipsCommittedResource() async throws {
    let harness = try ReceiverHarness()

    #expect(try await harness.manifest.decision(for: harness.offer) == .start(offset: 0))
    try await harness.manifest.recordCheckpoint(resourceID: harness.offer.resourceID, offset: 3)
    #expect(try await harness.manifest.decision(for: harness.offer) == .resume(offset: 3))
    try await harness.manifest.commit(
        resourceID: harness.offer.resourceID,
        relativePath: harness.expectedRelativePath
    )
    #expect(try await harness.manifest.decision(for: harness.offer) == .skip)
}
