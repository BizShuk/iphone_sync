import CryptoKit
import Foundation
import SwiftData
import SyncCore

public enum ManifestStoreError: Error, Equatable, LocalizedError, Sendable {
    case albumNotAccepted
    case invalidExpectedSize
    case invalidOffset
    case recordNotFound
    case sourceBindingMismatch

    public var errorDescription: String? {
        switch self {
        case .albumNotAccepted:
            "The album has not been accepted for this session."
        case .invalidExpectedSize:
            "The resource declared an invalid size."
        case .invalidOffset:
            "The checkpoint offset is outside the resource bounds."
        case .recordNotFound:
            "The resource manifest record was not found."
        case .sourceBindingMismatch:
            "The source binding does not match this destination."
        }
    }
}

public actor ManifestStore {
    public nonisolated let sourceBindingID: String
    private let context: ModelContext
    private var activeAlbum: AcceptedAlbum?

    public init(container: ModelContainer, sourceBindingID: String) {
        self.sourceBindingID = sourceBindingID
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
    }

    public func acceptSession(
        albumID: String,
        albumName: String,
        requestedBindingID: String?
    ) throws -> AcceptedAlbum {
        if let requestedBindingID, requestedBindingID != sourceBindingID {
            throw ManifestStoreError.sourceBindingMismatch
        }

        let source: SourceRecord
        if let existing = try sourceRecord() {
            source = existing
            try migrateLegacyAlbumIfNeeded(source)
        } else {
            source = SourceRecord(
                sourceBindingID: sourceBindingID,
                albumID: albumID,
                albumName: albumName
            )
            context.insert(source)
        }

        let bindingKey = Self.albumBindingKey(
            sourceBindingID: sourceBindingID,
            albumID: albumID
        )
        let album: AlbumRecord
        if let existing = try albumRecord(bindingKey: bindingKey) {
            album = existing
            album.albumName = albumName
            album.updatedAt = Date()
        } else {
            album = AlbumRecord(
                albumBindingKey: bindingKey,
                sourceBindingID: sourceBindingID,
                albumID: albumID,
                albumName: albumName,
                destinationFolderName: try nextDestinationFolderName(for: albumName)
            )
            context.insert(album)
        }

        if source.albumID == albumID {
            source.albumName = albumName
        }
        source.updatedAt = Date()
        try context.save()

        let accepted = AcceptedAlbum(
            sourceBindingID: sourceBindingID,
            albumID: albumID,
            albumName: albumName,
            destinationFolderName: album.destinationFolderName
        )
        activeAlbum = accepted
        return accepted
    }

    public func decision(for offer: ResourceOffer) throws -> TransferDecision {
        guard offer.descriptor.expectedSize >= 0 else {
            throw ManifestStoreError.invalidExpectedSize
        }
        let album = try requireActiveAlbum()
        if let record = try record(resourceID: offer.resourceID, album: album) {
            guard record.sourceBindingID == sourceBindingID,
                  record.albumID == album.albumID,
                  record.logicalResourceID == offer.resourceID else {
                throw ManifestStoreError.sourceBindingMismatch
            }
            let sameContent = record.contentHash == offer.descriptor.contentHash
                && record.expectedSize == offer.descriptor.expectedSize
            if sameContent, record.status == .committed {
                return .skip
            }
            if sameContent {
                record.status = .transferring
                record.updatedAt = Date()
                try context.save()
                return record.confirmedOffset > 0
                    ? .resume(offset: record.confirmedOffset)
                    : .start(offset: 0)
            }

            record.contentHash = offer.descriptor.contentHash
            record.expectedSize = offer.descriptor.expectedSize
            record.confirmedOffset = 0
            record.status = .transferring
            record.finalRelativePath = nil
            record.updatedAt = Date()
            try context.save()
            return .start(offset: 0)
        }

        let record = TransferRecord(
            sourceBindingID: sourceBindingID,
            resourceID: Self.transferRecordID(
                sourceBindingID: sourceBindingID,
                albumID: album.albumID,
                logicalResourceID: offer.resourceID
            ),
            albumID: album.albumID,
            logicalResourceID: offer.resourceID,
            contentHash: offer.descriptor.contentHash,
            expectedSize: offer.descriptor.expectedSize,
            status: .transferring
        )
        context.insert(record)
        try context.save()
        return .start(offset: 0)
    }

    public func recordCheckpoint(resourceID: String, offset: Int64) throws {
        let album = try requireActiveAlbum()
        guard let record = try record(resourceID: resourceID, album: album) else {
            throw ManifestStoreError.recordNotFound
        }
        guard offset >= 0, offset <= record.expectedSize else {
            throw ManifestStoreError.invalidOffset
        }
        record.confirmedOffset = offset
        record.status = .transferring
        record.updatedAt = Date()
        try context.save()
    }

    public func commit(resourceID: String, relativePath: String) throws {
        let album = try requireActiveAlbum()
        guard let record = try record(resourceID: resourceID, album: album) else {
            throw ManifestStoreError.recordNotFound
        }
        record.confirmedOffset = record.expectedSize
        record.status = .committed
        record.finalRelativePath = relativePath
        record.updatedAt = Date()
        try context.save()
    }

    public func reset(resourceID: String) throws {
        let album = try requireActiveAlbum()
        guard let record = try record(resourceID: resourceID, album: album) else {
            throw ManifestStoreError.recordNotFound
        }
        record.confirmedOffset = 0
        record.status = .transferring
        record.finalRelativePath = nil
        record.updatedAt = Date()
        try context.save()
    }

    public func snapshot(resourceID: String) throws -> TransferSnapshot? {
        let album = try requireActiveAlbum()
        guard let record = try record(resourceID: resourceID, album: album) else { return nil }
        return TransferSnapshot(
            sourceBindingID: record.sourceBindingID,
            albumID: record.albumID,
            resourceID: record.logicalResourceID,
            contentHash: record.contentHash,
            expectedSize: record.expectedSize,
            confirmedOffset: record.confirmedOffset,
            status: record.status,
            finalRelativePath: record.finalRelativePath,
            updatedAt: record.updatedAt
        )
    }

    func activeAlbumUsesLegacyPaths() throws -> Bool {
        let album = try requireActiveAlbum()
        return try sourceRecord()?.albumID == album.albumID
    }

    private func requireActiveAlbum() throws -> AcceptedAlbum {
        guard let activeAlbum else { throw ManifestStoreError.albumNotAccepted }
        return activeAlbum
    }

    private func record(
        resourceID: String,
        album: AcceptedAlbum
    ) throws -> TransferRecord? {
        let identifier = Self.transferRecordID(
            sourceBindingID: sourceBindingID,
            albumID: album.albumID,
            logicalResourceID: resourceID
        )
        var descriptor = FetchDescriptor<TransferRecord>(
            predicate: #Predicate { $0.resourceID == identifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func sourceRecord() throws -> SourceRecord? {
        let bindingID = sourceBindingID
        var descriptor = FetchDescriptor<SourceRecord>(
            predicate: #Predicate { $0.sourceBindingID == bindingID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func albumRecord(bindingKey: String) throws -> AlbumRecord? {
        let key = bindingKey
        var descriptor = FetchDescriptor<AlbumRecord>(
            predicate: #Predicate { $0.albumBindingKey == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func albumRecords() throws -> [AlbumRecord] {
        let bindingID = sourceBindingID
        return try context.fetch(FetchDescriptor<AlbumRecord>(
            predicate: #Predicate { $0.sourceBindingID == bindingID }
        ))
    }

    private func migrateLegacyAlbumIfNeeded(_ source: SourceRecord) throws {
        guard !source.albumID.isEmpty else { return }
        let bindingKey = Self.albumBindingKey(
            sourceBindingID: sourceBindingID,
            albumID: source.albumID
        )
        if try albumRecord(bindingKey: bindingKey) == nil {
            let legacyAlbum = AlbumRecord(
                albumBindingKey: bindingKey,
                sourceBindingID: sourceBindingID,
                albumID: source.albumID,
                albumName: source.albumName,
                destinationFolderName: try nextDestinationFolderName(for: source.albumName),
                createdAt: source.createdAt,
                updatedAt: source.updatedAt
            )
            context.insert(legacyAlbum)
        }
        try migrateLegacyTransfers(to: source.albumID)
    }

    private func migrateLegacyTransfers(to albumID: String) throws {
        let bindingID = sourceBindingID
        let emptyResourceID = ""
        let records = try context.fetch(FetchDescriptor<TransferRecord>(
            predicate: #Predicate {
                $0.sourceBindingID == bindingID
                    && $0.logicalResourceID == emptyResourceID
            }
        ))
        for record in records {
            let logicalResourceID = record.resourceID
            record.resourceID = Self.transferRecordID(
                sourceBindingID: sourceBindingID,
                albumID: albumID,
                logicalResourceID: logicalResourceID
            )
            record.albumID = albumID
            record.logicalResourceID = logicalResourceID
        }
    }

    private func nextDestinationFolderName(for albumName: String) throws -> String {
        let baseName = AlbumFolderPolicy.folderName(for: albumName)
        let usedNames = Set(try albumRecords().map(\.destinationFolderName))
        guard usedNames.contains(baseName) else { return baseName }
        for ordinal in 2...10_000 {
            let candidate = "\(baseName) (\(ordinal))"
            if !usedNames.contains(candidate) {
                return candidate
            }
        }
        return "\(baseName) (\(UUID().uuidString))"
    }

    private static func albumBindingKey(
        sourceBindingID: String,
        albumID: String
    ) -> String {
        digest(["album", sourceBindingID, albumID])
    }

    private static func transferRecordID(
        sourceBindingID: String,
        albumID: String,
        logicalResourceID: String
    ) -> String {
        digest(["transfer", sourceBindingID, albumID, logicalResourceID])
    }

    private static func digest(_ fields: [String]) -> String {
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
