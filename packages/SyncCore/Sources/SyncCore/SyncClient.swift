import Foundation

public enum ClientResourceResult: Equatable, Sendable {
    case skipped
    case committed(relativePath: String)
    case failed(code: TransferFailureCode, message: String, retryable: Bool)
}

/// Receiver verdict for an offer whose bytes have not been sent yet.
public enum ClientOfferDecision: Equatable, Sendable {
    case skip
    case transfer(requestID: UUID, startOffset: Int64)
}

public enum SyncClientError: Error, Equatable, Sendable {
    case invalidLocalFile
    case noOpenSession
    case protocolViolation
    case sessionRejected(String)
}

public actor SyncClient {
    private let connection: FramedConnection
    private var sessionIsOpen = false
    private var finished = false

    public init(connection: FramedConnection) {
        self.connection = connection
    }

    public func openSession(
        albumID: String,
        albumName: String,
        sourceBindingID: String?
    ) async throws -> String {
        guard !sessionIsOpen, !finished else { throw SyncClientError.protocolViolation }
        try await connection.start()
        let requestID = UUID()
        try await connection.send(try SyncFrame.control(
            .session(.request(
                albumID: albumID,
                albumName: albumName,
                sourceBindingID: sourceBindingID
            )),
            requestID: requestID
        ))
        let message = try await receiveControl(requestID: requestID, kind: .session)
        switch message {
        case let .session(.accepted(bindingID)):
            sessionIsOpen = true
            return bindingID
        case let .session(.rejected(reason)):
            throw SyncClientError.sessionRejected(reason)
        default:
            throw SyncClientError.protocolViolation
        }
    }

    public func sendResource(
        _ offer: ResourceOffer,
        fileURL: URL,
        progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> ClientResourceResult {
        // The receiver starts its idle deadline the moment it accepts an
        // offer, and hashing a large video takes longer than that deadline
        // allows — so the local file must be verified before offering, never
        // between the acceptance and the first chunk.
        try validateLocalFile(fileURL, descriptor: offer.descriptor)
        switch try await offerResource(offer) {
        case .skip:
            return .skipped
        case let .transfer(requestID, startOffset):
            return try await sendBody(
                offer,
                fileURL: fileURL,
                requestID: requestID,
                startOffset: startOffset,
                progress: progress
            )
        }
    }

    private func validateLocalFile(
        _ fileURL: URL,
        descriptor: ResourceDescriptor
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (attributes[FileAttributeKey.size] as? NSNumber)?.int64Value
                == descriptor.expectedSize,
              try FileHasher.sha256(url: fileURL) == descriptor.contentHash
        else {
            throw SyncClientError.invalidLocalFile
        }
    }

    /// Sends only the offer and reports the receiver's decision.
    ///
    /// Splitting the offer from the body lets a sender that already knows a
    /// resource's identity from an earlier confirmed transfer ask whether the
    /// receiver still holds it *before* paying to materialise the bytes.
    public func offerResource(
        _ offer: ResourceOffer
    ) async throws -> ClientOfferDecision {
        guard sessionIsOpen, !finished else { throw SyncClientError.noOpenSession }
        let requestID = UUID()
        try await connection.send(try SyncFrame.control(
            .offer(offer),
            requestID: requestID
        ))
        let response = try await receiveControl(requestID: requestID, kind: .decision)
        switch response {
        case .decision(.skip):
            return .skip
        case let .decision(.start(offset)):
            guard offset == 0 else { throw SyncClientError.protocolViolation }
            return .transfer(requestID: requestID, startOffset: offset)
        case let .decision(.resume(offset)):
            guard offset >= 0, offset <= offer.descriptor.expectedSize else {
                throw SyncClientError.protocolViolation
            }
            return .transfer(requestID: requestID, startOffset: offset)
        default:
            throw SyncClientError.protocolViolation
        }
    }

    /// Streams the bytes for an offer the receiver has already accepted.
    ///
    /// Only ever called with a file that has already been verified, because
    /// the receiver is counting the seconds between its acceptance and the
    /// first chunk.
    private func sendBody(
        _ offer: ResourceOffer,
        fileURL: URL,
        requestID: UUID,
        startOffset: Int64,
        progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> ClientResourceResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        var offset = startOffset
        progress?(offset, offer.descriptor.expectedSize)
        while offset < offer.descriptor.expectedSize {
            let remaining = offer.descriptor.expectedSize - offset
            let count = min(SyncConstants.chunkSize, Int(remaining))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                throw SyncClientError.invalidLocalFile
            }
            try await connection.send(try SyncFrame(
                kind: .chunk,
                requestID: requestID,
                offset: UInt64(offset),
                payload: data
            ))
            offset += Int64(data.count)
            progress?(offset, offer.descriptor.expectedSize)
        }

        let result = try await receiveControl(requestID: requestID, kind: .result)
        switch result {
        case let .result(.committed(relativePath)):
            return .committed(relativePath: relativePath)
        case let .result(.failed(code, message, retryable)):
            return .failed(code: code, message: message, retryable: retryable)
        default:
            throw SyncClientError.protocolViolation
        }
    }

    public func finish() async throws -> SyncSummary {
        guard sessionIsOpen, !finished else { throw SyncClientError.noOpenSession }
        let requestID = UUID()
        try await connection.send(try SyncFrame.control(
            .session(.finished),
            requestID: requestID
        ))
        let response = try await receiveControl(requestID: requestID, kind: .result)
        guard case let .result(.sessionCompleted(summary)) = response else {
            throw SyncClientError.protocolViolation
        }
        finished = true
        sessionIsOpen = false
        connection.cancel()
        return summary
    }

    public func cancel() {
        finished = true
        sessionIsOpen = false
        connection.cancel()
    }

    private func receiveControl(
        requestID: UUID,
        kind: FrameKind
    ) async throws -> SyncControlMessage {
        let frame = try await connection.receive()
        guard frame.requestID == requestID, frame.kind == kind else {
            throw SyncClientError.protocolViolation
        }
        return try frame.controlMessage()
    }
}
