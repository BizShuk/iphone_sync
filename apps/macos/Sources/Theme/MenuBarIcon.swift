import AppKit

/// Programmatically drawn template images for the menu bar status item.
///
/// The icon encodes the product's actual subject — two paired endpoints
/// with a gap between them. Template rendering keeps it adaptive to
/// the menu bar's appearance (black on light, white on dark).
enum MenuBarIcon {

    enum State {
        case idle
        case receiving
    }

    /// 18×14pt template image drawn at @1x. AppKit will produce the
    /// @2x variant automatically for Retina menu bars.
    static func image(state: State) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state: state, in: NSRect(origin: .zero, size: size))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "iPhone Sync"
        return image
    }

    private static func draw(state: State, in rect: NSRect) {
        // Phone outline on the left (taller, rounded).
        let phoneRect = NSRect(x: 0, y: 2, width: 7, height: 10)
        let phonePath = NSBezierPath(roundedRect: phoneRect, xRadius: 1.6, yRadius: 1.6)
        phonePath.lineWidth = 1.2

        // Mac outline on the right (wider, less rounded).
        let macRect = NSRect(x: 11, y: 2, width: 7, height: 10)
        let macPath = NSBezierPath(roundedRect: macRect, xRadius: 0.8, yRadius: 0.8)
        macPath.lineWidth = 1.2

        // Template strokes use black; AppKit inverts for dark menu bars.
        NSColor.black.setStroke()

        switch state {
        case .idle:
            phonePath.stroke()
            macPath.stroke()
        case .receiving:
            // Outline both, plus a small filled dot in the gap indicating
            // an active connection. The dot also picks up the template
            // tint, so it reads as the system accent.
            phonePath.stroke()
            macPath.stroke()
            let dot = NSBezierPath(
                ovalIn: NSRect(x: 8.2, y: 6.2, width: 1.6, height: 1.6)
            )
            NSColor.black.setFill()
            dot.fill()
        }
    }
}
