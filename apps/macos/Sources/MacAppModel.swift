import AppKit
import Foundation
import Observation
import OSLog
import ServiceManagement
import SyncCore

struct MacErrorLogEntry: Equatable, Identifiable {
    let id: UUID
    let occurredAt: Date
    let context: String
    let message: String

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        context: String,
        message: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.context = context
        self.message = message
    }
}

@MainActor
@Observable
final class MacAppModel {
    static let shared = MacAppModel()

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
    var launchAtLogin = false
    var errorLog: [MacErrorLogEntry] = []

    @ObservationIgnored private let settings: MacSettingsStore
    @ObservationIgnored private let bookmarkStore: DestinationBookmarkStore
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shuk.iphonesync.mac",
        category: "runtime"
    )
    @ObservationIgnored private var controller: ReceiverController?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var destinationAccessActive = false

    private init(settings: MacSettingsStore = MacSettingsStore()) {
        self.settings = settings
        self.bookmarkStore = DestinationBookmarkStore(settings: settings)
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
                }
            )
            pairedPeer = try controller?.loadPairedPeer()
            do {
                let resolved = try bookmarkStore.resolve()
                destinationAccessActive = resolved.startAccessingSecurityScopedResource()
                destinationURL = resolved
            } catch DestinationBookmarkError.missing {
                destinationURL = nil
            } catch {
                bookmarkStore.clear()
                destinationURL = nil
                recordError(error.localizedDescription, context: "Destination")
                return
            }
            await startReceiverIfReady()
        } catch {
            recordError(error.localizedDescription, context: "Startup")
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose iPhone Backup Destination"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

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
                await startReceiverIfReady()
            } catch {
                recordError(error.localizedDescription, context: "Destination")
            }
        }
    }

    func openPairingWindow() {
        guard destinationURL != nil else {
            state = .needsDestination
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
        Task { await startReceiverIfReady() }
    }

    func startReceiverIfReady() async {
        guard let destinationURL else {
            state = .needsDestination
            return
        }
        guard let pairedPeer else {
            state = .needsPairing
            return
        }
        do {
            try controller?.startReceiver(
                destination: destinationURL,
                peer: pairedPeer,
                sourceBindingID: sourceBindingID,
                displayName: computerName
            )
        } catch {
            recordError(error.localizedDescription, context: "Receiver")
        }
    }

    func stopReceiver() {
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
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            recordError(error.localizedDescription, context: "Launch at Login")
        }
    }

    func clearErrorLog() {
        errorLog.removeAll()
    }

    func recordError(_ message: String, context: String) {
        let entry = MacErrorLogEntry(context: context, message: message)
        errorLog.insert(entry, at: 0)
        if errorLog.count > 100 {
            errorLog.removeLast(errorLog.count - 100)
        }
        logger.error("\(context, privacy: .public): \(message, privacy: .private)")
        state = .error(message)
    }

    private var computerName: String {
        Host.current().localizedName ?? "Mac"
    }

    private func resetSourceIdentifier() {
        settings.resetSourceBindingID()
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
        logger.notice(
            "Launch at Login restored; requested=\(requested, privacy: .public), status=\(String(describing: service.status), privacy: .public)"
        )
    }
}
