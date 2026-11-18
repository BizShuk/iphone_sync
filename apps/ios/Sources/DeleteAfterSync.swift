import Foundation
import SyncCore

struct IOSDeleteAfterSyncSnapshot: Equatable, Sendable {
    var isEnabled: Bool
    var pendingAssetCount: Int
    var isDeleting: Bool
}

struct PhotoDeletionCandidate: Codable, Hashable, Sendable {
    let assetLocalIdentifier: String
    let modificationDate: Date?
}

struct IOSDeleteAfterSyncStore: @unchecked Sendable {
    private enum Key {
        static let enabled = "enabled"
        static let pendingCandidates = "pendingCandidates"
    }

    private let defaults: UserDefaults
    private let prefix: String

    init(
        prefix: String = "deleteAfterSync",
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.prefix = prefix
    }

    var snapshot: IOSDeleteAfterSyncSnapshot {
        IOSDeleteAfterSyncSnapshot(
            isEnabled: isEnabled,
            pendingAssetCount: pendingCandidates.count,
            isDeleting: false
        )
    }

    var isEnabled: Bool {
        defaults.bool(forKey: key(Key.enabled))
    }

    var pendingCandidates: Set<PhotoDeletionCandidate> {
        guard let data = defaults.data(forKey: key(Key.pendingCandidates)),
              let candidates = try? JSONDecoder().decode(
                  [PhotoDeletionCandidate].self,
                  from: data
              ) else {
            return []
        }
        return Set(candidates)
    }

    var pendingAssetIDs: Set<String> {
        Set(pendingCandidates.map(\.assetLocalIdentifier))
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key(Key.enabled))
        if !enabled {
            clearPending()
        }
    }

    /// Replaces the pending set with what the policy currently allows, so a
    /// receiver added or an album selected since the last evaluation can
    /// withdraw an asset from deletion.
    func replacePending(_ candidates: Set<PhotoDeletionCandidate>) {
        guard isEnabled else { return }
        savePending(candidates)
    }

    func resolve(_ assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        savePending(Set(pendingCandidates.filter {
            !assetIDs.contains($0.assetLocalIdentifier)
        }))
    }

    func clearPending() {
        defaults.removeObject(forKey: key(Key.pendingCandidates))
    }

    private func savePending(_ candidates: Set<PhotoDeletionCandidate>) {
        if candidates.isEmpty {
            clearPending()
            return
        }
        let sortedCandidates = candidates.sorted {
            $0.assetLocalIdentifier < $1.assetLocalIdentifier
        }
        if let data = try? JSONEncoder().encode(sortedCandidates) {
            defaults.set(data, forKey: key(Key.pendingCandidates))
        }
    }

    private func key(_ suffix: String) -> String {
        "\(prefix).\(suffix)"
    }
}

struct PhotoDeletionCandidateAccumulator: Equatable, Sendable {
    private struct State: Equatable, Sendable {
        var candidate: PhotoDeletionCandidate
        var isEligible: Bool
    }

    private var stateByAssetID: [String: State] = [:]

    mutating func record(
        assetLocalIdentifier: String,
        modificationDate: Date?,
        fullyBackedUp: Bool
    ) {
        guard !assetLocalIdentifier.isEmpty else { return }
        let candidate = PhotoDeletionCandidate(
            assetLocalIdentifier: assetLocalIdentifier,
            modificationDate: modificationDate
        )
        if let existing = stateByAssetID[assetLocalIdentifier] {
            stateByAssetID[assetLocalIdentifier] = State(
                candidate: candidate,
                isEligible: existing.isEligible
                    && fullyBackedUp
                    && existing.candidate.modificationDate == modificationDate
            )
        } else {
            stateByAssetID[assetLocalIdentifier] = State(
                candidate: candidate,
                isEligible: fullyBackedUp
            )
        }
    }

    mutating func merge(_ other: PhotoDeletionCandidateAccumulator) {
        for state in other.stateByAssetID.values {
            record(
                assetLocalIdentifier: state.candidate.assetLocalIdentifier,
                modificationDate: state.candidate.modificationDate,
                fullyBackedUp: state.isEligible
            )
        }
    }

    var eligibleCandidates: Set<PhotoDeletionCandidate> {
        Set(stateByAssetID.values.compactMap { state in
            state.isEligible ? state.candidate : nil
        })
    }
}

struct PhotoAssetDeletionResult: Equatable, Sendable {
    let deletedAssetIDs: Set<String>
    let skippedAssetIDs: Set<String>

    var resolvedAssetIDs: Set<String> {
        deletedAssetIDs.union(skippedAssetIDs)
    }
}

struct PhotoAssetDeletionService: Sendable {
    let delete: @Sendable (
        Set<PhotoDeletionCandidate>
    ) async throws -> PhotoAssetDeletionResult
}

@MainActor
final class IOSPostSyncDeletionController {
    private let store: IOSDeleteAfterSyncStore
    private let registry: AssetBackupRegistry
    private let eligibilityInput: @Sendable () async throws -> DeletionEligibilityInput
    private let deletionService: PhotoAssetDeletionService
    private let notifier: PendingDeletionNotifier
    private let now: () -> Date
    private let onSnapshotChange: (IOSDeleteAfterSyncSnapshot) -> Void
    private let onOperation: (OperationLogEvent) -> Void
    private var isDeleting = false

