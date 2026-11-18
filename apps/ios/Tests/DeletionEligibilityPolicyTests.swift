import Foundation
import XCTest
@testable import iPhone_Sync

final class DeletionEligibilityPolicyTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let modified = Date(timeIntervalSince1970: 100)
    private lazy var now = Date(timeIntervalSince1970: 100 * day)

    func testAssetOnTwoReceiversWaitsForBoth() {
        let input = input(profiles: [
            profile("mac", albums: ["shared"], completedDaysAgo: 1),
            profile("pc", albums: ["shared"], completedDaysAgo: 1),
        ], albums: ["shared": ["asset"]])

        XCTAssertTrue(eligible([record("asset", ["mac"])], input).isEmpty)
        XCTAssertEqual(
            eligible([record("asset", ["mac", "pc"])], input).map(\.assetLocalIdentifier),
            ["asset"]
        )
    }

    func testStaleReceiverIsSkippedWhenAnotherReceiverHasTheAsset() {
        let input = input(profiles: [
            profile("mac", albums: ["shared"], completedDaysAgo: 1),
            profile("pc", albums: ["shared"], completedDaysAgo: 14),
        ], albums: ["shared": ["asset"]])

        XCTAssertEqual(eligible([record("asset", ["mac"])], input).count, 1)
    }

    func testReceiverJustUnderFourteenDaysStillBlocks() {
        let input = input(profiles: [
            profile("mac", albums: ["shared"], completedDaysAgo: 1),
            profile("pc", albums: ["shared"], completedDaysAgo: 13.9),
        ], albums: ["shared": ["asset"]])

        XCTAssertTrue(eligible([record("asset", ["mac"])], input).isEmpty)
    }

    /// Staleness never lets an asset go that no required receiver holds.
    func testStaleOnlyReceiverWithoutConfirmationKeepsTheAsset() {
        let input = input(profiles: [
            profile("pc", albums: ["solo"], completedDaysAgo: 30),
            profile("mac", albums: ["other"], completedDaysAgo: 1),
        ], albums: ["solo": ["asset"], "other": []])

        XCTAssertTrue(eligible([record("asset", ["mac"])], input).isEmpty)
    }

    func testAssetOnlyInOneReceiversAlbumNeedsOnlyThatReceiver() {
        let input = input(profiles: [
            profile("mac", albums: ["travel"], completedDaysAgo: 1),
            profile("pc", albums: ["work"], completedDaysAgo: 1),
        ], albums: ["travel": ["asset"], "work": ["other"]])

        XCTAssertEqual(eligible([record("asset", ["mac"])], input).count, 1)
    }

    /// An asset moved out of every synced album is kept.
    func testAssetOutsideEverySelectedAlbumIsKept() {
        let input = input(profiles: [
            profile("mac", albums: ["travel"], completedDaysAgo: 1),
        ], albums: ["travel": []])

        XCTAssertTrue(eligible([record("asset", ["mac"])], input).isEmpty)
    }

    func testNeverCompletedReceiverIsMeasuredFromPairing() {
        let fresh = ReceiverProfile(
            id: "pc",
            displayName: "pc",
            albums: [],
            pairedAt: now.addingTimeInterval(-1 * day),
            lastConnectedAt: nil,
            lastCompletedAt: nil
        )
        XCTAssertFalse(DeletionEligibilityPolicy.isStale(fresh, now: now))

        let old = ReceiverProfile(
            id: "pc",
            displayName: "pc",
            albums: [],
            pairedAt: now.addingTimeInterval(-15 * day),
            lastConnectedAt: nil,
            lastCompletedAt: nil
        )
        XCTAssertTrue(DeletionEligibilityPolicy.isStale(old, now: now))
    }

    private func eligible(
        _ records: [AssetBackupRecord],
        _ input: DeletionEligibilityInput
    ) -> Set<PhotoDeletionCandidate> {
        DeletionEligibilityPolicy.eligibleCandidates(
            records: records,
            input: input,
            now: now
        )
    }

    private func input(
        profiles: [ReceiverProfile],
        albums: [String: Set<String>]
    ) -> DeletionEligibilityInput {
        DeletionEligibilityInput(profiles: profiles, assetIDsByAlbumID: albums)
    }

    private func record(_ assetID: String, _ receivers: Set<String>) -> AssetBackupRecord {
        AssetBackupRecord(
            assetLocalIdentifier: assetID,
            modificationDate: modified,
            receiverIDs: receivers
        )
    }

    private func profile(
        _ id: String,
        albums: [String],
        completedDaysAgo: Double
    ) -> ReceiverProfile {
        ReceiverProfile(
            id: id,
            displayName: id,
            albums: albums.map { PhotoAlbum(id: $0, title: $0, assetCount: 1) },
            pairedAt: now.addingTimeInterval(-60 * day),
            lastConnectedAt: nil,
            lastCompletedAt: now.addingTimeInterval(-completedDaysAgo * day)
        )
    }
}
