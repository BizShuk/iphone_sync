@preconcurrency import Photos
import Foundation
import Network
import SyncCore

enum SyncTrigger: Sendable {
    case manualForeground
    case automaticForeground
    case automaticBackground
}

enum SyncDeferredReason: String, Equatable, Sendable {
    case alreadyRunning
    case alreadyCompletedToday
    case macUnavailable
    case networkUnavailable
    case photosAccessRequired
    case albumsRequired
    case pairingRequired
}

enum SyncCancellationReason: Sendable {
    case user
    case sceneBackgrounded
    case expiration
    case budget
}

enum SyncFailureKind: Equatable, Sendable {
    case needsUserAction
    case internalFailure
}

struct SyncRunFailure: Equatable, Sendable {
    let kind: SyncFailureKind
    let message: String
    let shouldRetrySoon: Bool
}

struct SyncRunRequest: Sendable {
    let id: UUID
    let trigger: SyncTrigger
    let maximumElapsed: Duration?
}

enum SyncRunOutcome: Equatable, Sendable {
    case completed(SyncSummary)
    case noChanges(SyncSummary)
    case deferred(SyncDeferredReason)
    case budgetExhausted
    case cancelled
    case failed(SyncRunFailure)

    var automaticCode: AutomaticSyncOutcomeCode {
        switch self {
        case .completed: .completed
        case .noChanges: .noChanges
        case .deferred(.alreadyRunning): .alreadyRunning
        case .deferred(.alreadyCompletedToday): .alreadyCompletedToday
        case .deferred(.macUnavailable): .macUnavailable
        case .deferred(.networkUnavailable): .networkUnavailable
        case .deferred(.photosAccessRequired): .photosAccessRequired
        case .deferred(.albumsRequired): .albumsRequired
        case .deferred(.pairingRequired): .pairingRequired
        case .budgetExhausted: .budgetExhausted
        case .cancelled: .cancelled
        case .failed(let failure):
            failure.kind == .needsUserAction ? .needsUserAction : .failed
        }
    }

    var isSuccessfulSync: Bool {
        switch self {
        case .completed, .noChanges:
            true
        default:
            false
        }
    }

    var shouldRetrySoon: Bool {
        switch self {
        case .deferred(.alreadyRunning),
             .deferred(.macUnavailable),
             .deferred(.networkUnavailable),
             .budgetExhausted:
            true
        case .failed(let failure):
            failure.shouldRetrySoon
        default:
            false
        }
    }

    var backgroundTaskSucceeded: Bool {
        switch self {
        case .failed(let failure):
            failure.kind == .needsUserAction
        case .budgetExhausted, .cancelled:
            false
        default:
            true
        }
    }

    var summary: SyncSummary? {
        switch self {
        case .completed(let summary), .noChanges(let summary):
            summary
        default:
            nil
        }
    }

    var message: String? {
        switch self {
        case .completed:
            "Automatic sync completed."
        case .noChanges:
            "No new local resources were found."
        case .deferred(.alreadyRunning):
            "Another sync is already running."
        case .deferred(.alreadyCompletedToday):
            "Automatic sync already completed today."
        case .deferred(.macUnavailable):
            "The paired Mac is not visible on this local network."
        case .deferred(.networkUnavailable):
            "The local network connection is unavailable."
        case .deferred(.photosAccessRequired):
            "Full Photos access is required."
        case .deferred(.albumsRequired):
            "Choose at least one Photos album."
        case .deferred(.pairingRequired):
            "Pair this iPhone with a Mac first."
        case .budgetExhausted:
            "The scheduled batch reached its time budget and will resume later."
        case .cancelled:
            "The sync was cancelled."
        case .failed(let failure):
            failure.message
        }
    }
}

struct IOSSyncRuntimeEnvironment: Sendable {
    let hasFullPhotoAccess: @Sendable () -> Bool
    let loadSelectedAlbums: @Sendable () throws -> [PhotoAlbum]
    let hasPairedPeer: @Sendable () async throws -> Bool
    let sync: @Sendable (
        _ albums: [PhotoAlbum],
        _ discoveryStrategy: IOSSyncDiscoveryStrategy,
        _ trigger: SyncTrigger
    ) async throws -> SyncSummary
    let cancel: @Sendable () async -> Void
}

