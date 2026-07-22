import Foundation
import SwiftData

public enum TransferStatus: String, Codable, Equatable, Sendable {
    case pending
    case transferring
    case committed
    case failed
}

@Model
public final class TransferRecord {
    // Kept as the persisted unique field for lightweight migration. New records
    // store an album-scoped manifest key here and expose logicalResourceID to callers.
    @Attribute(.unique) public var resourceID: String
    public var sourceBindingID: String
    public var albumID: String = ""
    public var logicalResourceID: String = ""
    public var contentHash: String
    public var expectedSize: Int64
    public var confirmedOffset: Int64
    public var statusRawValue: String
    public var finalRelativePath: String?
    public var updatedAt: Date

    public init(
        sourceBindingID: String,
        resourceID: String,
        albumID: String = "",
        logicalResourceID: String = "",
        contentHash: String,
        expectedSize: Int64,
        confirmedOffset: Int64 = 0,
        status: TransferStatus = .pending,
        finalRelativePath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.sourceBindingID = sourceBindingID
        self.resourceID = resourceID
        self.albumID = albumID
        self.logicalResourceID = logicalResourceID
        self.contentHash = contentHash
        self.expectedSize = expectedSize
        self.confirmedOffset = confirmedOffset
        self.statusRawValue = status.rawValue
        self.finalRelativePath = finalRelativePath
        self.updatedAt = updatedAt
    }

    public var status: TransferStatus {
        get { TransferStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }
}

public struct TransferSnapshot: Equatable, Sendable {
    public let sourceBindingID: String
    public let albumID: String
    public let resourceID: String
    public let contentHash: String
    public let expectedSize: Int64
    public let confirmedOffset: Int64
    public let status: TransferStatus
    public let finalRelativePath: String?
    public let updatedAt: Date
}
