import Photos
import SwiftUI
import SyncCore
import UIKit

struct ContentView: View {
    @Bindable var model: IOSAppModel
    @State private var showsAlbumPicker = false
    @State private var showForgetConfirmation = false
    @State private var showEnableDeleteAfterSyncConfirmation = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Tokens.Layout.sectionSpacing) {
                    sourceZone
                    deleteAfterSyncZone
                    automaticZone
                    if let summary = model.lastSummary {
                        lastSyncCard(summary: summary)
                    }
                    IOSOperationLogCard(model: model)
                    if case let .error(message) = model.state {
                        errorCard(message: message)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .background(Tokens.Palette.paper)
            .navigationTitle("iPhone Sync")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsAlbumPicker) {
                AlbumPickerView(
                    albums: model.albums,
                    selectedAlbums: model.selectedAlbums,
                    save: model.selectAlbums
                )
            }
            .sheet(isPresented: Binding(
                get: { model.pairingIsPending },
                set: { isPresented in
                    if !isPresented, model.pairingIsPending {
                        model.cancelPairing()
                    }
                }
            )) {
                PairingView(model: model)
            }
            .confirmationDialog(
                "Forget the paired Mac?",
                isPresented: $showForgetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Forget", role: .destructive) { model.forgetMac() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If you continue, Automatic Sync will be disabled and you will need to pair again.")
            }
            .alert(
                "Enable Delete After Sync?",
                isPresented: $showEnableDeleteAfterSyncConfirmation
            ) {
                Button("Enable", role: .destructive) {
                    model.setDeleteAfterSyncEnabled(true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "After a complete backup, this can delete a photo from the "
                        + "entire Photos library, not only the selected album. "
                        + "With iCloud Photos, deletion also applies to your "
                        + "other signed-in devices. Photos asks you to confirm "
                        + "each deletion batch. Photos changed after backup stay "
                        + "on this iPhone until they sync again."
                )
            }
            .task {
                await model.bootstrap()
                model.enteredForeground()
            }
        }
    }

    // MARK: Source Zone

    private var sourceZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            zoneHeader("Source")

            sourceCard(
                icon: "photo.on.rectangle.angled",
                title: photosTitle,
                subtitle: photosSubtitle,
                action: {
                    if !model.hasFullPhotoAccess {
                        model.requestPhotosAccess()
                    } else {
                        showsAlbumPicker = true
                    }
                },
                actionLabel: model.hasFullPhotoAccess ? "Choose Albums" : "Grant Photos Access",
                actionEnabled: !model.isAnySyncRunning,
                actionTinted: !model.hasFullPhotoAccess
            )

            sourceCard(
                icon: "desktopcomputer",
                title: macTitle,
                subtitle: macSubtitle,
                action: macAction,
                actionLabel: macActionLabel,
                actionEnabled: macActionEnabled,
                actionTinted: model.pairedPeer != nil,
                leadingAction: model.pairedPeer == nil ? nil : { model.syncNow() },
                leadingActionLabel: model.pairedPeer == nil ? nil : "Sync Now",
                leadingActionEnabled: model.canSync,
                actionsAtTrailing: true
            )

            if model.pairedPeer == nil, model.state == .findingMac {
                receiverSelectionCard
            }

            if model.state == .syncing {
                VStack(alignment: .leading, spacing: 12) {
                    progressView
                }
                .padding(Tokens.Layout.cardPadding)
                .background(Tokens.Palette.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                        .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
                )
            }
        }
    }

    private var photosTitle: String {
        guard model.hasFullPhotoAccess else { return "Photos access required" }
        return model.selectedAlbumsText
    }

    private var photosSubtitle: String {
        if !model.hasFullPhotoAccess {
            return "Full Photos Access is required to read original resources."
        }
        let total = model.selectedAlbums.reduce(0) { $0 + $1.assetCount }
        switch model.selectedAlbums.count {
        case 0: return "Tap to choose albums to back up."
        case 1: return "1 album · \(total.formatted()) photos"
        default: return "\(model.selectedAlbums.count) albums · \(total.formatted()) photos"
        }
    }

    private var macTitle: String {
        model.pairedPeer?.displayName ?? "Mac"
    }

    private var macSubtitle: String {
        if model.state == .findingMac {
            return model.receivers.isEmpty
                ? "Searching for Macs with an open pairing window..."
                : "\(model.receivers.count) Mac candidate(s) found."
        }
        if model.pairedPeer != nil {
            return "Paired · same Wi-Fi"
        }
        return "Not paired. Choose a Mac on the same Wi-Fi to begin."
    }

    private var macAction: () -> Void {
        if model.pairedPeer == nil {
            return { model.findMac() }
        }
        return { showForgetConfirmation = true }
    }

    private var macActionLabel: String {
        model.pairedPeer == nil ? "Find Mac" : "Forget"
    }

    private var macActionEnabled: Bool {
        !model.isAnySyncRunning
    }

    private func sourceCard(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void,
        actionLabel: String,
        actionEnabled: Bool,
        actionTinted: Bool,
        leadingAction: (() -> Void)? = nil,
        leadingActionLabel: String? = nil,
        leadingActionEnabled: Bool = true,
        actionsAtTrailing: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Tokens.Palette.wire)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Tokens.Typography.body.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.wire)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                if actionsAtTrailing {
                    Spacer()
                    if let leadingAction, let leadingActionLabel {
                        Button(leadingActionLabel, action: leadingAction)
                            .buttonStyle(.bordered)
                            .disabled(!leadingActionEnabled)
                            .tint(Tokens.Palette.signal)
                    }
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                        .disabled(!actionEnabled)
                        .tint(actionTinted ? Tokens.Palette.alert : Tokens.Palette.signal)
                } else {
                    if let leadingAction, let leadingActionLabel {
                        Button(leadingActionLabel, action: leadingAction)
                            .buttonStyle(.bordered)
                            .disabled(!leadingActionEnabled)
                            .tint(Tokens.Palette.signal)
                    }
                    Spacer()
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                        .disabled(!actionEnabled)
                        .tint(actionTinted ? Tokens.Palette.alert : Tokens.Palette.signal)
                }
            }
        }
        .padding(Tokens.Layout.cardPadding)
        .background(Tokens.Palette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
        )
    }

    private var receiverSelectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap a Mac to start pairing")
                .font(Tokens.Typography.body.weight(.semibold))
                .foregroundStyle(Tokens.Palette.wire)

            if model.receivers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(Tokens.Palette.signal)
                    Text("Waiting for discovery...")
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(model.receivers, id: \.id) { receiver in
                        Button {
                            model.beginPairing(with: receiver)
                        } label: {
                            HStack {
                                Text(receiver.displayName)
                                    .font(Tokens.Typography.body)
                                    .foregroundStyle(Tokens.Palette.wire)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Tokens.Palette.wire.opacity(0.55))
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(Tokens.Palette.paper)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.Layout.cellCornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Tokens.Layout.cellCornerRadius)
                                    .stroke(Tokens.Palette.frame, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(Tokens.Layout.cardPadding)
        .background(Tokens.Palette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
        )
    }

    private var progressView: some View {
        VStack(spacing: 8) {
            if let progress = model.progress {
                HStack {
                    Text(progress.albumName)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        "\(progress.sentBytes.formatted(.byteCount(style: .file))) "
                            + "of \(progress.totalBytes.formatted(.byteCount(style: .file)))"
                    )
                    .font(Tokens.Typography.numericData)
                    .foregroundStyle(Tokens.Palette.wire)
                }
                Text(progress.resourceName)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Chunk-tick: no implicit animation; progress updates land
                // at the 1 MiB chunk boundary rather than smoothing.
                ProgressView(
                    value: Double(progress.sentBytes),
                    total: Double(max(1, progress.totalBytes))
                )
                .tint(Tokens.Palette.signal)
                .animation(nil, value: progress.sentBytes)
                .accessibilityLabel(
                    "Syncing \(progress.albumName), "
                        + "\(progress.resourceName), "
                        + "\(progress.sentBytes.formatted(.byteCount(style: .file))) "
                        + "of \(progress.totalBytes.formatted(.byteCount(style: .file)))"
                )
            } else {
                ProgressView()
                    .tint(Tokens.Palette.signal)
                    .accessibilityLabel("Preparing sync")
            }

            Button("Cancel", role: .cancel) { model.cancel() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Delete After Sync Zone

    private var deleteAfterSyncZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            zoneHeader("After Sync")

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 21))
                        .foregroundStyle(
                            model.deleteAfterSync.isEnabled
                                ? Tokens.Palette.alert
                                : Tokens.Palette.wire
                        )
                        .frame(width: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete After Sync")
                            .font(Tokens.Typography.body.weight(.semibold))
                            .foregroundStyle(Tokens.Palette.wire)
                        Text(deleteAfterSyncDescription)
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Toggle(
                        "Delete photos after sync",
                        isOn: Binding(
                            get: { model.deleteAfterSync.isEnabled },
                            set: { enabled in
                                if enabled {
                                    showEnableDeleteAfterSyncConfirmation = true
                                } else {
                                    model.setDeleteAfterSyncEnabled(false)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(Tokens.Palette.alert)
                    .disabled(model.isAnySyncRunning)
                }

                if model.deleteAfterSync.pendingAssetCount > 0 {
                    Button(
                        "Delete \(model.deleteAfterSync.pendingAssetCount) "
                            + "Synced Photo"
                            + (model.deleteAfterSync.pendingAssetCount == 1 ? "" : "s"),
                        role: .destructive
                    ) {
                        model.deletePendingSyncedPhotos()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isAnySyncRunning)
                }

                if model.deleteAfterSync.isDeleting {
                    Label {
                        Text("Waiting for Photos confirmation")
                    } icon: {
                        ProgressView()
                            .tint(Tokens.Palette.alert)
                    }
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(Tokens.Layout.cardPadding)
            .background(Tokens.Palette.paper)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                    .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
            )
        }
    }

    private var deleteAfterSyncDescription: String {
        guard model.deleteAfterSync.isEnabled else {
            return "Off. Synced photos stay in your Photos library."
        }
        if model.deleteAfterSync.pendingAssetCount > 0 {
            return "\(model.deleteAfterSync.pendingAssetCount) fully backed-up "
                + "photo(s) are waiting for foreground confirmation."
        }
        return "Only photos whose every local original resource is confirmed "
            + "on the computer are eligible; changed photos stay."
    }

    // MARK: Automatic Zone

    private var automaticZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            zoneHeader("Automatic Sync")

            #if DEBUG
            AutomaticSyncCard(model: model, mode: .debug)
            #endif
            AutomaticSyncCard(model: model, mode: .production)
        }
    }

    // MARK: Last Sync Card

    private func lastSyncCard(summary: SyncSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            zoneHeader("Last Sync")
            HStack(spacing: 16) {
                summaryStat(label: "Added", value: summary.added)
                summaryStat(label: "Already", value: summary.existing)
                summaryStat(label: "Not local", value: summary.notLocal)
                summaryStat(label: "Failed", value: summary.failed)
            }
            .padding(Tokens.Layout.cardPadding)
            .background(Tokens.Palette.paper)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                    .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Last sync: \(summary.added) added, "
                    + "\(summary.existing) already present, "
                    + "\(summary.notLocal) not on iPhone, "
                    + "\(summary.failed) failed."
            )
        }
    }

    private func summaryStat(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Tokens.Typography.numericData)
                .foregroundStyle(Tokens.Palette.wire)
            Text(label)
                .font(Tokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Error Card

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Palette.alert)
                Text(message)
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.alert)
            }
            Button("Open Settings") {
                guard let url = URL(
                    string: UIApplication.openSettingsURLString
                ) else { return }
                openURL(url)
            }
            .buttonStyle(.bordered)
        }
        .padding(Tokens.Layout.cardPadding)
        .background(Tokens.Palette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                .stroke(Tokens.Palette.alert.opacity(0.4), lineWidth: Tokens.Layout.hairline)
        )
    }

    // MARK: Helpers

    private func zoneHeader(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.sectionHeader)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Automatic Sync Card

