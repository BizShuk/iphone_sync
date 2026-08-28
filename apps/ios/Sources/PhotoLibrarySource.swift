@preconcurrency import Photos
import Foundation
import SyncCore

enum PhotoLibrarySourceError: Error, LocalizedError {
    case albumNotFound
    case fullAccessRequired
    case notEnoughSpace
    case resourceNotLocal

    var errorDescription: String? {
        switch self {
        case .albumNotFound:
            return "The selected Photos album no longer exists. Choose it again."
        case .fullAccessRequired:
            return "Full Photos access is required to guarantee a complete album backup."
        case .notEnoughSpace:
            return "There is not enough iPhone storage to stage this original resource."
        case .resourceNotLocal:
            return "This original resource is not stored on this iPhone."
        }
    }
}

enum PhotoResourceEvent: Sendable {
    /// A resource the consumer may either offer from a remembered descriptor
    /// or export on demand; the walk pauses until the consumer finishes it.
    case candidate(PhotoResourceCandidate)
    case skippedNotLocal(
        assetLocalIdentifier: String,
        resourceName: String
    )
    case assetFinished(
        assetLocalIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        fullyBackedUp: Bool
    )
}

/// One resource offered to the consumer without its bytes.
///
/// Exporting an original costs a full write plus a SHA-256 pass, so the walk
/// hands over metadata first and materialises the file only when `stage()` is
/// called. The consumer must call `finish(_:)` exactly once, which both
/// releases the walk and reports whether the resource turned out to be absent
/// from this iPhone.
struct PhotoResourceCandidate: Sendable {
    let identity: PhotoResourceIdentity
    let resourceName: String
    private let stageOperation: @Sendable () async throws -> StagedPhotoResource
    private let handoff: ResourceHandoff

    init(
        identity: PhotoResourceIdentity,
        resourceName: String,
        handoff: ResourceHandoff,
        stageOperation: @escaping @Sendable () async throws -> StagedPhotoResource
    ) {
        self.identity = identity
        self.resourceName = resourceName
        self.handoff = handoff
        self.stageOperation = stageOperation
    }

    /// Exports the original to a temporary file and hashes it.
    ///
    /// Throws `PhotoLibrarySourceError.resourceNotLocal` when the bytes only
    /// exist in iCloud.
    func stage() async throws -> StagedPhotoResource {
        try await stageOperation()
    }

    func finish(_ outcome: ResourceHandoff.Outcome) async {
        await handoff.finish(outcome)
    }
}

/// Back-pressure gate between the album walk and its consumer.
actor ResourceHandoff {
    enum Outcome: Sendable {
        case handled
        case notLocal
    }

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.finish(.handled) }
        }
    }

    func finish(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

struct StagedPhotoResource: Sendable {
    let descriptor: ResourceDescriptor
    let fileURL: URL
    private let lease: StagingLease

    init(descriptor: ResourceDescriptor, fileURL: URL, lease: StagingLease) {
        self.descriptor = descriptor
        self.fileURL = fileURL
        self.lease = lease
    }

    func cleanup() async {
        await lease.consume()
    }
}

actor StagingLease {
    private let fileURL: URL
    private var consumed = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func wait() async {
        if consumed { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.consume() }
        }
    }

    func consume() {
        guard !consumed else { return }
        consumed = true
        try? FileManager.default.removeItem(at: fileURL)
        continuation?.resume()
        continuation = nil
    }
}

/// Carries PhotoKit's non-`Sendable` handles into the lazy staging closure.
private struct PhotoResourceBox: @unchecked Sendable {
    let resource: PHAssetResource
    let asset: PHAsset
}

private final class PhotoResourceDataRequest: @unchecked Sendable {
    private let fileURL: URL
    private let manager: PHAssetResourceManager
    private let lock = NSLock()

    private var fileHandle: FileHandle?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelRequestWhenAvailable = false
    private var finished = false