actor IOSSyncRuntime {
    private let environment: IOSSyncRuntimeEnvironment

    private var activeRunID: UUID?
    private var activeOperation: Task<SyncSummary, any Error>?
    private var cancellationReason: SyncCancellationReason?

    init(
        photoSource: PhotoLibrarySource,
        albumStore: AlbumSelectionStore,
        coordinator: IOSSyncCoordinator,
        postSyncDeletionController: IOSPostSyncDeletionController
    ) {
        environment = IOSSyncRuntimeEnvironment(
            hasFullPhotoAccess: {
                photoSource.authorizationStatus() == .authorized
            },
            loadSelectedAlbums: {
                let selectedIDs = Set(albumStore.load().map(\.id))
                guard !selectedIDs.isEmpty else { return [] }
                return try photoSource.albums().filter { selectedIDs.contains($0.id) }
            },
            hasPairedPeer: {
                try await coordinator.loadPairedPeer() != nil
            },
            sync: { albums, discoveryStrategy, trigger in
                let result = try await coordinator.syncTransfer(
                    albums: albums,
                    discoveryStrategy: discoveryStrategy
                )
                await postSyncDeletionController.handleSuccessfulSync(
                    candidates: result.deletionCandidates,
                    trigger: trigger
                )
                return result.summary
            },
            cancel: {
                await coordinator.cancel()
            }
        )
    }

    init(environment: IOSSyncRuntimeEnvironment) {
        self.environment = environment
    }

    func run(_ request: SyncRunRequest) async -> SyncRunOutcome {
        guard activeRunID == nil else {
            return .deferred(.alreadyRunning)
        }
        activeRunID = request.id
        cancellationReason = nil
        defer {
            if activeRunID == request.id {
                activeRunID = nil
                activeOperation = nil
                cancellationReason = nil
            }
        }
        if Task.isCancelled {
            return .cancelled
        }

        guard environment.hasFullPhotoAccess() else {
            return .deferred(.photosAccessRequired)
        }

        let albums: [PhotoAlbum]
        do {
            albums = try environment.loadSelectedAlbums()
        } catch {
            return .deferred(.photosAccessRequired)
        }
        guard !albums.isEmpty else {
            return .deferred(.albumsRequired)
        }
        do {
            guard try await environment.hasPairedPeer() else {
                return .deferred(.pairingRequired)
            }
        } catch {
            if Task.isCancelled || cancellationReason != nil {
                return cancellationOutcome()
            }
            return .failed(SyncRunFailure(
                kind: .needsUserAction,
                message: error.localizedDescription,
                shouldRetrySoon: false
            ))
        }

        if Task.isCancelled || cancellationReason != nil {
            return cancellationOutcome()
        }
        let discoveryStrategy: IOSSyncDiscoveryStrategy =
            request.trigger == .manualForeground ? .foregroundRetries : .singleAttempt
        let environment = environment
        let operation = Task {
            try await environment.sync(
                albums,
                discoveryStrategy,
                request.trigger
            )
        }
        activeOperation = operation

        do {
            let summary = try await withTaskCancellationHandler {
                try await waitForOperation(
                    operation,
                    runID: request.id,
                    maximumElapsed: request.maximumElapsed
                )
            } onCancel: {
                Task {
                    await self.cancel(
                        runID: request.id,
                        reason: request.trigger == .automaticForeground
                            ? .sceneBackgrounded
                            : .user
                    )
                }
            }
            if summary.added == 0, summary.failed == 0 {
                return .noChanges(summary)
            }
            return .completed(summary)
        } catch is CancellationError {
            return cancellationOutcome()
        } catch let error as IOSSyncCoordinatorError {
            if Task.isCancelled || cancellationReason != nil {
                return cancellationOutcome()
            }
            switch error {
            case .macNotFound:
                return .deferred(.macUnavailable)
            case .notPaired:
                return .deferred(.pairingRequired)
            case .pairingNotStarted:
                return .failed(SyncRunFailure(
                    kind: .needsUserAction,
                    message: error.localizedDescription,
                    shouldRetrySoon: false
                ))
            case let .resourceFailed(code, message, retryable):
                return .failed(resourceFailure(
                    code: code,
                    message: message,
                    retryable: retryable
                ))
            }
        } catch let error as PhotoLibrarySourceError {
            if Task.isCancelled || cancellationReason != nil {
                return cancellationOutcome()
            }
            switch error {
            case .fullAccessRequired:
                return .deferred(.photosAccessRequired)
            case .albumNotFound:
                return .deferred(.albumsRequired)
            case .notEnoughSpace:
                return .failed(SyncRunFailure(
                    kind: .needsUserAction,
                    message: error.localizedDescription,
                    shouldRetrySoon: false
                ))
            }
        } catch let error as SyncClientError {
            if Task.isCancelled || cancellationReason != nil {
                return cancellationOutcome()
            }
            let kind: SyncFailureKind
            switch error {
            case .sessionRejected, .protocolViolation:
                kind = .needsUserAction
            case .invalidLocalFile, .noOpenSession:
                kind = .internalFailure
            }
            return .failed(SyncRunFailure(
                kind: kind,
                message: String(describing: error),
                shouldRetrySoon: kind == .internalFailure
            ))
        } catch let error as NWError {
            if Task.isCancelled || cancellationReason != nil {
                return cancellationOutcome()
            }
            if case .tls = error {
                return .failed(SyncRunFailure(
                    kind: .needsUserAction,
                    message: "Secure authentication failed. Open the app and pair this Mac again.",
                    shouldRetrySoon: false
                ))
            }
            return .deferred(.networkUnavailable)
        } catch let error as FramedConnectionError {
            if Task.isCancelled || cancellationReason != nil {
                return cancellationOutcome()
            }
            if error == .cancelled {
                return cancellationOutcome(defaultingTo: .deferred(.networkUnavailable))
            }
            return .deferred(.networkUnavailable)
        } catch {
            if Task.isCancelled || cancellationReason != nil {
                return cancellationOutcome()
            }
            return .failed(SyncRunFailure(
                kind: .internalFailure,
                message: error.localizedDescription,
                shouldRetrySoon: true
            ))
        }
    }

    func cancel(
        runID: UUID,
        reason: SyncCancellationReason
    ) async {
        guard activeRunID == runID else { return }
        if cancellationReason == nil || reason == .expiration {
            cancellationReason = reason
        }
        activeOperation?.cancel()
        await environment.cancel()
    }

    private func resourceFailure(
        code: TransferFailureCode,
        message: String,
        retryable: Bool
    ) -> SyncRunFailure {
        let kind: SyncFailureKind
        let shouldRetrySoon: Bool
        switch code {
        case .authentication, .diskFull, .protocolMismatch:
            kind = .needsUserAction
            shouldRetrySoon = false
        case .destinationUnavailable:
            kind = retryable ? .internalFailure : .needsUserAction
            shouldRetrySoon = retryable
        case .integrity, .invalidFrame:
            kind = .internalFailure
            shouldRetrySoon = false
        case .unknown:
            kind = .internalFailure
            shouldRetrySoon = retryable
        }
        return SyncRunFailure(
            kind: kind,
            message: message,
            shouldRetrySoon: shouldRetrySoon
        )
    }

    private func waitForOperation(
        _ operation: Task<SyncSummary, any Error>,
        runID: UUID,
        maximumElapsed: Duration?
    ) async throws -> SyncSummary {
        guard let maximumElapsed else {
            return try await operation.value
        }
        return try await withThrowingTaskGroup(of: SyncSummary.self) { group in
            group.addTask {
                try await operation.value
            }
            group.addTask {
                try await Task.sleep(for: maximumElapsed)
                await self.cancel(runID: runID, reason: .budget)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let summary = try await group.next() else {
                throw CancellationError()
            }
            return summary
        }
    }

    private func cancellationOutcome(
        defaultingTo fallback: SyncRunOutcome = .cancelled
    ) -> SyncRunOutcome {
        switch cancellationReason {
        case .budget, .expiration:
            .budgetExhausted
        case .user, .sceneBackgrounded:
            .cancelled
        case nil:
            fallback
        }
    }
}
