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

struct IOSSyncTransferResult: Equatable, Sendable {
    let summary: SyncSummary
    /// Fully backed-up assets per receiver, only for receivers whose every
    /// selected album finished in this run.
    let confirmations: [String: Set<PhotoDeletionCandidate>]
    let failedReceiverCount: Int
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
        case .macNotFound: "The paired computer is not available on this local network."
        case .notPaired: "Pair this iPhone with a computer first."
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
    private static let receiverRetryDelays: [UInt64] = [0, 1, 2, 4]

    private let photoSource: PhotoLibrarySource
    private let ledger: SyncedResourceLedger
    private let cursorStore: AlbumSyncCursorStore
    private let profileStore: ReceiverProfileStore
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
        ledger: SyncedResourceLedger = SyncedResourceLedger(),
        cursorStore: AlbumSyncCursorStore = AlbumSyncCursorStore(),
        profileStore: ReceiverProfileStore = ReceiverProfileStore(),
        onProgress: @escaping @Sendable (IOSSyncProgress?) -> Void,
        onOperation: @escaping @Sendable (OperationLogEvent) async -> Void = { _ in }
    ) {
        self.photoSource = photoSource
        self.ledger = ledger
        self.cursorStore = cursorStore
        self.profileStore = profileStore
        self.deviceID = deviceID
        self.onProgress = onProgress
        self.onOperation = onOperation
    }

    func loadPeer(receiverID: String) throws -> PairedPeer? {
        try keychain.load(
            PairedPeer.self,
            account: ReceiverProfileStore.peerAccount(receiverID: receiverID)
        )
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

    /// Adds the receiver, or replaces the secret of one paired again.
    /// Other paired receivers are untouched.
    func confirmPairing(code: String) async throws -> ReceiverProfile {
        guard let pendingPairing else {
            throw IOSSyncCoordinatorError.pairingNotStarted
        }
        let peer = try await pendingPairing.confirm(code: code)
        try keychain.save(
            peer,
            account: ReceiverProfileStore.peerAccount(receiverID: peer.id)
        )
        let profile = profileStore.upsertPaired(
            id: peer.id,
            displayName: peer.displayName,
            at: Date()
        )
        self.pendingPairing = nil
        await emit(
            .success,
            category: "Pairing",
            message: "Paired with “\(peer.displayName)”."
        )
        return profile
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

    func pair(endpoint: NWEndpoint, code: String) async throws -> ReceiverProfile {
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

    /// Forgets one receiver: its secret, what its destination confirmed and
    /// where its album passes stopped. Other receivers keep their state.
    func forgetReceiver(id receiverID: String) throws {
        let account = ReceiverProfileStore.peerAccount(receiverID: receiverID)
        if let peer = try loadPeer(receiverID: receiverID),
           let binding = peer.sourceBindingID {
            ledger.forget(sourceBindingID: binding)
        }
        try keychain.delete(account: account)
        cursorStore.clear(receiverID: receiverID)
        profileStore.remove(receiverID: receiverID)
    }

    /// Syncs every receiver in turn, the one that waited longest first, so a
    /// background window that ends early still moves every receiver forward
    /// over successive runs. One unreachable or failing receiver does not
    /// stop the others; the run throws only when no receiver finished.
    func syncTransfer(
        plans: [ReceiverSyncPlan],
        discoveryStrategy: IOSSyncDiscoveryStrategy
    ) async throws -> IOSSyncTransferResult {
        cancelRequested = false
        var combinedSummary = SyncSummary.zero
        var confirmations: [String: Set<PhotoDeletionCandidate>] = [:]
        var failures: [any Error] = []

        let ordered = plans
            .filter { !$0.albums.isEmpty }
            .sorted {
                ($0.profile.lastCompletedAt ?? .distantPast)
                    < ($1.profile.lastCompletedAt ?? .distantPast)
            }
        for plan in ordered {
            try Task.checkCancellation()
            if cancelRequested { throw CancellationError() }
            do {
                let result = try await sync(
                    plan: plan,
                    discoveryStrategy: discoveryStrategy
                )
                combinedSummary.added += result.summary.added
                combinedSummary.existing += result.summary.existing
                combinedSummary.notLocal += result.summary.notLocal
                combinedSummary.failed += result.summary.failed
                confirmations[plan.profile.id] = result.deletionCandidates
                profileStore.markCompleted(receiverID: plan.profile.id, at: Date())
            } catch {
                if cancelRequested || Task.isCancelled || error is CancellationError {
                    throw error
                }
                failures.append(error)
                await emit(
                    .error,
                    category: "Receiver",
                    message: "“\(plan.profile.displayName)” did not finish: "
                        + error.localizedDescription
                )
            }
        }
        if confirmations.isEmpty, let first = failures.first {
            throw first
        }
        return IOSSyncTransferResult(
            summary: combinedSummary,
            confirmations: confirmations,
            failedReceiverCount: failures.count
        )
    }

    private func sync(
        plan: ReceiverSyncPlan,
        discoveryStrategy: IOSSyncDiscoveryStrategy
    ) async throws -> (
        summary: SyncSummary,
        deletionCandidates: Set<PhotoDeletionCandidate>
    ) {
        guard var peer = try loadPeer(receiverID: plan.profile.id) else {
            throw IOSSyncCoordinatorError.notPaired
        }
        await emit(
            .info,
            category: "Receiver",
            message: "Syncing \(plan.albums.count) album(s) to "
                + "“\(plan.profile.displayName)”."
        )
        var summary = SyncSummary.zero
        var deletionCandidates = PhotoDeletionCandidateAccumulator()
        for album in plan.albums {
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
            summary.added += result.summary.added
            summary.existing += result.summary.existing
            summary.notLocal += result.summary.notLocal
            summary.failed += result.summary.failed
            deletionCandidates.merge(result.deletionCandidates)
            await emit(
                .success,
                category: "Album",
                message: "Finished “\(album.title)” on "
                    + "“\(plan.profile.displayName)”: \(result.summary.added) added, "
                    + "\(result.summary.existing) already present, "
                    + "\(result.summary.notLocal) not local, "
                    + "\(result.summary.failed) failed."
            )
        }
        return (summary, deletionCandidates.eligibleCandidates)
    }

    private func sync(
        album: PhotoAlbum,
        peer: PairedPeer,
        discoveryStrategy: IOSSyncDiscoveryStrategy
    ) async throws -> (
        summary: SyncSummary,
        peer: PairedPeer,
        deletionCandidates: PhotoDeletionCandidateAccumulator
    ) {
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
                message: "“\(peer.displayName)” accepted album “\(album.title)”."
            )
            profileStore.markConnected(receiverID: peer.id, at: Date())
            if peer.sourceBindingID != sourceBindingID {
                peer = PairedPeer(
                    id: peer.id,
                    displayName: peer.displayName,
                    pskIdentity: peer.pskIdentity,
                    psk: peer.psk,
                    sourceBindingID: sourceBindingID
                )
                try keychain.save(
                    peer,
                    account: ReceiverProfileStore.peerAccount(receiverID: peer.id)
                )
                await emit(
                    .info,
                    category: "Session",
                    message: "Saved the destination source binding."
                )
            }

            var notLocal = 0
            var deletionCandidates = PhotoDeletionCandidateAccumulator()
            let resumeCursor = cursorStore.cursor(
                receiverID: peer.id,
                albumID: album.id
            )
            if resumeCursor != nil {
                await emit(
                    .info,
                    category: "Album",
                    message: "Resuming “\(album.title)” where the previous run stopped."
                )
            }
            defer {
                cursorStore.flush()
                ledger.flush()
            }
            for try await event in photoSource.resources(
                albumID: album.id,
                resumingAfter: resumeCursor
            ) {
                try Task.checkCancellation()
                if cancelRequested { throw CancellationError() }
                switch event {
                case let .skippedNotLocal(_, resourceName):
                    notLocal += 1
                    await emit(
                        .warning,
                        category: "Resource",
                        message: "Skipped “\(resourceName)”; it is not stored on this iPhone."
                    )
                case let .candidate(candidate):
                    do {
                        try await handle(
                            candidate,
                            albumName: album.title,
                            bindingID: sourceBindingID,
                            client: client
                        )
                    } catch PhotoLibrarySourceError.resourceNotLocal {
                        await candidate.finish(.notLocal)
                        continue
                    } catch {
                        await candidate.finish(.handled)
                        throw error
                    }
                    await candidate.finish(.handled)
                case let .assetFinished(
                    assetLocalIdentifier,
                    creationDate,
                    modificationDate,
                    fullyBackedUp
                ):
                    deletionCandidates.record(
                        assetLocalIdentifier: assetLocalIdentifier,
                        modificationDate: modificationDate,
                        fullyBackedUp: fullyBackedUp
                    )
                    if let creationDate {
                        cursorStore.advance(
                            receiverID: peer.id,
                            albumID: album.id,
                            to: AlbumSyncCursor(
                                assetLocalIdentifier: assetLocalIdentifier,
                                assetCreationDate: creationDate
                            )
                        )
                    }
                }
            }
            try Task.checkCancellation()
            if cancelRequested { throw CancellationError() }
            // The walk reached the end of the album, so the next run starts a
            // fresh pass and picks up assets imported with an older date.
            cursorStore.clear(receiverID: peer.id, albumID: album.id)
            var summary = try await client.finish()
            summary.notLocal = notLocal
            return (summary, peer, deletionCandidates)
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

    /// Decides how one candidate reaches the Mac.
    ///
    /// A resource the Mac confirmed earlier is offered from its remembered
    /// descriptor, so the common case — a photo that is already backed up —
    /// costs one round trip instead of a full export plus SHA-256 pass. Only
    /// an unknown resource, or one the receiver has since lost, is exported.
    private func handle(
        _ candidate: PhotoResourceCandidate,
        albumName: String,
        bindingID: String,
        client: SyncClient
    ) async throws {
        if let remembered = ledger.confirmedDescriptor(
            for: candidate.identity,
            sourceBindingID: bindingID
        ) {
            let offer = ResourceOffer(
                resourceID: ResourceIdentity.make(
                    sourceBindingID: bindingID,
                    descriptor: remembered
                ),
                descriptor: remembered
            )
            switch try await client.offerResource(offer) {
            case .skip:
                await emit(
                    .info,
                    category: "Resource",
                    message: "Skipped “\(candidate.resourceName)”; "
                        + "already present on the Mac."
                )
            case .transfer:
                // The Mac wants the bytes back, but it is already counting
                // the seconds until the first chunk and exporting an original
                // can outlast that deadline. Drop the stale entry and let the
                // next run rebuild this resource the ordinary way.
                ledger.forget(candidate.identity, sourceBindingID: bindingID)
                await emit(
                    .warning,
                    category: "Resource",
                    message: "The Mac no longer holds “\(candidate.resourceName)”; "
                        + "it will be sent again on the next run."
                )
                throw IOSSyncCoordinatorError.resourceFailed(
                    code: .destinationUnavailable,
                    message: "“\(candidate.resourceName)” must be sent to the Mac again.",
                    retryable: true
                )
            }
            return
        }

        let staged = try await candidate.stage()
        transferringResource = true
        do {
            try await send(
                staged,
                identity: candidate.identity,
                albumName: albumName,
                bindingID: bindingID,
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

    private func send(
        _ staged: StagedPhotoResource,
        identity: PhotoResourceIdentity,
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
        let progress = progressReporter(
            albumName: albumName,
            descriptor: staged.descriptor
        )
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
        try await record(
            result,
            identity: identity,
            descriptor: staged.descriptor,
            bindingID: bindingID,
            resourceName: resourceName
        )
    }

    /// Turns the receiver's verdict into a log line and a ledger entry.
    private func record(
        _ result: ClientResourceResult,
        identity: PhotoResourceIdentity,
        descriptor: ResourceDescriptor,
        bindingID: String,
        resourceName: String
    ) async throws {
        switch result {
        case .skipped:
            ledger.record(descriptor, for: identity, sourceBindingID: bindingID)
            await emit(
                .info,
                category: "Resource",
                message: "Skipped “\(resourceName)”; already present on the Mac."
            )
        case let .committed(relativePath):
            ledger.record(descriptor, for: identity, sourceBindingID: bindingID)
            await emit(
                .success,
                category: "Resource",
                message: "Sent “\(resourceName)” to “\(relativePath)”."
            )
        case let .failed(code, message, retryable):
            ledger.forget(identity, sourceBindingID: bindingID)
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

    private func progressReporter(
        albumName: String,
        descriptor: ResourceDescriptor
    ) -> @Sendable (Int64, Int64) -> Void {
        let onProgress = onProgress
        let resourceName = descriptor.originalFilename
        return { sent, total in
            onProgress(IOSSyncProgress(
                albumName: albumName,
                resourceName: resourceName,
                sentBytes: sent,
                totalBytes: total
            ))
        }
    }

    private func discoverReceiver(id: String) async throws -> DiscoveredReceiver {
        await emit(
            .info,
            category: "Discovery",
            message: "Looking for the exact paired receiver on Wi-Fi."
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
                    message: "The paired receiver was not found in this discovery attempt."
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
