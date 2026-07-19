import Foundation
import SwiftData
import SyncCore

public enum ManifestStoreError: Error, Equatable, Sendable {
    case invalidExpectedSize
    case invalidOffset
    case recordNotFound
    case sourceBindingMismatch
}

public actor ManifestStore {
    public nonisolated let sourceBindingID: String
    private let context: ModelContext

    public init(container: ModelContainer, sourceBindingID: String) {
        self.sourceBindingID = sourceBindingID
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
    }

    public func decision(for offer: ResourceOffer) throws -> TransferDecision {
        guard offer.descriptor.expectedSize >= 0 else {
            throw ManifestStoreError.invalidExpectedSize
        }
        if let record = try record(resourceID: offer.resourceID) {
            guard record.sourceBindingID == sourceBindingID else {
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
            resourceID: offer.resourceID,
            contentHash: offer.descriptor.contentHash,
            expectedSize: offer.descriptor.expectedSize,
            status: .transferring
        )
        context.insert(record)
        try context.save()
        return .start(offset: 0)
    }

    public func recordCheckpoint(resourceID: String, offset: Int64) throws {
        guard let record = try record(resourceID: resourceID) else {
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
        guard let record = try record(resourceID: resourceID) else {
            throw ManifestStoreError.recordNotFound
        }
        record.confirmedOffset = record.expectedSize
        record.status = .committed
        record.finalRelativePath = relativePath
        record.updatedAt = Date()
        try context.save()
    }

    public func reset(resourceID: String) throws {
        guard let record = try record(resourceID: resourceID) else {
            throw ManifestStoreError.recordNotFound
        }
        record.confirmedOffset = 0
        record.status = .transferring
        record.finalRelativePath = nil
        record.updatedAt = Date()
        try context.save()
    }

    public func snapshot(resourceID: String) throws -> TransferSnapshot? {
        guard let record = try record(resourceID: resourceID) else { return nil }
        return TransferSnapshot(
            sourceBindingID: record.sourceBindingID,
            resourceID: record.resourceID,
            contentHash: record.contentHash,
            expectedSize: record.expectedSize,
            confirmedOffset: record.confirmedOffset,
            status: record.status,
            finalRelativePath: record.finalRelativePath,
            updatedAt: record.updatedAt
        )
    }

    private func record(resourceID: String) throws -> TransferRecord? {
        let identifier = resourceID
        var descriptor = FetchDescriptor<TransferRecord>(
            predicate: #Predicate { $0.resourceID == identifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
