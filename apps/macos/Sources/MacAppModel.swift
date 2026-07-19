import AppKit
import Foundation
import Observation
import ServiceManagement
import SyncCore

@MainActor
@Observable
final class MacAppModel {
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

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let bookmarkStore = DestinationBookmarkStore()
    @ObservationIgnored private var controller: ReceiverController?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var destinationAccessActive = false

    private var receiverID: String {
        if let value = defaults.string(forKey: "receiverID") { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: "receiverID")
        return value
    }

    private var sourceBindingID: String {
        if let value = defaults.string(forKey: "sourceBindingID") { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: "sourceBindingID")
        return value
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
                    case let .error(message): self.state = .error(message)
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
                state = .error(error.localizedDescription)
                return
            }
            await startReceiverIfReady()
        } catch {
            state = .error(error.localizedDescription)
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
                state = .error(error.localizedDescription)
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
                state = .error(error.localizedDescription)
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
                state = .error(error.localizedDescription)
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
            state = .error(error.localizedDescription)
        }
    }

    func stopReceiver() {
        controller?.stopReceiver()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            state = .error(error.localizedDescription)
        }
    }

    private var computerName: String {
        Host.current().localizedName ?? "Mac"
    }

    private func resetSourceIdentifier() {
        defaults.set(UUID().uuidString, forKey: "sourceBindingID")
    }
}
