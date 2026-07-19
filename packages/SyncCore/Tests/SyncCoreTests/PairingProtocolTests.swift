import Foundation
import Network
import Testing
@testable import SyncCore

@Test
func pairingConfirmationWireMessageContainsProofButNoCode() throws {
    let encoded = try JSONEncoder().encode(
        PairingMessage.confirm(proof: Data(repeating: 0x42, count: 32))
    )
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(json.contains("proof"))
    #expect(!json.lowercased().contains("code"))
}

@Test
func pairingLoopbackRejectsLocalMismatchThenCreatesSameTrust() async throws {
    let recorder = PairingRecorder()
    let server = PairingServer(
        receiverID: "mac-1",
        serviceType: nil,
        port: .any,
        requireWiFi: false
    )
    try await server.open(
        window: 10,
        displayName: "Studio Mac",
        onCode: { code, _ in Task { await recorder.record(code: code) } },
        onPaired: { peer in Task { await recorder.record(peer: peer) } }
    )
    defer { Task { await server.close() } }
    let port = try #require(await server.localPort)

    let client = PairingClient(deviceID: "phone-1", requireWiFi: false)
    let pending = try await client.begin(
        endpoint: .hostPort(host: "127.0.0.1", port: port),
        deviceName: "My iPhone"
    )
    let code = await recorder.code()
    let wrongCode = code == "000000" ? "000001" : "000000"

    await #expect(throws: PairingClientError.codeMismatch(remainingAttempts: 4)) {
        try await pending.confirm(code: wrongCode)
    }

    let mac = try await pending.confirm(code: code)
    let phone = await recorder.peer()

    #expect(mac.id == "mac-1")
    #expect(mac.displayName == "Studio Mac")
    #expect(phone.id == "phone-1")
    #expect(phone.displayName == "My iPhone")
    #expect(mac.psk == phone.psk)
    #expect(mac.pskIdentity == phone.pskIdentity)
}

@Test
func wrongPairingProofIsRejected() async throws {
    let recorder = PairingRecorder()
    let server = PairingServer(
        receiverID: "mac-1",
        serviceType: nil,
        port: .any,
        requireWiFi: false
    )
    try await server.open(
        window: 5,
        displayName: "Studio Mac",
        onCode: { _, _ in },
        onPaired: { peer in Task { await recorder.record(peer: peer) } }
    )
    defer { Task { await server.close() } }
    let port = try #require(await server.localPort)
    let channel = PairingChannel(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: .tcp
    ))
    defer { channel.cancel() }
    try await channel.start()
    let material = PairingCrypto.makeMaterial()
    try await channel.send(.hello(PairingHello(
        deviceID: "phone-1",
        displayName: "My iPhone",
        publicKey: material.publicKey,
        nonce: material.nonce
    )))
    guard case .hello = try await channel.receive() else {
        Issue.record("server did not return pairing hello")
        return
    }
    try await channel.send(.confirm(proof: Data(repeating: 0, count: 32)))

    #expect(try await channel.receive() == .rejected(reason: "invalid-proof"))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await !recorder.hasPeer())
}

@Test
func expiredPairingWindowClosesListener() async throws {
    let server = PairingServer(
        receiverID: "mac-1",
        serviceType: nil,
        port: .any,
        requireWiFi: false
    )
    try await server.open(
        window: 0.01,
        displayName: "Studio Mac",
        onCode: { _, _ in },
        onPaired: { _ in }
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(await server.localPort == nil)
}
