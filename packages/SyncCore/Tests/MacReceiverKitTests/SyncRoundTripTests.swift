import Foundation
import MacReceiverKit
import Network
import SyncCore
import Testing

@Test
func roundTripSecondSyncSkipsCommittedResource() async throws {
    let bytes = Data(repeating: 0x5a, count: SyncConstants.chunkSize * 2 + 17)
    let harness = try ReceiverHarness(bytes: bytes)
    let sourceURL = harness.directory.appendingPathComponent("source.bin")
    try bytes.write(to: sourceURL)

    let psk = Data(repeating: 0x42, count: 32)
    let identity = Data("phone-1".utf8)
    let listener = try SyncTestListener(
        parameters: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .server,
            requireWiFi: false
        ),
        manifest: harness.manifest,
        destinationRoot: harness.directory
    )
    let port = try await listener.start()
    defer { Task { await listener.stop() } }

    let first = SyncClient(connection: FramedConnection(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .client,
            requireWiFi: false
        )
    )))
    let binding = try await first.openSession(
        albumID: "album-1",
        albumName: "Camera Roll",
        sourceBindingID: nil
    )
    #expect(binding == "binding-1")
    let firstResult = try await first.sendResource(harness.offer, fileURL: sourceURL)
    let firstSummary = try await first.finish()

    guard case let .committed(relativePath) = firstResult else {
        Issue.record("first transfer did not commit")
        return
    }
    #expect(firstSummary == SyncSummary(added: 1, existing: 0, notLocal: 0, failed: 0))
    #expect(try Data(contentsOf: harness.directory.appendingPathComponent(relativePath)) == bytes)

    let second = SyncClient(connection: FramedConnection(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .client,
            requireWiFi: false
        )
    )))
    _ = try await second.openSession(
        albumID: "album-1",
        albumName: "Camera Roll",
        sourceBindingID: binding
    )
    #expect(try await second.sendResource(harness.offer, fileURL: sourceURL) == .skipped)
    #expect(
        try await second.finish()
            == SyncSummary(added: 0, existing: 1, notLocal: 0, failed: 0)
    )
    #expect(await listener.recordedFailures().isEmpty)
}
