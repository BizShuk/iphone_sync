import SwiftUI

/// Six-digit pairing code entry as six individually framed mono cells.
///
/// Mirrors the shape of `PairingCodeDisplay` on Mac — they read and
/// write the same artifact. A hidden `TextField` captures the numeric
/// keypad and forwards digits into the bound `code` string.
struct PairingCodeInput: View {
    @Binding var code: String
    let maxDigits: Int
    let onComplete: () -> Void

    @FocusState private var isFocused: Bool

    init(
        code: Binding<String>,
        maxDigits: Int = 6,
        onComplete: @escaping () -> Void = {}
    ) {
        self._code = code
        self.maxDigits = maxDigits
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(0..<maxDigits, id: \.self) { index in
                    PairingDigitCell(
                        digit: digit(at: index),
                        isFilled: index < code.count
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // Hidden numeric keypad capture. Sized to 0×0 and placed
            // below the visible cells so it never covers them.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityLabel("Pairing code")
                .onChange(of: code) { _, newValue in
                    let filtered = String(
                        newValue.filter(\.isNumber).prefix(maxDigits)
                    )
                    if filtered != newValue {
                        code = filtered
                    }
                    if code.count == maxDigits {
                        onComplete()
                    }
                }

            Button {
                isFocused = true
            } label: {
                Text("Tap to type the code")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isFocused ? 0 : 1)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        let chars = Array(code)
        return String(chars[index])
    }
}

private struct PairingDigitCell: View {
    let digit: String
    let isFilled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Layout.cellCornerRadius)
                .fill(Tokens.Palette.paper)
            RoundedRectangle(cornerRadius: Tokens.Layout.cellCornerRadius)
                .stroke(
                    isFilled
                        ? Tokens.Palette.signal
                        : Tokens.Palette.wire.opacity(0.5),
                    lineWidth: 1.5
                )
            if isFilled {
                Text(digit)
                    .font(.system(size: 28, weight: .regular, design: .monospaced))
                    .foregroundStyle(Tokens.Palette.wire)
            } else {
                Text("·")
                    .font(.system(size: 28, weight: .regular, design: .monospaced))
                    .foregroundStyle(Tokens.Palette.wire.opacity(0.3))
            }
        }
        .frame(
            width: Tokens.Layout.pairingCellSize.width,
            height: Tokens.Layout.pairingCellSize.height
        )
        .accessibilityHidden(true)
    }
}
