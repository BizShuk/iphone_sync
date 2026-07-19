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
                LabeledContent("Paired iPhone", value: model.pairedPeer?.displayName ?? "Not paired")
                HStack {
                    Button("Choose Destination") { model.chooseDestination() }
                    Button("Pair iPhone") { model.openPairingWindow() }
                    Button("Reset Source") { model.resetSource() }
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
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 580, minHeight: 470)
        .task { await model.bootstrap() }
    }
}
