import SwiftUI
import SyncCore

struct SetupView: View {
    @Bindable var model: MacAppModel

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Receiver", value: model.statusText)
                if case let .error(message) = model.state {
                    Text(message).foregroundStyle(.red)
                }
                if case let .pairing(code, expiresAt) = model.state {
                    LabeledContent("Pairing code") {
                        Text(code).font(.system(.title2, design: .monospaced))
                    }
                    LabeledContent("Expires") {
                        Text(expiresAt, style: .relative)
                    }
                }
            }

            Section("Backup") {
                LabeledContent("Destination") {
                    Text(model.destinationURL?.path(percentEncoded: false) ?? "Not selected")
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Choose Destination") { model.chooseDestination() }
                    Button("Pair iPhone") { model.openPairingWindow() }
                    Button("Reset Source") { model.resetSource() }
                }
            }

            Section("Paired iPhone") {
                if let peer = model.pairedPeer {
                    LabeledContent("Name", value: peer.displayName)
                    LabeledContent("Device ID") {
                        Text(peer.id)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(
                        "iOS does not expose the hardware serial number to apps. "
                            + "Device ID is the app-specific identifier exchanged during pairing."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Not paired")
                        .foregroundStyle(.secondary)
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

            Section("Operation Log") {
                HStack {
                    Text(
                        model.operationLog.isEmpty
                            ? "No operations recorded"
                            : "\(model.operationLog.count) recorded"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy All") { model.copyOperationLog() }
                        .disabled(model.operationLog.isEmpty)
                    Button("Clear") { model.clearOperationLog() }
                        .disabled(model.operationLog.isEmpty)
                }

                Text(
                    "Keeps the latest \(OperationLogBuffer.defaultCapacity) semantic "
                        + "operations for this app run. Secrets, pairing codes, and "
                        + "full destination paths are not recorded."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !model.operationLog.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.operationLog) { entry in
                                MacOperationLogRow(entry: entry)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                }
            }

            Section("System") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                Button("Forget Paired iPhone", role: .destructive) {
                    model.forgetPhone()
                }
                .disabled(model.pairedPeer == nil)
                Text(
                    "If the icon is missing, the menu bar has no free space. "
                        + "Hide one menu bar item, then hold Command and drag "
                        + "iPhone Sync closer to the right."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 580, minHeight: 620)
        .task { await model.bootstrap() }
    }
}

private struct MacOperationLogRow: View {
    let entry: OperationLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityLabel(entry.level.rawValue)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.category)
                    Spacer()
                    Text(
                        entry.occurredAt.formatted(
                            date: .abbreviated,
                            time: .standard
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    private var symbolName: String {
        switch entry.level {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch entry.level {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
