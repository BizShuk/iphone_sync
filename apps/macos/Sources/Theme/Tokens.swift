import AppKit
import SwiftUI

/// iPhone Sync design tokens — color, typography, spacing.
///
/// The palette mirrors the iOS token set so both apps feel like one
/// product. Both light and dark menu bar appearances are supported.
enum Tokens {

    // MARK: Color

    enum Palette {
        /// Primary text and monospaced pairing code.
        static let wire = adaptive(light: 0x1F2024, dark: 0xE8E9EE)

        /// Card and form background.
        static let paper = adaptive(light: 0xFAFBFC, dark: 0x101113)

        /// Hairline borders, separators, progress tracks.
        static let frame = adaptive(light: 0xE2E4E8, dark: 0x26282C)

        /// Accent — connection, active state, primary action.
        static let signal = adaptive(light: 0xFF6B35, dark: 0xFF8559)

        /// Success / committed.
        static let verified = adaptive(light: 0x3F8C5E, dark: 0x5BA579)

        /// Errors, warnings.
        static let alert = adaptive(light: 0xC84B3F, dark: 0xE16B5F)
    }

    // MARK: Typography

    enum Typography {
        /// Page title.
        static let displayTitle = Font.system(
            size: 28, weight: .semibold, design: .rounded
        )

        /// Pairing code — the only role at this size, used with restraint.
        static let numericDisplay = Font.system(
            size: 56, weight: .regular, design: .monospaced
        )

        /// Section header (Status, Backup, Operation Log).
        static let sectionHeader = Font.system(size: 13, weight: .medium)

        /// Default body.
        static let body = Font.system(size: 15, weight: .regular)

        /// Operation Log messages.
        static let callout = Font.system(size: 14, weight: .regular)

        /// Helper text, secondary captions.
        static let caption = Font.system(size: 12, weight: .regular)

        /// Counters, byte counts, device ID, hash prefixes.
        static let numericData = Font.system(
            size: 13, weight: .medium, design: .monospaced
        )
    }

    // MARK: Layout

    enum Layout {
        static let cardCornerRadius: CGFloat = 12
        static let cellCornerRadius: CGFloat = 6
        static let hairline: CGFloat = 1
        static let cardPadding: CGFloat = 16
        static let sectionSpacing: CGFloat = 20
        static let pairingCellSize: CGSize = .init(width: 52, height: 80)
    }
}

private func adaptive(light: UInt32, dark: UInt32) -> Color {
    let l = make(hex: light)
    let d = make(hex: dark)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? d : l
    })
}

private func make(hex: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}
