import Foundation
import Network
import SyncCore
import UIKit

struct IOSSyncProgress: Equatable, Sendable {
    let resourceName: String
    let sentBytes: Int64
    let totalBytes: Int64
}

enum IOSSyncCoordinatorError: Error, LocalizedError {
    case macNotFound
    case notPaired
    case pairingNotStarted
    case resourceFailed(String)

    var errorDescription: String? {
        switch self {
        case .macNotFound: "The paired Mac is not available on this local network."
        case .notPaired: "Pair this iPhone with a Mac first."
        case .pairingNotStarted: "Choose a Mac before entering its pairing code."
        case let .resourceFailed(message): message
        }
    }
}

actor IOSSyncCoordinator {
    private static let pairedPeerAccount = "paired-peer"
    private static let receiverRetryDelays: [UInt64] = [0, 1, 2, 4]

    private let photoSource: PhotoLibrarySource
    private let keychain = KeychainSecretStore()
    private let deviceID: String
    private let onProgress: @Sendable (IOSSyncProgress?) -> Void
    private var discovery: BonjourDiscovery?
    private var pendingPairing: PendingPairing?
    private var activeClient: SyncClient?
    private var cancelRequested = false
    private var transferringResource = false

    init(
        photoSource: PhotoLibrarySource,
        deviceID: String,
        onProgress: @escaping @Sendable (IOSSyncProgress?) -> Void
    ) {
        self.photoSource = photoSource
        self.deviceID = deviceID
        self.onProgress = onProgress
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
        let client = PairingClient(deviceID: deviceID, requireWiFi: true)
        pendingPairing = try await client.begin(
            endpoint: receiver.endpoint,
            deviceName: UIDevice.current.name
        )
    }

    func confirmPairing(code: String) async throws -> PairedPeer {
        guard let pendingPairing else {
            throw IOSSyncCoordinatorError.pairingNotStarted
        }
        let peer = try await pendingPairing.confirm(code: code)
        try keychain.save(peer, account: Self.pairedPeerAccount)
        self.pendingPairing = nil
        return peer
    }

    func cancelPairing() async {
        if let pendingPairing {
            await pendingPairing.cancel()
        }
        pendingPairing = nil
    }

    func pair(endpoint: NWEndpoint, code: String) async throws -> PairedPeer {
        if pendingPairing == nil {
            let client = PairingClient(deviceID: deviceID, requireWiFi: true)
            pendingPairing = try await client.begin(
                endpoint: endpoint,
                deviceName: UIDevice.current.name
            )
        }
        return try await confirmPairing(code: code)
    }

    func forgetPeer() throws {
        try keychain.delete(account: Self.pairedPeerAccount)
    }

    func sync(album: PhotoAlbum) async throws -> SyncSummary {
        guard var peer = try loadPairedPeer() else {
            throw IOSSyncCoordinatorError.notPaired
        }
        cancelRequested = false
        let receiver: DiscoveredReceiver
        do {
            receiver = try await discoverReceiverWithRetry(id: peer.id)
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
            Task { await client.cancel() }
        }

        let sourceBindingID = try await client.openSession(
            albumID: album.id,
            albumName: album.title,
            sourceBindingID: peer.sourceBindingID
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
        }

        var notLocal = 0
        for try await event in photoSource.resources(albumID: album.id) {
            if cancelRequested { break }
            switch event {
            case .skippedNotLocal:
                notLocal += 1
            case let .staged(staged):
                transferringResource = true
                do {
                    try await send(staged, bindingID: sourceBindingID, client: client)
                } catch {
                    await staged.cleanup()
                    transferringResource = false
                    throw error
                }
                await staged.cleanup()
                transferringResource = false
            }
        }
        var summary = try await client.finish()
        summary.notLocal = notLocal
        return summary
    }

    func cancel() async {
        cancelRequested = true
        discovery?.stop()
    }

    private func send(
        _ staged: StagedPhotoResource,
        bindingID: String,
        client: SyncClient
    ) async throws {
        let resourceID = ResourceIdentity.make(
            sourceBindingID: bindingID,
            descriptor: staged.descriptor
        )
        let offer = ResourceOffer(resourceID: resourceID, descriptor: staged.descriptor)
        let progress: @Sendable (Int64, Int64) -> Void = { [onProgress] sent, total in
            onProgress(IOSSyncProgress(
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
        if case let .failed(_, _, retryable) = result, retryable {
            result = try await client.sendResource(
                offer,
                fileURL: staged.fileURL,
                progress: progress
            )
        }
        if case let .failed(_, message, _) = result {
            throw IOSSyncCoordinatorError.resourceFailed(message)
        }
    }

    private func discoverReceiver(id: String) async throws -> DiscoveredReceiver {
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
            }
        }
        throw lastError
    }
}