    init(
        fileURL: URL,
        manager: PHAssetResourceManager = .default()
    ) throws {
        self.fileURL = fileURL
        self.manager = manager

        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil
        ) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }

        do {
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func load(
        resource: PHAssetResource,
        options: PHAssetResourceRequestOptions
    ) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                begin(
                    resource: resource,
                    options: options,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func begin(
        resource: PHAssetResource,
        options: PHAssetResourceRequestOptions,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let requestID = manager.requestData(
            for: resource,
            options: options
        ) { data in
            self.receive(data)
        } completionHandler: { error in
            if let error {
                self.finish(
                    with: .failure(error),
                    cancelRequest: false,
                    removePartialFile: true
                )
            } else {
                self.finish(
                    with: .success(()),
                    cancelRequest: false,
                    removePartialFile: false
                )
            }
        }

        lock.lock()
        self.requestID = requestID
        let shouldCancel = cancelRequestWhenAvailable
        lock.unlock()

        if shouldCancel {
            manager.cancelDataRequest(requestID)
        }
    }

    private func receive(_ data: Data) {
        var writeError: (any Error)?

        lock.lock()
        if !finished, let fileHandle {
            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                writeError = error
            }
        }
        lock.unlock()

        if let writeError {
            finish(
                with: .failure(writeError),
                cancelRequest: true,
                removePartialFile: true
            )
        }
    }

    func cancel() {
        finish(
            with: .failure(CancellationError()),
            cancelRequest: true,
            removePartialFile: true
        )
    }

    private func finish(
        with result: Result<Void, any Error>,
        cancelRequest: Bool,
        removePartialFile: Bool
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let fileHandle = self.fileHandle
        self.fileHandle = nil

        var requestIDToCancel: PHAssetResourceDataRequestID?
        if cancelRequest {
            cancelRequestWhenAvailable = true
            requestIDToCancel = requestID
        }
        lock.unlock()

        try? fileHandle?.close()
        if removePartialFile {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let requestIDToCancel {
            manager.cancelDataRequest(requestIDToCancel)
        }
        continuation?.resume(with: result)
    }
}

final class PhotoLibrarySource: @unchecked Sendable {
    func requestFullAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func albums() throws -> [PhotoAlbum] {
        guard authorizationStatus() == .authorized else {
            throw PhotoLibrarySourceError.fullAccessRequired
        }
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var albums: [PhotoAlbum] = []
        collections.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            albums.append(PhotoAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled Album",
                assetCount: count
            ))
        }
        return albums.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder == .orderedSame {
                return $0.id < $1.id
            }
            return titleOrder == .orderedAscending
        }
    }

    /// Walks an album oldest first, handing each resource over as metadata.
    ///
    /// Passing `resumingAfter` starts the walk at the interrupted position
    /// instead of the oldest asset, which is what lets a background window
    /// that ran out of time continue rather than repeat itself.
    func resources(
        albumID: String,
        resumingAfter cursor: AlbumSyncCursor? = nil
    ) -> AsyncThrowingStream<PhotoResourceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard self.authorizationStatus() == .authorized else {
                        throw PhotoLibrarySourceError.fullAccessRequired
                    }
                    let collections = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [albumID],
                        options: nil
                    )
                    guard let collection = collections.firstObject else {
                        throw PhotoLibrarySourceError.albumNotFound
                    }
                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(
                        key: "creationDate",
                        ascending: true
                    )]
                    if let cursor {
                        options.predicate = NSPredicate(
                            format: "creationDate >= %@",
                            cursor.assetCreationDate as NSDate
                        )
                    }
                    let result = PHAsset.fetchAssets(in: collection, options: options)

                    for assetIndex in 0..<result.count {
                        try Task.checkCancellation()
                        let asset = result.object(at: assetIndex)
                        var duplicateCounts: [String: Int] = [:]
                        var allResourcesAreLocal = true
                        let resources = PHAssetResource.assetResources(for: asset)
                        for resource in resources {
                            try Task.checkCancellation()
                            let key = "\(resource.type.rawValue)\u{0}\(resource.originalFilename)"
                            let duplicateOrdinal = duplicateCounts[key, default: 0]
                            duplicateCounts[key] = duplicateOrdinal + 1
                            let identity = PhotoResourceIdentity(
                                assetLocalIdentifier: asset.localIdentifier,
                                assetCreationDate: asset.creationDate,
                                assetModificationDate: asset.modificationDate,
                                resourceType: self.resourceTypeName(resource.type),
                                originalFilename: resource.originalFilename,
                                duplicateOrdinal: duplicateOrdinal,
                                role: self.resourceRole(resource.type)
                            )
                            let handoff = ResourceHandoff()
                            let box = PhotoResourceBox(resource: resource, asset: asset)
                            continuation.yield(.candidate(PhotoResourceCandidate(
                                identity: identity,
                                resourceName: resource.originalFilename,
                                handoff: handoff,
                                stageOperation: { [weak self] in
                                    guard let self else { throw CancellationError() }
                                    return try await self.stage(
                                        box.resource,
                                        asset: box.asset,
                                        duplicateOrdinal: duplicateOrdinal
                                    )
                                }
                            )))
                            if case .notLocal = await handoff.wait() {
                                allResourcesAreLocal = false
                                continuation.yield(.skippedNotLocal(
                                    assetLocalIdentifier: asset.localIdentifier,
                                    resourceName: resource.originalFilename
                                ))
                            }
                        }
                        continuation.yield(.assetFinished(
                            assetLocalIdentifier: asset.localIdentifier,
                            creationDate: asset.creationDate,
                            modificationDate: asset.modificationDate,
                            fullyBackedUp: !resources.isEmpty && allResourcesAreLocal
                        ))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func deleteAssets(
        candidates: Set<PhotoDeletionCandidate>
    ) async throws -> PhotoAssetDeletionResult {
        guard authorizationStatus() == .authorized else {
            throw PhotoLibrarySourceError.fullAccessRequired
        }
        guard !candidates.isEmpty else {
            return PhotoAssetDeletionResult(
                deletedAssetIDs: [],
                skippedAssetIDs: []
            )
        }

        var candidatesByAssetID: [String: PhotoDeletionCandidate] = [:]
        for candidate in candidates {
            candidatesByAssetID[candidate.assetLocalIdentifier] = candidate
        }
        let localIdentifiers = Set(candidatesByAssetID.keys)
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: localIdentifiers.sorted(),
            options: nil
        )
        var deletableAssets: [PHAsset] = []
        var deletableAssetIDs: Set<String> = []
        assets.enumerateObjects { asset, _, _ in
            guard let candidate = candidatesByAssetID[asset.localIdentifier],
                  candidate.modificationDate == asset.modificationDate else {
                return
            }
            guard asset.canPerform(.delete) else { return }
            deletableAssets.append(asset)
            deletableAssetIDs.insert(asset.localIdentifier)
        }
        let skippedAssetIDs = localIdentifiers.subtracting(deletableAssetIDs)

        guard !deletableAssets.isEmpty else {
            return PhotoAssetDeletionResult(
                deletedAssetIDs: [],
                skippedAssetIDs: skippedAssetIDs
            )
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(deletableAssets as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: PHPhotosErrorDomain,
                        code: PHPhotosError.userCancelled.rawValue
                    ))
                }
            }
        }

        return PhotoAssetDeletionResult(
            deletedAssetIDs: deletableAssetIDs,
            skippedAssetIDs: skippedAssetIDs
        )
    }

    private func stage(
        _ resource: PHAssetResource,
        asset: PHAsset,
        duplicateOrdinal: Int
    ) async throws -> StagedPhotoResource {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iPhoneSyncStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalExtension = (resource.originalFilename as NSString).pathExtension
        let safeExtension = originalExtension.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        } ? originalExtension : ""
        let filename = safeExtension.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(safeExtension)"
        let fileURL = directory.appendingPathComponent(filename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        do {
            let request = try PhotoResourceDataRequest(fileURL: fileURL)
            try await request.load(resource: resource, options: options)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            if isNotEnoughSpace(error) {
                throw PhotoLibrarySourceError.notEnoughSpace
            }
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain,
               nsError.code == PHPhotosError.networkAccessRequired.rawValue {
                throw PhotoLibrarySourceError.resourceNotLocal
            }
            throw error
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0
            let descriptor = ResourceDescriptor(
                assetLocalIdentifier: asset.localIdentifier,
                resourceType: resourceTypeName(resource.type),
                originalFilename: resource.originalFilename,
                duplicateOrdinal: duplicateOrdinal,
                contentHash: try FileHasher.sha256(url: fileURL),
                expectedSize: size,
                creationDate: asset.creationDate,
                role: resourceRole(resource.type)
            )
            let lease = StagingLease(fileURL: fileURL)
            return StagedPhotoResource(descriptor: descriptor, fileURL: fileURL, lease: lease)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    private func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternate-photo"
        case .fullSizePhoto: "full-size-photo"
        case .fullSizeVideo: "full-size-video"
        case .adjustmentData: "adjustment-data"
        case .adjustmentBasePhoto: "adjustment-base-photo"
        case .pairedVideo: "paired-video"
        case .fullSizePairedVideo: "full-size-paired-video"
        case .adjustmentBasePairedVideo: "adjustment-base-paired-video"
        case .adjustmentBaseVideo: "adjustment-base-video"
        case .photoProxy: "photo-proxy"
        @unknown default: "resource-\(type.rawValue)"
        }
    }

    private func resourceRole(_ type: PHAssetResourceType) -> String? {
        switch type {
        case .photo, .video, .audio:
            nil
        default:
            resourceTypeName(type)
        }
    }

    private func isNotEnoughSpace(_ error: any Error) -> Bool {
        var currentError: NSError? = error as NSError
        var remainingUnderlyingErrors = 4

        while let candidate = currentError, remainingUnderlyingErrors > 0 {
            if candidate.domain == PHPhotosErrorDomain,
               candidate.code == PHPhotosError.notEnoughSpace.rawValue {
                return true
            }
            if candidate.domain == NSCocoaErrorDomain,
               candidate.code == NSFileWriteOutOfSpaceError {
                return true
            }
            if candidate.domain == NSPOSIXErrorDomain,
               candidate.code == POSIXErrorCode.ENOSPC.rawValue {
                return true
            }

            currentError = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            remainingUnderlyingErrors -= 1
        }

        return false
    }
}
