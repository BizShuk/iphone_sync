import Foundation
import MacReceiverKit
import Network
import SyncCore
import Testing

extension MacReceiverKitTestSuite {

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
    #expect(relativePath.hasPrefix("iPhoneSync/Camera Roll/"))
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

@Test
func sameResourceInMultipleAlbumsCreatesCorrespondingFolders() async throws {
    let bytes = Data("photo in two albums".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
    let sourceURL = harness.directory.appendingPathComponent("multi-album-source.bin")
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

    func makeClient() -> SyncClient {
        SyncClient(connection: FramedConnection(NWConnection(
            host: "127.0.0.1",
            port: port,
            using: PSKTLSParameters.make(
                psk: psk,
                identity: identity,
                role: .client,
                requireWiFi: false
            )
        )))
    }

    let first = makeClient()
    let binding = try await first.openSession(
        albumID: "album-1",
        albumName: "Camera Roll",
        sourceBindingID: nil
    )
    guard case let .committed(firstPath) = try await first.sendResource(
        harness.offer,
        fileURL: sourceURL
    ) else {
        Issue.record("first album transfer did not commit")
        return
    }
    _ = try await first.finish()

    let second = makeClient()
    _ = try await second.openSession(
        albumID: "album-2",
        albumName: "Other Album",
        sourceBindingID: binding
    )
    guard case let .committed(secondPath) = try await second.sendResource(
        harness.offer,
        fileURL: sourceURL
    ) else {
        Issue.record("second album transfer did not commit")
        return
    }
    #expect(
        try await second.finish()
            == SyncSummary(added: 1, existing: 0, notLocal: 0, failed: 0)
    )

    #expect(firstPath.hasPrefix("iPhoneSync/Camera Roll/"))
    #expect(secondPath.hasPrefix("iPhoneSync/Other Album/"))
    #expect(firstPath != secondPath)
    #expect(try Data(contentsOf: harness.directory.appendingPathComponent(firstPath)) == bytes)
    #expect(try Data(contentsOf: harness.directory.appendingPathComponent(secondPath)) == bytes)
    #expect(await listener.recordedFailures().isEmpty)
}

@Test
func unavailableAlbumFolderRejectsSessionWithUsefulReceiverError() async throws {
    let harness = try ReceiverHarness()
    try Data("conflicting file".utf8).write(
        to: harness.receivingRootURL
    )
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
    let client = SyncClient(connection: FramedConnection(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .client,
            requireWiFi: false
        )
    )))
    defer { Task { await client.cancel() } }

    await #expect(throws: SyncClientError.sessionRejected("destination-unavailable")) {
        _ = try await client.openSession(
            albumID: "album-1",
            albumName: "Camera Roll",
            sourceBindingID: nil
        )
    }
    try await Task.sleep(for: .milliseconds(20))

    let failures = await listener.recordedFailures()
    #expect(failures.count == 1)
    #expect(failures[0].contains("album destination folder is unavailable"))
    #expect(failures[0].contains("conflicts with a file, symlink, or unsafe path"))
}

@Test
func secondIntegrityFailureIsNotRetryable() async throws {
    let bytes = Data("photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
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
    let connection = FramedConnection(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .client,
            requireWiFi: false
        )
    ))
    defer { connection.cancel() }
    try await connection.start()
    let sessionID = UUID()
    try await connection.send(try SyncFrame.control(
        .session(.request(
            albumID: "album-1",
            albumName: "Camera Roll",
            sourceBindingID: nil
        )),
        requestID: sessionID
    ))
    #expect(
        try await connection.receive().controlMessage()
            == .session(.accepted(sourceBindingID: "binding-1"))
    )

    let badDescriptor = ResourceDescriptor(
        assetLocalIdentifier: harness.offer.descriptor.assetLocalIdentifier,
        resourceType: harness.offer.descriptor.resourceType,
        originalFilename: harness.offer.descriptor.originalFilename,
        duplicateOrdinal: harness.offer.descriptor.duplicateOrdinal,
        contentHash: String(repeating: "0", count: 64),
        expectedSize: Int64(bytes.count),
        creationDate: harness.offer.descriptor.creationDate,
        role: harness.offer.descriptor.role
    )
    let offer = ResourceOffer(
        resourceID: harness.offer.resourceID,
        descriptor: badDescriptor
    )

    func sendAttempt() async throws -> TransferResult {
        let requestID = UUID()
        try await connection.send(try SyncFrame.control(.offer(offer), requestID: requestID))
        let decision = try await connection.receive()
        #expect(decision.requestID == requestID)
        #expect(try decision.controlMessage() == .decision(.start(offset: 0)))
        try await connection.send(try SyncFrame(
            kind: .chunk,
            requestID: requestID,
            offset: 0,
            payload: bytes
        ))
        let response = try await connection.receive()
        guard case let .result(result) = try response.controlMessage() else {
            throw SyncServerSessionError.protocolViolation
        }
        return result
    }

    guard case let .failed(code1, _, retryable1) = try await sendAttempt() else {
        Issue.record("first integrity attempt did not fail")
        return
    }
    guard case let .failed(code2, _, retryable2) = try await sendAttempt() else {
        Issue.record("second integrity attempt did not fail")
        return
    }
    #expect(code1 == .integrity)
    #expect(retryable1)
    #expect(code2 == .integrity)
    #expect(!retryable2)
}

@Test
func recoveredIntegrityRetryDoesNotCountAsFailedResource() async throws {
    let expectedBytes = Data("photo".utf8)
    let corruptedBytes = Data("wrong".utf8)
    let harness = try ReceiverHarness(bytes: expectedBytes)
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
    let connection = FramedConnection(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .client,
            requireWiFi: false
        )
    ))
    defer { connection.cancel() }
    try await connection.start()

    let sessionID = UUID()
    try await connection.send(try SyncFrame.control(
        .session(.request(
            albumID: "album-1",
            albumName: "Camera Roll",
            sourceBindingID: nil
        )),
        requestID: sessionID
    ))
    #expect(
        try await connection.receive().controlMessage()
            == .session(.accepted(sourceBindingID: "binding-1"))
    )

    func sendAttempt(_ bytes: Data) async throws -> TransferResult {
        let requestID = UUID()
        try await connection.send(try SyncFrame.control(
            .offer(harness.offer),
            requestID: requestID
        ))
        #expect(
            try await connection.receive().controlMessage()
                == .decision(.start(offset: 0))
        )
        try await connection.send(try SyncFrame(
            kind: .chunk,
            requestID: requestID,
            offset: 0,
            payload: bytes
        ))
        guard case let .result(result) = try await connection.receive().controlMessage() else {
            throw SyncServerSessionError.protocolViolation
        }
        return result
    }

    guard case let .failed(.integrity, _, retryable) = try await sendAttempt(corruptedBytes) else {
        Issue.record("corrupted attempt did not fail integrity verification")
        return
    }
    #expect(retryable)
    guard case .committed = try await sendAttempt(expectedBytes) else {
        Issue.record("correct retry did not commit")
        return
    }

    let finishID = UUID()
    try await connection.send(try SyncFrame.control(
        .session(.finished),
        requestID: finishID
    ))
    #expect(
        try await connection.receive().controlMessage()
            == .result(.sessionCompleted(SyncSummary(
                added: 1,
                existing: 0,
                notLocal: 0,
                failed: 0
            )))
    )
    #expect(await listener.recordedFailures().isEmpty)
}

}
