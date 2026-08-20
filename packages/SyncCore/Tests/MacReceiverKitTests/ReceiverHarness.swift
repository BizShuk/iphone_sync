import CryptoKit
import Foundation
import MacReceiverKit
import Network
import SwiftData
import SyncCore
import Testing

@Suite(.serialized)
struct MacReceiverKitTestSuite {}

final class ReceiverHarness {
    struct Recovery {
        let offset: Int64
        let fileSize: Int64
    }

    let directory: URL
    let container: ModelContainer
    let manifest: ManifestStore
    let storageMode: DestinationStorageMode
    var writer: DestinationWriter
    let offer: ResourceOffer
    let receivingFolderName = DestinationWriter.receivingFolderName
    let albumName = "Camera Roll"
    let albumFolderName = "Camera Roll"
    let resourceRelativePath: String
    let expectedRelativePath: String

    init(
        bytes: Data = Data("photo".utf8),
        existingBytes: Data? = nil,
        storageMode: DestinationStorageMode = .albumDate
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer(
            for: TransferRecord.self, SourceRecord.self, AlbumRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        manifest = ManifestStore(container: container, sourceBindingID: "binding-1")
        self.storageMode = storageMode
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let descriptor = ResourceDescriptor(
            assetLocalIdentifier: "asset-1",
            resourceType: "photo",
            originalFilename: "IMG_0001.HEIC",
            duplicateOrdinal: 0,
            contentHash: hash,
            expectedSize: Int64(bytes.count),
            creationDate: Date(timeIntervalSince1970: 1_753_000_000),
            role: nil
        )
        let resourceID = ResourceIdentity.make(
            sourceBindingID: "binding-1",
            descriptor: descriptor
        )
        offer = ResourceOffer(resourceID: resourceID, descriptor: descriptor)
        let generatedResourcePath = try FilenamePolicy.relativePath(
            originalFilename: descriptor.originalFilename,
            resourceID: resourceID,
            role: descriptor.role,
            creationDate: descriptor.creationDate
        )
        resourceRelativePath = Self.normalizedResourcePath(
            generatedResourcePath,
            mode: storageMode
        )
        expectedRelativePath = Self.expectedRelativePath(
            receivingFolderName: receivingFolderName,
            albumFolderName: albumFolderName,
            resourceRelativePath: resourceRelativePath,
            mode: storageMode
        )
        if let existingBytes {
            let existingURL = directory.appendingPathComponent(expectedRelativePath)
            try FileManager.default.createDirectory(
                at: existingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try existingBytes.write(to: existingURL)
        }
        writer = DestinationWriter(
            destinationRoot: directory,
            manifest: manifest,
            storageMode: storageMode
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var existingURL: URL {
        directory.appendingPathComponent(expectedRelativePath)
    }

    var receivingRootURL: URL {
        directory.appendingPathComponent(receivingFolderName, isDirectory: true)
    }

    func simulateCrash() async {
        await writer.simulateCrash()
    }

    @discardableResult
    func acceptAlbum(
        id: String = "album-1",
        name: String? = nil,
        requestedBindingID: String? = nil
    ) async throws -> AcceptedAlbum {
        try await manifest.acceptSession(
            albumID: id,
            albumName: name ?? albumName,
            requestedBindingID: requestedBindingID
        )
    }

    @discardableResult
    func prepareWriter() async throws -> String {
        let accepted = try await acceptAlbum()
        return try await writer.prepareAlbumDirectory(
            named: accepted.destinationFolderName
        )
    }

    func recover() async throws -> Recovery {
        writer = DestinationWriter(
            destinationRoot: directory,
            manifest: manifest,
            storageMode: storageMode
        )
        try await prepareWriter()
        let result = try await writer.begin(offer)
        guard case let .transfer(offset, _) = result else {
            throw ReceiverHarnessError.expectedTransfer
        }
        let partialURL = try await writer.activePartialURL()
        let attributes = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        return Recovery(
            offset: offset,
            fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? -1
        )
    }

    private static func normalizedResourcePath(
        _ generatedResourcePath: String,
        mode: DestinationStorageMode
    ) -> String {
        switch mode {
        case .albumDate:
            return generatedResourcePath
        case .albumOnly, .flat:
            return URL(fileURLWithPath: generatedResourcePath).lastPathComponent
        }
    }

    private static func expectedRelativePath(
        receivingFolderName: String,
        albumFolderName: String,
        resourceRelativePath: String,
        mode: DestinationStorageMode
    ) -> String {
        switch mode {
        case .albumDate, .albumOnly:
            return "\(receivingFolderName)/\(albumFolderName)/\(resourceRelativePath)"
        case .flat:
            return "\(receivingFolderName)/\(resourceRelativePath)"
        }
    }
}

enum ReceiverHarnessError: Error {
    case expectedTransfer
}

actor SyncTestListener {
    private let listener: NWListener
    private let manifest: ManifestStore
    private let destinationRoot: URL
    private let openingTimeout: Duration
    private let idleTimeout: Duration
    private let onAccepted: SyncServerSession.AcceptedHandler?
    private let onEvent: SyncServerSession.EventHandler?
    private let queue = DispatchQueue(label: "com.shuk.iphonesync.tests.sync-listener")
    private var readyContinuation: CheckedContinuation<NWEndpoint.Port, any Error>?
    private var sessions: [Task<Void, Never>] = []
    private var failures: [String] = []
    private var sessionErrors: [SyncServerSessionError] = []

    init(
        parameters: NWParameters,
        manifest: ManifestStore,
        destinationRoot: URL,
        openingTimeout: Duration = SyncServerSession.defaultOpeningTimeout,
        idleTimeout: Duration = SyncServerSession.defaultIdleTimeout,
        onAccepted: SyncServerSession.AcceptedHandler? = nil,
        onEvent: SyncServerSession.EventHandler? = nil
    ) throws {
        listener = try NWListener(using: parameters, on: .any)
        self.manifest = manifest
        self.destinationRoot = destinationRoot
        self.openingTimeout = openingTimeout
        self.idleTimeout = idleTimeout
        self.onAccepted = onAccepted
        self.onEvent = onEvent
    }

    func start() async throws -> NWEndpoint.Port {
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        sessions.forEach { $0.cancel() }
        sessions.removeAll()
    }

    func recordedFailures() -> [String] {
        failures
    }

    func recordedSessionErrors() -> [SyncServerSessionError] {
        sessionErrors
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port, port.rawValue != 0 else { return }
            readyContinuation?.resume(returning: port)
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let manifest = manifest
        let root = destinationRoot
        let openingTimeout = openingTimeout
        let idleTimeout = idleTimeout
        let onAccepted = onAccepted
        let onEvent = onEvent
        let task = Task { [weak self] in
            do {
                let writer = DestinationWriter(destinationRoot: root, manifest: manifest)
                let session = SyncServerSession(manifest: manifest, writer: writer)
                _ = try await session.run(
                    connection: FramedConnection(connection),
                    openingTimeout: openingTimeout,
                    idleTimeout: idleTimeout,
                    onAccepted: onAccepted,
                    onEvent: onEvent
                )
            } catch {
                await self?.record(error)
            }
        }
        sessions.append(task)
    }

    private func record(_ error: any Error) {
        failures.append(error.localizedDescription)
        if let sessionError = error as? SyncServerSessionError {
            sessionErrors.append(sessionError)
        }
    }
}