private struct AutomaticSyncCard: View {
    @Bindable var model: IOSAppModel
    let mode: IOSAppModel.AutomaticSyncMode
    @State private var showTimingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Text(cardTitle)
                        .font(Tokens.Typography.body.weight(.semibold))
                        .foregroundStyle(cardTint)
                    Button {
                        showTimingInfo = true
                    } label: {
                        Image(systemName: "exclamationmark.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.backgroundRefreshText)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Automatically sync",
                    isOn: Binding(
                        get: { snapshot.isEnabled },
                        set: { model.setAutomaticSyncEnabled($0, mode: mode) }
                    )
                )
                .labelsHidden()
                .tint(Tokens.Palette.signal)
            }

            if isRunning {
                Label {
                    Text("Syncing now")
                } icon: {
                    ProgressView()
                        .tint(Tokens.Palette.signal)
                }
                .font(Tokens.Typography.callout)
            }

            statRow("Last attempt", value: formattedDate(snapshot.lastAttemptAt))
            statRow("Last success", value: formattedDate(snapshot.lastSuccessAt))
            statRow("Next attempt", value: formattedDate(snapshot.nextEligibleAt))

            if mode == .production {
                HStack(spacing: 8) {
                    Text("Schedule time")
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker(
                        "Schedule time",
                        selection: Binding(
                            get: { model.automaticProductionSyncDate },
                            set: { model.automaticProductionSyncDate = $0 }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(Tokens.Palette.signal)
                }
            } else {
                statRow("Cadence", value: "Every 10 minutes")
            }

        }
        .padding(Tokens.Layout.cardPadding)
        .background(Tokens.Palette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
        )
        .alert("Automatic sync timing", isPresented: $showTimingInfo) {
            Button("OK", role: .cancel) { showTimingInfo = false }
        } message: {
            Text("iOS controls the actual background execution time. "
                + "The configured time may still be delayed by device conditions.")
        }
    }

