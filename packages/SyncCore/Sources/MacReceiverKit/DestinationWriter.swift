import Foundation
import SyncCore

public enum DestinationBeginResult: Equatable, Sendable {
    case transfer(offset: Int64, relativePath: String)
    case adopted(relativePath: String)
}

public enum DestinationWriterError: Error, Equatable, LocalizedError, Sendable {
    case activeTransferExists
    case albumNotPrepared
    case noActiveTransfer
    case invalidOffset
    case expectedSizeExceeded
    case incompleteTransfer
    case integrityMismatch
    case unsafeDestination
    case unableToCreatePartial(reason: String)

    public var errorDescription: String? {
        switch self {
        case .activeTransferExists:
            "Another resource transfer is already active."
        case .albumNotPrepared:
            "The album destination folder has not been prepared."
        case .noActiveTransfer:
            "There is no active resource transfer."
        case .invalidOffset:
            "The resource offset does not match the durable checkpoint."
        case .expectedSizeExceeded:
            "The received resource exceeded its declared size."
        case .incompleteTransfer:
            "The resource ended before its declared size was received."
        case .integrityMismatch:
            "The received resource failed SHA-256 verification."
        case .unsafeDestination:
            "The album destination conflicts with a file, symlink, or unsafe path."
        case let .unableToCreatePartial(reason):
            "The receiver could not create the partial resource file: \(reason)"
        }
    }
}

