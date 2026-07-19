import Photos
import SwiftUI

struct ContentView: View {
    @Bindable var model: IOSAppModel
    @State private var showsAlbumPicker = false

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
                            "Album",
                            value: model.selectedAlbum?.title ?? "Not selected"
                        )
                    }
                    .disabled(!model.hasFullPhotoAccess)
                }

                Section("Mac") {
                    LabeledContent(
                        "Paired Mac",
                        value: model.pairedPeer?.displayName ?? "Not paired"
                    )
                    Button("Find Mac") { model.findMac() }
                    ForEach(model.receivers) { receiver in
                        Button {
                            model.beginPairing(with: receiver)
                        } label: {
                            Label(receiver.displayName, systemImage: "desktopcomputer")
                        }
                        .disabled(model.pairedPeer != nil)
                    }
                    if model.pairedPeer != nil {
                        Button("Forget Mac", role: .destructive) { model.forgetMac() }
                    }
                }

                Section("Backup") {
                    Button("Sync Now") { model.syncNow() }
                        .disabled(!model.canSync)
                    if model.state == .syncing {
                        if let progress = model.progress {
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

                if let summary = model.lastSummary {
                    Section("Last Sync") {
                        LabeledContent("Added", value: String(summary.added))
                        LabeledContent("Already present", value: String(summary.existing))
                        LabeledContent("Not on iPhone", value: String(summary.notLocal))
                        LabeledContent("Failed", value: String(summary.failed))
                    }
                }

                if case let .error(message) = model.state {
                    Section("Error") {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("iPhone Sync")
            .sheet(isPresented: $showsAlbumPicker) {
                AlbumPickerView(albums: model.albums, select: model.selectAlbum)
            }
            .sheet(isPresented: Binding(
                get: { model.pairingIsPending },
                set: { model.pairingIsPending = $0 }
            )) {
                PairingView(model: model)
            }
            .task { await model.bootstrap() }
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
