import BackgroundTasks
import Foundation
import SyncCore

struct AutomaticSyncPendingRequest: Equatable, Sendable {
    let identifier: String
    let earliestBeginDate: Date?
}

@MainActor
protocol AutomaticSyncRequestScheduling: AnyObject {
    func submit(_ request: BGTaskRequest) throws
    func cancel(identifier: String)
    func pendingRequests() async -> [AutomaticSyncPendingRequest]
}

@MainActor
private final class LiveAutomaticSyncRequestScheduler: AutomaticSyncRequestScheduling {
    private let scheduler: BGTaskScheduler

    init(scheduler: BGTaskScheduler) {
        self.scheduler = scheduler
    }

    func submit(_ request: BGTaskRequest) throws {
        try scheduler.submit(request)
    }

    func cancel(identifier: String) {
        scheduler.cancel(taskRequestWithIdentifier: identifier)
    }

    func pendingRequests() async -> [AutomaticSyncPendingRequest] {
        await withCheckedContinuation { continuation in
            scheduler.getPendingTaskRequests { requests in
                continuation.resume(returning: requests.map {
                    AutomaticSyncPendingRequest(
                        identifier: $0.identifier,
                        earliestBeginDate: $0.earliestBeginDate
                    )
                })
            }
        }
    }
}

@MainActor
final class AutomaticSyncScheduler {
    static let taskIdentifier = "com.shuk.iphonesync.ios.scheduled-sync"

    private let runtime: IOSSyncRuntime
    private let store: IOSAutomaticSyncStore
    private let policy: AutomaticSyncPolicy
    private let scheduler: BGTaskScheduler
    private let requestScheduler: any AutomaticSyncRequestScheduling
    private let now: () -> Date
    private let isPaired: () -> Bool
    private let onSnapshotChange: (IOSAutomaticSyncSnapshot) -> Void
    private let onRunStateChange: (Bool) -> Void
    private let onOperation: (OperationLogEvent) -> Void
    private let taskIdentifier: String
    private var isRegistered = false
    private var backgroundExecution: BackgroundExecution?
    private var activeRunIDs: Set<UUID> = []
    private var scheduleReconcileIsActive = false

    @MainActor
    private final class BackgroundExecution {
        let runID: UUID
        let task: BGProcessingTask
        var worker: Task<Void, Never>?
        var isCompleted = false
        var forcedOutcome: SyncRunOutcome?

        init(runID: UUID, task: BGProcessingTask) {
            self.runID = runID
            self.task = task
        }
    }

    init(
        runtime: IOSSyncRuntime,
        store: IOSAutomaticSyncStore,
        policy: AutomaticSyncPolicy,
        scheduler: BGTaskScheduler = .shared,
        requestScheduler: (any AutomaticSyncRequestScheduling)? = nil,
        taskIdentifier: String = AutomaticSyncScheduler.taskIdentifier,
        now: @escaping () -> Date = Date.init,
        isPaired: @escaping () -> Bool = { true },
        onSnapshotChange: @escaping (IOSAutomaticSyncSnapshot) -> Void,
        onRunStateChange: @escaping (Bool) -> Void,
        onOperation: @escaping (OperationLogEvent) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.store = store
        self.policy = policy
        self.scheduler = scheduler
        self.taskIdentifier = taskIdentifier
        self.isPaired = isPaired
        if let requestScheduler {
            self.requestScheduler = requestScheduler
        } else {
            self.requestScheduler = LiveAutomaticSyncRequestScheduler(
                scheduler: scheduler
            )
        }
        self.now = now
        self.onSnapshotChange = onSnapshotChange
        self.onRunStateChange = onRunStateChange
        self.onOperation = onOperation
    }

