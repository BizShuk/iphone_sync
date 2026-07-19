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
    @Attribute(.unique) public var resourceID: String
    public var sourceBindingID: String
    public var contentHash: String
    public var expectedSize: Int64
    public var confirmedOffset: Int64
    public var statusRawValue: String
    public var finalRelativePath: String?
    public var updatedAt: Date

    public init(
        sourceBindingID: String,
        resourceID: String,
        contentHash: String,
        expectedSize: Int64,
        confirmedOffset: Int64 = 0,
        status: TransferStatus = .pending,
        finalRelativePath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.sourceBindingID = sourceBindingID
        self.resourceID = resourceID
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
    public let resourceID: String
    public let contentHash: String
    public let expectedSize: Int64
    public let confirmedOffset: Int64
    public let status: TransferStatus
    public let finalRelativePath: String?
    public let updatedAt: Date
}
