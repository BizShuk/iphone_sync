import AppKit
import Observation
import OSLog
import SwiftUI
import SyncCore

@main
@MainActor
struct iPhoneSyncMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private struct MenuSnapshot {
        let state: MacAppModel.State
        let statusText: String
        let pairedPhoneName: String?
        let pairedIPhoneReady: Bool
    }

    private let logger = Logger(
        subsystem: "com.shuk.iphonesync.mac",
        category: "menu-bar"
    )
    private let model = MacAppModel.shared
    private let statusMenu = NSMenu()
    private var statusItem: NSStatusItem?
    private var statusItemWatchdogTask: Task<Void, Never>?
    private var visibilityObservation: NSKeyValueObservation?
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        observeModel()
        Task { await model.bootstrap() }

        if CommandLine.arguments.contains("--open-setup") {
            showSetupWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopReceiver()
        statusItemWatchdogTask?.cancel()
    }

    private func configureStatusItem() {
        createStatusItem()
        startStatusItemWatchdog()

        logger.notice("AppKit status item created; visible=\(self.statusItem?.isVisible == true, privacy: .public)")
        model.recordOperation(OperationLogEvent(
            level: .success,
            category: "Menu Bar",
            message: "Created the menu bar status item."
        ))
        perform(#selector(logStatusItemDiagnostics), with: nil, afterDelay: 1)
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "com.shuk.iphonesync.statusItem"
        item.menu = statusMenu
        item.isVisible = true
        item.button?.imagePosition = .imageOnly
        statusItem = item
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor [weak self] in
                self?.restoreStatusItemVisibility()
            }
        }
    }

    private func startStatusItemWatchdog() {
        statusItemWatchdogTask?.cancel()
        statusItemWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    self?.validateStatusItemGeometry()
                }
            }
        }
    }

    private func validateStatusItemGeometry() {
        guard let item = statusItem else { return }
        if !item.isVisible {
            return
        }
        guard let button = item.button else {
            recreateStatusItem(reason: "missing button")
            return
        }
        let hostFrame = button.window?.frame ?? .zero
        let hostHeight = hostFrame.height
        let hostWidth = hostFrame.width
        if hostHeight <= 0 || hostWidth <= 0 || button.frame.width <= 0 || button.frame.height <= 0 {
            logger.notice("Status item has invalid frame; hostWidth=\(hostWidth, privacy: .public), hostHeight=\(hostHeight, privacy: .public), buttonWidth=\(button.frame.width, privacy: .public), buttonHeight=\(button.frame.height, privacy: .public)")
            recreateStatusItem(reason: "invalid host frame")
        }
    }

    private func recreateStatusItem(reason: String) {
        statusItemWatchdogTask?.cancel()
        statusItemWatchdogTask = nil
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil

        logger.warning("Recreating status item. reason=\(reason, privacy: .public)")
        model.recordOperation(OperationLogEvent(
            level: .warning,
            category: "Menu Bar",
            message: "Recreated status item due \(reason)."
        ))
        createStatusItem()
        startStatusItemWatchdog()
    }

    private func restoreStatusItemVisibility() {
        guard let statusItem, !statusItem.isVisible else { return }
        logger.notice("Status item became hidden; restoring visibility")
        model.recordOperation(OperationLogEvent(
            level: .warning,
            category: "Menu Bar",
            message: "The status item became hidden; restored visibility."
        ))
        statusItem.isVisible = true
    }

    @objc private func logStatusItemDiagnostics() {
        guard let statusItem else {
            logger.error("Status item diagnostic: missing item")
            model.recordError("The menu bar status item is unavailable.", context: "Menu Bar")
            return
        }

        let button = statusItem.button
        let buttonFrame = String(describing: button?.frame ?? .zero)
        let windowFrame = String(describing: button?.window?.frame ?? .zero)
        logger.notice(
            "Status item diagnostic: visible=\(statusItem.isVisible, privacy: .public), length=\(statusItem.length, privacy: .public), hasImage=\(button?.image != nil, privacy: .public), buttonFrame=\(buttonFrame, privacy: .public), windowFrame=\(windowFrame, privacy: .public), windowVisible=\(button?.window?.isVisible == true, privacy: .public)"
        )
        model.recordOperation(OperationLogEvent(
            level: .info,
            category: "Menu Bar",
            message: "Status item diagnostics completed; visible=\(statusItem.isVisible)."
        ))
    }

    private func observeModel() {
        let snapshot = withObservationTracking {
            MenuSnapshot(
                state: model.state,
                statusText: model.statusText,
                pairedPhoneName: model.pairedPeer?.displayName,
                pairedIPhoneReady: model.pairedPeer != nil
                    && (model.state == .ready || model.state == .receiving)
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeModel()
            }
        }

        updateStatusItem(using: snapshot)
        rebuildMenu(using: snapshot)
    }

    private func updateStatusItem(using snapshot: MenuSnapshot) {
        guard let statusItem, let button = statusItem.button else { return }

        let iconState: MenuBarIcon.State = switch snapshot.state {
        case .receiving, .pairing: .receiving
        case .ready, .needsDestination, .needsPairing, .error: .idle
        }
        let image = MenuBarIcon.image(state: iconState)
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "iPhone Sync — \(snapshot.statusText)"
        button.setAccessibilityLabel("iPhone Sync")
        statusItem.isVisible = true
    }

    private func rebuildMenu(using snapshot: MenuSnapshot) {
        statusMenu.removeAllItems()

        if snapshot.pairedPhoneName == nil {
            let status = NSMenuItem(
                title: snapshot.statusText,
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            statusMenu.addItem(status)
        }

        if let name = snapshot.pairedPhoneName {
            addPairedIPhoneInfoItem(name: name, isReady: snapshot.pairedIPhoneReady)
        }

        if case let .pairing(code, _) = snapshot.state {
            let codeItem = NSMenuItem(
                title: "Pairing code: \(code)",
                action: nil,
                keyEquivalent: ""
            )
            codeItem.isEnabled = false
            statusMenu.addItem(codeItem)
        }

        statusMenu.addItem(.separator())
        addMenuItem("Open Setup", action: #selector(openSetup))
        addMenuItem("Pair New iPhone", action: #selector(pairNewIPhone))
        addMenuItem("Choose Destination", action: #selector(chooseDestination))
        statusMenu.addItem(.separator())
        addMenuItem("Quit", action: #selector(quit))
    }

    private func addPairedIPhoneInfoItem(name: String, isReady: Bool) {
        let item = NSMenuItem()
        item.isEnabled = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setFrameSize(.init(width: 260, height: 24))

        let title = NSTextField(labelWithString: "iPhone \(name)")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.isEditable = false
        title.isBordered = false
        title.backgroundColor = .clear
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.textColor = NSColor.secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = statusIcon(isReady: isReady)
        icon.contentTintColor = isReady ? .systemGreen : .systemRed
        icon.imageScaling = .scaleProportionallyDown

        container.addSubview(title)
        container.addSubview(icon)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: icon.leadingAnchor,
                constant: -8
            ),

            icon.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -8
            ),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            container.heightAnchor.constraint(equalToConstant: 22)
        ])
        statusMenu.addItem(item)
        item.view = container
    }

    private func statusIcon(isReady: Bool) -> NSImage {
        let symbolName = isReady ? "circle.fill" : "xmark.circle.fill"
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            ?? NSImage()
    }

    private func addMenuItem(
        _ title: String,
        action: Selector,
        isEnabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        statusMenu.addItem(item)
    }

    @objc private func openSetup() {
        showSetupWindow()
    }

    @objc private func pairNewIPhone() {
        showSetupWindow()
        model.openPairingWindow()
    }

    @objc private func chooseDestination() {
        showSetupWindow()
        model.chooseDestination()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showSetupWindow() {
        if let setupWindow {
            model.recordOperation(OperationLogEvent(
                level: .info,
                category: "Setup",
                message: "Brought the existing Setup window forward."
            ))
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iPhone Sync Setup"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 580, height: 560)
        window.contentViewController = NSHostingController(
            rootView: SetupView(model: model)
        )
        if !window.setFrameUsingName(MacSettingsStore.setupWindowFrameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(MacSettingsStore.setupWindowFrameAutosaveName)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
        model.recordOperation(OperationLogEvent(
            level: .info,
            category: "Setup",
            message: "Opened the Setup window."
        ))
    }
}
