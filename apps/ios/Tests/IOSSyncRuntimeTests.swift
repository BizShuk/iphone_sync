import Foundation
import Network
import SyncCore
import XCTest
@testable import iPhone_Sync

@MainActor
final class IOSSyncRuntimeTests: XCTestCase {
    func testPrerequisiteFailuresAreTypedWithoutStartingSync() async {
        let noPhotos = IOSSyncRuntime(environment: environment(
            hasFullPhotoAccess: false
        ))
        let noAlbums = IOSSyncRuntime(environment: environment(
            albums: []
        ))
        let noPairing = IOSSyncRuntime(environment: environment(
            hasPairedPeer: { false }
        ))

        let noPhotosOutcome = await noPhotos.run(request())
        let noAlbumsOutcome = await noAlbums.run(request())
        let noPairingOutcome = await noPairing.run(request())

        XCTAssertEqual(noPhotosOutcome, .deferred(.photosAccessRequired))
        XCTAssertEqual(noAlbumsOutcome, .deferred(.albumsRequired))
        XCTAssertEqual(noPairingOutcome, .deferred(.pairingRequired))
    }

    func testSecondRunIsDeferredWhileFirstRunAwaitsPairedPeer() async {
        let peerGate = AsyncBooleanGate()
        let runtime = IOSSyncRuntime(environment: environment(
            hasPairedPeer: {
                await peerGate.wait()
            }
        ))
        let firstRequest = request()
        let firstRun = Task { await runtime.run(firstRequest) }

        await peerGate.waitUntilEntered()
        let secondOutcome = await runtime.run(request())

        XCTAssertEqual(secondOutcome, .deferred(.alreadyRunning))
        await peerGate.release(returning: true)
        let firstOutcome = await firstRun.value
        XCTAssertEqual(firstOutcome, .noChanges(.zero))
    }

    func testBudgetCancellationWaitsForExecutorCleanup() async {
        let executor = BlockingSyncExecutor()
        let runtime = IOSSyncRuntime(environment: environment(
            sync: { _, _, _ in try await executor.run() },
            cancel: { await executor.cancel() }
        ))
        let runRequest = request()
        let run = Task { await runtime.run(runRequest) }

        await executor.waitUntilStarted()
        await runtime.cancel(runID: runRequest.id, reason: .budget)

        let outcome = await run.value
        let cancelCount = await executor.cancelCount
        XCTAssertEqual(outcome, .budgetExhausted)
        XCTAssertEqual(cancelCount, 1)
    }

    func testCallerCancellationClosesExecutor() async {
        let executor = BlockingSyncExecutor()
        let runtime = IOSSyncRuntime(environment: environment(
            sync: { _, _, _ in try await executor.run() },
            cancel: { await executor.cancel() }
        ))
        let run = Task { await runtime.run(request()) }

        await executor.waitUntilStarted()
        run.cancel()

        let outcome = await run.value
        let cancelCount = await executor.cancelCount
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(cancelCount, 1)
    }

