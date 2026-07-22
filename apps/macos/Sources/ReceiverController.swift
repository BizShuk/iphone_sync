import Foundation
import MacReceiverKit
import Network
import SwiftData
import SyncCore

@MainActor
final class ReceiverController {
    enum RuntimeState {
        case ready
        case receiving
        case error(String)
    }

    private static let pairedPeerAccount = "paired-peer"

    private let receiverID: String
    private let keychain = KeychainSecretStore()
    private let modelContainer: ModelContainer
    private let listenerQueue = DispatchQueue(label: "com.shuk.iphonesync.mac-listener")
    private let onPairingCode: (String, Date) -> Void
    private let onPaired: (PairedPeer) -> Void
    private let onRuntimeState: (RuntimeState) -> Void
    private let onSummary: (SyncSummary) -> Void

    private var pairingServer: PairingServer?
    private var normalListener: NWListener?
    private var activeConnection: FramedConnection?
    private var sessionTask: Task<Void, Never>?

    init(
        receiverID: String,
        onPairingCode: @escaping (String, Date) -> Void,
        onPaired: @escaping (PairedPeer) -> Void,
        onRuntimeState: @escaping (RuntimeState) -> Void,
        onSummary: @escaping (SyncSummary) -> Void
    ) throws {
        self.receiverID = receiverID
        self.onPairingCode = onPairingCode
        self.onPaired = onPaired
        self.onRuntimeState = onRuntimeState
        self.onSummary = onSummary
        self.modelContainer = try ModelContainer(
            for: TransferRecord.self,
            SourceRecord.self,
            AlbumRecord.self
        )
    }

    func loadPairedPeer() throws -> PairedPeer? {
        try keychain.load(PairedPeer.self, account: Self.pairedPeerAccount)
    }

    func openPairingWindow(displayName: String) async throws {
        stopReceiver()
        if let pairingServer {
            await pairingServer.close()
        }

        let server = PairingServer(receiverID: receiverID)
        pairingServer = server
        try await server.open(
            window: 120,
            displayName: displayName,
            onCode: { [weak self] code, expiresAt in
                Task { @MainActor in
                    self?.onPairingCode(code, expiresAt)
                }
            },
            onPaired: { [weak self] peer in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        try self.keychain.save(peer, account: Self.pairedPeerAccount)
                        self.onPaired(peer)
                    } catch {
                        self.onRuntimeState(.error(error.localizedDescription))
                    }
                }
            }
        )
    }

    func startReceiver(
        destination: URL,
        peer: PairedPeer,
        sourceBindingID: String,
        displayName: String
    ) throws {
        stopReceiver()
        let parameters = PSKTLSParameters.make(
            psk: peer.psk,
            identity: peer.pskIdentity,
            role: .server,
            requireWiFi: false
        )
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: receiverID,
            type: SyncConstants.normalServiceType,
            txtRecord: NWTXTRecord([
                "id": receiverID,
                "name": displayName,
                "pairing": "0",
                "version": String(SyncConstants.protocolVersion),
            ])
        )
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onRuntimeState(.ready)
                case let .failed(error):
                    self.onRuntimeState(.error(error.localizedDescription))
                    self.stopReceiver()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(
                    connection,
                    destination: destination,
                    sourceBindingID: sourceBindingID
                )
            }
        }
        normalListener = listener
        listener.start(queue: listenerQueue)
    }

    func forgetPhone() async throws {
        stopReceiver()
        if let pairingServer {
            await pairingServer.close()
            self.pairingServer = nil
        }
        try keychain.delete(account: Self.pairedPeerAccount)
    }

    func stopReceiver() {
        normalListener?.cancel()
        normalListener = nil
        activeConnection?.cancel()
        activeConnection = nil
        sessionTask?.cancel()
        sessionTask = nil
    }

    func stopAll() async {
        stopReceiver()
        if let pairingServer {
            await pairingServer.close()
            self.pairingServer = nil
        }
    }

    private func accept(
        _ nwConnection: NWConnection,
        destination: URL,
        sourceBindingID: String
    ) {
        guard activeConnection == nil else {
            nwConnection.cancel()
            return
        }
        let connection = FramedConnection(nwConnection)
        activeConnection = connection
        onRuntimeState(.receiving)
        let container = modelContainer
        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeConnection = nil
                self.sessionTask = nil
            }
            do {
                let manifest = ManifestStore(
                    container: container,
                    sourceBindingID: sourceBindingID
                )
                let writer = DestinationWriter(
                    destinationRoot: destination,
                    manifest: manifest
                )
                let session = SyncServerSession(manifest: manifest, writer: writer)
                let summary = try await session.run(connection: connection)
                self.onSummary(summary)
                self.onRuntimeState(.ready)
            } catch {
                if !Task.isCancelled {
                    self.onRuntimeState(.error(error.localizedDescription))
                }
            }
        }
    }
}
