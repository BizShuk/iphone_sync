import Foundation
import MacReceiverKit
import SwiftData
import SyncCore
import Testing

extension MacReceiverKitTestSuite {

@Test
func manifestStartsResumesAndSkipsCommittedResource() async throws {
    let harness = try ReceiverHarness()
    try await harness.acceptAlbum()

    #expect(try await harness.manifest.decision(for: harness.offer) == .start(offset: 0))
    try await harness.manifest.recordCheckpoint(resourceID: harness.offer.resourceID, offset: 3)
    #expect(try await harness.manifest.decision(for: harness.offer) == .resume(offset: 3))
    try await harness.manifest.commit(
        resourceID: harness.offer.resourceID,
        relativePath: harness.expectedRelativePath
    )
    #expect(try await harness.manifest.decision(for: harness.offer) == .skip)
}

@Test
func manifestResumesFromDurableSixteenMiBCheckpoint() async throws {
    let harness = try ReceiverHarness(
        bytes: Data(repeating: 0x5a, count: Int(SyncConstants.checkpointSize) + 1)
    )
    try await harness.acceptAlbum()
    _ = try await harness.manifest.decision(for: harness.offer)
    try await harness.manifest.recordCheckpoint(
        resourceID: harness.offer.resourceID,
        offset: SyncConstants.checkpointSize
    )

    #expect(
        try await harness.manifest.decision(for: harness.offer)
            == .resume(offset: SyncConstants.checkpointSize)
    )
}

@Test
func manifestScopesTheSameResourceToEachAcceptedAlbum() async throws {
    let harness = try ReceiverHarness()

    try await harness.acceptAlbum(id: "album-1", name: "Camera Roll")
    #expect(try await harness.manifest.decision(for: harness.offer) == .start(offset: 0))
    try await harness.manifest.commit(
        resourceID: harness.offer.resourceID,
        relativePath: "iPhoneSync/Camera Roll/photo.heic"
    )

    try await harness.acceptAlbum(
        id: "album-2",
        name: "Trips",
        requestedBindingID: "binding-1"
    )
    #expect(try await harness.manifest.decision(for: harness.offer) == .start(offset: 0))

    try await harness.acceptAlbum(
        id: "album-1",
        name: "Camera Roll",
        requestedBindingID: "binding-1"
    )
    #expect(try await harness.manifest.decision(for: harness.offer) == .skip)
}

@Test
func duplicateAlbumNamesReceiveStableDistinctFolderNames() async throws {
    let harness = try ReceiverHarness()

    let first = try await harness.acceptAlbum(id: "album-1", name: "Family")
    let second = try await harness.acceptAlbum(
        id: "album-2",
        name: "Family",
        requestedBindingID: "binding-1"
    )
    let repeated = try await harness.acceptAlbum(
        id: "album-2",
        name: "Renamed Family",
        requestedBindingID: "binding-1"
    )

    #expect(first.destinationFolderName == "Family")
    #expect(second.destinationFolderName == "Family (2)")
    #expect(repeated.destinationFolderName == "Family (2)")
}

@Test
func manifestRejectsAnUnknownSourceBinding() async throws {
    let harness = try ReceiverHarness()

    await #expect(throws: ManifestStoreError.sourceBindingMismatch) {
        try await harness.acceptAlbum(
            id: "album-1",
            requestedBindingID: "different-binding"
        )
    }
}

@Test
func legacySingleAlbumRecordsMigrateIntoTheAlbumScope() async throws {
    let harness = try ReceiverHarness()
    let legacyContext = ModelContext(harness.container)
    legacyContext.autosaveEnabled = false
    legacyContext.insert(SourceRecord(
        sourceBindingID: "binding-1",
        albumID: "album-1",
        albumName: "Camera Roll"
    ))
    legacyContext.insert(TransferRecord(
        sourceBindingID: "binding-1",
        resourceID: harness.offer.resourceID,
        contentHash: harness.offer.descriptor.contentHash,
        expectedSize: harness.offer.descriptor.expectedSize,
        confirmedOffset: harness.offer.descriptor.expectedSize,
        status: .committed,
        finalRelativePath: harness.expectedRelativePath
    ))
    try legacyContext.save()

    let accepted = try await harness.acceptAlbum(id: "album-1", name: "Camera Roll")
    let snapshot = try await harness.manifest.snapshot(resourceID: harness.offer.resourceID)

    #expect(accepted.destinationFolderName == "Camera Roll")
    #expect(try await harness.manifest.decision(for: harness.offer) == .skip)
    #expect(snapshot?.albumID == "album-1")
    #expect(snapshot?.resourceID == harness.offer.resourceID)
    #expect(snapshot?.finalRelativePath == harness.expectedRelativePath)
}

}
