import Foundation
import Testing
@testable import SyncCore

@Test
func resourceIdentityIsStableAndBindingScoped() {
    let descriptor = ResourceDescriptor.fixture(assetID: "asset", filename: "IMG_1.HEIC")

    let first = ResourceIdentity.make(sourceBindingID: "binding-A", descriptor: descriptor)
    let repeatValue = ResourceIdentity.make(sourceBindingID: "binding-A", descriptor: descriptor)
    let otherBinding = ResourceIdentity.make(sourceBindingID: "binding-B", descriptor: descriptor)

    #expect(first == repeatValue)
    #expect(first != otherBinding)
    #expect(first.count == 64)
}

@Test
func filenamePolicyRejectsTraversal() {
    #expect(throws: FilenamePolicyError.invalidFilename) {
        try FilenamePolicy.relativePath(
            originalFilename: "../secret",
            resourceID: String(repeating: "a", count: 64),
            role: nil,
            creationDate: .distantPast
        )
    }
}

@Test
func filenamePolicyGroupsByUTCMonthAndKeepsRole() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-07-19T12:30:00Z"))

    let path = try FilenamePolicy.relativePath(
        originalFilename: "IMG 0001.MOV",
        resourceID: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        role: "paired-video",
        creationDate: date
    )

    #expect(path == "2026/07/IMG 0001__abcdef01_paired-video.MOV")
}

@Test
func fileHasherMatchesKnownSHA256() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("value")
    try Data("abc".utf8).write(to: file)

    #expect(try FileHasher.sha256(url: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}
