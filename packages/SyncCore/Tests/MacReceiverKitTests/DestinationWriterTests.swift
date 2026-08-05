import Foundation
import MacReceiverKit
import SyncCore
import Testing

extension MacReceiverKitTestSuite {

@Test
func restartTruncatesBytesBeyondDurableCheckpoint() async throws {
    let bytes = Data(repeating: 1, count: 20_000_000)
    let harness = try ReceiverHarness(bytes: bytes)
    try await harness.prepareWriter()
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
    try await harness.prepareWriter()
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
    try await harness.prepareWriter()

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
    try await harness.prepareWriter()
    _ = try await harness.writer.begin(harness.offer)

    await #expect(throws: DestinationWriterError.invalidOffset) {
        try await harness.writer.append(bytes, offset: 1)
    }
}

@Test
func albumFolderUsesSourceNameAndSanitizesPathInjection() async throws {
    let harness = try ReceiverHarness()

    #expect(AlbumFolderPolicy.folderName(for: "Family Photos") == "Family Photos")
    #expect(
        AlbumFolderPolicy.folderName(for: "../../Family\\2026")
            == "_.._.._Family_2026"
    )
    #expect(AlbumFolderPolicy.folderName(for: "   ") == "Untitled Album")

    let folderName = try await harness.writer.prepareAlbumDirectory(
        named: "../../Family\\2026"
    )
    let folderURL = harness.receivingRootURL.appendingPathComponent(
        folderName,
        isDirectory: true
    )
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(folderURL.deletingLastPathComponent().standardizedFileURL == harness.receivingRootURL)
}

@Test
func receivingFolderIsCreatedBeforeAlbumFolder() async throws {
    let harness = try ReceiverHarness()

    try await harness.prepareWriter()

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(
        atPath: harness.receivingRootURL.path,
        isDirectory: &isDirectory
    ))
    #expect(isDirectory.boolValue)
    #expect(FileManager.default.fileExists(
        atPath: harness.receivingRootURL
            .appendingPathComponent(harness.albumFolderName)
            .path
    ))
}

@Test
func existingReceivingFolderIsReusedWithoutRemovingItsContents() async throws {
    let harness = try ReceiverHarness()
    try FileManager.default.createDirectory(
        at: harness.receivingRootURL,
        withIntermediateDirectories: false
    )
    let existingURL = harness.receivingRootURL.appendingPathComponent("keep.txt")
    let existing = Data("existing user file".utf8)
    try existing.write(to: existingURL)

    try await harness.prepareWriter()

    #expect(try Data(contentsOf: existingURL) == existing)
}

@Test
func existingAlbumFolderIsReusedWithoutRemovingItsContents() async throws {
    let harness = try ReceiverHarness()
    let folderURL = harness.receivingRootURL.appendingPathComponent("Family", isDirectory: true)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    let existingURL = folderURL.appendingPathComponent("keep.txt")
    let existing = Data("existing user file".utf8)
    try existing.write(to: existingURL)

    let folderName = try await harness.writer.prepareAlbumDirectory(named: "Family")

    #expect(folderName == "Family")
    #expect(try Data(contentsOf: existingURL) == existing)
}

@Test
func existingAlbumNameThatIsAFileIsRejected() async throws {
    let harness = try ReceiverHarness()
    try FileManager.default.createDirectory(
        at: harness.receivingRootURL,
        withIntermediateDirectories: false
    )
    let conflictingURL = harness.receivingRootURL.appendingPathComponent("Family")
    try Data("not a folder".utf8).write(to: conflictingURL)

    await #expect(throws: DestinationWriterError.unsafeDestination) {
        try await harness.writer.prepareAlbumDirectory(named: "Family")
    }
}

@Test
func destinationRootWithoutDirectoryFlagStillPreparesAlbum() async throws {
    let harness = try ReceiverHarness()
    let nonDirectoryRoot = URL(
        fileURLWithPath: harness.directory.path,
        isDirectory: false
    )
    let writer = DestinationWriter(
        destinationRoot: nonDirectoryRoot,
        manifest: harness.manifest
    )

    let folderName = try await writer.prepareAlbumDirectory(named: "surfing-raw")

    #expect(folderName == "surfing-raw")
    var isDirectory: ObjCBool = false
    let albumURL = harness.receivingRootURL
        .appendingPathComponent("surfing-raw", isDirectory: true)
    #expect(
        FileManager.default.fileExists(atPath: albumURL.path, isDirectory: &isDirectory)
    )
    #expect(isDirectory.boolValue)
}

