import Foundation
import XCTest
@testable import iPhone_Sync

final class AssetBackupRegistryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetBackupRegistryTests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testConfirmationsAccumulateAndPersist() {
        let registry = makeRegistry()
        registry.record([candidate(modified: 1)], receiverID: "mac")
        registry.record([candidate(modified: 1)], receiverID: "pc")

        XCTAssertEqual(makeRegistry().allRecords.first?.receiverIDs, ["mac", "pc"])
    }

    /// An edited asset carries other bytes; earlier confirmations are void.
    func testChangedModificationDateStartsOver() {
        let registry = makeRegistry()
        registry.record([candidate(modified: 1)], receiverID: "mac")
        registry.record([candidate(modified: 2)], receiverID: "pc")

        let record = makeRegistry().allRecords.first
        XCTAssertEqual(record?.receiverIDs, ["pc"])
        XCTAssertEqual(record?.modificationDate, Date(timeIntervalSince1970: 2))
    }

    func testRemovingReceiverDropsItsConfirmationsOnly() {
        let registry = makeRegistry()
        registry.record([candidate("a", modified: 1)], receiverID: "mac")
        registry.record([candidate("a", modified: 1), candidate("b", modified: 1)], receiverID: "pc")
        registry.remove(receiverID: "pc")

        let records = makeRegistry().allRecords
        XCTAssertEqual(records.map(\.assetLocalIdentifier), ["a"])
        XCTAssertEqual(records.first?.receiverIDs, ["mac"])
    }

    func testRemovingAssetsAndClear() {
        let registry = makeRegistry()
        registry.record([candidate("a", modified: 1), candidate("b", modified: 1)], receiverID: "mac")
        registry.remove(assetIDs: ["a"])
        XCTAssertEqual(makeRegistry().allRecords.map(\.assetLocalIdentifier), ["b"])

        registry.clear()
        XCTAssertTrue(makeRegistry().allRecords.isEmpty)
    }

    private func makeRegistry() -> AssetBackupRegistry {
        AssetBackupRegistry(fileURL: directory.appendingPathComponent("asset-backups.json"))
    }

    private func candidate(_ id: String = "asset", modified: TimeInterval) -> PhotoDeletionCandidate {
        PhotoDeletionCandidate(
            assetLocalIdentifier: id,
            modificationDate: Date(timeIntervalSince1970: modified)
        )
    }
}
