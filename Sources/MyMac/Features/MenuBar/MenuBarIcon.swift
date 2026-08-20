import AppKit

/// Draws the status bar readout as a single image.
///
/// SwiftUI's `Text("\(Image(systemName:)) 42%")` reports the symbol to
/// accessibility but does not actually paint it inside a `MenuBarExtra` label —
/// the result is the percentages with a blank gap where each icon should be.
/// Rendering it here removes the guesswork: the layout is exact, it is one
/// image node for AppKit to lay out rather than a stack of views, and marking it
/// as a template lets macOS tint it correctly in light mode, dark mode and while
/// the menu is highlighted.
enum MenuBarIcon {
    struct Segment {
        let symbol: String
        let text: String
    }

    /// One metric on its own gets a readable single line; two are stacked, which
    /// roughly halves the width. A menu bar is shared real estate, and two
    /// readouts side by side read as two separate items rather than one.
    private static let singleFontSize: CGFloat = 12
    private static let stackedFontSize: CGFloat = 10
    private static let symbolGap: CGFloat = 3
    private static let height: CGFloat = 20

    static func render(_ segments: [Segment]) -> NSImage {
        segments.count >= 2 ? stacked(segments) : single(segments)
    }

    // MARK: - Layouts

    private static func single(_ segments: [Segment]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: singleFontSize, weight: .regular)
        let rows = segments.map { row(for: $0, font: font, symbolSize: singleFontSize) }
        let slot = textSlot(font: font)
        let width = rows.map { rowWidth($0, slot: slot) }.max() ?? 1

        return image(width: width) {
            draw(rows[0], at: (height - lineHeight(font)) / 2, slot: slot, font: font)
        }
    }

    private static func stacked(_ segments: [Segment]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: stackedFontSize, weight: .regular)
        let rows = segments.prefix(2).map { row(for: $0, font: font, symbolSize: stackedFontSize) }
        let slot = textSlot(font: font)
        let width = rows.map { rowWidth($0, slot: slot) }.max() ?? 1
        let line = lineHeight(font)
        let top = (height - line * 2) / 2

        return image(width: width) {
            draw(rows[1], at: top, slot: slot, font: font)
            draw(rows[0], at: top + line, slot: slot, font: font)
        }
    }

    // MARK: - Pieces

    private struct Row {
        let symbol: NSImage?
        let text: NSAttributedString
    }

    private static func row(for segment: Segment, font: NSFont, symbolSize: CGFloat) -> Row {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        return Row(
            symbol: NSImage(systemSymbolName: segment.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration),
            // Template rendering only reads coverage, so the colour just needs
            // to be fully opaque.
            text: NSAttributedString(string: segment.text, attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
            ])
        )
    }

    /// Numbers are right-aligned in a slot wide enough for the largest value, so
    /// the item keeps a constant width and the status bar never reflows.
    private static func textSlot(font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: "100%", attributes: [.font: font]).size().width)
    }

    private static func rowWidth(_ row: Row, slot: CGFloat) -> CGFloat {
        (row.symbol.map { $0.size.width + symbolGap } ?? 0) + (row.text.string.isEmpty ? 0 : slot)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender)
    }

    private static func draw(_ row: Row, at y: CGFloat, slot: CGFloat, font: NSFont) {
        var x: CGFloat = 0
        if let symbol = row.symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x, y: (y + (lineHeight(font) - size.height) / 2).rounded(),
                                   width: size.width, height: size.height))
            x += size.width + symbolGap
        }
        guard !row.text.string.isEmpty else { return }
        let textWidth = ceil(row.text.size().width)
        row.text.draw(at: NSPoint(x: x + slot - textWidth, y: y.rounded()))
    }

    private static func image(width: CGFloat, _ body: () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: max(1, ceil(width)), height: height))
        image.lockFocus()
        body()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
