import Foundation
import Network

public enum PairingClientError: Error, Equatable, Sendable {
    case codeMismatch(remainingAttempts: Int)
    case invalidServerProof
    case protocolViolation
    case rejected(String)
    case tooManyAttempts
}

public struct PairingClient: Sendable {
    public let deviceID: String
    public let requireWiFi: Bool

    public init(deviceID: String, requireWiFi: Bool = true) {
        self.deviceID = deviceID
        self.requireWiFi = requireWiFi
    }

    public func begin(
        endpoint: NWEndpoint,
        deviceName: String
    ) async throws -> PendingPairing {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if requireWiFi {
            parameters.requiredInterfaceType = .wifi
        }

        let channel = PairingChannel(NWConnection(to: endpoint, using: parameters))
        do {
            try await channel.start()
            let material = PairingCrypto.makeMaterial()
            try await channel.send(.hello(PairingHello(
                deviceID: deviceID,
                displayName: deviceName,
                publicKey: material.publicKey,
                nonce: material.nonce
            )))

            guard case let .hello(serverHello) = try await channel.receive() else {
                throw PairingClientError.protocolViolation
            }
            let transcript = PairingTranscript(
                receiverID: serverHello.deviceID,
                initiatorPublicKey: material.publicKey,
                receiverPublicKey: serverHello.publicKey,
                initiatorNonce: material.nonce,
                receiverNonce: serverHello.nonce
            )
            let secret = try PairingCrypto.derive(
                local: material,
                peerPublicKey: serverHello.publicKey,
                transcript: transcript
            )
            return PendingPairing(
                channel: channel,
                server: serverHello,
                secret: secret
            )
        } catch {
            channel.cancel()
            throw error
        }
    }
}

public actor PendingPairing {
    private let channel: PairingChannel
    private let server: PairingHello
    private let secret: DerivedPairingSecret
    private var remainingAttempts = 5
    private var completed = false

    init(channel: PairingChannel, server: PairingHello, secret: DerivedPairingSecret) {
        self.channel = channel
        self.server = server
        self.secret = secret
    }

    public func confirm(code: String) async throws -> PairedPeer {
        guard !completed else {
            throw PairingClientError.protocolViolation
        }
        guard remainingAttempts > 0 else {
            throw PairingClientError.tooManyAttempts
        }
        guard code == secret.verificationCode else {
            remainingAttempts -= 1
            if remainingAttempts == 0 {
                channel.cancel()
            }
            throw PairingClientError.codeMismatch(remainingAttempts: remainingAttempts)
        }

        do {
            try await channel.send(.confirm(proof: secret.clientProof))
            switch try await channel.receive() {
            case let .accepted(proof):
                guard PairingProof.equals(proof, secret.serverProof) else {
                    throw PairingClientError.invalidServerProof
                }
            case let .rejected(reason):
                throw PairingClientError.rejected(reason)
            default:
                throw PairingClientError.protocolViolation
            }
            completed = true
            channel.cancel()
            return PairedPeer(
                id: server.deviceID,
                displayName: server.displayName,
                pskIdentity: secret.pskIdentity,
                psk: secret.psk,
                sourceBindingID: nil
            )
        } catch {
            channel.cancel()
            throw error
        }
    }
}
