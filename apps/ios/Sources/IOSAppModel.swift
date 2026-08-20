@preconcurrency import Photos
import Foundation
import Observation
import OSLog
import SyncCore
import UIKit

@MainActor
@Observable
final class IOSAppModel {
    enum State: Equatable {
        case setup
        case ready
        case findingMac
        case pairing
        case syncing
        case error(String)
    }

    enum AutomaticSyncMode {
        case debug
        case production
    }

    var state: State = .setup
    var authorizationStatus: PHAuthorizationStatus
    var albums: [PhotoAlbum] = []
    var selectedAlbums: [PhotoAlbum] = []
    var pairedPeer: PairedPeer?
    var receivers: [DiscoveredReceiver] = []
    var pairingCode = ""
    var pairingError: String?
    var pairingExpiresAt: Date?
    var pairingIsPending = false
    var progress: IOSSyncProgress?
    var lastSummary: SyncSummary?
    var automaticDebugSync: IOSAutomaticSyncSnapshot
    var automaticProductionSync: IOSAutomaticSyncSnapshot
    var automaticDebugRunIsActive = false
    var automaticProductionRunIsActive = false
    var deleteAfterSync: IOSDeleteAfterSyncSnapshot
    var operationLog: [OperationLogEntry] = []

    @ObservationIgnored private let photoSource: PhotoLibrarySource
    @ObservationIgnored private let albumStore: AlbumSelectionStore
    @ObservationIgnored private let automaticDebugStore: IOSAutomaticSyncStore
    @ObservationIgnored private let automaticProductionStore: IOSAutomaticSyncStore
    @ObservationIgnored private let deleteAfterSyncStore: IOSDeleteAfterSyncStore
    @ObservationIgnored private let debugPolicy: AutomaticSyncPolicy
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shuk.iphonesync.ios",
        category: "operations"
    )
    @ObservationIgnored private var operationLogBuffer = OperationLogBuffer()
    @ObservationIgnored private var coordinator: IOSSyncCoordinator!
    @ObservationIgnored private var runtime: IOSSyncRuntime!
    @ObservationIgnored private var postSyncDeletionController:
        IOSPostSyncDeletionController!
    @ObservationIgnored private var automaticDebugScheduler: AutomaticSyncScheduler!
    @ObservationIgnored private var automaticProductionScheduler: AutomaticSyncScheduler!
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var debugForegroundAutomaticTask: Task<Void, Never>?
    @ObservationIgnored private var activeForegroundRunID: UUID?
    @ObservationIgnored private let activityAssertion = SyncActivityAssertion()
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var automaticDebugSchedulerRegistered = false
    @ObservationIgnored private var automaticProductionSchedulerRegistered = false

    var automaticSchedulerRegistered: Bool {
#if DEBUG
        automaticDebugSchedulerRegistered && automaticProductionSchedulerRegistered
#else
        automaticProductionSchedulerRegistered
#endif
    }

    var automaticRunIsActive: Bool {
#if DEBUG
        automaticDebugRunIsActive || automaticProductionRunIsActive
#else
        automaticProductionRunIsActive
#endif
    }

    init() {
        let photoSource = PhotoLibrarySource()
        let albumStore = AlbumSelectionStore()
        let automaticDebugStore = IOSAutomaticSyncStore(prefix: "automaticSyncDebug")
        let automaticProductionStore = IOSAutomaticSyncStore(prefix: "automaticSyncProduction")
        let deleteAfterSyncStore = IOSDeleteAfterSyncStore()
        let debugPolicy = AutomaticSyncPolicy(cadence: .tenMinutes)
        let productionPolicy = AutomaticSyncPolicy(
            cadence: .thirtyMinutesWhileCharging
        )
        self.photoSource = photoSource
        self.albumStore = albumStore
        self.automaticDebugStore = automaticDebugStore
        self.automaticProductionStore = automaticProductionStore
        self.deleteAfterSyncStore = deleteAfterSyncStore
        self.debugPolicy = debugPolicy
        automaticDebugSync = automaticDebugStore.snapshot
        automaticProductionSync = automaticProductionStore.snapshot
        deleteAfterSync = deleteAfterSyncStore.snapshot
        authorizationStatus = photoSource.authorizationStatus()

        let defaults = UserDefaults.standard
        let deviceID: String
        if let existing = defaults.string(forKey: "deviceID") {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "deviceID")
        }
        coordinator = IOSSyncCoordinator(
            photoSource: photoSource,
            deviceID: deviceID,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.progress = progress }
            },
            onOperation: { [weak self] event in
                await self?.recordOperation(event)
            }
        )
        postSyncDeletionController = IOSPostSyncDeletionController(
            store: deleteAfterSyncStore,
            deletionService: PhotoAssetDeletionService { candidates in
                try await photoSource.deleteAssets(candidates: candidates)
            },
            onSnapshotChange: { [weak self] snapshot in
                self?.deleteAfterSync = snapshot
            },
            onOperation: { [weak self] event in
                self?.recordOperation(event)
            }
        )
        runtime = IOSSyncRuntime(
            photoSource: photoSource,
            albumStore: albumStore,
            coordinator: coordinator,
            postSyncDeletionController: postSyncDeletionController
        )
        automaticDebugScheduler = AutomaticSyncScheduler(
            runtime: runtime,
            store: automaticDebugStore,
            policy: debugPolicy,
            taskIdentifier: AutomaticSyncScheduler.debugTaskIdentifier,
            isPaired: { [weak self] in self?.pairedPeer != nil },
            onSnapshotChange: { [weak self] snapshot in
                self?.automaticDebugSync = snapshot
            },
            onRunStateChange: { [weak self] isRunning in
                self?.automaticDebugRunIsActive = isRunning
            },
            onOperation: { [weak self] event in
                self?.recordOperation(event)
            }
        )
        automaticProductionScheduler = AutomaticSyncScheduler(
            runtime: runtime,
            store: automaticProductionStore,
            policy: productionPolicy,
            taskIdentifier: AutomaticSyncScheduler.taskIdentifier,
            isPaired: { [weak self] in self?.pairedPeer != nil },
            onSnapshotChange: { [weak self] snapshot in
                self?.automaticProductionSync = snapshot
            },
            onRunStateChange: { [weak self] isRunning in
                self?.automaticProductionRunIsActive = isRunning
            },
            onOperation: { [weak self] event in
                self?.recordOperation(event)
            }
        )
    }

    @discardableResult
    func registerAutomaticSyncScheduler() -> Bool {
#if DEBUG
        automaticDebugSchedulerRegistered = automaticDebugScheduler.register()
#endif
        automaticProductionSchedulerRegistered = automaticProductionScheduler.register()
        return automaticSchedulerRegistered
    }

    var hasFullPhotoAccess: Bool {
        authorizationStatus == .authorized
    }

    var canSync: Bool {
        hasFullPhotoAccess
            && !selectedAlbums.isEmpty
            && pairedPeer != nil
            && state != .syncing
            && !automaticRunIsActive
            && !deleteAfterSync.isDeleting
    }

    var canEnableAutomaticSync: Bool {
        hasFullPhotoAccess && !selectedAlbums.isEmpty
    }

    var isAnySyncRunning: Bool {
        state == .syncing
            || automaticRunIsActive
            || deleteAfterSync.isDeleting
    }

    var backgroundRefreshText: String {
        guard automaticSchedulerRegistered else { return "Unavailable" }
        return switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "Available"
        case .denied: "Disabled in Settings"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    var selectedAlbumsText: String {
        switch selectedAlbums.count {
        case 0: "Not selected"
        case 1: selectedAlbums[0].title
        default: "\(selectedAlbums.count) selected"
        }
    }

    func bootstrap() async {
        recordOperation(
            .info,
            category: "App",
            message: "Loading saved albums, pairing, and automatic sync state."
        )
        do {
            pairedPeer = try await coordinator.loadPairedPeer()
            if hasFullPhotoAccess {
                try loadAlbums()
            }
            state = hasFullPhotoAccess && !selectedAlbums.isEmpty && pairedPeer != nil
                ? .ready
                : .setup
            automaticDebugSync = automaticDebugStore.snapshot
            automaticProductionSync = automaticProductionStore.snapshot
            deleteAfterSync = postSyncDeletionController.snapshot
            await ensureAutomaticSchedulersScheduled()
            recordOperation(
                .success,
                category: "App",
                message: "Startup completed; \(selectedAlbums.count) album(s) selected"
                    + (pairedPeer == nil ? " and no Mac is paired." : " and the Mac is paired.")
            )
        } catch {
            recordFailure(error.localizedDescription, category: "Startup")
        }
    }

    func requestPhotosAccess() {
        guard !isAnySyncRunning else { return }
        recordOperation(
            .info,
            category: "Photos",
            message: "Requested Full Photos Access."
        )
        Task {
            authorizationStatus = await photoSource.requestFullAccess()
            guard authorizationStatus == .authorized else {
                recordFailure(
                    PhotoLibrarySourceError.fullAccessRequired.localizedDescription,
                    category: "Photos"
                )
                return
            }
            recordOperation(
                .success,
                category: "Photos",
                message: "Full Photos Access granted."
            )
            do {
                try loadAlbums()
                state = selectedAlbums.isEmpty || pairedPeer == nil ? .setup : .ready
                refreshAutomaticSchedulers()
            } catch {
                recordFailure(error.localizedDescription, category: "Photos")
            }
        }
    }

    func selectAlbums(_ albums: [PhotoAlbum]) {
        guard !isAnySyncRunning else { return }
        selectedAlbums = albums
        albumStore.save(albums)
        let albumNames = albums.map(\.title).joined(separator: ", ")
        recordOperation(
            .info,
            category: "Albums",
            message: albums.isEmpty
                ? "Cleared the album selection."
                : "Selected \(albums.count) album(s): \(albumNames)."
        )
        state = albums.isEmpty || pairedPeer == nil ? .setup : .ready
        refreshAutomaticSchedulers()
    }

    func findMac() {
        guard !isAnySyncRunning else { return }
        discoveryTask?.cancel()
        state = .findingMac
        receivers = []
        recordOperation(
            .info,
            category: "Discovery",
            message: pairedPeer == nil
                ? "Looking for Macs with an open pairing window."
                : "Looking for the paired Mac."
        )
        discoveryTask = Task {
            let stream = await coordinator.receiverStream(pairing: pairedPeer == nil)
            var previousReceiverIDs: Set<String> = []
            for await values in stream {
                guard !Task.isCancelled else { break }
                receivers = values
                let receiverIDs = Set(values.map(\.id))
                guard receiverIDs != previousReceiverIDs else { continue }
                previousReceiverIDs = receiverIDs
                recordOperation(
                    values.isEmpty ? .info : .success,
                    category: "Discovery",
                    message: values.isEmpty
                        ? "No available Mac is currently visible."
                        : "Found \(values.count) Mac receiver(s): "
                            + values.map(\.displayName).joined(separator: ", ")
                            + "."
                )
            }
        }
    }

    func beginPairing(with receiver: DiscoveredReceiver) {
        guard !isAnySyncRunning else { return }
        discoveryTask?.cancel()
        Task {
            do {
                try await coordinator.beginPairing(receiver: receiver)
                pairingCode = ""
                pairingError = nil
                pairingExpiresAt = Date().addingTimeInterval(120)
                pairingIsPending = true
                state = .pairing
            } catch {
                recordFailure(error.localizedDescription, category: "Pairing")
            }
        }
    }

    func confirmPairing() {
        guard pairingCode.count == 6,
              pairingCode.allSatisfy({ $0.isNumber }) else { return }
        Task {
            do {
                pairedPeer = try await coordinator.confirmPairing(code: pairingCode)
                pairingIsPending = false
                pairingError = nil
                pairingExpiresAt = nil
                state = selectedAlbums.isEmpty ? .setup : .ready
                refreshAutomaticSchedulers()
            } catch let error as PairingClientError {
                pairingError = error.localizedDescription
                if case let .codeMismatch(remainingAttempts) = error,
                   remainingAttempts > 0 {
                    recordOperation(
                        .warning,
                        category: "Pairing",
                        message: error.localizedDescription
                    )
                    state = .pairing
                } else {
                    pairingIsPending = false
                    pairingExpiresAt = nil
                    recordFailure(error.localizedDescription, category: "Pairing")
                }
            } catch {
                pairingIsPending = false
                pairingExpiresAt = nil
                recordFailure(error.localizedDescription, category: "Pairing")
            }
        }
    }

    func cancelPairing() {
        pairingIsPending = false
        pairingCode = ""
        pairingError = nil
        pairingExpiresAt = nil
        state = selectedAlbums.isEmpty || pairedPeer == nil ? .setup : .ready
        Task { await coordinator.cancelPairing() }
    }

    func syncNow() {
        guard canSync else { return }
        let runID = UUID()
        activeForegroundRunID = runID
        activityAssertion.beginRun()
        state = .syncing
        recordOperation(
            .info,
            category: "Manual Sync",
            message: "Started Sync Now for \(selectedAlbums.count) album(s)."
        )
        Task {
            let outcome = await runtime.run(SyncRunRequest(
                id: runID,
                trigger: .manualForeground,
                maximumElapsed: nil
            ))
            if activeForegroundRunID == runID {
                activeForegroundRunID = nil
            }
            activityAssertion.endRun()
            recordSyncOutcome(outcome, category: "Manual Sync")
            switch outcome {
            case .completed(let summary), .noChanges(let summary):
                lastSummary = summary
                do {
                    pairedPeer = try await coordinator.loadPairedPeer()
                    if hasFullPhotoAccess {
                        try loadAlbums()
                    }
                } catch {
                    recordFailure(error.localizedDescription, category: "Sync Completion")
                    return
                }
                state = .ready
            case .cancelled:
                state = .ready
            case .deferred, .budgetExhausted, .failed:
                state = .error(outcome.message ?? "Sync failed.")
            }
        }
    }

    func handleIncomingURL(_ url: URL) {
        guard let action = parseIncomingURLAction(from: url),
              action == .syncNow else {
            return
        }
        recordOperation(
            .info,
            category: "Widget",
            message: "Sync Now requested from widget link."
        )
        if canSync {
            syncNow()
        } else {
            recordOperation(
                .warning,
                category: "Widget",
                message: "Widget trigger ignored because sync prerequisites are not met."
            )
        }
    }

    private func parseIncomingURLAction(from url: URL) -> IncomingURLAction? {
        guard url.scheme == "iphonesync" else {
            return nil
        }
        let host = url.host?.lowercased()
        let path = url.path
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "sync-now" || path == "sync-now" {
            return .syncNow
        }
        return nil
    }

    private enum IncomingURLAction: Equatable {
        case syncNow
    }

    func setDeleteAfterSyncEnabled(_ enabled: Bool) {
        guard !isAnySyncRunning else { return }
        postSyncDeletionController.setEnabled(enabled)
        deleteAfterSync = postSyncDeletionController.snapshot
    }

    func deletePendingSyncedPhotos() {
        guard deleteAfterSync.isEnabled,
              deleteAfterSync.pendingAssetCount > 0,
              !isAnySyncRunning else {
            return
        }
        Task {
            await postSyncDeletionController.deletePendingAssets()
            deleteAfterSync = postSyncDeletionController.snapshot
            if hasFullPhotoAccess {
                do {
                    try loadAlbums()
                } catch {
                    recordFailure(error.localizedDescription, category: "Photos")
                }
            }
        }
    }

    func setAutomaticSyncEnabled(_ enabled: Bool, mode: AutomaticSyncMode) {
        switch mode {
        case .debug:
            setAutomaticDebugSyncEnabled(enabled)
        case .production:
            setAutomaticProductionSyncEnabled(enabled)
        }
    }

    private func setAutomaticDebugSyncEnabled(_ enabled: Bool) {
        automaticDebugScheduler.setEnabled(enabled)
        automaticDebugSync = automaticDebugStore.snapshot
        if enabled {
            startDebugForegroundAutomaticTestingIfNeeded()
        } else {
            debugForegroundAutomaticTask?.cancel()
            debugForegroundAutomaticTask = nil
        }
    }

    private func setAutomaticProductionSyncEnabled(_ enabled: Bool) {
        automaticProductionScheduler.setEnabled(enabled)
        automaticProductionSync = automaticProductionStore.snapshot
        refreshAutomaticSchedulers()
    }

    func enteredForeground() {
        guard !isSceneActive else { return }
        isSceneActive = true
        recordOperation(
            .info,
            category: "App",
            message: "Entered the foreground."
        )
        authorizationStatus = photoSource.authorizationStatus()
        if hasFullPhotoAccess, !isAnySyncRunning {
            do {
                try loadAlbums()
                if pairedPeer != nil, !selectedAlbums.isEmpty {
                    state = .ready
                }
            } catch {
                recordFailure(error.localizedDescription, category: "Photos")
            }
        }
        automaticDebugSync = automaticDebugStore.snapshot
        automaticProductionSync = automaticProductionStore.snapshot
        deleteAfterSync = postSyncDeletionController.snapshot
        Task {
            await ensureAutomaticSchedulersScheduled()
#if DEBUG
            startDebugForegroundAutomaticTestingIfNeeded()
#endif
        }
    }

    func enteredBackground() {
        guard isSceneActive else { return }
        isSceneActive = false
        recordOperation(
            .info,
            category: "App",
            message: "Entered the background."
        )
        debugForegroundAutomaticTask?.cancel()
        debugForegroundAutomaticTask = nil
        if let activeForegroundRunID {
            // Hold execution open long enough for the cancellation to reach
            // the TLS connection. Suspending with the socket still open leaves
            // the receiver blocked on a sender that will never send again.
            activityAssertion.beginBackgroundGracePeriod()
            Task {
                await runtime.cancel(
                    runID: activeForegroundRunID,
                    reason: .sceneBackgrounded
                )
            }
        }
        if pairingIsPending {
            cancelPairing()
        }
        Task { await ensureAutomaticSchedulersScheduled() }
    }

    private func startDebugForegroundAutomaticTestingIfNeeded() {
        guard isSceneActive,
              automaticDebugSync.isEnabled,
              debugForegroundAutomaticTask == nil else {
            return
        }
        debugForegroundAutomaticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let delay = debugPolicy.foregroundTestDelay(
                    after: Date(),
                    nextEligibleAt: self.automaticDebugSync.nextEligibleAt
                ) else {
                    return
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isSceneActive else { return }
                let outcome = await self.automaticDebugScheduler.runForegroundAutomatic()
                if let summary = outcome.summary {
                    self.lastSummary = summary
                    if self.hasFullPhotoAccess {
                        do {
                            try self.loadAlbums()
                        } catch {
                            self.recordFailure(
                                error.localizedDescription,
                                category: "Photos"
                            )
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        guard let activeForegroundRunID else { return }
        recordOperation(
            .warning,
            category: "Manual Sync",
            message: "Cancel requested by the user."
        )
        Task { await runtime.cancel(runID: activeForegroundRunID, reason: .user) }
    }

    func forgetMac() {
        guard !isAnySyncRunning else { return }
        Task {
            do {
                try await coordinator.forgetPeer()
                pairedPeer = nil
                automaticDebugScheduler.setEnabled(false)
                automaticProductionScheduler.setEnabled(false)
                automaticDebugSync = automaticDebugStore.snapshot
                automaticProductionSync = automaticProductionStore.snapshot
                postSyncDeletionController.setEnabled(false)
                deleteAfterSync = postSyncDeletionController.snapshot
                debugForegroundAutomaticTask?.cancel()
                debugForegroundAutomaticTask = nil
                state = .setup
                recordOperation(
                    .success,
                    category: "Pairing",
                    message: "Forgot the paired Mac and disabled Automatic Sync "
                        + "and Delete After Sync."
                )
            } catch {
                recordFailure(error.localizedDescription, category: "Pairing")
            }
        }
    }

    func clearOperationLog() {
        operationLogBuffer.clear()
        operationLog = operationLogBuffer.entries
        logger.notice("Operation Log cleared")
    }

    func recordOperation(_ event: OperationLogEvent) {
        operationLogBuffer.record(event)
        operationLog = operationLogBuffer.entries
        switch event.level {
        case .info:
            logger.info(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        case .success:
            logger.notice(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        case .warning:
            logger.warning(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        case .error:
            logger.error(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        }
    }

    private func refreshAutomaticSchedulers() {
        Task { await ensureAutomaticSchedulersScheduled() }
    }

    private func ensureAutomaticSchedulersScheduled() async {
#if DEBUG
        await automaticDebugScheduler.ensureScheduled()
#endif
        await automaticProductionScheduler.ensureScheduled()
    }

    private func loadAlbums() throws {
        albums = try photoSource.albums()
        let savedIDs = Set(albumStore.load().map(\.id))
        selectedAlbums = albums.filter { savedIDs.contains($0.id) }
        if selectedAlbums.isEmpty {
            albumStore.clear()
        } else {
            albumStore.save(selectedAlbums)
        }
    }

    private func recordOperation(
        _ level: OperationLogLevel,
        category: String,
        message: String
    ) {
        recordOperation(OperationLogEvent(
            level: level,
            category: category,
            message: message
        ))
    }

    private func recordFailure(_ message: String, category: String) {
        recordOperation(.error, category: category, message: message)
        state = .error(message)
    }

    private func recordSyncOutcome(
        _ outcome: SyncRunOutcome,
        category: String
    ) {
        switch outcome {
        case let .completed(summary):
            recordOperation(
                .success,
                category: category,
                message: "Completed: \(summary.added) added, "
                    + "\(summary.existing) already present, "
                    + "\(summary.notLocal) not local, \(summary.failed) failed."
            )
        case let .noChanges(summary):
            recordOperation(
                .success,
                category: category,
                message: "No changes: \(summary.existing) already present, "
                    + "\(summary.notLocal) not local."
            )
        case .cancelled:
            recordOperation(
                .warning,
                category: category,
                message: "Sync cancelled."
            )
        case .deferred, .budgetExhausted:
            recordOperation(
                .warning,
                category: category,
                message: outcome.message ?? "Sync deferred."
            )
        case .failed:
            recordOperation(
                .error,
                category: category,
                message: outcome.message ?? "Sync failed."
            )
        }
    }
}
