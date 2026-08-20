import Foundation
import MacReceiverKit
import Network
import SyncCore
import Testing

extension MacReceiverKitTestSuite {

@Test
func validPSKHalfOpenSessionTimesOutBeforeAcceptance() async throws {
    let harness = try ReceiverHarness()
    let psk = Data(repeating: 0x42, count: 32)
    let identity = Data("phone-1".utf8)
    let acceptanceRecorder = SessionAcceptanceRecorder()
    let listener = try SyncTestListener(
        parameters: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .server,
            requireWiFi: false
        ),
        manifest: harness.manifest,
        destinationRoot: harness.directory,
        openingTimeout: .milliseconds(250),
        onAccepted: {
            await acceptanceRecorder.record()
        }
    )
    let port = try await listener.start()
    defer { Task { await listener.stop() } }

    let halfOpenConnection = FramedConnection(NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .client,
            requireWiFi: false
        )
    ))
    defer { halfOpenConnection.cancel() }
    try await halfOpenConnection.start()

    for _ in 0..<100 {
        if !(await listener.recordedSessionErrors()).isEmpty {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await listener.recordedSessionErrors() == [.openingTimedOut])
    #expect(await acceptanceRecorder.count == 0)
    await #expect(throws: (any Error).self) {
        _ = try await halfOpenConnection.receive()
    }

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
    _ = try await client.openSession(
        albumID: "album-1",
        albumName: "Camera Roll",
        sourceBindingID: nil
    )
    _ = try await client.finish()
    #expect(await acceptanceRecorder.count == 1)
}

/// A locked or suspended iPhone stops sending mid-session without closing the
/// TLS connection. The receiver must abandon that session instead of blocking
/// on `receive()` forever, otherwise its single active-connection slot stays
/// taken and every following sync is rejected.
@Test
func openSessionThatStopsSendingIsAbandonedAndTheNextClientCanConnect() async throws {
    let harness = try ReceiverHarness()
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
        destinationRoot: harness.directory,
        idleTimeout: .milliseconds(250)
    )
    let port = try await listener.start()
    defer { Task { await listener.stop() } }

    func makeConnection() -> FramedConnection {
        FramedConnection(NWConnection(
            host: "127.0.0.1",
            port: port,
            using: PSKTLSParameters.make(
                psk: psk,
                identity: identity,
                role: .client,
                requireWiFi: false
            )
        ))
    }

    // Open a valid session, then go silent the way a suspended app does.
    let silent = SyncClient(connection: makeConnection())
    _ = try await silent.openSession(
        albumID: "album-1",
        albumName: "Camera Roll",
        sourceBindingID: nil
    )

    for _ in 0..<100 {
        if !(await listener.recordedSessionErrors()).isEmpty {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await listener.recordedSessionErrors() == [.idleTimedOut])

    // The receiver is free again, so the next run resumes normally.
    let next = SyncClient(connection: makeConnection())
    let binding = try await next.openSession(
        albumID: "album-1",
        albumName: "Camera Roll",
        sourceBindingID: nil
    )
    #expect(binding == "binding-1")
    _ = try await next.finish()
}

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
func roundTripEmitsSessionAndResourceOperations() async throws {
    let bytes = Data("logged photo".utf8)
    let harness = try ReceiverHarness(bytes: bytes)
    let sourceURL = harness.directory.appendingPathComponent("logged-source.bin")
    try bytes.write(to: sourceURL)
    let psk = Data(repeating: 0x42, count: 32)
    let identity = Data("phone-1".utf8)
    let recorder = ServerOperationRecorder()
    let listener = try SyncTestListener(
        parameters: PSKTLSParameters.make(
            psk: psk,
            identity: identity,
            role: .server,
            requireWiFi: false
        ),
        manifest: harness.manifest,
        destinationRoot: harness.directory,
        onEvent: { event in
            await recorder.record(event)
        }
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

    _ = try await client.openSession(
        albumID: "album-1",
        albumName: "Camera Roll",
        sourceBindingID: nil
    )
    _ = try await client.sendResource(harness.offer, fileURL: sourceURL)
    _ = try await client.finish()

    for _ in 0..<100 {
        if await recorder.events.count >= 6 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    let events = await recorder.events
    #expect(events.contains {
        $0.level == .success
            && $0.category == "Session"
            && $0.message.contains("Accepted album")
    })
    #expect(events.contains {
        $0.level == .info
            && $0.category == "Resource"
            && $0.message.contains("Offered “IMG_0001.HEIC”")
    })
    #expect(events.contains {
        $0.level == .success
            && $0.category == "Resource"
            && $0.message.contains("Committed “IMG_0001.HEIC”")
    })
    #expect(events.last?.message.contains("1 added") == true)
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

private actor SessionAcceptanceRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor ServerOperationRecorder {
    private(set) var events: [OperationLogEvent] = []

    func record(_ event: OperationLogEvent) {
        events.append(event)
    }
}
