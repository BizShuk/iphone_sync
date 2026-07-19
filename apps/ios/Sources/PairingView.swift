import SwiftUI

struct PairingView: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the six-digit code shown by iPhone Sync on your Mac. The code stays on your devices and is never sent over the network.")
                    if let expiresAt = model.pairingExpiresAt {
                        LabeledContent("Local timeout") {
                            Text(expiresAt, style: .relative)
                        }
                    }
                    TextField("000000", text: Binding(
                        get: { model.pairingCode },
                        set: { value in
                            model.pairingCode = String(
                                value.filter(\.isNumber).prefix(6)
                            )
                        }
                    ))
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .monospaced))
                    .multilineTextAlignment(.center)
                    if let error = model.pairingError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Button("Pair") { model.confirmPairing() }
                    .disabled(model.pairingCode.count != 6)
            }
            .navigationTitle("Pair Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelPairing() }
                }
            }
        }
    }
}
