import Foundation
import Testing
@testable import SyncCore

@Test
func bothSidesDeriveSameCodePSKAndProofs() throws {
    let mac = PairingCrypto.makeMaterial()
    let phone = PairingCrypto.makeMaterial()
    let transcript = PairingTranscript(
        receiverID: "mac-1",
        initiatorPublicKey: phone.publicKey,
        receiverPublicKey: mac.publicKey,
        initiatorNonce: phone.nonce,
        receiverNonce: mac.nonce
    )

    let macSecret = try PairingCrypto.derive(
        local: mac,
        peerPublicKey: phone.publicKey,
        transcript: transcript
    )
    let phoneSecret = try PairingCrypto.derive(
        local: phone,
        peerPublicKey: mac.publicKey,
        transcript: transcript
    )

    #expect(macSecret.verificationCode == phoneSecret.verificationCode)
    #expect(macSecret.psk == phoneSecret.psk)
    #expect(macSecret.pskIdentity == phoneSecret.pskIdentity)
    #expect(macSecret.clientProof == phoneSecret.clientProof)
    #expect(macSecret.serverProof == phoneSecret.serverProof)
    #expect(macSecret.verificationCode.count == 6)
    #expect(macSecret.verificationCode.allSatisfy { $0.isNumber })
}

@Test
func transcriptTamperingChangesDerivedSecret() throws {
    let mac = PairingCrypto.makeMaterial()
    let phone = PairingCrypto.makeMaterial()
    let original = PairingTranscript(
        receiverID: "mac-1",
        initiatorPublicKey: phone.publicKey,
        receiverPublicKey: mac.publicKey,
        initiatorNonce: phone.nonce,
        receiverNonce: mac.nonce
    )
    let tampered = PairingTranscript(
        receiverID: "other-mac",
        initiatorPublicKey: phone.publicKey,
        receiverPublicKey: mac.publicKey,
        initiatorNonce: phone.nonce,
        receiverNonce: mac.nonce
    )

    let first = try PairingCrypto.derive(local: mac, peerPublicKey: phone.publicKey, transcript: original)
    let second = try PairingCrypto.derive(local: mac, peerPublicKey: phone.publicKey, transcript: tampered)

    #expect(first.psk != second.psk)
    #expect(first.clientProof != second.clientProof)
}

@Test
func pairedPeerKeychainRoundTrips() throws {
    let account = "test-\(UUID().uuidString)"
    let store = KeychainSecretStore(service: "com.bizshuk.iphonesync.tests")
    defer { try? store.delete(account: account) }
    let peer = PairedPeer(
        id: "mac-1",
        displayName: "Studio Mac",
        pskIdentity: Data("phone-1".utf8),
        psk: Data(repeating: 0x42, count: 32),
        sourceBindingID: nil
    )

    try store.save(peer, account: account)

    #expect(try store.load(PairedPeer.self, account: account) == peer)
    try store.delete(account: account)
    #expect(try store.load(PairedPeer.self, account: account) == nil)
}
