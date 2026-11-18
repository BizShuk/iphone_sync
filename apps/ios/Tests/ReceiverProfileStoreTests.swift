import Foundation
import XCTest
@testable import iPhone_Sync

final class ReceiverProfileStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ReceiverProfileStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testEachReceiverKeepsItsOwnAlbums() {
        let store = makeStore()
        store.upsertPaired(id: "mac", displayName: "Mac", at: date(1))
        store.upsertPaired(id: "pc", displayName: "PC", at: date(2))
        store.setAlbums([album("travel")], receiverID: "mac")
        store.setAlbums([album("work"), album("work")], receiverID: "pc")

        let profiles = makeStore().load()
        XCTAssertEqual(profiles.map(\.id), ["mac", "pc"])
        XCTAssertEqual(profiles[0].albums.map(\.id), ["travel"])
        XCTAssertEqual(profiles[1].albums.map(\.id), ["work"])
    }

    func testPairingAgainKeepsAlbumsAndHistory() {
        let store = makeStore()
        store.upsertPaired(id: "mac", displayName: "Mac", at: date(1))
        store.setAlbums([album("travel")], receiverID: "mac")
        store.markCompleted(receiverID: "mac", at: date(5))
        store.upsertPaired(id: "mac", displayName: "Studio Mac", at: date(9))

        let profile = makeStore().profile(id: "mac")
        XCTAssertEqual(profile?.displayName, "Studio Mac")
        XCTAssertEqual(profile?.albums.map(\.id), ["travel"])
        XCTAssertEqual(profile?.pairedAt, date(1))
        XCTAssertEqual(profile?.lastCompletedAt, date(5))
        XCTAssertEqual(profile?.lastConnectedAt, date(5))
    }

    func testConnectedDoesNotCountAsCompleted() {
        let store = makeStore()
        store.upsertPaired(id: "mac", displayName: "Mac", at: date(1))
        store.markConnected(receiverID: "mac", at: date(3))

        let profile = makeStore().profile(id: "mac")
        XCTAssertEqual(profile?.lastConnectedAt, date(3))
        XCTAssertNil(profile?.lastCompletedAt)
    }

    func testRemoveAffectsOnlyThatReceiver() {
        let store = makeStore()
        store.upsertPaired(id: "mac", displayName: "Mac", at: date(1))
        store.upsertPaired(id: "pc", displayName: "PC", at: date(2))
        store.remove(receiverID: "mac")

        XCTAssertEqual(makeStore().load().map(\.id), ["pc"])
        XCTAssertNotEqual(
            ReceiverProfileStore.peerAccount(receiverID: "mac"),
            ReceiverProfileStore.peerAccount(receiverID: "pc")
        )
    }

    private func makeStore() -> ReceiverProfileStore {
        ReceiverProfileStore(defaults: defaults)
    }

    private func album(_ id: String) -> PhotoAlbum {
        PhotoAlbum(id: id, title: id, assetCount: 1)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
