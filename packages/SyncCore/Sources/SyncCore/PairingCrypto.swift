import CryptoKit
import Foundation

public struct PairingMaterial {
    fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKey: Data
    public let nonce: Data

    fileprivate init(privateKey: Curve25519.KeyAgreement.PrivateKey, nonce: Data) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey.rawRepresentation
        self.nonce = nonce
    }
}

public struct PairingTranscript: Codable, Equatable, Sendable {
    public let receiverID: String
    public let initiatorPublicKey: Data
    public let receiverPublicKey: Data
    public let initiatorNonce: Data
    public let receiverNonce: Data
    public let protocolVersion: UInt16

    public init(
        receiverID: String,
        initiatorPublicKey: Data,
        receiverPublicKey: Data,
        initiatorNonce: Data,
        receiverNonce: Data,
        protocolVersion: UInt16 = SyncConstants.protocolVersion
    ) {
        self.receiverID = receiverID
        self.initiatorPublicKey = initiatorPublicKey
        self.receiverPublicKey = receiverPublicKey
        self.initiatorNonce = initiatorNonce
        self.receiverNonce = receiverNonce
        self.protocolVersion = protocolVersion
    }

    fileprivate var canonicalData: Data {
        var result = Data()
        append(Data([UInt8(protocolVersion >> 8), UInt8(protocolVersion & 0xff)]), to: &result)
        append(Data(receiverID.utf8), to: &result)
        append(initiatorPublicKey, to: &result)
        append(receiverPublicKey, to: &result)
        append(initiatorNonce, to: &result)
        append(receiverNonce, to: &result)
        return result
    }

    private func append(_ field: Data, to result: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(field)
    }
}

public struct DerivedPairingSecret: Equatable, Sendable {
    public let verificationCode: String
    public let psk: Data
    public let pskIdentity: Data
    public let clientProof: Data
    public let serverProof: Data

    public init(
        verificationCode: String,
        psk: Data,
        pskIdentity: Data,
        clientProof: Data,
        serverProof: Data
    ) {
        self.verificationCode = verificationCode
        self.psk = psk
        self.pskIdentity = pskIdentity
        self.clientProof = clientProof
        self.serverProof = serverProof
    }
}

public enum PairingCryptoError: Error, Equatable {
    case invalidPublicKey
    case invalidNonce
    case transcriptKeyMismatch
}

public enum PairingCrypto {
    public static func makeMaterial() -> PairingMaterial {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return PairingMaterial(privateKey: privateKey, nonce: nonce)
    }

    public static func derive(
        local: PairingMaterial,
        peerPublicKey: Data,
        transcript: PairingTranscript
    ) throws -> DerivedPairingSecret {
        guard transcript.initiatorNonce.count == 32, transcript.receiverNonce.count == 32 else {
            throw PairingCryptoError.invalidNonce
        }
        let transcriptKeys = [transcript.initiatorPublicKey, transcript.receiverPublicKey]
        guard transcriptKeys.contains(local.publicKey), transcriptKeys.contains(peerPublicKey) else {
            throw PairingCryptoError.transcriptKeyMismatch
        }

        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        } catch {
            throw PairingCryptoError.invalidPublicKey
        }
        let sharedSecret = try local.privateKey.sharedSecretFromKeyAgreement(with: peer)
        let transcriptHash = Data(SHA256.hash(data: transcript.canonicalData))

        let sasBytes = derive(
            sharedSecret: sharedSecret,
            salt: transcriptHash,
            label: "iphonesync-sas-v1",
            count: 3
        )
        let sasValue = (
            (Int(sasBytes[0]) << 12)
                | (Int(sasBytes[1]) << 4)
                | (Int(sasBytes[2]) >> 4)
        ) % 1_000_000

        return DerivedPairingSecret(
            verificationCode: String(format: "%06d", sasValue),
            psk: derive(sharedSecret: sharedSecret, salt: transcriptHash, label: "iphonesync-psk-v1", count: 32),
            pskIdentity: derive(sharedSecret: sharedSecret, salt: transcriptHash, label: "iphonesync-identity-v1", count: 32),
            clientProof: derive(sharedSecret: sharedSecret, salt: transcriptHash, label: "iphonesync-client-proof-v1", count: 32),
            serverProof: derive(sharedSecret: sharedSecret, salt: transcriptHash, label: "iphonesync-server-proof-v1", count: 32)
        )
    }

    private static func derive(
        sharedSecret: SharedSecret,
        salt: Data,
        label: String,
        count: Int
    ) -> Data {
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(label.utf8),
            outputByteCount: count
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