@Test
func receivingFolderNameThatIsAFileIsRejected() async throws {
    let harness = try ReceiverHarness()
    try Data("not a folder".utf8).write(to: harness.receivingRootURL)

    await #expect(throws: DestinationWriterError.unsafeDestination) {
        try await harness.writer.prepareAlbumDirectory(named: "Family")
    }
}

@Test
func destinationWriterRequiresAlbumFolderBeforeTransfer() async throws {
    let harness = try ReceiverHarness()

    await #expect(throws: DestinationWriterError.albumNotPrepared) {
        try await harness.writer.begin(harness.offer)
    }
}

@Test
func legacyRootPartialMovesIntoAlbumFolderAndResumes() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
    try await harness.acceptAlbum()
    _ = try await harness.manifest.decision(for: harness.offer)
    try await harness.manifest.recordCheckpoint(
        resourceID: harness.offer.resourceID,
        offset: 3
    )
    let legacyPartialURL = harness.directory
        .appendingPathComponent(harness.resourceRelativePath)
        .appendingPathExtension("partial")
    try FileManager.default.createDirectory(
        at: legacyPartialURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(bytes.prefix(3)).write(to: legacyPartialURL)

    try await harness.prepareWriter()
    #expect(
        try await harness.writer.begin(harness.offer)
            == .transfer(offset: 3, relativePath: harness.expectedRelativePath)
    )
    let albumPartialURL = try await harness.writer.activePartialURL()
    #expect(!FileManager.default.fileExists(atPath: legacyPartialURL.path))
    #expect(albumPartialURL.path.hasPrefix(
        harness.receivingRootURL
            .appendingPathComponent(harness.albumFolderName)
            .path + "/"
    ))
    #expect(try Data(contentsOf: albumPartialURL) == Data(bytes.prefix(3)))
}

@Test
func previousAlbumPartialMovesIntoReceivingFolderAndResumes() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
    try await harness.acceptAlbum()
    _ = try await harness.manifest.decision(for: harness.offer)
    try await harness.manifest.recordCheckpoint(
        resourceID: harness.offer.resourceID,
        offset: 3
    )
    let previousPartialURL = harness.directory
        .appendingPathComponent(harness.albumFolderName, isDirectory: true)
        .appendingPathComponent(harness.resourceRelativePath)
        .appendingPathExtension("partial")
    try FileManager.default.createDirectory(
        at: previousPartialURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(bytes.prefix(3)).write(to: previousPartialURL)

    try await harness.prepareWriter()
    #expect(
        try await harness.writer.begin(harness.offer)
            == .transfer(offset: 3, relativePath: harness.expectedRelativePath)
    )
    let currentPartialURL = try await harness.writer.activePartialURL()

    #expect(!FileManager.default.fileExists(atPath: previousPartialURL.path))
    #expect(currentPartialURL.path.hasPrefix(
        harness.receivingRootURL
            .appendingPathComponent(harness.albumFolderName)
            .path + "/"
    ))
    #expect(try Data(contentsOf: currentPartialURL) == Data(bytes.prefix(3)))
}

@Test
func anotherAlbumDoesNotConsumeTheLegacyAlbumsRootPartial() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
    try await harness.acceptAlbum()
    _ = try await harness.manifest.decision(for: harness.offer)
    try await harness.manifest.recordCheckpoint(
        resourceID: harness.offer.resourceID,
        offset: 3
    )
    let legacyPartialURL = harness.directory
        .appendingPathComponent(harness.resourceRelativePath)
        .appendingPathExtension("partial")
    try FileManager.default.createDirectory(
        at: legacyPartialURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let legacyBytes = Data(bytes.prefix(3))
    try legacyBytes.write(to: legacyPartialURL)

    let accepted = try await harness.acceptAlbum(
        id: "album-2",
        name: "Trips",
        requestedBindingID: "binding-1"
    )
    harness.writer = DestinationWriter(
        destinationRoot: harness.directory,
        manifest: harness.manifest
    )
    try await harness.writer.prepareAlbumDirectory(
        named: accepted.destinationFolderName
    )
    #expect(
        try await harness.writer.begin(harness.offer)
            == .transfer(
                offset: 0,
                relativePath: "\(harness.receivingFolderName)/Trips/\(harness.resourceRelativePath)"
            )
    )
    let secondAlbumPartialURL = try await harness.writer.activePartialURL()

    #expect(try Data(contentsOf: legacyPartialURL) == legacyBytes)
    #expect(try Data(contentsOf: secondAlbumPartialURL).isEmpty)
}

