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

    private struct ReceiverConfiguration: Equatable {
        let destination: URL
        let peer: PairedPeer
        let sourceBindingID: String
        let displayName: String
    }

    private static let pairedPeerAccount = "paired-peer"
    private static let pairingWindow: TimeInterval = 120
    private static let pairingMonitorIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let maximumListenerRetryAttempts = 5
    private static let maximumListenerRetryDelay: TimeInterval = 16

    private let receiverID: String
    private let keychain = KeychainSecretStore()
    private let modelContainer: ModelContainer
    private let listenerQueue = DispatchQueue(label: "com.shuk.iphonesync.mac-listener")
    private let onPairingCode: (String, Date) -> Void
    private let onPaired: (PairedPeer) -> Void
    private let onPairingClosed: () -> Void
    private let onRuntimeState: (RuntimeState) -> Void
    private let onSummary: (SyncSummary) -> Void
    private let onOperation: (OperationLogEvent) -> Void

    private var pairingServer: PairingServer?
    private var pairingMonitorTask: Task<Void, Never>?
    private var receiverConfiguration: ReceiverConfiguration?
    private var normalListener: NWListener?
    private var normalListenerIsReady = false
    private var listenerRetryAttempt = 0
    private var listenerRetryTask: Task<Void, Never>?
    private var listenerRetryToken: UUID?
    private var activeConnection: FramedConnection?
    private var activeSessionID: UUID?
    private var sessionTask: Task<Void, Never>?

    init(
        receiverID: String,
        onPairingCode: @escaping (String, Date) -> Void,
        onPaired: @escaping (PairedPeer) -> Void,
        onPairingClosed: @escaping () -> Void,
        onRuntimeState: @escaping (RuntimeState) -> Void,
        onSummary: @escaping (SyncSummary) -> Void,
        onOperation: @escaping (OperationLogEvent) -> Void
    ) throws {
        self.receiverID = receiverID
        self.onPairingCode = onPairingCode
        self.onPaired = onPaired
        self.onPairingClosed = onPairingClosed
        self.onRuntimeState = onRuntimeState
        self.onSummary = onSummary
        self.onOperation = onOperation
        self.modelContainer = try ModelContainer(
            for: TransferRecord.self,
            SourceRecord.self,
            AlbumRecord.self
        )
    }

    func loadPairedPeer() throws -> PairedPeer? {
        try keychain.load(PairedPeer.self, account: Self.pairedPeerAccount)
    }

    var isPairingWindowOpen: Bool {
        pairingServer != nil
    }

    func openPairingWindow(displayName: String) async throws {
        guard pairingServer == nil else {
            emit(
                .info,
                category: "Pairing",
                message: "The pairing window is already open."
            )
            return
        }
        emit(
            .info,
            category: "Pairing",
            message: "Opening a two-minute pairing window."
        )
        suspendReceiverForPairing()

        let server = PairingServer(receiverID: receiverID)
        pairingServer = server
        let expiresAt = Date().addingTimeInterval(Self.pairingWindow)
        do {
            try await server.open(
                window: Self.pairingWindow,
                displayName: displayName,
                onCode: { [weak self] code, expiresAt in
                    Task { @MainActor in
                        self?.emit(
                            .success,
                            category: "Pairing",
                            message: "Pairing code ready; waiting for the iPhone."
                        )
                        self?.onPairingCode(code, expiresAt)
                    }
                },
                onPaired: { [weak self] peer in
                    Task { @MainActor in
                        guard let self, self.pairingServer === server else { return }
                        do {
                            try self.keychain.save(peer, account: Self.pairedPeerAccount)
                            await self.closePairingWindow(
                                server,
                                resumeReceiver: false
                            )
                            self.emit(
                                .success,
                                category: "Pairing",
                                message: "Paired with “\(peer.displayName)”."
                            )
                            self.onPaired(peer)
                        } catch {
                            self.onRuntimeState(.error(error.localizedDescription))
                            await self.closePairingWindow(
                                server,
                                resumeReceiver: true
                            )
                        }
                    }
                }
            )
            guard pairingServer === server else { return }
            monitorPairingWindow(server, expiresAt: expiresAt)
        } catch {
            guard pairingServer === server else { return }
            await closePairingWindow(server, resumeReceiver: true)
            throw error
        }
    }

    func startReceiver(
        destination: URL,
        peer: PairedPeer,
        sourceBindingID: String,
        displayName: String,
        forceRestart: Bool = false
    ) throws {
        let configuration = ReceiverConfiguration(
            destination: destination,
            peer: peer,
            sourceBindingID: sourceBindingID,
            displayName: displayName
        )
        let configurationChanged = receiverConfiguration != configuration
        receiverConfiguration = configuration

        if configurationChanged {
            emit(
                .info,
                category: "Receiver",
                message: "Applying a new receiver configuration."
            )
            cancelListenerRetry(resetAttempt: true)
            stopNormalListener()
            stopActiveSession()
        } else if forceRestart {
            emit(
                .info,
                category: "Receiver",
                message: "Restarting the receiver listener."
            )
            cancelListenerRetry(resetAttempt: true)
            stopNormalListener()
        }

        guard pairingServer == nil else { return }
        guard normalListener == nil, listenerRetryTask == nil else { return }

        do {
            try startNormalListener(using: configuration)
        } catch {
            handleListenerStartFailure(error, reportError: false)
            throw error
        }
    }

    func reconcileReceiver(forceRestart: Bool = false) {
        guard let configuration = receiverConfiguration else { return }
        guard pairingServer == nil else { return }

        if forceRestart {
            cancelListenerRetry(resetAttempt: true)
            stopNormalListener()
        }
        guard normalListener == nil, listenerRetryTask == nil else { return }

        do {
            try startNormalListener(using: configuration)
        } catch {
            handleListenerStartFailure(error)
        }
    }

    func cancelPairingWindow() async {
        guard let pairingServer else { return }
        emit(
            .info,
            category: "Pairing",
            message: "Pairing window cancelled."
        )
        await closePairingWindow(pairingServer, resumeReceiver: true)
    }

    func forgetPhone() async throws {
        emit(
            .info,
            category: "Pairing",
            message: "Forgetting the paired iPhone."
        )
        stopReceiver()
        if let pairingServer {
            await closePairingWindow(pairingServer, resumeReceiver: false)
        }
        try keychain.delete(account: Self.pairedPeerAccount)
        emit(
            .success,
            category: "Pairing",
            message: "Paired iPhone trust removed from Keychain."
        )
    }

    func stopReceiver() {
        if receiverConfiguration != nil
            || normalListener != nil
            || activeConnection != nil {
            emit(
                .info,
                category: "Receiver",
                message: "Stopping the receiver and active session."
            )
        }
        receiverConfiguration = nil
        cancelListenerRetry(resetAttempt: true)
        stopNormalListener()
        stopActiveSession()
    }

    func stopAll() async {
        stopReceiver()
        if let pairingServer {
            await closePairingWindow(pairingServer, resumeReceiver: false)
        }
    }

    private func startNormalListener(
        using configuration: ReceiverConfiguration
    ) throws {
        emit(
            .info,
            category: "Receiver",
            message: "Starting the authenticated Bonjour receiver listener."
        )
        let parameters = PSKTLSParameters.make(
            psk: configuration.peer.psk,
            identity: configuration.peer.pskIdentity,
            role: .server,
            requireWiFi: false
        )
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: receiverID,
            type: SyncConstants.normalServiceType,
            txtRecord: NWTXTRecord([
                "id": receiverID,
                "name": configuration.displayName,
                "pairing": "0",
                "version": String(SyncConstants.protocolVersion),
            ])
        )
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener else { return }
                self.handleListenerState(state, from: listener)
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.normalListener === listener else {
                    connection.cancel()
                    return
                }
                self.accept(
                    connection,
                    destination: configuration.destination,
                    sourceBindingID: configuration.sourceBindingID
                )
            }
        }
        normalListenerIsReady = false
        normalListener = listener
        listener.start(queue: listenerQueue)
    }

    private func handleListenerState(
        _ state: NWListener.State,
        from listener: NWListener
    ) {
        guard normalListener === listener else { return }
        switch state {
        case .ready:
            normalListenerIsReady = true
            listenerRetryAttempt = 0
            if activeConnection == nil {
                onRuntimeState(.ready)
            }
            emit(
                .success,
                category: "Receiver",
                message: "Receiver is ready for the paired iPhone."
            )
        case .waiting:
            normalListenerIsReady = false
            emit(
                .warning,
                category: "Receiver",
                message: "Receiver listener is waiting for the network."
            )
        case let .failed(error):
            normalListener = nil
            normalListenerIsReady = false
            listener.cancel()
            onRuntimeState(.error(error.localizedDescription))
            scheduleListenerRetry()
        case .cancelled:
            normalListener = nil
            normalListenerIsReady = false
            emit(
                .warning,
                category: "Receiver",
                message: "Receiver listener was cancelled unexpectedly."
            )
            scheduleListenerRetry()
        default:
            break
        }
    }

    private func handleListenerStartFailure(
        _ error: any Error,
        reportError: Bool = true
    ) {
        normalListenerIsReady = false
        if reportError {
            onRuntimeState(.error(error.localizedDescription))
        }
        scheduleListenerRetry()
    }

    private func scheduleListenerRetry() {
        guard receiverConfiguration != nil, pairingServer == nil else { return }
        guard normalListener == nil, listenerRetryTask == nil else { return }
        guard listenerRetryAttempt < Self.maximumListenerRetryAttempts else { return }

        let attempt = listenerRetryAttempt + 1
        listenerRetryAttempt = attempt
        let delay = min(
            pow(2, Double(attempt - 1)),
            Self.maximumListenerRetryDelay
        )
        let token = UUID()
        emit(
            .warning,
            category: "Receiver",
            message: "Scheduled listener retry \(attempt) of "
                + "\(Self.maximumListenerRetryAttempts) in \(Int(delay)) second(s)."
        )
        listenerRetryToken = token
        listenerRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, self.listenerRetryToken == token else { return }
            self.listenerRetryTask = nil
            self.listenerRetryToken = nil
            self.reconcileReceiver()
        }
    }

    private func cancelListenerRetry(resetAttempt: Bool) {
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        listenerRetryToken = nil
        if resetAttempt {
            listenerRetryAttempt = 0
        }
    }

    private func stopNormalListener() {
        let listener = normalListener
        normalListener = nil
        normalListenerIsReady = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
    }

    private func stopActiveSession() {
        activeSessionID = nil
        activeConnection?.cancel()
        activeConnection = nil
        sessionTask?.cancel()
        sessionTask = nil
    }

    private func suspendReceiverForPairing() {
        cancelListenerRetry(resetAttempt: true)
        stopNormalListener()
        stopActiveSession()
    }

    private func monitorPairingWindow(
        _ server: PairingServer,
        expiresAt: Date
    ) {
        pairingMonitorTask?.cancel()
        pairingMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if Date() >= expiresAt {
                    break
                }
                do {
                    try await Task.sleep(
                        nanoseconds: Self.pairingMonitorIntervalNanoseconds
                    )
                } catch {
                    return
                }
                guard let self, self.pairingServer === server else { return }
                if await server.localPort == nil {
                    break
                }
            }
            guard let self, self.pairingServer === server else { return }
            self.emit(
                .info,
                category: "Pairing",
                message: "Pairing window closed or expired."
            )
            await self.closePairingWindow(server, resumeReceiver: true)
        }
    }

    private func closePairingWindow(
        _ server: PairingServer,
        resumeReceiver: Bool
    ) async {
        guard pairingServer === server else { return }
        pairingMonitorTask?.cancel()
        pairingMonitorTask = nil
        pairingServer = nil
        await server.close()
        if resumeReceiver {
            onPairingClosed()
        }
    }

    private func accept(
        _ nwConnection: NWConnection,
        destination: URL,
        sourceBindingID: String
    ) {
        guard activeConnection == nil else {
            emit(
                .warning,
                category: "Session",
                message: "Rejected an additional connection while a session is active."
            )
            nwConnection.cancel()
            return
        }
        emit(
            .info,
            category: "Session",
            message: "Accepted an incoming connection; waiting for TLS and session opening."
        )
        let connection = FramedConnection(nwConnection)
        activeConnection = connection
        let sessionID = UUID()
        activeSessionID = sessionID
        let container = modelContainer
        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                connection.cancel()
                self.finishSession(sessionID, connection: connection)
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
                let summary = try await session.run(
                    connection: connection,
                    onAccepted: { [weak self] in
                        await self?.sessionDidAccept(sessionID)
                    },
                    onEvent: { [weak self] event in
                        await self?.forward(event)
                    }
                )
                self.onSummary(summary)
            } catch {
                if !Task.isCancelled, self.activeSessionID == sessionID {
                    self.onRuntimeState(.error(error.localizedDescription))
                }
            }
        }
    }

    private func sessionDidAccept(_ sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        onRuntimeState(.receiving)
    }

    private func forward(_ event: OperationLogEvent) {
        onOperation(event)
    }

    private func finishSession(
        _ sessionID: UUID,
        connection: FramedConnection
    ) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        if activeConnection === connection {
            activeConnection = nil
        }
        sessionTask = nil
        if receiverConfiguration != nil,
           pairingServer == nil,
           normalListenerIsReady {
            onRuntimeState(.ready)
        }
    }

    private func emit(
        _ level: OperationLogLevel,
        category: String,
        message: String
    ) {
        onOperation(OperationLogEvent(
            level: level,
            category: category,
            message: message
        ))
    }
}
