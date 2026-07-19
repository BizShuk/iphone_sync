import Foundation
@testable import SyncCore

extension ResourceDescriptor {
    static func fixture(
        assetID: String = "asset-1",
        filename: String = "IMG_0001.HEIC",
        contentHash: String = String(repeating: "a", count: 64),
        creationDate: Date? = Date(timeIntervalSince1970: 1_753_000_000),
        role: String? = nil
    ) -> ResourceDescriptor {
        ResourceDescriptor(
            assetLocalIdentifier: assetID,
            resourceType: "photo",
            originalFilename: filename,
            duplicateOrdinal: 0,
            contentHash: contentHash,
            expectedSize: 3,
            creationDate: creationDate,
            role: role
        )
    }
}