    init(
        store: IOSDeleteAfterSyncStore,
        registry: AssetBackupRegistry,
        eligibilityInput: @escaping @Sendable () async throws -> DeletionEligibilityInput,
        deletionService: PhotoAssetDeletionService,
        notifier: PendingDeletionNotifier = .disabled,
        now: @escaping () -> Date = Date.init,
        onSnapshotChange: @escaping (IOSDeleteAfterSyncSnapshot) -> Void = { _ in },
        onOperation: @escaping (OperationLogEvent) -> Void = { _ in }
    ) {
        self.store = store
        self.registry = registry
        self.eligibilityInput = eligibilityInput
        self.deletionService = deletionService
        self.notifier = notifier
        self.now = now
        self.onSnapshotChange = onSnapshotChange
        self.onOperation = onOperation
    }

    var snapshot: IOSDeleteAfterSyncSnapshot {
        var snapshot = store.snapshot
        snapshot.isDeleting = isDeleting
        return snapshot
    }

    func setEnabled(_ enabled: Bool) {
        guard !isDeleting else { return }
        store.setEnabled(enabled)
        if !enabled {
            registry.clear()
        }
        publishSnapshot()
        let notifier = notifier
        Task {
            if enabled {
                await notifier.requestAuthorization()
            } else {
                await notifier.clearPending()
            }
        }
        emit(
            .info,
            enabled
                ? "Delete After Sync enabled."
                : "Delete After Sync disabled; pending deletions were cleared."
        )
    }

    /// A forgotten receiver no longer holds anything this iPhone may rely on.
    func forgetReceiver(_ receiverID: String) {
        registry.remove(receiverID: receiverID)
    }

    /// Drops pending deletions after the setup changed (a receiver was added
    /// or an album selection changed), because the assets may now be required
    /// on a receiver that has not received them yet. The next sync evaluates
    /// the policy again.
    func invalidatePending() {
        guard !isDeleting, !store.pendingCandidates.isEmpty else { return }
        store.clearPending()
        publishSnapshot()
        let notifier = notifier
        Task { await notifier.clearPending() }
        emit(
            .info,
            "Receivers or albums changed; pending deletions wait for the next sync."
        )
    }

    /// Records what each receiver confirmed in this run, then queues every
    /// asset the policy now allows: one that all required receivers hold.
    ///
    /// - Parameter confirmations: fully backed-up assets per receiver ID,
    ///   only for receivers whose every selected album finished.
    func handleSuccessfulSync(
        confirmations: [String: Set<PhotoDeletionCandidate>],
        trigger: SyncTrigger
    ) async {
        guard store.isEnabled else { return }

        for (receiverID, candidates) in confirmations {
            registry.record(candidates, receiverID: receiverID)
        }
        let input: DeletionEligibilityInput
        do {
            input = try await eligibilityInput()
        } catch {
            emit(
                .warning,
                "Kept all photos; the Photos library could not be read: "
                    + error.localizedDescription
            )
            return
        }
        let eligible = DeletionEligibilityPolicy.eligibleCandidates(
            records: registry.allRecords,
            input: input,
            now: now()
        )
        store.replacePending(eligible)
        publishSnapshot()

        guard !store.pendingAssetIDs.isEmpty else {
            emit(
                .info,
                "No photos are backed up on every required receiver yet."
            )
            return
        }

        if trigger == .automaticBackground {
            let pendingCount = store.pendingAssetIDs.count
            emit(
                .warning,
                "\(pendingCount) synced photo(s) are waiting "
                    + "for foreground deletion confirmation."
            )
            await notifier.notifyPending(pendingCount)
            return
        }

        await deletePendingAssets()
    }

    func deletePendingAssets() async {
        guard store.isEnabled, !isDeleting else { return }
        let pendingCandidates = store.pendingCandidates
        guard !pendingCandidates.isEmpty else { return }
        let pendingAssetIDs = Set(
            pendingCandidates.map(\.assetLocalIdentifier)
        )

        isDeleting = true
        publishSnapshot()
        emit(
            .info,
            "Requesting confirmation to delete \(pendingAssetIDs.count) "
                + "fully backed-up photo(s)."
        )
        defer {
            isDeleting = false
            publishSnapshot()
        }

        do {
            let result = try await deletionService.delete(pendingCandidates)
            store.resolve(result.resolvedAssetIDs)
            registry.remove(assetIDs: result.resolvedAssetIDs)
            await notifier.clearPending()
            if !result.deletedAssetIDs.isEmpty {
                emit(
                    .success,
                    "Deleted \(result.deletedAssetIDs.count) fully backed-up "
                        + "photo(s) from the Photos library."
                )
            }
            if !result.skippedAssetIDs.isEmpty {
                emit(
                    .warning,
                    "Kept \(result.skippedAssetIDs.count) photo(s) that were "
                        + "unavailable, changed since sync, or could not be deleted."
                )
            }
        } catch {
            emit(
                .warning,
                "Photos kept all \(pendingAssetIDs.count) pending photo(s): "
                    + error.localizedDescription
            )
        }
    }

    private func publishSnapshot() {
        onSnapshotChange(snapshot)
    }

    private func emit(_ level: OperationLogLevel, _ message: String) {
        onOperation(OperationLogEvent(
            level: level,
            category: "Delete After Sync",
            message: message
        ))
    }
}
