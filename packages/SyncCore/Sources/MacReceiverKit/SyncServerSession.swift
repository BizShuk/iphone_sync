import Foundation
import SyncCore

public enum SyncServerSessionError: Error, Equatable, LocalizedError, Sendable {
    case idleTimedOut
    case integrityFailureLimitExceeded
    case invalidChunk
    case openingTimedOut
    case protocolViolation
    case sessionRejected(String)

    public var errorDescription: String? {
        switch self {
        case .idleTimedOut:
            "The sender stopped sending before the session finished; "
                + "the iPhone was most likely locked or suspended."
        case .integrityFailureLimitExceeded:
            "The same resource failed integrity verification twice."
        case .invalidChunk:
            "The sender provided an invalid or out-of-order chunk."
        case .openingTimedOut:
            "The incoming connection did not open a valid session before the deadline."
        case .protocolViolation:
            "The sender violated the sync protocol."
        case let .sessionRejected(message):
            message
        }
    }
}

public actor SyncServerSession {
    public typealias AcceptedHandler = @Sendable () async -> Void
    public typealias EventHandler = @Sendable (OperationLogEvent) async -> Void

    public static let defaultOpeningTimeout: Duration = .seconds(15)
    // An open session that stops producing frames is almost always an iPhone
    // that got locked or suspended mid-transfer. Without this bound the
    // receiver would block on `receive()` until TCP keepalive gives up
    // (~2 hours on Darwin) and reject every following connection.
    public static let defaultIdleTimeout: Duration = .seconds(45)

    private let manifest: ManifestStore
    private let writer: DestinationWriter
    private var integrityFailures: [String: Int] = [:]
    private var idleTimeout: Duration = SyncServerSession.defaultIdleTimeout

    public init(manifest: ManifestStore, writer: DestinationWriter) {
        self.manifest = manifest
        self.writer = writer
    }

    public func run(
        connection: FramedConnection,
        openingTimeout: Duration = SyncServerSession.defaultOpeningTimeout,
        idleTimeout: Duration = SyncServerSession.defaultIdleTimeout,
        onAccepted: AcceptedHandler? = nil,
        onEvent: EventHandler? = nil
    ) async throws -> SyncSummary {
        defer { connection.cancel() }
        self.idleTimeout = idleTimeout

        try await openSession(
            connection: connection,
            timeout: openingTimeout,
            onEvent: onEvent
        )
        await onAccepted?()

        var summary = SyncSummary.zero
        while true {
            let frame = try await receive(from: connection)
            let message = try frame.controlMessage()
            switch message {
            case .session(.finished):
                try await connection.send(try SyncFrame.control(
                    .result(.sessionCompleted(summary)),
                    requestID: frame.requestID
                ))
                await onEvent?(OperationLogEvent(
                    level: .success,
                    category: "Session",
                    message: "Completed: \(summary.added) added, "
                        + "\(summary.existing) already present, "
                        + "\(summary.notLocal) not local, \(summary.failed) failed."
                ))
                return summary
            case let .offer(offer):
                try await handle(
                    offer: offer,
                    requestID: frame.requestID,
                    connection: connection,
                    summary: &summary,
                    onEvent: onEvent
                )
            default:
                throw SyncServerSessionError.protocolViolation
            }
        }
    }

    private func openSession(
        connection: FramedConnection,
        timeout: Duration,
        onEvent: EventHandler?
    ) async throws {
        let deadline = SessionOpeningDeadline()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard await deadline.markTimedOut() else { return }
            connection.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            try await connection.start()
            try Task.checkCancellation()

            try await acceptOpeningRequest(
                connection: connection,
                onEvent: onEvent
            )
            guard await deadline.markAccepted() else {
                throw SyncServerSessionError.openingTimedOut
            }
        } catch {
            if await deadline.didTimeOut {
                throw SyncServerSessionError.openingTimedOut
            }
            throw error
        }
    }

    private func acceptOpeningRequest(
        connection: FramedConnection,
        onEvent: EventHandler?
    ) async throws {
        let openingFrame = try await connection.receive()
        guard openingFrame.kind == .session,
              case let .session(.request(albumID, albumName, requestedBinding)) = try openingFrame.controlMessage()
        else {
            throw SyncServerSessionError.protocolViolation
        }
        await onEvent?(OperationLogEvent(
            level: .info,
            category: "Session",
            message: "Opening album “\(albumName)”."
        ))
        let acceptedAlbum: AcceptedAlbum
        do {
            acceptedAlbum = try await manifest.acceptSession(
                albumID: albumID,
                albumName: albumName,
                requestedBindingID: requestedBinding
            )
        } catch ManifestStoreError.sourceBindingMismatch {
            await onEvent?(OperationLogEvent(
                level: .error,
                category: "Session",
                message: "Rejected album “\(albumName)”: source binding mismatch."
            ))
            try await connection.send(try SyncFrame.control(
                .session(.rejected(reason: "source-binding-mismatch")),
                requestID: openingFrame.requestID
            ))
            throw SyncServerSessionError.sessionRejected(
                "The iPhone source binding does not match this destination."
            )
        }
        do {
            try await writer.prepareAlbumDirectory(
                named: acceptedAlbum.destinationFolderName
            )
        } catch {
            await onEvent?(OperationLogEvent(
                level: .error,
                category: "Destination",
                message: "Could not prepare album “\(albumName)”: "
                    + error.localizedDescription
            ))
            try await connection.send(try SyncFrame.control(
                .session(.rejected(reason: "destination-unavailable")),
                requestID: openingFrame.requestID
            ))
            throw SyncServerSessionError.sessionRejected(
                "The album destination folder is unavailable: \(error.localizedDescription)"
            )
        }
        try await connection.send(try SyncFrame.control(
            .session(.accepted(sourceBindingID: acceptedAlbum.sourceBindingID)),
            requestID: openingFrame.requestID
        ))
        await onEvent?(OperationLogEvent(
            level: .success,
            category: "Session",
            message: "Accepted album “\(albumName)” in folder "
                + "“\(acceptedAlbum.destinationFolderName)”."
        ))
    }

    private func handle(
        offer: ResourceOffer,
        requestID: UUID,
        connection: FramedConnection,
        summary: inout SyncSummary,
        onEvent: EventHandler?
    ) async throws {
        let resourceName = offer.descriptor.originalFilename
        await onEvent?(OperationLogEvent(
            level: .info,
            category: "Resource",
            message: "Offered “\(resourceName)” "
                + "(\(offer.descriptor.expectedSize) bytes)."
        ))
        do {
            switch try await writer.begin(offer) {
            case .adopted:
                integrityFailures.removeValue(forKey: offer.resourceID)
                summary.existing += 1
                try await connection.send(try SyncFrame.control(
                    .decision(.skip),
                    requestID: requestID
                ))
                await onEvent?(OperationLogEvent(
                    level: .info,
                    category: "Resource",
                    message: "Skipped “\(resourceName)”; already present."
                ))
                return
            case let .transfer(offset, _):
                let decision: TransferDecision = offset == 0
                    ? .start(offset: 0)
                    : .resume(offset: offset)
                try await connection.send(try SyncFrame.control(
                    .decision(decision),
                    requestID: requestID
                ))
                await onEvent?(OperationLogEvent(
                    level: .info,
                    category: "Resource",
                    message: offset == 0
                        ? "Receiving “\(resourceName)”."
                        : "Resuming “\(resourceName)” at byte \(offset)."
                ))
                try await receiveBytes(
                    offer: offer,
                    requestID: requestID,
                    startingOffset: offset,
                    connection: connection
                )
            }

            let committedURL = try await writer.commit(
                expectedHash: offer.descriptor.contentHash
            )
            let relativePath = String(
                committedURL.path.dropFirst(
                    committedURL.deletingLastPathComponent().path.count + 1
                )
            )
            let snapshot = try await manifest.snapshot(resourceID: offer.resourceID)
            let committedRelativePath = snapshot?.finalRelativePath ?? relativePath
            integrityFailures.removeValue(forKey: offer.resourceID)
            summary.added += 1
            try await connection.send(try SyncFrame.control(
                .result(.committed(relativePath: committedRelativePath)),
                requestID: requestID
            ))
            await onEvent?(OperationLogEvent(
                level: .success,
                category: "Resource",
                message: "Committed “\(resourceName)” to "
                    + "“\(committedRelativePath)”."
            ))
        } catch {
            await writer.abort()
            let isIntegrityMismatch = (error as? DestinationWriterError) == .integrityMismatch
            let retryableIntegrityFailure: Bool
            if isIntegrityMismatch {
                let failureCount = (integrityFailures[offer.resourceID] ?? 0) + 1
                integrityFailures[offer.resourceID] = failureCount
                retryableIntegrityFailure = failureCount == 1
            } else {
                retryableIntegrityFailure = false
            }
            if !isIntegrityMismatch || !retryableIntegrityFailure {
                summary.failed += 1
            }
            let failure = failureResult(
                for: error,
                retryableIntegrityFailure: retryableIntegrityFailure
            )
            await onEvent?(OperationLogEvent(
                level: retryableIntegrityFailure ? .warning : .error,
                category: "Resource",
                message: "Failed “\(resourceName)”: \(error.localizedDescription)"
                    + (retryableIntegrityFailure ? " Retrying once." : "")
            ))
            try? await connection.send(try SyncFrame.control(
                .result(failure),
                requestID: requestID
            ))
            if isIntegrityMismatch && !retryableIntegrityFailure {
                throw SyncServerSessionError.integrityFailureLimitExceeded
            }
            if error is SyncServerSessionError {
                throw error
            }
            if !isIntegrityMismatch {
                throw SyncServerSessionError.sessionRejected(
                    "Resource transfer failed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Receives the next frame, bounding the wait so a sender that vanishes
    /// (locked iPhone, suspended app, LAN drop) ends the session instead of
    /// holding the receiver's single active connection slot open forever.
    private func receive(from connection: FramedConnection) async throws -> SyncFrame {
        let idleTimeout = idleTimeout
        return try await withThrowingTaskGroup(of: SyncFrame.self) { group in
            group.addTask {
                try await connection.receive()
            }
            group.addTask {
                try await Task.sleep(for: idleTimeout)
                connection.cancel()
                throw SyncServerSessionError.idleTimedOut
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else {
                throw SyncServerSessionError.idleTimedOut
            }
            return frame
        }
    }

    private func receiveBytes(
        offer: ResourceOffer,
        requestID: UUID,
        startingOffset: Int64,
        connection: FramedConnection
    ) async throws {
        var offset = startingOffset
        while offset < offer.descriptor.expectedSize {
            let chunk = try await receive(from: connection)
            guard chunk.kind == .chunk,
                  chunk.requestID == requestID,
                  chunk.offset == UInt64(offset),
                  !chunk.payload.isEmpty
            else {
                throw SyncServerSessionError.invalidChunk
            }
            try await writer.append(chunk.payload, offset: offset)
            offset += Int64(chunk.payload.count)
            if offset % SyncConstants.checkpointSize == 0 {
                try await writer.checkpoint(at: offset)
            }
        }
    }

    private func failureResult(
        for error: any Error,
        retryableIntegrityFailure: Bool
    ) -> TransferResult {
        if let writerError = error as? DestinationWriterError,
           writerError == .integrityMismatch {
            return .failed(
                code: .integrity,
                message: "Received bytes failed integrity verification.",
                retryable: retryableIntegrityFailure
            )
        }
        if error is SyncServerSessionError || error is FrameCodecError {
            return .failed(
                code: .invalidFrame,
                message: "The transfer stream was invalid.",
                retryable: false
            )
        }
        return .failed(
            code: .destinationUnavailable,
            message: "The destination could not accept this resource.",
            retryable: false
        )
    }
}

private actor SessionOpeningDeadline {
    private enum State: Equatable {
        case pending
        case accepted
        case timedOut
    }

    private var state = State.pending

    var didTimeOut: Bool {
        state == .timedOut
    }

    func markAccepted() -> Bool {
        guard state == .pending else { return false }
        state = .accepted
        return true
    }

    func markTimedOut() -> Bool {
        guard state == .pending else { return false }
        state = .timedOut
        return true
    }
}
