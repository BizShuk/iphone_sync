import Foundation

public struct ResourceDescriptor: Codable, Equatable, Hashable, Sendable {
    public let assetLocalIdentifier: String
    public let resourceType: String
    public let originalFilename: String
    public let duplicateOrdinal: Int
    public let contentHash: String
    public let expectedSize: Int64
    public let creationDate: Date?
    public let role: String?

    public init(
        assetLocalIdentifier: String,
        resourceType: String,
        originalFilename: String,
        duplicateOrdinal: Int,
        contentHash: String,
        expectedSize: Int64,
        creationDate: Date?,
        role: String?
    ) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.resourceType = resourceType
        self.originalFilename = originalFilename
        self.duplicateOrdinal = duplicateOrdinal
        self.contentHash = contentHash
        self.expectedSize = expectedSize
        self.creationDate = creationDate
        self.role = role
    }
}

public struct ResourceOffer: Codable, Equatable, Sendable {
    public let resourceID: String
    public let descriptor: ResourceDescriptor

    public init(resourceID: String, descriptor: ResourceDescriptor) {
        self.resourceID = resourceID
        self.descriptor = descriptor
    }
}