@Test
func legacyCommittedFileIsAdoptedWithoutMoving() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
    let legacyFinalURL = harness.directory
        .appendingPathComponent(harness.resourceRelativePath)
    try FileManager.default.createDirectory(
        at: legacyFinalURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try bytes.write(to: legacyFinalURL)
    try await harness.acceptAlbum()
    _ = try await harness.manifest.decision(for: harness.offer)
    try await harness.manifest.commit(
        resourceID: harness.offer.resourceID,
        relativePath: harness.resourceRelativePath
    )

    try await harness.prepareWriter()
    #expect(
        try await harness.writer.begin(harness.offer)
            == .adopted(relativePath: harness.resourceRelativePath)
    )
    #expect(try Data(contentsOf: legacyFinalURL) == bytes)
    #expect(!FileManager.default.fileExists(atPath: harness.existingURL.path))
}

@Test
func albumOnlyModeWritesFileDirectlyUnderAlbum() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes, storageMode: .albumOnly)
    try await harness.prepareWriter()

    let result = try await harness.writer.begin(harness.offer)
    #expect(result == .transfer(offset: 0, relativePath: harness.expectedRelativePath))

    let albumRoot = harness.receivingRootURL.appendingPathComponent(
        harness.albumFolderName,
        isDirectory: true
    )
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: albumRoot.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)

    try await harness.writer.append(bytes, offset: 0)
    let committed = try await harness.writer.commit(expectedHash: harness.offer.descriptor.contentHash)
    #expect(committed == harness.existingURL)
    #expect(try Data(contentsOf: committed) == bytes)
    #expect(committed.path.hasPrefix(albumRoot.path + "/"))
    #expect(!committed.path.contains("/2025/"))
}

@Test
func flatModeWritesFileDirectlyUnderReceivingFolder() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes, storageMode: .flat)
    try await harness.prepareWriter()

    let result = try await harness.writer.begin(harness.offer)
    #expect(result == .transfer(offset: 0, relativePath: harness.expectedRelativePath))

    let albumRoot = harness.receivingRootURL.appendingPathComponent(
        harness.albumFolderName,
        isDirectory: true
    )
    var isDirectory: ObjCBool = false
    #expect(
        !FileManager.default.fileExists(atPath: albumRoot.path, isDirectory: &isDirectory)
    )

    try await harness.writer.append(bytes, offset: 0)
    let committed = try await harness.writer.commit(expectedHash: harness.offer.descriptor.contentHash)
    #expect(committed == harness.existingURL)
    #expect(try Data(contentsOf: committed) == bytes)
    #expect(committed.deletingLastPathComponent().standardizedFileURL
        == harness.receivingRootURL.standardizedFileURL)
}

@Test
func flatModeAdoptsLegacyRootPartialWithoutAlbumFolder() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes, storageMode: .flat)
    try await harness.acceptAlbum()
    _ = try await harness.manifest.decision(for: harness.offer)
    try await harness.manifest.recordCheckpoint(
        resourceID: harness.offer.resourceID,
        offset: 3
    )
    let legacyPartialURL = harness.directory
        .appendingPathComponent(harness.resourceRelativePath)
        .appendingPathExtension("partial")
    try FileManager.default.createDirectory(
        at: legacyPartialURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(bytes.prefix(3)).write(to: legacyPartialURL)

    try await harness.prepareWriter()
    #expect(
        try await harness.writer.begin(harness.offer)
            == .transfer(offset: 3, relativePath: harness.expectedRelativePath)
    )
    let activePartial = try await harness.writer.activePartialURL()
    #expect(activePartial.path.hasPrefix(harness.receivingRootURL.path + "/"))
    #expect(!FileManager.default.fileExists(atPath: legacyPartialURL.path))
    #expect(try Data(contentsOf: activePartial) == Data(bytes.prefix(3)))
}

}
