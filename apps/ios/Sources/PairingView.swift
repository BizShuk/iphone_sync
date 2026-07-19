import SwiftUI

struct PairingView: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the six-digit code shown by iPhone Sync on your Mac. The code stays on your devices and is never sent over the network.")
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
                }
                Button("Pair") { model.confirmPairing() }
                    .disabled(model.pairingCode.count != 6)
            }
            .navigationTitle("Pair Mac")
        }
    }
}
