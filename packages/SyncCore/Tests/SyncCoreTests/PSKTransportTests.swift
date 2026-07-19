import Foundation
import Network
import Testing
@testable import SyncCore

@Test
func tlsPSKLoopbackTransfersAFrame() async throws {
    let psk = Data(repeating: 0x42, count: 32)
    let identity = Data("phone-1".utf8)
    let listener = try NWListener(
        using: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .server,
            requireWiFi: false
        ),
        on: .any
    )
    let server = TestListener(listener)
    let port = try await server.start()
    defer { Task { await server.stop() } }

    let client = FramedConnection(
        NWConnection(
            host: "127.0.0.1",
            port: port,
            using: PSKTLSParameters.make(
                psk: psk,
                identity: identity,
                role: .client,
                requireWiFi: false
            )
        )
    )
    defer { client.cancel() }
    try await client.start()

    let requestID = UUID()
    let sent = try SyncFrame.control(
        .result(.sessionCompleted(.zero)),
        requestID: requestID
    )
    try await client.send(sent)

    #expect(try await server.receivedFrame() == sent)
}

@Test
func wrongPSKFailsTLSHandshake() async throws {
    let identity = Data("phone-1".utf8)
    let listener = try NWListener(
        using: PSKTLSParameters.make(
            psk: Data(repeating: 0x42, count: 32),
            identity: identity,
            role: .server,
            requireWiFi: false
        ),
        on: .any
    )
    let server = TestListener(listener)
    let port = try await server.start()
    defer { Task { await server.stop() } }
    let client = FramedConnection(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PSKTLSParameters.make(
            psk: Data(repeating: 0x24, count: 32),
            identity: identity,
            role: .client,
            requireWiFi: false
        )
    ))
    defer { client.cancel() }

    await #expect(throws: (any Error).self) {
        try await client.start()
    }
}
