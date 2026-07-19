@preconcurrency import Photos
import Foundation
import SyncCore

enum PhotoLibrarySourceError: Error, LocalizedError {
    case albumNotFound
    case fullAccessRequired
    case notEnoughSpace

    var errorDescription: String? {
        switch self {
        case .albumNotFound:
            return "The selected Photos album no longer exists. Choose it again."
        case .fullAccessRequired:
            return "Full Photos access is required to guarantee a complete album backup."
        case .notEnoughSpace:
            return "There is not enough iPhone storage to stage this original resource."
        }
    }
}

enum PhotoResourceEvent: Sendable {
    case staged(StagedPhotoResource)
    case skippedNotLocal
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

    fileprivate func waitUntilConsumed() async {
        await lease.wait()
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
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func resources(albumID: String) -> AsyncThrowingStream<PhotoResourceEvent, any Error> {
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
                    let result = PHAsset.fetchAssets(in: collection, options: options)
                    var assets: [PHAsset] = []
                    result.enumerateObjects { asset, _, _ in assets.append(asset) }

                    for asset in assets {
                        try Task.checkCancellation()
                        var duplicateCounts: [String: Int] = [:]
                        for resource in PHAssetResource.assetResources(for: asset) {
                            try Task.checkCancellation()
                            let key = "\(resource.type.rawValue)\u{0}\(resource.originalFilename)"
                            let duplicateOrdinal = duplicateCounts[key, default: 0]
                            duplicateCounts[key] = duplicateOrdinal + 1
                            do {
                                let staged = try await self.stage(
                                    resource,
                                    asset: asset,
                                    duplicateOrdinal: duplicateOrdinal
                                )
                                continuation.yield(.staged(staged))
                                await staged.waitUntilConsumed()
                            } catch let error as NSError
                                where error.domain == PHPhotosErrorDomain
                                    && error.code == PHPhotosError.networkAccessRequired.rawValue {
                                continuation.yield(.skippedNotLocal)
                            }
                        }
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
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: fileURL,
                    options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain,
               nsError.code == PHPhotosError.notEnoughSpace.rawValue {
                throw PhotoLibrarySourceError.notEnoughSpace
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
}
