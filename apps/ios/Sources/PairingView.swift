import SwiftUI

struct PairingView: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(
                        "Enter the six-digit code shown by the receiver on your computer. "
                            + "The code stays on your devices and is never sent over the network."
                    )
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let expiresAt = model.pairingExpiresAt {
                        HStack {
                            Text("Local timeout")
                                .font(Tokens.Typography.callout)
                            Spacer()
                            Text(expiresAt, style: .relative)
                                .font(Tokens.Typography.numericData)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    PairingCodeInput(
                        code: Binding(
                            get: { model.pairingCode },
                            set: { value in
                                model.pairingCode = String(
                                    value.filter(\.isNumber).prefix(6)
                                )
                            }
                        ),
                        maxDigits: 6,
                        onComplete: {
                            if model.pairingCode.count == 6 {
                                model.confirmPairing()
                            }
                        }
                    )

                    if let error = model.pairingError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Tokens.Palette.alert)
                            Text(error)
                                .font(Tokens.Typography.callout)
                                .foregroundStyle(Tokens.Palette.alert)
                        }
                    }

                    Button("Pair") { model.confirmPairing() }
                        .disabled(model.pairingCode.count != 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(model.pairingCode.count == 6
                                    ? Tokens.Palette.signal
                                    : Tokens.Palette.frame)
                        .foregroundStyle(model.pairingCode.count == 6
                                         ? .white
                                         : Tokens.Palette.wire.opacity(0.5))
                        .clipShape(RoundedRectangle(
                            cornerRadius: Tokens.Layout.cellCornerRadius
                        ))
                }
                .padding(.horizontal)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Tokens.Palette.paper)
            .navigationTitle("Pair Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelPairing() }
                }
            }
        }
    }
}
