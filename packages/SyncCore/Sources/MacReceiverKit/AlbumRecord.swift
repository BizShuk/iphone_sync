import Foundation
import SwiftData

@Model
public final class AlbumRecord {
    @Attribute(.unique) public var albumBindingKey: String
    public var sourceBindingID: String
    public var albumID: String
    public var albumName: String
    public var destinationFolderName: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        albumBindingKey: String,
        sourceBindingID: String,
        albumID: String,
        albumName: String,
        destinationFolderName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.albumBindingKey = albumBindingKey
        self.sourceBindingID = sourceBindingID
        self.albumID = albumID
        self.albumName = albumName
        self.destinationFolderName = destinationFolderName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AcceptedAlbum: Equatable, Sendable {
    public let sourceBindingID: String
    public let albumID: String
    public let albumName: String
    public let destinationFolderName: String

    public init(
        sourceBindingID: String,
        albumID: String,
        albumName: String,
        destinationFolderName: String
    ) {
        self.sourceBindingID = sourceBindingID
        self.albumID = albumID
        self.albumName = albumName
        self.destinationFolderName = destinationFolderName
    }
}
