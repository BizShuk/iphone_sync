import Foundation
import Network

public enum PairingServerError: Error, Equatable, Sendable {
    case alreadyOpen
    case listenerCancelled
    case listenerFailed(String)
}

public actor PairingServer {
    public typealias CodeHandler = @Sendable (String, Date) -> Void
    public typealias PairedHandler = @Sendable (PairedPeer) -> Void

    private let receiverID: String
    private let serviceType: String?
    private let requestedPort: NWEndpoint.Port
    private let requireWiFi: Bool
    private let queue = DispatchQueue(label: "com.bizshuk.iphonesync.pairing-listener")

    private var listener: NWListener?
    private var activeChannel: PairingChannel?
    private var expiry: Date?
    private var windowTask: Task<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var onCode: CodeHandler?
    private var onPaired: PairedHandler?
    private var displayName = ""

    public init(
        receiverID: String,
        serviceType: String? = SyncConstants.pairingServiceType,
        port: NWEndpoint.Port = .any,
        requireWiFi: Bool = false
    ) {
        self.receiverID = receiverID
        self.serviceType = serviceType
        self.requestedPort = port
        self.requireWiFi = requireWiFi
    }

    public var localPort: NWEndpoint.Port? {
        guard let port = listener?.port, port.rawValue != 0 else { return nil }
        return port
    }

    public func open(
        window: TimeInterval = 120,
        displayName: String,
        onCode: @escaping CodeHandler,
        onPaired: @escaping PairedHandler
    ) async throws {
        guard listener == nil else { throw PairingServerError.alreadyOpen }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if requireWiFi {
            parameters.requiredInterfaceType = .wifi
        }

        let listener = try NWListener(using: parameters, on: requestedPort)
        if let serviceType {
            listener.service = NWListener.Service(
                name: receiverID,
                type: serviceType,
                txtRecord: NWTXTRecord([
                    "id": receiverID,
                    "name": displayName,
                    "pairing": "1",
                    "version": String(SyncConstants.protocolVersion),
                ])
            )
        }
        self.listener = listener
        self.onCode = onCode
        self.onPaired = onPaired
        self.displayName = displayName
        let expiry = Date().addingTimeInterval(window)
        self.expiry = expiry

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListener(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                openContinuation = continuation
                listener.start(queue: queue)
            }
        } catch {
            close()
            throw error
        }

        windowTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, window) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.expire(at: expiry)
        }
    }

    public func close() {
        windowTask?.cancel()
        windowTask = nil
        activeChannel?.cancel()
        activeChannel = nil
        listener?.cancel()
        listener = nil
        expiry = nil
        onCode = nil
        onPaired = nil
    }

    private func handleListener(_ state: NWListener.State) {
        switch state {
        case .ready:
            openContinuation?.resume()
            openContinuation = nil
        case let .failed(error):
            openContinuation?.resume(
                throwing: PairingServerError.listenerFailed(String(describing: error))
            )
            openContinuation = nil
            close()
        case .cancelled:
            openContinuation?.resume(throwing: PairingServerError.listenerCancelled)
            openContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) async {
        guard activeChannel == nil else {
            connection.cancel()
            return
        }
        let channel = PairingChannel(connection)
        activeChannel = channel

        do {
            let peer = try await performPairing(on: channel)
            onPaired?(peer)
            close()
        } catch {
            channel.cancel()
            if activeChannel === channel {
                activeChannel = nil
            }
        }
    }

    private func performPairing(on channel: PairingChannel) async throws -> PairedPeer {
        try await channel.start()
        guard case let .hello(clientHello) = try await channel.receive() else {
            throw PairingProtocolError.invalidMessage
        }

        let material = PairingCrypto.makeMaterial()
        try await channel.send(.hello(PairingHello(
            deviceID: receiverID,
            displayName: displayName,
            publicKey: material.publicKey,
            nonce: material.nonce
        )))
        let transcript = PairingTranscript(
            receiverID: receiverID,
            initiatorPublicKey: clientHello.publicKey,
            receiverPublicKey: material.publicKey,
            initiatorNonce: clientHello.nonce,
            receiverNonce: material.nonce
        )
        let secret = try PairingCrypto.derive(
            local: material,
            peerPublicKey: clientHello.publicKey,
            transcript: transcript
        )
        onCode?(secret.verificationCode, expiry ?? Date())

        guard case let .confirm(proof) = try await channel.receive() else {
            throw PairingProtocolError.invalidMessage
        }
        guard PairingProof.equals(proof, secret.clientProof) else {
            try? await channel.send(.rejected(reason: "invalid-proof"))
            throw PairingProtocolError.invalidMessage
        }
        try await channel.send(.accepted(proof: secret.serverProof))
        return PairedPeer(
            id: clientHello.deviceID,
            displayName: clientHello.displayName,
            pskIdentity: secret.pskIdentity,
            psk: secret.psk,
            sourceBindingID: nil
        )
    }

    private func expire(at expectedExpiry: Date) {
        guard expiry == expectedExpiry else { return }
        close()
    }
}