public actor DestinationWriter {
    public static let receivingFolderName = "iPhoneSync"

    private struct PathResolution {
        let relativePath: String
        let resourceRelativePath: String
        let adopted: Bool
    }

    private struct ActiveTransfer {
        let offer: ResourceOffer
        var relativePath: String
        var finalURL: URL
        var partialURL: URL
        var offset: Int64
        let handle: FileHandle
    }

    private let destinationRoot: URL
    private let manifest: ManifestStore
    private let storageMode: DestinationStorageMode
    private var albumFolderName: String?
    private var active: ActiveTransfer?

    public init(
        destinationRoot: URL,
        manifest: ManifestStore,
        storageMode: DestinationStorageMode = .albumDate
    ) {
        self.destinationRoot = URL(
            fileURLWithPath: destinationRoot.standardizedFileURL.path,
            isDirectory: true
        )
        self.manifest = manifest
        self.storageMode = storageMode
    }

    @discardableResult
    public func prepareAlbumDirectory(named albumName: String) throws -> String {
        guard active == nil else { throw DestinationWriterError.activeTransferExists }
        let receivingRoot = destinationRoot.appendingPathComponent(
            Self.receivingFolderName,
            isDirectory: true
        )
        try prepareSafeDirectory(receivingRoot, expectedParent: destinationRoot)

        let folderName = AlbumFolderPolicy.folderName(for: albumName)
        albumFolderName = folderName
        if storageMode != .flat {
            let folderURL = receivingRoot.appendingPathComponent(folderName, isDirectory: true)
            guard isSameDirectory(folderURL.deletingLastPathComponent(), receivingRoot) else {
                throw DestinationWriterError.unsafeDestination
            }
            try prepareSafeDirectory(folderURL, expectedParent: receivingRoot)
        }
        return folderName
    }

    public func begin(_ offer: ResourceOffer) async throws -> DestinationBeginResult {
        guard active == nil else { throw DestinationWriterError.activeTransferExists }
        guard albumFolderName != nil else { throw DestinationWriterError.albumNotPrepared }
        let decision = try await manifest.decision(for: offer)
        if case .skip = decision,
           let snapshot = try await manifest.snapshot(resourceID: offer.resourceID),
           let relativePath = snapshot.finalRelativePath {
            let finalURL = destinationRoot.appendingPathComponent(relativePath)
            if try fileMatches(finalURL, offer: offer) {
                return .adopted(relativePath: relativePath)
            }
            try await manifest.reset(resourceID: offer.resourceID)
        }

        let resolution = try await resolveRelativePath(for: offer)
        if resolution.adopted {
            try await manifest.commit(
                resourceID: offer.resourceID,
                relativePath: resolution.relativePath
            )
            return .adopted(relativePath: resolution.relativePath)
        }

        let finalURL = destinationRoot.appendingPathComponent(resolution.relativePath)
        try createSafeParentDirectory(for: finalURL)
        let partialURL = finalURL.appendingPathExtension("partial")
        try rejectSymbolicLink(at: partialURL)
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            let previousAlbumPartialURL: URL? = {
                guard storageMode != .flat, let albumFolderName else { return nil }
                return destinationRoot
                    .appendingPathComponent(albumFolderName, isDirectory: true)
                    .appendingPathComponent(resolution.resourceRelativePath)
                    .appendingPathExtension("partial")
            }()
            let legacyPartialURL = destinationRoot
                .appendingPathComponent(resolution.resourceRelativePath)
                .appendingPathExtension("partial")
            if let previousAlbumPartialURL {
                try rejectSymbolicLink(at: previousAlbumPartialURL)
            }
            try rejectSymbolicLink(at: legacyPartialURL)
            if let previousAlbumPartialURL,
               FileManager.default.fileExists(atPath: previousAlbumPartialURL.path) {
                try FileManager.default.moveItem(at: previousAlbumPartialURL, to: partialURL)
            } else if try await manifest.activeAlbumUsesLegacyPaths(),
                      FileManager.default.fileExists(atPath: legacyPartialURL.path) {
                try FileManager.default.moveItem(at: legacyPartialURL, to: partialURL)
            } else {
                do {
                    // `Data.write` reports why the file could not be created;
                    // `FileManager.createFile` only returns false.
                    try Data().write(to: partialURL, options: .withoutOverwriting)
                } catch {
                    throw DestinationWriterError.unableToCreatePartial(
                        reason: error.localizedDescription
                    )
                }
            }
        }

        let snapshot = try await manifest.snapshot(resourceID: offer.resourceID)
        var confirmedOffset = snapshot?.confirmedOffset ?? 0
        let attributes = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        let fileSize = (attributes[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forUpdating: partialURL)
        if fileSize > confirmedOffset {
            try handle.truncate(atOffset: UInt64(confirmedOffset))
        } else if fileSize < confirmedOffset {
            confirmedOffset = fileSize
            try await manifest.recordCheckpoint(
                resourceID: offer.resourceID,
                offset: confirmedOffset
            )
        }
        try handle.seek(toOffset: UInt64(confirmedOffset))
        active = ActiveTransfer(
            offer: offer,
            relativePath: resolution.relativePath,
            finalURL: finalURL,
            partialURL: partialURL,
            offset: confirmedOffset,
            handle: handle
        )
        return .transfer(offset: confirmedOffset, relativePath: resolution.relativePath)
    }

    public func append(_ data: Data, offset: Int64) throws {
        guard var transfer = active else { throw DestinationWriterError.noActiveTransfer }
        guard offset == transfer.offset else { throw DestinationWriterError.invalidOffset }
        let nextOffset = offset + Int64(data.count)
        guard nextOffset <= transfer.offer.descriptor.expectedSize else {
            throw DestinationWriterError.expectedSizeExceeded
        }
        try transfer.handle.write(contentsOf: data)
        transfer.offset = nextOffset
        active = transfer
    }

    public func checkpoint(at offset: Int64? = nil) async throws {
        guard let transfer = active else { throw DestinationWriterError.noActiveTransfer }
        let durableOffset = offset ?? transfer.offset
        guard durableOffset >= 0, durableOffset <= transfer.offset else {
            throw DestinationWriterError.invalidOffset
        }
        try transfer.handle.synchronize()
        try await manifest.recordCheckpoint(
            resourceID: transfer.offer.resourceID,
            offset: durableOffset
        )
    }

    public func commit(expectedHash: String) async throws -> URL {
        guard var transfer = active else { throw DestinationWriterError.noActiveTransfer }
        guard transfer.offset == transfer.offer.descriptor.expectedSize else {
            throw DestinationWriterError.incompleteTransfer
        }
        try transfer.handle.synchronize()
        try transfer.handle.close()

        guard try FileHasher.sha256(url: transfer.partialURL) == expectedHash else {
            try? FileManager.default.removeItem(at: transfer.partialURL)
            active = nil
            try await manifest.reset(resourceID: transfer.offer.resourceID)
            throw DestinationWriterError.integrityMismatch
        }

        let currentResolution = try await resolveRelativePath(for: transfer.offer)
        if currentResolution.adopted {
            try? FileManager.default.removeItem(at: transfer.partialURL)
            transfer.relativePath = currentResolution.relativePath
            transfer.finalURL = destinationRoot.appendingPathComponent(currentResolution.relativePath)
        } else if currentResolution.relativePath != transfer.relativePath {
            transfer.relativePath = currentResolution.relativePath
            transfer.finalURL = destinationRoot.appendingPathComponent(currentResolution.relativePath)
            try createSafeParentDirectory(for: transfer.finalURL)
            let newPartialURL = transfer.finalURL.appendingPathExtension("partial")
            try FileManager.default.moveItem(at: transfer.partialURL, to: newPartialURL)
            transfer.partialURL = newPartialURL
        }

        if !currentResolution.adopted {
            guard !FileManager.default.fileExists(atPath: transfer.finalURL.path) else {
                active = nil
                throw DestinationWriterError.unsafeDestination
            }
            try FileManager.default.moveItem(at: transfer.partialURL, to: transfer.finalURL)
        }
        if let creationDate = transfer.offer.descriptor.creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate, .modificationDate: creationDate],
                ofItemAtPath: transfer.finalURL.path
            )
        }
        try await manifest.commit(
            resourceID: transfer.offer.resourceID,
            relativePath: transfer.relativePath
        )
        active = nil
        return transfer.finalURL
    }

    public func abort() {
        guard let transfer = active else { return }
        try? transfer.handle.close()
        active = nil
    }

    public func simulateCrash() {
        abort()
    }

    public func activePartialURL() throws -> URL {
        guard let active else { throw DestinationWriterError.noActiveTransfer }
        return active.partialURL
    }

    private func resolveRelativePath(
        for offer: ResourceOffer
    ) async throws -> PathResolution {
        for prefixLength in [8, 16, 64] {
            let generatedResourcePath = try FilenamePolicy.relativePath(
                originalFilename: offer.descriptor.originalFilename,
                resourceID: offer.resourceID,
                role: offer.descriptor.role,
                creationDate: offer.descriptor.creationDate,
                resourceIDPrefixLength: prefixLength
            )
            let resourceRelativePath = normalizedResourceRelativePath(from: generatedResourcePath)
            let relativePath = try albumRelativePath(for: resourceRelativePath)
            let url = destinationRoot.appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: url.path) {
                return PathResolution(
                    relativePath: relativePath,
                    resourceRelativePath: resourceRelativePath,
                    adopted: false
                )
            }
            if try fileMatches(url, offer: offer) {
                return PathResolution(
                    relativePath: relativePath,
                    resourceRelativePath: resourceRelativePath,
                    adopted: true
                )
            }
        }

        let fullResourcePath = try FilenamePolicy.relativePath(
            originalFilename: offer.descriptor.originalFilename,
            resourceID: offer.resourceID,
            role: offer.descriptor.role,
            creationDate: offer.descriptor.creationDate,
            resourceIDPrefixLength: 64
        )
        let normalizedFullResourcePath = normalizedResourceRelativePath(
            from: fullResourcePath
        )
        let fullURL = URL(fileURLWithPath: normalizedFullResourcePath)
        let fileExtension = fullURL.pathExtension
        let base = fullURL.deletingPathExtension().path
        for ordinal in 2...10_000 {
            let resourceRelativePath = fileExtension.isEmpty
                ? "\(base)-\(ordinal)"
                : "\(base)-\(ordinal).\(fileExtension)"
            let relativePath = try albumRelativePath(for: resourceRelativePath)
            let url = destinationRoot.appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: url.path) {
                return PathResolution(
                    relativePath: relativePath,
                    resourceRelativePath: resourceRelativePath,
                    adopted: false
                )
            }
            if try fileMatches(url, offer: offer) {
                return PathResolution(
                    relativePath: relativePath,
                    resourceRelativePath: resourceRelativePath,
                    adopted: true
                )
            }
        }
        throw DestinationWriterError.unsafeDestination
    }

    private func albumRelativePath(for resourceRelativePath: String) throws -> String {
        switch storageMode {
        case .albumDate, .albumOnly:
            guard let albumFolderName else {
                throw DestinationWriterError.albumNotPrepared
            }
            return "\(Self.receivingFolderName)/\(albumFolderName)/\(resourceRelativePath)"
        case .flat:
            return "\(Self.receivingFolderName)/\(resourceRelativePath)"
        }
    }

    private func normalizedResourceRelativePath(from generatedResourcePath: String) -> String {
        switch storageMode {
        case .albumDate:
            return generatedResourcePath
        case .albumOnly, .flat:
            return URL(fileURLWithPath: generatedResourcePath).lastPathComponent
        }
    }

    private func prepareSafeDirectory(_ url: URL, expectedParent: URL) throws {
        guard isSameDirectory(url.deletingLastPathComponent(), expectedParent) else {
            throw DestinationWriterError.unsafeDestination
        }
        try prepareDirectory(at: url)
    }

    /// Creates `url` when it is missing. An existing entry is accepted only when it
    /// resolves to a directory, so a symbolic link to a folder is used like a normal
    /// folder even when its target lives outside the destination root.
    private func prepareDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw DestinationWriterError.unsafeDestination
            }
            return
        }

        // A dangling symbolic link is invisible to `fileExists` but still owns the name.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
            throw DestinationWriterError.unsafeDestination
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
    }

    private func fileMatches(_ url: URL, offer: ResourceOffer) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try rejectSymbolicLink(at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[FileAttributeKey.size] as? NSNumber)?.int64Value
                == offer.descriptor.expectedSize else {
            return false
        }
        return try FileHasher.sha256(url: url) == offer.descriptor.contentHash
    }

    private func createSafeParentDirectory(for fileURL: URL) throws {
        var current = destinationRoot
        let relativeParent = fileURL.deletingLastPathComponent().path
            .dropFirst(destinationRoot.path.count)
            .split(separator: "/")
        for component in relativeParent {
            guard component != ".." else {
                throw DestinationWriterError.unsafeDestination
            }
            current.appendPathComponent(String(component), isDirectory: true)
            try prepareDirectory(at: current)
        }
    }

    private func isSameDirectory(_ url: URL, _ other: URL) -> Bool {
        url.standardizedFileURL.path == other.standardizedFileURL.path
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw DestinationWriterError.unsafeDestination
        }
    }
}
