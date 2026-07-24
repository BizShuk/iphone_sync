import Foundation
import Network
import SyncCore
import UIKit

struct IOSSyncProgress: Equatable, Sendable {
    let albumName: String
    let resourceName: String
    let sentBytes: Int64
    let totalBytes: Int64
}

enum IOSSyncCoordinatorError: Error, LocalizedError, Sendable {
    case macNotFound
    case notPaired
    case pairingNotStarted
    case resourceFailed(
        code: TransferFailureCode,
        message: String,
        retryable: Bool
    )

    var errorDescription: String? {
        switch self {
        case .macNotFound: "The paired Mac is not available on this local network."
        case .notPaired: "Pair this iPhone with a Mac first."
        case .pairingNotStarted: "Choose a Mac before entering its pairing code."
        case let .resourceFailed(_, message, _): message
        }
    }
}

enum IOSSyncDiscoveryStrategy: Sendable {
    case foregroundRetries
    case singleAttempt
}

enum IOSSyncResourceRetryPolicy {
    static func shouldRetryImmediately(
        code: TransferFailureCode,
        retryable: Bool
    ) -> Bool {
        code == .integrity && retryable
    }
}

actor IOSSyncCoordinator {
    private static let pairedPeerAccount = "paired-peer"
    private static let receiverRetryDelays: [UInt64] = [0, 1, 2, 4]

    private let photoSource: PhotoLibrarySource
    private let keychain = KeychainSecretStore()
    private let deviceID: String
    private let onProgress: @Sendable (IOSSyncProgress?) -> Void
    private let onOperation: @Sendable (OperationLogEvent) async -> Void
    private var discovery: BonjourDiscovery?
    private var pendingPairing: PendingPairing?
    private var activeClient: SyncClient?
    private var cancelRequested = false
    private var transferringResource = false

    init(
        photoSource: PhotoLibrarySource,
        deviceID: String,
        onProgress: @escaping @Sendable (IOSSyncProgress?) -> Void,
        onOperation: @escaping @Sendable (OperationLogEvent) async -> Void = { _ in }
    ) {
        self.photoSource = photoSource
        self.deviceID = deviceID
        self.onProgress = onProgress
        self.onOperation = onOperation
    }

    func loadPairedPeer() throws -> PairedPeer? {
        try keychain.load(PairedPeer.self, account: Self.pairedPeerAccount)
    }

    func receiverStream(pairing: Bool) -> AsyncStream<[DiscoveredReceiver]> {
        discovery?.stop()
        let service = pairing
            ? SyncConstants.pairingServiceType
            : SyncConstants.normalServiceType
        let discovery = BonjourDiscovery(serviceType: service, requireWiFi: true)
        self.discovery = discovery
        return discovery.receivers()
    }

    func stopDiscovery() {
        discovery?.stop()
        discovery = nil
    }

    func beginPairing(receiver: DiscoveredReceiver) async throws {
        stopDiscovery()
        await emit(
            .info,
            category: "Pairing",
            message: "Connecting to “\(receiver.displayName)”."
        )
        let client = PairingClient(deviceID: deviceID, requireWiFi: true)
        pendingPairing = try await client.begin(
            endpoint: receiver.endpoint,
            deviceName: resolvedDeviceName()
        )
        await emit(
            .info,
            category: "Pairing",
            message: "Secure pairing channel opened; waiting for code confirmation."
        )
    }

    func confirmPairing(code: String) async throws -> PairedPeer {
        guard let pendingPairing else {
            throw IOSSyncCoordinatorError.pairingNotStarted
        }
        let peer = try await pendingPairing.confirm(code: code)
        try keychain.save(peer, account: Self.pairedPeerAccount)
        self.pendingPairing = nil
        await emit(
            .success,
            category: "Pairing",
            message: "Paired with “\(peer.displayName)”."
        )
        return peer
    }

    func cancelPairing() async {
        if let pendingPairing {
            await pendingPairing.cancel()
        }
        pendingPairing = nil
        await emit(
            .info,
            category: "Pairing",
            message: "Pairing cancelled."
        )
    }

    func pair(endpoint: NWEndpoint, code: String) async throws -> PairedPeer {
        if pendingPairing == nil {
            let client = PairingClient(deviceID: deviceID, requireWiFi: true)
            pendingPairing = try await client.begin(
                endpoint: endpoint,
                deviceName: await resolvedDeviceName()
            )
        }
        return try await confirmPairing(code: code)
    }

    @MainActor
    private func resolvedDeviceName() -> String {
        let trimmedName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "iPhone" : trimmedName
    }

    func forgetPeer() throws {
        try keychain.delete(account: Self.pairedPeerAccount)
    }

    func sync(albums: [PhotoAlbum]) async throws -> SyncSummary {
        try await sync(albums: albums, discoveryStrategy: .foregroundRetries)
    }

    func sync(
        albums: [PhotoAlbum],
        discoveryStrategy: IOSSyncDiscoveryStrategy
    ) async throws -> SyncSummary {
        guard var peer = try loadPairedPeer() else {
            throw IOSSyncCoordinatorError.notPaired
        }
        cancelRequested = false
        var combinedSummary = SyncSummary.zero

        for album in albums {
            try Task.checkCancellation()
            if cancelRequested { throw CancellationError() }
            await emit(
                .info,
                category: "Album",
                message: "Starting album “\(album.title)” "
                    + "(\(album.assetCount) assets)."
            )
            let result = try await sync(
                album: album,
                peer: peer,
                discoveryStrategy: discoveryStrategy
            )
            peer = result.peer
            combinedSummary.added += result.summary.added
            combinedSummary.existing += result.summary.existing
            combinedSummary.notLocal += result.summary.notLocal
            combinedSummary.failed += result.summary.failed
            await emit(
                .success,
                category: "Album",
                message: "Finished “\(album.title)”: \(result.summary.added) added, "
                    + "\(result.summary.existing) already present, "
                    + "\(result.summary.notLocal) not local, "
                    + "\(result.summary.failed) failed."
            )
        }
        return combinedSummary
    }

    private func sync(
        album: PhotoAlbum,
        peer: PairedPeer,
        discoveryStrategy: IOSSyncDiscoveryStrategy
    ) async throws -> (summary: SyncSummary, peer: PairedPeer) {
        var peer = peer
        let receiver: DiscoveredReceiver
        do {
            switch discoveryStrategy {
            case .foregroundRetries:
                receiver = try await discoverReceiverWithRetry(id: peer.id)
            case .singleAttempt:
                receiver = try await discoverReceiver(id: peer.id)
            }
        } catch {
            if cancelRequested { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        if cancelRequested { throw CancellationError() }
        let parameters = PSKTLSParameters.make(
            psk: peer.psk,
            identity: peer.pskIdentity,
            role: .client,
            requireWiFi: true
        )
        let client = SyncClient(connection: FramedConnection(NWConnection(
            to: receiver.endpoint,
            using: parameters
        )))
        activeClient = client
        defer {
            activeClient = nil
            onProgress(nil)
        }

        do {
            let sourceBindingID = try await client.openSession(
                albumID: album.id,
                albumName: album.title,
                sourceBindingID: peer.sourceBindingID
            )
            await emit(
                .success,
                category: "Session",
                message: "Mac accepted album “\(album.title)”."
            )
            if peer.sourceBindingID != sourceBindingID {
                peer = PairedPeer(
                    id: peer.id,
                    displayName: peer.displayName,
                    pskIdentity: peer.pskIdentity,
                    psk: peer.psk,
                    sourceBindingID: sourceBindingID
                )
                try keychain.save(peer, account: Self.pairedPeerAccount)
                await emit(
                    .info,
                    category: "Session",
                    message: "Saved the destination source binding."
                )
            }

            var notLocal = 0
            for try await event in photoSource.resources(albumID: album.id) {
                try Task.checkCancellation()
                if cancelRequested { throw CancellationError() }
                switch event {
                case let .skippedNotLocal(resourceName):
                    notLocal += 1
                    await emit(
                        .warning,
                        category: "Resource",
                        message: "Skipped “\(resourceName)”; it is not stored on this iPhone."
                    )
                case let .staged(staged):
                    transferringResource = true
                    do {
                        try await send(
                            staged,
                            albumName: album.title,
                            bindingID: sourceBindingID,
                            client: client
                        )
                    } catch {
                        await staged.cleanup()
                        transferringResource = false
                        throw error
                    }
                    await staged.cleanup()
                    transferringResource = false
                }
            }
            try Task.checkCancellation()
            if cancelRequested { throw CancellationError() }
            var summary = try await client.finish()
            summary.notLocal = notLocal
            return (summary, peer)
        } catch {
            await client.cancel()
            throw error
        }
    }

    func cancel() async {
        cancelRequested = true
        discovery?.stop()
        if let activeClient {
            await activeClient.cancel()
        }
        await emit(
            .warning,
            category: "Sync",
            message: transferringResource
                ? "Cancelled the active resource transfer."
                : "Cancelled the active sync operation."
        )
    }

    private func send(
        _ staged: StagedPhotoResource,
        albumName: String,
        bindingID: String,
        client: SyncClient
    ) async throws {
        let resourceID = ResourceIdentity.make(
            sourceBindingID: bindingID,
            descriptor: staged.descriptor
        )
        let offer = ResourceOffer(resourceID: resourceID, descriptor: staged.descriptor)
        let resourceName = staged.descriptor.originalFilename
        await emit(
            .info,
            category: "Resource",
            message: "Sending “\(resourceName)” "
                + "(\(staged.descriptor.expectedSize) bytes)."
        )
        let progress: @Sendable (Int64, Int64) -> Void = { [onProgress] sent, total in
            onProgress(IOSSyncProgress(
                albumName: albumName,
                resourceName: staged.descriptor.originalFilename,
                sentBytes: sent,
                totalBytes: total
            ))
        }
        var result = try await client.sendResource(
            offer,
            fileURL: staged.fileURL,
            progress: progress
        )
        try Task.checkCancellation()
        if cancelRequested { throw CancellationError() }
        if case let .failed(code, _, retryable) = result,
           IOSSyncResourceRetryPolicy.shouldRetryImmediately(
               code: code,
               retryable: retryable
           ) {
            await emit(
                .warning,
                category: "Resource",
                message: "Integrity verification failed for “\(resourceName)”; retrying once."
            )
            result = try await client.sendResource(
                offer,
                fileURL: staged.fileURL,
                progress: progress
            )
        }
        try Task.checkCancellation()
        if cancelRequested { throw CancellationError() }
        switch result {
        case .skipped:
            await emit(
                .info,
                category: "Resource",
                message: "Skipped “\(resourceName)”; already present on the Mac."
            )
        case let .committed(relativePath):
            await emit(
                .success,
                category: "Resource",
                message: "Sent “\(resourceName)” to “\(relativePath)”."
            )
        case let .failed(code, message, retryable):
            await emit(
                .error,
                category: "Resource",
                message: "Failed “\(resourceName)”: \(message)"
            )
            throw IOSSyncCoordinatorError.resourceFailed(
                code: code,
                message: message,
                retryable: retryable
            )
        }
    }

    private func discoverReceiver(id: String) async throws -> DiscoveredReceiver {
        await emit(
            .info,
            category: "Discovery",
            message: "Looking for the exact paired Mac on Wi-Fi."
        )
        let discovery = BonjourDiscovery(
            serviceType: SyncConstants.normalServiceType,
            requireWiFi: true
        )
        self.discovery = discovery
        defer {
            discovery.stop()
            if self.discovery === discovery { self.discovery = nil }
        }
        return try await withThrowingTaskGroup(of: DiscoveredReceiver.self) { group in
            group.addTask {
                for await receivers in discovery.receivers() {
                    if let receiver = receivers.first(where: { $0.id == id }) {
                        return receiver
                    }
                }
                throw IOSSyncCoordinatorError.macNotFound
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw IOSSyncCoordinatorError.macNotFound
            }
            guard let receiver = try await group.next() else {
                throw IOSSyncCoordinatorError.macNotFound
            }
            group.cancelAll()
            await emit(
                .success,
                category: "Discovery",
                message: "Found “\(receiver.displayName)”."
            )
            return receiver
        }
    }

    private func discoverReceiverWithRetry(id: String) async throws -> DiscoveredReceiver {
        var lastError: any Error = IOSSyncCoordinatorError.macNotFound
        for delay in Self.receiverRetryDelays {
            if cancelRequested { throw CancellationError() }
            if delay > 0 {
                try await Task.sleep(for: .seconds(Int64(delay)))
            }
            if cancelRequested { throw CancellationError() }
            do {
                return try await discoverReceiver(id: id)
            } catch {
                if cancelRequested || error is CancellationError {
                    throw CancellationError()
                }
                lastError = error
                await emit(
                    .warning,
                    category: "Discovery",
                    message: "The paired Mac was not found in this discovery attempt."
                )
            }
        }
        throw lastError
    }

    private func emit(
        _ level: OperationLogLevel,
        category: String,
        message: String
    ) async {
        await onOperation(OperationLogEvent(
            level: level,
            category: category,
            message: message
        ))
    }
}
