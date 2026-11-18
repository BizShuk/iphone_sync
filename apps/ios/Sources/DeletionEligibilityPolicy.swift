import Foundation

/// Which receivers have confirmed one Photos asset as fully backed up.
struct AssetBackupRecord: Codable, Equatable, Sendable {
    let assetLocalIdentifier: String
    let modificationDate: Date?
    var receiverIDs: Set<String>

    var candidate: PhotoDeletionCandidate {
        PhotoDeletionCandidate(
            assetLocalIdentifier: assetLocalIdentifier,
            modificationDate: modificationDate
        )
    }
}

/// What the policy needs to know about the current setup.
struct DeletionEligibilityInput: Sendable {
    let profiles: [ReceiverProfile]
    /// Asset local identifiers contained in each album that some receiver
    /// has selected.
    let assetIDsByAlbumID: [String: Set<String>]
}

/// Decides when a backed-up asset may leave the iPhone.
///
/// An asset is required on every receiver whose album selection contains it.
/// iPhone cannot see a receiver that was reset, re-pointed or unpaired on the
/// computer side, so a receiver that has not completed a sync for
/// `staleInterval` stops blocking deletion, but only for assets at least one
/// other required receiver has already confirmed.
enum DeletionEligibilityPolicy {
    static let staleInterval: TimeInterval = 14 * 24 * 60 * 60

    static func isStale(_ profile: ReceiverProfile, now: Date) -> Bool {
        let baseline = profile.lastCompletedAt ?? profile.pairedAt
        return now.timeIntervalSince(baseline) >= staleInterval
    }

    static func eligibleCandidates(
        records: [AssetBackupRecord],
        input: DeletionEligibilityInput,
        now: Date
    ) -> Set<PhotoDeletionCandidate> {
        var albumIDsByAssetID: [String: Set<String>] = [:]
        for (albumID, assetIDs) in input.assetIDsByAlbumID {
            for assetID in assetIDs {
                albumIDsByAssetID[assetID, default: []].insert(albumID)
            }
        }
        let staleIDs = Set(input.profiles.filter { isStale($0, now: now) }.map(\.id))

        return Set(records.compactMap { record in
            let albumIDs = albumIDsByAssetID[record.assetLocalIdentifier] ?? []
            let required = Set(input.profiles.filter { profile in
                profile.albums.contains { albumIDs.contains($0.id) }
            }.map(\.id))
            // At least one receiver that should hold the asset holds it.
            guard !required.intersection(record.receiverIDs).isEmpty else {
                return nil
            }
            let awaited = required.subtracting(staleIDs)
            return awaited.isSubset(of: record.receiverIDs) ? record.candidate : nil
        })
    }
}