    @discardableResult
    func register() -> Bool {
        guard !isRegistered else { return true }
        isRegistered = scheduler.register(
            forTaskWithIdentifier: taskIdentifier,
            using: .main
        ) { @MainActor [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let self else {
                processingTask.setTaskCompleted(success: false)
                return
            }
            self.launch(processingTask)
        }
        emit(
            isRegistered ? .success : .error,
            isRegistered
                ? "Registered the background processing handler."
                : "Could not register the background processing handler."
        )
        return isRegistered
    }

    func setEnabled(_ enabled: Bool) {
        store.setEnabled(enabled)
        emit(
            .info,
            enabled ? "Automatic Sync enabled." : "Automatic Sync disabled."
        )
        if enabled {
            let didSubmit = replaceSchedule(reason: .enabled)
            if !didSubmit, let nextDate = store.snapshot.nextEligibleAt {
                emit(
                    .info,
                    "Next automatic sync attempt scheduled at "
                        + Self.formattedAttemptDate(nextDate)
                        + "."
                )
            }
            if !didSubmit, !store.snapshot.isEnabled {
                emit(
                    .warning,
                    "Automatic Sync could not be scheduled and has been disabled."
                )
            }
        } else {
            requestScheduler.cancel(identifier: taskIdentifier)
            store.recordNextEligibleAt(nil)
            if let execution = backgroundExecution,
               !execution.isCompleted {
                execution.forcedOutcome = .cancelled
                execution.worker?.cancel()
            }
            if let runID = backgroundExecution?.runID {
                Task {
                    await runtime.cancel(runID: runID, reason: .user)
                }
            }
        }
        publishSnapshot()
    }

    private static func formattedAttemptDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    func ensureScheduled() async {
        guard !scheduleReconcileIsActive else { return }
        scheduleReconcileIsActive = true
        defer { scheduleReconcileIsActive = false }

        guard store.snapshot.isEnabled else {
            requestScheduler.cancel(identifier: taskIdentifier)
            store.recordNextEligibleAt(nil)
            publishSnapshot()
            return
        }
        let referenceDate = now()
        let snapshot = store.snapshot
        let restoredDate = policy.restoredRequestDate(
            after: referenceDate,
            persistedDate: snapshot.nextEligibleAt
        )
        let pendingRequest = await requestScheduler.pendingRequests().first {
            $0.identifier == taskIdentifier
        }
        guard store.snapshot.isEnabled else {
            publishSnapshot()
            return
        }

        if let pendingRequest {
            if Self.shouldReplacePendingRequest(
                pendingRequest,
                with: restoredDate
            ) {
                _ = submitSchedule(earliestBeginDate: restoredDate)
            } else {
                store.recordNextEligibleAt(
                    pendingRequest.earliestBeginDate ?? referenceDate
                )
            }
        } else {
            _ = submitSchedule(earliestBeginDate: restoredDate)
        }
        publishSnapshot()
    }

    static func shouldReplacePendingRequest(
        _ pendingRequest: AutomaticSyncPendingRequest,
        with desiredDate: Date
    ) -> Bool {
        guard let pendingDate = pendingRequest.earliestBeginDate else {
            return false
        }
        return desiredDate < pendingDate
    }

    private func launch(_ task: BGProcessingTask) {
        guard store.snapshot.isEnabled else {
            emit(.warning, "Ignored a background launch because Automatic Sync is disabled.")
            task.setTaskCompleted(success: true)
            return
        }
        guard backgroundExecution == nil else {
            emit(
                .warning,
                "Skipped a background launch because a sync is already running."
            )
            _ = replaceSchedule(reason: .retry)
            task.setTaskCompleted(success: true)
            return
        }

        let runID = UUID()
        emit(.info, "iOS launched the scheduled background sync handler.")
        let execution = BackgroundExecution(runID: runID, task: task)
        backgroundExecution = execution
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.expire(runID: runID)
            }
        }
        execution.worker = Task { @MainActor [weak self] in
            await self?.handle(runID: runID)
        }
    }

    private func handle(runID: UUID) async {
        guard let execution = backgroundExecution,
              execution.runID == runID else {
            return
        }
        if let forcedOutcome = execution.forcedOutcome {
            finishBackgroundExecution(runID: runID, outcome: forcedOutcome)
            return
        }
        let attemptDate = now()

        store.recordAttempt(at: attemptDate)
        guard isPaired() else {
            emit(
                .warning,
                "No iPhone paired; scheduled automatic sync was skipped."
            )
            finishBackgroundExecution(
                runID: runID,
                outcome: .deferred(.pairingRequired)
            )
            return
        }

        _ = replaceSchedule(reason: .retry)
        beginRun(runID)
        emit(.info, "Starting a scheduled background sync attempt.")
        publishSnapshot()

        let outcome: SyncRunOutcome
        if let forcedOutcome = execution.forcedOutcome {
            outcome = forcedOutcome
        } else {
            // No application budget: iOS decides how long this window lasts
            // and calls the expiration handler, which cancels the run and
            // leaves the receiver checkpoint to resume from.
            outcome = await runtime.run(SyncRunRequest(
                id: runID,
                trigger: .automaticBackground,
                maximumElapsed: nil
            ))
        }
        finishBackgroundExecution(
            runID: runID,
            outcome: execution.forcedOutcome ?? outcome
        )
    }

    private func expire(runID: UUID) async {
        guard let execution = backgroundExecution,
              execution.runID == runID,
              !execution.isCompleted else {
            return
        }
        execution.forcedOutcome = .budgetExhausted
        emit(.warning, "The scheduled background task expired; cancelling active work.")
        execution.worker?.cancel()
        await runtime.cancel(runID: runID, reason: .expiration)
        await execution.worker?.value
        if !execution.isCompleted {
            finishBackgroundExecution(
                runID: runID,
                outcome: .budgetExhausted
            )
        }
    }

    private func finishBackgroundExecution(
        runID: UUID,
        outcome: SyncRunOutcome
    ) {
        guard let execution = backgroundExecution,
              execution.runID == runID,
              !execution.isCompleted else {
            return
        }
        execution.isCompleted = true
        execution.task.expirationHandler = nil
        endRun(runID)
        record(outcome, at: now())
        emitOutcome(outcome, trigger: "Scheduled background sync")
        _ = replaceSchedule(reason: scheduleReason(after: outcome))
        publishSnapshot()
        execution.task.setTaskCompleted(success: outcome.backgroundTaskSucceeded)
        backgroundExecution = nil
    }

    private func scheduleReason(after outcome: SyncRunOutcome) -> AutomaticSyncScheduleReason {
        if outcome.isSuccessfulSync {
            return .completed
        }
        if outcome.shouldRetrySoon {
            return .retry
        }
        return .needsAttention
    }

    private func record(_ outcome: SyncRunOutcome, at date: Date) {
        store.recordOutcome(
            outcome.automaticCode,
            message: outcome.message,
            at: date,
            successful: outcome.isSuccessfulSync
        )
    }

    private func replaceSchedule(reason: AutomaticSyncScheduleReason) -> Bool {
        guard store.snapshot.isEnabled, isRegistered else {
            store.recordNextEligibleAt(nil)
            return false
        }
        let date = policy.nextRequestDate(after: now(), reason: reason)
        return submitSchedule(earliestBeginDate: date)
    }

    private func submitSchedule(earliestBeginDate date: Date) -> Bool {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = date
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = policy.requiresExternalPower
        do {
            try requestScheduler.submit(request)
            store.recordNextEligibleAt(date)
            emit(
                .info,
                "Submitted a background request eligible after "
                    + Self.formattedAttemptDate(date)
                    + "."
            )
            return true
        } catch {
            let failureMessage = isBGTaskSchedulerDomainError3(error)
                ? "Could not schedule automatic sync: "
                    + "The operation couldn't be completed. "
                    + "BGTaskSchedulerErrorDomain error 3. "
                    + "\(error.localizedDescription)"
                : "Could not schedule automatic sync: \(error.localizedDescription)"
            store.recordOutcome(
                .failed,
                message: failureMessage,
                at: now(),
                successful: false
            )
            store.recordNextEligibleAt(nil)
            if isBGTaskSchedulerDomainError3(error) {
                store.setEnabled(false)
                requestScheduler.cancel(identifier: taskIdentifier)
            }
            emit(
                .error,
                failureMessage
            )
            return false
        }
    }

    private func isBGTaskSchedulerDomainError3(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "BGTaskSchedulerErrorDomain" && nsError.code == 3
    }

    private func beginRun(_ runID: UUID) {
        let wasRunning = !activeRunIDs.isEmpty
        activeRunIDs.insert(runID)
        if !wasRunning {
            onRunStateChange(true)
        }
    }

    private func endRun(_ runID: UUID) {
        let wasRunning = !activeRunIDs.isEmpty
        activeRunIDs.remove(runID)
        if wasRunning, activeRunIDs.isEmpty {
            onRunStateChange(false)
        }
    }

    private func publishSnapshot() {
        onSnapshotChange(store.snapshot)
    }

    private func emitOutcome(_ outcome: SyncRunOutcome, trigger: String) {
        let level: OperationLogLevel
        switch outcome {
        case .completed, .noChanges:
            level = .success
        case .deferred, .budgetExhausted, .cancelled:
            level = .warning
        case .failed:
            level = .error
        }
        let message = outcome.message ?? "Finished without a result message."
        emit(level, "\(trigger): \(message)")
    }

    private func emit(_ level: OperationLogLevel, _ message: String) {
        onOperation(OperationLogEvent(
            level: level,
            category: "Automatic Sync",
            message: message
        ))
    }
}