    func testAlreadyCancelledTaskDoesNotEnterPrerequisitesOrSync() async {
        let probe = SynchronousInvocationProbe()
        let runtime = IOSSyncRuntime(environment: IOSSyncRuntimeEnvironment(
            hasFullPhotoAccess: {
                probe.record()
                return true
            },
            loadSelectedAlbums: {
                probe.record()
                return [PhotoAlbum(id: "album", title: "Album", assetCount: 1)]
            },
            hasPairedPeer: {
                probe.record()
                return true
            },
            sync: { _, _, _ in
                probe.record()
                return .zero
            },
            cancel: {}
        ))

        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runtime.run(request())
        }.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(probe.count, 0)
    }

    func testManualCancellationWinsOverNWECancelled() async {
        let executor = TransportFailureOnCancelExecutor(failure: .nwCancelled)
        let runtime = IOSSyncRuntime(environment: environment(
            sync: { _, _, _ in try await executor.run() },
            cancel: { await executor.cancel() }
        ))
        let runRequest = request(trigger: .manualForeground)
        let run = Task { await runtime.run(runRequest) }

        await executor.waitUntilStarted()
        await runtime.cancel(runID: runRequest.id, reason: .user)

        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testExpirationWinsOverTruncatedTransportError() async {
        let executor = TransportFailureOnCancelExecutor(failure: .truncatedFrame)
        let runtime = IOSSyncRuntime(environment: environment(
            sync: { _, _, _ in try await executor.run() },
            cancel: { await executor.cancel() }
        ))
        let runRequest = request()
        let run = Task { await runtime.run(runRequest) }

        await executor.waitUntilStarted()
        await runtime.cancel(runID: runRequest.id, reason: .expiration)

        let outcome = await run.value
        XCTAssertEqual(outcome, .budgetExhausted)
        XCTAssertTrue(outcome.shouldRetrySoon)
        XCTAssertFalse(outcome.backgroundTaskSucceeded)
    }

    func testCancellationWinsOverGenericCleanupError() async {
        let executor = TransportFailureOnCancelExecutor(failure: .generic)
        let runtime = IOSSyncRuntime(environment: environment(
            sync: { _, _, _ in try await executor.run() },
            cancel: { await executor.cancel() }
        ))
        let runRequest = request(trigger: .manualForeground)
        let run = Task { await runtime.run(runRequest) }

        await executor.waitUntilStarted()
        await runtime.cancel(runID: runRequest.id, reason: .user)

        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testTLSFailureRequiresUserActionWithoutShortRetry() async {
        let runtime = IOSSyncRuntime(environment: environment(
            sync: { _, _, _ in throw NWError.tls(-9807) }
        ))

        let outcome = await runtime.run(request())

        guard case .failed(let failure) = outcome else {
            return XCTFail("Expected a typed failure, got \(outcome)")
        }
        XCTAssertEqual(failure.kind, .needsUserAction)
        XCTAssertFalse(outcome.shouldRetrySoon)
    }

    func testResourceFailurePreservesDispositionAndMessage() async {
        let cases: [(
            code: TransferFailureCode,
            retryable: Bool,
            expectedKind: SyncFailureKind,
            expectedShortRetry: Bool
        )] = [
            (.diskFull, true, .needsUserAction, false),
            (.destinationUnavailable, false, .needsUserAction, false),
            (.destinationUnavailable, true, .internalFailure, true),
            (.authentication, true, .needsUserAction, false),
            (.invalidFrame, true, .internalFailure, false),
            (.protocolMismatch, true, .needsUserAction, false),
            (.integrity, false, .internalFailure, false),
            (.integrity, true, .internalFailure, false),
            (.unknown, false, .internalFailure, false),
            (.unknown, true, .internalFailure, true),
        ]

        for testCase in cases {
            let message = "\(testCase.code)-\(testCase.retryable)"
            let runtime = IOSSyncRuntime(environment: environment(
                sync: { _, _, _ in
                    throw IOSSyncCoordinatorError.resourceFailed(
                        code: testCase.code,
                        message: message,
                        retryable: testCase.retryable
                    )
                }
            ))

            let outcome = await runtime.run(request())

            guard case .failed(let failure) = outcome else {
                XCTFail("Expected \(testCase.code) to fail, got \(outcome)")
                continue
            }
            XCTAssertEqual(failure.kind, testCase.expectedKind)
            XCTAssertEqual(failure.message, message)
            XCTAssertEqual(outcome.shouldRetrySoon, testCase.expectedShortRetry)
            XCTAssertEqual(
                outcome.backgroundTaskSucceeded,
                testCase.expectedKind == .needsUserAction
            )
        }
    }

    func testOnlyRetryableIntegrityFailureIsRetriedImmediately() {
        XCTAssertTrue(IOSSyncResourceRetryPolicy.shouldRetryImmediately(
            code: .integrity,
            retryable: true
        ))
        XCTAssertFalse(IOSSyncResourceRetryPolicy.shouldRetryImmediately(
            code: .integrity,
            retryable: false
        ))

        let otherCodes: [TransferFailureCode] = [
            .authentication,
            .destinationUnavailable,
            .diskFull,
            .invalidFrame,
            .protocolMismatch,
            .unknown,
        ]
        for code in otherCodes {
            XCTAssertFalse(IOSSyncResourceRetryPolicy.shouldRetryImmediately(
                code: code,
                retryable: true
            ))
        }
    }

    func testInternalFailureRequestsBoundedRetry() {
        let outcome = SyncRunOutcome.failed(SyncRunFailure(
            kind: .internalFailure,
            message: "transient internal failure",
            shouldRetrySoon: true
        ))

        XCTAssertTrue(outcome.shouldRetrySoon)
        XCTAssertFalse(outcome.backgroundTaskSucceeded)
        XCTAssertTrue(SyncRunOutcome.budgetExhausted.shouldRetrySoon)
        XCTAssertFalse(SyncRunOutcome.budgetExhausted.backgroundTaskSucceeded)
    }

    private func request(
        trigger: SyncTrigger = .automaticBackground
    ) -> SyncRunRequest {
        SyncRunRequest(
            id: UUID(),
            trigger: trigger,
            maximumElapsed: nil
        )
    }

    private func environment(
        hasFullPhotoAccess: Bool = true,
        albums: [PhotoAlbum] = [
            PhotoAlbum(id: "album", title: "Album", assetCount: 1),
        ],
        hasPairedPeer: @escaping @Sendable () async throws -> Bool = { true },
        sync: @escaping @Sendable (
            [PhotoAlbum],
            IOSSyncDiscoveryStrategy,
            SyncTrigger
        ) async throws -> SyncSummary = { _, _, _ in .zero },
        cancel: @escaping @Sendable () async -> Void = {}
    ) -> IOSSyncRuntimeEnvironment {
        IOSSyncRuntimeEnvironment(
            hasFullPhotoAccess: { hasFullPhotoAccess },
            loadSelectedAlbums: { albums },
            hasPairedPeer: hasPairedPeer,
            sync: sync,
            cancel: cancel
        )
    }
}

private actor AsyncBooleanGate {
    private var entered = false
    private var result: Bool?
    private var resultContinuation: CheckedContinuation<Bool, Never>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Bool {
        entered = true
        enteredContinuations.forEach { $0.resume() }
        enteredContinuations.removeAll()
        if let result { return result }
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuations.append($0) }
    }

    func release(returning result: Bool) {
        self.result = result
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

private actor BlockingSyncExecutor {
    private(set) var cancelCount = 0
    private var started = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var runContinuation: CheckedContinuation<SyncSummary, any Error>?

    func run() async throws -> SyncSummary {
        started = true
        startedContinuations.forEach { $0.resume() }
        startedContinuations.removeAll()
        return try await withCheckedThrowingContinuation { runContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuations.append($0) }
    }

    func cancel() {
        cancelCount += 1
        runContinuation?.resume(throwing: CancellationError())
        runContinuation = nil
    }
}

private final class SynchronousInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }

    func record() {
        lock.lock()
        invocationCount += 1
        lock.unlock()
    }
}

private enum TestTransportFailure: Error, Sendable {
    case cleanupFailed
}

private actor TransportFailureOnCancelExecutor {
    enum Failure: Sendable {
        case nwCancelled
        case truncatedFrame
        case generic
    }

    private let failure: Failure
    private var started = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var runContinuation: CheckedContinuation<SyncSummary, any Error>?

    init(failure: Failure) {
        self.failure = failure
    }

    func run() async throws -> SyncSummary {
        started = true
        startedContinuations.forEach { $0.resume() }
        startedContinuations.removeAll()
        return try await withCheckedThrowingContinuation { runContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuations.append($0) }
    }

    func cancel() {
        let error: any Error
        switch failure {
        case .nwCancelled:
            error = NWError.posix(.ECANCELED)
        case .truncatedFrame:
            error = FramedConnectionError.truncatedFrame
        case .generic:
            error = TestTransportFailure.cleanupFailed
        }
        runContinuation?.resume(throwing: error)
        runContinuation = nil
    }
}
