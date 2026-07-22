import Foundation
import SyncCore

public enum SyncServerSessionError: Error, Equatable, LocalizedError, Sendable {
    case integrityFailureLimitExceeded
    case invalidChunk
    case protocolViolation
    case sessionRejected(String)

    public var errorDescription: String? {
        switch self {
        case .integrityFailureLimitExceeded:
            "The same resource failed integrity verification twice."
        case .invalidChunk:
            "The sender provided an invalid or out-of-order chunk."
        case .protocolViolation:
            "The sender violated the sync protocol."
        case let .sessionRejected(message):
            message
        }
    }
}

public actor SyncServerSession {
    private let manifest: ManifestStore
    private let writer: DestinationWriter
    private var integrityFailures: [String: Int] = [:]

    public init(manifest: ManifestStore, writer: DestinationWriter) {
        self.manifest = manifest
        self.writer = writer
    }

    public func run(connection: FramedConnection) async throws -> SyncSummary {
        try await connection.start()
        defer { connection.cancel() }

        let openingFrame = try await connection.receive()
        guard openingFrame.kind == .session,
              case let .session(.request(albumID, albumName, requestedBinding)) = try openingFrame.controlMessage()
        else {
            throw SyncServerSessionError.protocolViolation
        }
        let acceptedAlbum: AcceptedAlbum
        do {
            acceptedAlbum = try await manifest.acceptSession(
                albumID: albumID,
                albumName: albumName,
                requestedBindingID: requestedBinding
            )
        } catch ManifestStoreError.sourceBindingMismatch {
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

        var summary = SyncSummary.zero
        while true {
            let frame = try await connection.receive()
            let message = try frame.controlMessage()
            switch message {
            case .session(.finished):
                try await connection.send(try SyncFrame.control(
                    .result(.sessionCompleted(summary)),
                    requestID: frame.requestID
                ))
                return summary
            case let .offer(offer):
                try await handle(
                    offer: offer,
                    requestID: frame.requestID,
                    connection: connection,
                    summary: &summary
                )
            default:
                throw SyncServerSessionError.protocolViolation
            }
        }
    }

    private func handle(
        offer: ResourceOffer,
        requestID: UUID,
        connection: FramedConnection,
        summary: inout SyncSummary
    ) async throws {
        do {
            switch try await writer.begin(offer) {
            case .adopted:
                integrityFailures.removeValue(forKey: offer.resourceID)
                summary.existing += 1
                try await connection.send(try SyncFrame.control(
                    .decision(.skip),
                    requestID: requestID
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

    private func receiveBytes(
        offer: ResourceOffer,
        requestID: UUID,
        startingOffset: Int64,
        connection: FramedConnection
    ) async throws {
        var offset = startingOffset
        while offset < offer.descriptor.expectedSize {
            let chunk = try await connection.receive()
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
