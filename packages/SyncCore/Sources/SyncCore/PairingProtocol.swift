import Foundation
import Network

public struct PairingHello: Codable, Equatable, Sendable {
    public let deviceID: String
    public let displayName: String
    public let publicKey: Data
    public let nonce: Data

    public init(deviceID: String, displayName: String, publicKey: Data, nonce: Data) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.publicKey = publicKey
        self.nonce = nonce
    }
}

public enum PairingMessage: Codable, Equatable, Sendable {
    case hello(PairingHello)
    case confirm(proof: Data)
    case accepted(proof: Data)
    case rejected(reason: String)
}

public enum PairingProtocolError: Error, Equatable, Sendable {
    case cancelled
    case invalidMessage
    case payloadTooLarge
    case truncatedMessage
}

enum PairingProof {
    static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

final class PairingChannel: @unchecked Sendable {
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

    init(
        _ connection: NWConnection,
        queue: DispatchQueue = DispatchQueue(label: "com.bizshuk.iphonesync.pairing")
    ) {
        self.connection = connection
        self.queue = queue
    }

    func start() async throws {
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
                continuation.resume(throwing: PairingProtocolError.cancelled)
            case .starting:
                stateLock.unlock()
                continuation.resume(throwing: PairingProtocolError.invalidMessage)
            }
        }
    }

    func send(_ message: PairingMessage) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        guard payload.count <= SyncConstants.maximumControlPayload else {
            throw PairingProtocolError.payloadTooLarge
        }

        var framed = Data()
        let length = UInt32(payload.count)
        framed.append(UInt8((length >> 24) & 0xff))
        framed.append(UInt8((length >> 16) & 0xff))
        framed.append(UInt8((length >> 8) & 0xff))
        framed.append(UInt8(length & 0xff))
        framed.append(payload)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> PairingMessage {
        let header = try await receiveExactly(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(SyncConstants.maximumControlPayload) else {
            throw PairingProtocolError.payloadTooLarge
        }
        let payload = try await receiveExactly(Int(length))
        return try JSONDecoder().decode(PairingMessage.self, from: payload)
    }

    func cancel() {
        stateLock.lock()
        let continuation: CheckedContinuation<Void, any Error>?
        if case let .starting(pending) = startState {
            continuation = pending
        } else {
            continuation = nil
        }
        startState = .cancelled
        stateLock.unlock()

        continuation?.resume(throwing: PairingProtocolError.cancelled)
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finishStart(with: .success(()))
        case let .failed(error):
            finishStart(with: .failure(error))
        case .cancelled:
            finishStart(with: .failure(PairingProtocolError.cancelled))
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
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let remaining = count - result.count
            let part = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data?, Bool), any Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (data, isComplete))
                    }
                }
            }
            if let data = part.0, !data.isEmpty {
                result.append(data)
            }
            if result.count < count, part.1 || (part.0?.isEmpty ?? true) {
                throw PairingProtocolError.truncatedMessage
            }
        }
        return result
    }
}
