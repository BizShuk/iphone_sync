import Foundation
import XCTest
@testable import iPhone_Sync

final class AlbumSyncCursorStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AlbumSyncCursorStoreTests.\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    /// An interrupted window must leave a resume point behind, even though
    /// advances are batched rather than written per asset.
    func testFlushPersistsBatchedProgressForTheNextRun() throws {
        let cursor = AlbumSyncCursor(
            assetLocalIdentifier: "asset-9",
            assetCreationDate: Date(timeIntervalSince1970: 9_000)
        )
        let interrupted = makeStore()
        interrupted.advance(receiverID: "receiver-a", albumID: "album-1", to: cursor)
        interrupted.flush()

        XCTAssertEqual(makeStore().cursor(receiverID: "receiver-a", albumID: "album-1"), cursor)
    }

    func testLatestAdvanceWins() throws {
        let store = makeStore()
        store.advance(receiverID: "receiver-a", albumID: "album-1", to: AlbumSyncCursor(
            assetLocalIdentifier: "asset-1",
            assetCreationDate: Date(timeIntervalSince1970: 1_000)
        ))
        let latest = AlbumSyncCursor(
            assetLocalIdentifier: "asset-2",
            assetCreationDate: Date(timeIntervalSince1970: 2_000)
        )
        store.advance(receiverID: "receiver-a", albumID: "album-1", to: latest)
        store.flush()

        XCTAssertEqual(makeStore().cursor(receiverID: "receiver-a", albumID: "album-1"), latest)
    }

    /// A completed pass clears its cursor so the next run walks the whole
    /// album again and picks up assets imported with an older date.
    func testClearedAlbumStartsFromTheBeginningAgain() throws {
        let store = makeStore()
        store.advance(receiverID: "receiver-a", albumID: "album-1", to: AlbumSyncCursor(
            assetLocalIdentifier: "asset-1",
            assetCreationDate: Date(timeIntervalSince1970: 1_000)
        ))
        store.flush()
        store.clear(receiverID: "receiver-a", albumID: "album-1")
        store.flush()

        XCTAssertNil(makeStore().cursor(receiverID: "receiver-a", albumID: "album-1"))
    }

    func testCursorsAreScopedPerAlbum() throws {
        let store = makeStore()
        let first = AlbumSyncCursor(
            assetLocalIdentifier: "asset-1",
            assetCreationDate: Date(timeIntervalSince1970: 1_000)
        )
        store.advance(receiverID: "receiver-a", albumID: "album-1", to: first)
        store.flush()

        XCTAssertEqual(store.cursor(receiverID: "receiver-a", albumID: "album-1"), first)
        XCTAssertNil(store.cursor(receiverID: "receiver-a", albumID: "album-2"))
    }

    /// The same album selected on two receivers keeps two independent
    /// passes, and forgetting one receiver leaves the other's pass intact.
    func testCursorsAreScopedPerReceiver() throws {
        let store = makeStore()
        let cursor = AlbumSyncCursor(
            assetLocalIdentifier: "asset-1",
            assetCreationDate: Date(timeIntervalSince1970: 1_000)
        )
        store.advance(receiverID: "receiver-a", albumID: "album-1", to: cursor)
        store.advance(receiverID: "receiver-b", albumID: "album-1", to: cursor)
        store.clear(receiverID: "receiver-a")
        store.flush()

        let restored = makeStore()
        XCTAssertNil(restored.cursor(receiverID: "receiver-a", albumID: "album-1"))
        XCTAssertEqual(
            restored.cursor(receiverID: "receiver-b", albumID: "album-1"),
            cursor
        )
    }

    private func makeStore() -> AlbumSyncCursorStore {
        AlbumSyncCursorStore(
            fileURL: directory.appendingPathComponent("album-cursors.json")
        )
    }
}
