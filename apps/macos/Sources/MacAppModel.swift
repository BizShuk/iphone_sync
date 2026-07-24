import AppKit
import Foundation
import Network
import Observation
import OSLog
import ServiceManagement
import SyncCore

@MainActor
@Observable
final class MacAppModel {
    static let shared = MacAppModel()

    /// The first destination chooser opens here; access is still granted only
    /// after the user confirms the folder in `NSOpenPanel`.
    static var defaultDestinationURL: URL? {
        FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
    }

    enum State: Equatable {
        case needsDestination
        case needsPairing
        case ready
        case pairing(code: String, expiresAt: Date)
        case receiving
        case error(String)
    }

    var state: State = .needsDestination
    var destinationURL: URL?
    var pairedPeer: PairedPeer?
    var lastSummary: SyncSummary?
    var destinationStorageMode: DestinationStorageMode = .albumDate
    var launchAtLogin = false
    var operationLog: [OperationLogEntry] = []

    @ObservationIgnored private let settings: MacSettingsStore
    @ObservationIgnored private let bookmarkStore: DestinationBookmarkStore
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shuk.iphonesync.mac",
        category: "operations"
    )
    @ObservationIgnored private var operationLogBuffer = OperationLogBuffer()
    @ObservationIgnored private var controller: ReceiverController?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var destinationAccessActive = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(
        label: "com.shuk.iphonesync.mac-path-monitor"
    )
    @ObservationIgnored private var pathMonitorStarted = false
    @ObservationIgnored private var lastPathStatus: NWPath.Status?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private init(settings: MacSettingsStore = MacSettingsStore()) {
        self.settings = settings
        self.bookmarkStore = DestinationBookmarkStore(settings: settings)
        destinationStorageMode = settings.destinationStorageMode
    }

    private var receiverID: String {
        settings.receiverID()
    }

    private var sourceBindingID: String {
        settings.sourceBindingID()
    }

    var statusText: String {
        switch state {
        case .needsDestination: "Choose a destination"
        case .needsPairing: "Pair an iPhone"
        case .ready: "Ready"
        case .pairing: "Pairing"
        case .receiving: "Receiving"
        case .error: "Error"
        }
    }

    var statusSymbol: String {
        switch state {
        case .ready: "checkmark.circle"
        case .pairing: "link"
        case .receiving: "arrow.down.circle"
        case .error: "exclamationmark.triangle"
        default: "iphone.and.arrow.forward"
        }
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        recordOperation(
            .info,
            category: "App",
            message: "Loading saved receiver settings."
        )
        restoreLaunchAtLogin()
        do {
            controller = try ReceiverController(
                receiverID: receiverID,
                onPairingCode: { [weak self] code, expiresAt in
                    self?.state = .pairing(code: code, expiresAt: expiresAt)
                },
                onPaired: { [weak self] peer in
                    guard let self else { return }
                    self.pairedPeer = peer
                    Task { await self.startReceiverIfReady() }
                },
                onPairingClosed: { [weak self] in
                    guard let self else { return }
                    Task { await self.startReceiverIfReady() }
                },
                onRuntimeState: { [weak self] runtimeState in
                    guard let self else { return }
                    switch runtimeState {
                    case .ready: self.state = .ready
                    case .receiving: self.state = .receiving
                    case let .error(message):
                        self.recordError(message, context: "Receiver")
                    }
                },
                onSummary: { [weak self] summary in
                    self?.lastSummary = summary
                },
                onOperation: { [weak self] event in
                    self?.recordOperation(event)
                }
            )
            startRecoveryMonitoring()
            pairedPeer = try controller?.loadPairedPeer()
            recordOperation(
                .info,
                category: "Pairing",
                message: pairedPeer == nil
                    ? "No paired iPhone was restored."
                    : "Restored the paired iPhone from Keychain."
            )
            do {
                let resolved = try bookmarkStore.resolve()
                destinationAccessActive = resolved.startAccessingSecurityScopedResource()
                destinationURL = resolved
                recordOperation(
                    .success,
                    category: "Destination",
                    message: "Restored access to “\(resolved.lastPathComponent)”."
                )
            } catch DestinationBookmarkError.missing {
                destinationURL = nil
                recordOperation(
                    .info,
                    category: "Destination",
                    message: "No destination is selected; the chooser defaults to Downloads."
                )
            } catch {
                bookmarkStore.clear()
                destinationURL = nil
                recordError(error.localizedDescription, context: "Destination")
                return
            }
            await startReceiverIfReady()
            recordOperation(
                .success,
                category: "App",
                message: "Startup completed."
            )
        } catch {
            recordError(error.localizedDescription, context: "Startup")
        }
    }

    func chooseDestination() {
        recordOperation(
            .info,
            category: "Destination",
            message: "Opened the destination chooser."
        )
        let panel = NSOpenPanel()
        panel.title = "Choose iPhone Backup Destination"
        panel.prompt = "Choose"
        panel.directoryURL = destinationURL ?? Self.defaultDestinationURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            recordOperation(
                .info,
                category: "Destination",
                message: "Destination selection cancelled."
            )
            return
        }

        Task {
            await controller?.stopAll()
            if destinationAccessActive {
                destinationURL?.stopAccessingSecurityScopedResource()
            }
            do {
                try bookmarkStore.save(url)
                destinationAccessActive = url.startAccessingSecurityScopedResource()
                destinationURL = url
                resetSourceIdentifier()
                recordOperation(
                    .success,
                    category: "Destination",
                    message: "Selected “\(url.lastPathComponent)” and reset source binding."
                )
                await startReceiverIfReady()
            } catch {
                recordError(error.localizedDescription, context: "Destination")
            }
        }
    }

    func openPairingWindow() {
        guard destinationURL != nil else {
            state = .needsDestination
            recordOperation(
                .warning,
                category: "Pairing",
                message: "Choose a destination before opening pairing."
            )
            return
        }
        state = .pairing(
            code: "------",
            expiresAt: Date().addingTimeInterval(120)
        )
        Task {
            do {
                try await controller?.openPairingWindow(displayName: computerName)
            } catch {
                recordError(error.localizedDescription, context: "Pairing")
            }
        }
    }

    func forgetPhone() {
        Task {
            do {
                try await controller?.forgetPhone()
                pairedPeer = nil
                state = destinationURL == nil ? .needsDestination : .needsPairing
            } catch {
                recordError(error.localizedDescription, context: "Pairing")
            }
        }
    }

    func resetSource() {
        resetSourceIdentifier()
        recordOperation(
            .info,
            category: "Source",
            message: "Reset the source binding; existing Finder files were preserved."
        )
        Task { await startReceiverIfReady() }
    }

    func startReceiverIfReady(forceRestart: Bool = false) async {
        guard controller?.isPairingWindowOpen != true else { return }
        guard let destinationURL else {
            state = .needsDestination
            recordOperation(
                .info,
                category: "Receiver",
                message: "Receiver is waiting for a destination."
            )
            return
        }
        guard let pairedPeer else {
            state = .needsPairing
            recordOperation(
                .info,
                category: "Receiver",
                message: "Receiver is waiting for a paired iPhone."
            )
            return
        }
        do {
            try controller?.startReceiver(
                destination: destinationURL,
                peer: pairedPeer,
                storageMode: destinationStorageMode,
                sourceBindingID: sourceBindingID,
                displayName: computerName,
                forceRestart: forceRestart
            )
        } catch {
            recordError(error.localizedDescription, context: "Receiver")
        }
    }

    func stopReceiver() {
        recordOperation(
            .info,
            category: "Receiver",
            message: "Stop requested."
        )
        controller?.stopReceiver()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLoginRequested = enabled
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            recordOperation(
                .success,
                category: "Launch at Login",
                message: enabled
                    ? "Launch at Login enabled."
                    : "Launch at Login disabled."
            )
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            recordError(error.localizedDescription, context: "Launch at Login")
        }
    }

    func clearOperationLog() {
        operationLogBuffer.clear()
        operationLog = operationLogBuffer.entries
        logger.notice("Operation Log cleared")
    }

    func setDestinationStorageMode(_ mode: DestinationStorageMode) {
        guard destinationStorageMode != mode else { return }
        destinationStorageMode = mode
        settings.destinationStorageMode = mode
        recordOperation(
            .info,
            category: "Destination",
            message: "Storage mode changed to \(mode.rawValue)."
        )
        Task { await startReceiverIfReady(forceRestart: true) }
    }

    func copyOperationLog() {
        guard !operationLog.isEmpty else { return }
        let formatter = ISO8601DateFormatter()
        let text = operationLog.reversed().map { entry in
            "\(formatter.string(from: entry.occurredAt)) "
                + "[\(entry.level.rawValue.uppercased())] "
                + "\(entry.category): \(entry.message)"
        }
        .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        recordOperation(
            .info,
            category: "Operation Log",
            message: "Copied \(operationLog.count) entries to the clipboard."
        )
    }

    func recordError(_ message: String, context: String) {
        recordOperation(.error, category: context, message: message)
        state = .error(message)
    }

    func recordOperation(_ event: OperationLogEvent) {
        operationLogBuffer.record(event)
        operationLog = operationLogBuffer.entries
        switch event.level {
        case .info:
            logger.info(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        case .success:
            logger.notice(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        case .warning:
            logger.warning(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        case .error:
            logger.error(
                "\(event.category, privacy: .public): \(event.message, privacy: .private)"
            )
        }
    }

    private var computerName: String {
        Host.current().localizedName ?? "Mac"
    }

    private func resetSourceIdentifier() {
        settings.resetSourceBindingID()
    }

    private func startRecoveryMonitoring() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path.status)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverReceiver(reason: "Mac wake")
            }
        }
    }

    private func handlePathUpdate(_ status: NWPath.Status) {
        let previousStatus = lastPathStatus
        lastPathStatus = status
        guard previousStatus != nil,
              previousStatus != .satisfied,
              status == .satisfied else {
            return
        }
        recoverReceiver(reason: "Network path recovery")
    }

    private func recoverReceiver(reason: String) {
        guard controller?.isPairingWindowOpen != true else {
            logger.notice(
                "\(reason, privacy: .public); receiver reconcile deferred while pairing"
            )
            recordOperation(
                .info,
                category: "Recovery",
                message: "\(reason); deferred receiver recovery while pairing."
            )
            return
        }
        logger.notice("\(reason, privacy: .public); reconciling receiver listener")
        recordOperation(
            .info,
            category: "Recovery",
            message: "\(reason); reconciling the receiver listener."
        )
        Task { await startReceiverIfReady(forceRestart: true) }
    }

    private func restoreLaunchAtLogin() {
        let service = SMAppService.mainApp
        let requested = settings.launchAtLoginRequested
        do {
            if requested {
                switch service.status {
                case .enabled:
                    break
                case .requiresApproval:
                    recordError(
                        "Allow iPhone Sync in System Settings > General > Login Items.",
                        context: "Launch at Login"
                    )
                case .notFound, .notRegistered:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            recordError(error.localizedDescription, context: "Launch at Login")
        }
        launchAtLogin = service.status == .enabled
        recordOperation(
            .info,
            category: "Launch at Login",
            message: "Restored requested=\(requested); status=\(String(describing: service.status))."
        )
    }

    private func recordOperation(
        _ level: OperationLogLevel,
        category: String,
        message: String
    ) {
        recordOperation(OperationLogEvent(
            level: level,
            category: category,
            message: message
        ))
    }
}