    private var snapshot: IOSAutomaticSyncSnapshot {
        switch mode {
        case .debug:
            model.automaticDebugSync
        case .production:
            model.automaticProductionSync
        }
    }

    private var isRunning: Bool {
        switch mode {
        case .debug:
            model.automaticDebugRunIsActive
        case .production:
            model.automaticProductionRunIsActive
        }
    }

    private var cardTitle: String {
        mode == .debug ? "AUTOMATIC SYNC (DEBUG)" : "AUTOMATIC SYNC"
    }

    private var cardTint: Color {
        mode == .debug ? Tokens.Palette.alert : Tokens.Palette.signal
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(Tokens.Typography.numericData)
                .foregroundStyle(Tokens.Palette.wire)
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Operation Log Card

private struct IOSOperationLogCard: View {
    @Bindable var model: IOSAppModel
    @State private var showFullLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Operation Log")
                    .font(Tokens.Typography.sectionHeader)
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.operationLog.isEmpty {
                    Button("View all (\(model.operationLog.count))") {
                        showFullLog = true
                    }
                    .font(Tokens.Typography.caption)
                    .buttonStyle(.borderless)
                }
            }

            if model.operationLog.isEmpty {
                Text("No operations recorded")
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(model.operationLog.prefix(3))) { entry in
                        IOSOperationLogRow(entry: entry)
                    }
                }
                Button("Clear Log", role: .destructive) {
                    model.clearOperationLog()
                }
                .font(Tokens.Typography.caption)
                .buttonStyle(.borderless)
            }

            Text(
                "Keeps the latest \(OperationLogBuffer.defaultCapacity) "
                    + "semantic operations for this app run. Secrets and "
                    + "pairing codes are never included."
            )
            .font(Tokens.Typography.caption)
            .foregroundStyle(.secondary)
        }
        .padding(Tokens.Layout.cardPadding)
        .background(Tokens.Palette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
        )
        .sheet(isPresented: $showFullLog) {
            IOSOperationLogView(model: model)
        }
    }
}
