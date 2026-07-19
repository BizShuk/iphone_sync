import Foundation
import SwiftData

@Model
public final class SourceRecord {
    @Attribute(.unique) public var sourceBindingID: String
    public var albumID: String
    public var albumName: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sourceBindingID: String,
        albumID: String,
        albumName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.sourceBindingID = sourceBindingID
        self.albumID = albumID
        self.albumName = albumName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
