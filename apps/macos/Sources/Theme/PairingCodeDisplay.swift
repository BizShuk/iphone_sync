import SwiftUI

/// The signature element of the product — the six-digit pairing code
/// rendered as six individually framed monospaced cells with eyebrow
/// label, helper copy, mono countdown, and attempts indicator.
///
/// The two-minute pairing window is the only moment a user reads a
/// six-digit number in the entire product, so it earns a deliberate
/// visual treatment.
struct PairingCodeDisplay: View {
    let code: String
    let expiresAt: Date
    let remainingAttempts: Int
    let totalAttempts: Int

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Text("PAIRING CODE")
                .font(Tokens.Typography.sectionHeader)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { index in
                    PairingCodeCell(digit: digit(at: index))
                }
            }

            Text("Verify on iPhone — code never travels.")
                .font(Tokens.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Rectangle()
                    .fill(Tokens.Palette.frame)
                    .frame(height: Tokens.Layout.hairline)
                    .frame(maxWidth: 60)
                Text(expiresAt, style: .relative)
                    .font(Tokens.Typography.numericData)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Tokens.Palette.frame)
                    .frame(height: Tokens.Layout.hairline)
                    .frame(maxWidth: 60)
            }

            HStack(spacing: 6) {
                Text("attempts")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(.tertiary)
                ForEach(0..<totalAttempts, id: \.self) { index in
                    Circle()
                        .fill(index < remainingAttempts
                              ? Tokens.Palette.alert
                              : Tokens.Palette.frame)
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(remainingAttempts) of \(totalAttempts) attempts remaining"
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func digit(at index: Int) -> String {
        let chars = Array(code)
        guard index < chars.count else { return "" }
        return String(chars[index])
    }
}

private struct PairingCodeCell: View {
    let digit: String

    var body: some View {
        Text(digit.isEmpty ? " " : digit)
            .font(Tokens.Typography.numericDisplay)
            .foregroundStyle(Tokens.Palette.wire)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(
                width: Tokens.Layout.pairingCellSize.width,
                height: Tokens.Layout.pairingCellSize.height
            )
            .background(
                RoundedRectangle(cornerRadius: Tokens.Layout.cellCornerRadius)
                    .fill(Color.white.opacity(0.001))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Layout.cellCornerRadius)
                    .stroke(Tokens.Palette.wire.opacity(0.6), lineWidth: 1.5)
            )
            .accessibilityLabel(digit.isEmpty ? "empty" : digit)
    }
}
