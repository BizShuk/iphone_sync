import Foundation
import Network

public enum FramedConnectionError: Error, Equatable, Sendable {
    case alreadyStarted
    case cancelled
    case connectionFailed(String)
    case truncatedFrame
}

public final class FramedConnection: @unchecked Sendable {
    private enum StartState {
        case idle
        case starting(CheckedContinuation<Void, any Error>)
        case ready
        case failed(any Error)
        case cancelled
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var startState: StartState = .idle

    public init(
        _ connection: NWConnection,
        queue: DispatchQueue = DispatchQueue(label: "com.bizshuk.iphonesync.connection")
    ) {
        self.connection = connection
        self.queue = queue
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stateLock.lock()
            switch startState {
            case .idle:
                startState = .starting(continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                stateLock.unlock()
                connection.start(queue: queue)
            case .ready:
                stateLock.unlock()
                continuation.resume()
            case let .failed(error):
                stateLock.unlock()
                continuation.resume(throwing: error)
            case .cancelled:
                stateLock.unlock()
                continuation.resume(throwing: FramedConnectionError.cancelled)
            case .starting:
                stateLock.unlock()
                continuation.resume(throwing: FramedConnectionError.alreadyStarted)
            }
        }
    }

    public func send(_ frame: SyncFrame) async throws {
        let data = try FrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> SyncFrame {
        let headerData = try await receiveExactly(FrameHeader.byteCount)
        let header = try FrameCodec.decodeHeader(headerData)
        let payload = try await receiveExactly(Int(header.payloadLength))
        return try SyncFrame(
            kind: header.kind,
            requestID: header.requestID,
            offset: header.offset,
            payload: payload
        )
    }

    public func cancel() {
        stateLock.lock()
        let continuation: CheckedContinuation<Void, any Error>?
        if case let .starting(pending) = startState {
            continuation = pending
        } else {
            continuation = nil
        }
        startState = .cancelled
        stateLock.unlock()

        continuation?.resume(throwing: FramedConnectionError.cancelled)
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finishStart(with: .success(()))
        case let .failed(error):
            finishStart(with: .failure(error))
        case .cancelled:
            finishStart(with: .failure(FramedConnectionError.cancelled))
        default:
            break
        }
    }

    private func finishStart(with result: Result<Void, any Error>) {
        stateLock.lock()
        guard case let .starting(continuation) = startState else {
            stateLock.unlock()
            return
        }
        switch result {
        case .success:
            startState = .ready
        case let .failure(error):
            startState = .failed(error)
        }
        stateLock.unlock()
        continuation.resume(with: result)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)

        while result.count < count {
            let remaining = count - result.count
            let part = try await receivePart(maximumLength: remaining)
            if let data = part.data, !data.isEmpty {
                result.append(data)
            }
            if result.count < count, part.isComplete {
                throw FramedConnectionError.truncatedFrame
            }
            if (part.data?.isEmpty ?? true), !part.isComplete {
                throw FramedConnectionError.truncatedFrame
            }
        }
        return result
    }

    private func receivePart(maximumLength: Int) async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }
}
