import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var model: IOSAppModel
    @State private var showsAlbumPicker = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section("Photos") {
                    LabeledContent("Access", value: accessText)
                    if !model.hasFullPhotoAccess {
                        Button("Grant Full Photos Access") { model.requestPhotosAccess() }
                    }
                    Button {
                        showsAlbumPicker = true
                    } label: {
                        LabeledContent(
                            "Albums",
                            value: model.selectedAlbumsText
                        )
                    }
                    .disabled(!model.hasFullPhotoAccess || model.isAnySyncRunning)
                }

                Section("Mac") {
                    LabeledContent(
                        "Paired Mac",
                        value: model.pairedPeer?.displayName ?? "Not paired"
                    )
                    Button("Find Mac") { model.findMac() }
                        .disabled(model.isAnySyncRunning)
                    ForEach(model.receivers) { receiver in
                        Button {
                            model.beginPairing(with: receiver)
                        } label: {
                            Label(receiver.displayName, systemImage: "desktopcomputer")
                        }
                        .disabled(model.pairedPeer != nil || model.isAnySyncRunning)
                    }
                    if model.pairedPeer != nil {
                        Button("Forget Mac", role: .destructive) { model.forgetMac() }
                            .disabled(model.isAnySyncRunning)
                    }
                }

                Section("Backup") {
                    Button("Sync Now") { model.syncNow() }
                        .disabled(!model.canSync)
                    if model.state == .syncing {
                        if let progress = model.progress {
                            Text(progress.albumName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(progress.resourceName).lineLimit(1)
                            ProgressView(
                                value: Double(progress.sentBytes),
                                total: Double(max(1, progress.totalBytes))
                            )
                            Text("\(progress.sentBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                }

                AutomaticSyncSection(model: model)

                if let summary = model.lastSummary {
                    Section("Last Sync") {
                        LabeledContent("Added", value: String(summary.added))
                        LabeledContent("Already present", value: String(summary.existing))
                        LabeledContent("Not on iPhone", value: String(summary.notLocal))
                        LabeledContent("Failed", value: String(summary.failed))
                    }
                }

                IOSOperationLogSection(model: model)

                if case let .error(message) = model.state {
                    Section("Error") {
                        Text(message).foregroundStyle(.red)
                        Button("Open Settings") {
                            guard let url = URL(
                                string: UIApplication.openSettingsURLString
                            ) else { return }
                            openURL(url)
                        }
                    }
                }
            }
            .navigationTitle("iPhone Sync")
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
            .task {
                await model.bootstrap()
                model.enteredForeground()
            }
        }
    }

    private var accessText: String {
        switch model.authorizationStatus {
        case .authorized: "Full Access"
        case .limited: "Limited (insufficient)"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}

private struct AutomaticSyncSection: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        Section("Automatic Sync") {
            Toggle(
                "Automatically sync",
                isOn: Binding(
                    get: { model.automaticSync.isEnabled },
                    set: { model.setAutomaticSyncEnabled($0) }
                )
            )
            .disabled(
                !model.automaticSync.isEnabled
                    && !model.canEnableAutomaticSync
            )

            LabeledContent("Cadence", value: model.automaticCadenceText)
            LabeledContent(
                "Background App Refresh",
                value: model.backgroundRefreshText
            )

            if model.automaticRunIsActive {
                LabeledContent("Status") {
                    HStack {
                        ProgressView()
                        Text("Syncing")
                    }
                }
            } else {
                LabeledContent("Last outcome", value: model.automaticOutcomeText)
            }

            if let attempt = model.automaticSync.lastAttemptAt {
                LabeledContent(
                    "Last attempt",
                    value: attempt.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let success = model.automaticSync.lastSuccessAt {
                LabeledContent(
                    "Last success",
                    value: success.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let eligible = model.automaticSync.nextEligibleAt {
                LabeledContent(
                    "Eligible after",
                    value: eligible.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Text("iOS chooses the actual background run time. Keep Sync Now as the immediate fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
