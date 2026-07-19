import Foundation
import Network
@testable import SyncCore

extension ResourceDescriptor {
    static func fixture(
        assetID: String = "asset-1",
        filename: String = "IMG_0001.HEIC",
        contentHash: String = String(repeating: "a", count: 64),
        creationDate: Date? = Date(timeIntervalSince1970: 1_753_000_000),
        role: String? = nil
    ) -> ResourceDescriptor {
        ResourceDescriptor(
            assetLocalIdentifier: assetID,
            resourceType: "photo",
            originalFilename: filename,
            duplicateOrdinal: 0,
            contentHash: contentHash,
            expectedSize: 3,
            creationDate: creationDate,
            role: role
        )
    }
}

actor TestListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.bizshuk.iphonesync.tests.listener")
    private var portContinuation: CheckedContinuation<NWEndpoint.Port, any Error>?
    private var frameContinuation: CheckedContinuation<SyncFrame, any Error>?
    private var received: SyncFrame?
    private var failure: (any Error)?
    private var connection: FramedConnection?

    init(_ listener: NWListener) {
        self.listener = listener
    }

    func start() async throws -> NWEndpoint.Port {
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)

        return try await withCheckedThrowingContinuation { continuation in
            if let port = listener.port, port.rawValue != 0 {
                continuation.resume(returning: port)
            } else if let failure {
                continuation.resume(throwing: failure)
            } else {
                portContinuation = continuation
            }
        }
    }

    func receivedFrame() async throws -> SyncFrame {
        if let received {
            return received
        }
        if let failure {
            throw failure
        }
        return try await withCheckedThrowingContinuation { continuation in
            frameContinuation = continuation
        }
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port {
                portContinuation?.resume(returning: port)
                portContinuation = nil
            }
        case let .failed(error):
            fail(error)
        case .cancelled:
            if portContinuation != nil || frameContinuation != nil {
                fail(TestListenerError.cancelled)
            }
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) async {
        let framed = FramedConnection(nwConnection)
        connection = framed
        do {
            try await framed.start()
            let frame = try await framed.receive()
            received = frame
            frameContinuation?.resume(returning: frame)
            frameContinuation = nil
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        failure = error
        portContinuation?.resume(throwing: error)
        portContinuation = nil
        frameContinuation?.resume(throwing: error)
        frameContinuation = nil
    }
}

enum TestListenerError: Error {
    case cancelled
}

actor PairingRecorder {
    private var codeValue: String?
    private var peerValue: PairedPeer?
    private var codeContinuation: CheckedContinuation<String, Never>?
    private var peerContinuation: CheckedContinuation<PairedPeer, Never>?

    func record(code: String) {
        codeValue = code
        codeContinuation?.resume(returning: code)
        codeContinuation = nil
    }

    func record(peer: PairedPeer) {
        peerValue = peer
        peerContinuation?.resume(returning: peer)
        peerContinuation = nil
    }

    func code() async -> String {
        if let codeValue { return codeValue }
        return await withCheckedContinuation { codeContinuation = $0 }
    }

    func peer() async -> PairedPeer {
        if let peerValue { return peerValue }
        return await withCheckedContinuation { peerContinuation = $0 }
    }
}
