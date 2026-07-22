import SwiftUI

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

            Section("Error Log") {
                HStack {
                    Text(
                        model.errorLog.isEmpty
                            ? "No errors recorded"
                            : "\(model.errorLog.count) recorded"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.clearErrorLog() }
                        .disabled(model.errorLog.isEmpty)
                }

                if !model.errorLog.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.errorLog) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.context)
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
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 90, maxHeight: 190)
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
