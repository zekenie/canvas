import AppKit

/// The card's look. World units.
@MainActor
enum SubboardStyle {
    static let cornerRadius: CGFloat = 10
    /// The plates behind the card: each this much narrower on each side than the one in front of it,
    /// and showing this much below it.
    static let plateInset: CGFloat = 6
    static let plateStep: CGFloat = 4
    static let headerHeight: CGFloat = 32
    static let padding: CGFloat = 10
    /// Between the symbol and the title.
    static let spacing: CGFloat = 6
    /// Between the body's edges and the board's preview.
    static let previewInset: CGFloat = 12
    static let borderWidth: CGFloat = 1.5
    static let plateBorderWidth: CGFloat = 1
    /// The line between the header band and the body.
    static let ruleWidth: CGFloat = 1
    static let ruleAlpha: CGFloat = 0.25

    static let border = NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)
    static let cardFill = NSColor.white
    /// The border's indigo at 15% over the card.
    static let headerFill = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.98, alpha: 1)
    static let plate = NSColor(white: 0.97, alpha: 1)
    static let plateBorder = border.withAlphaComponent(0.45)
    static let text = NSColor(white: 0.12, alpha: 1)
    /// A placeholder's, as a tertiary label is on white.
    static let tertiaryText = NSColor(white: 0.62, alpha: 1)
    static let secondaryText = NSColor(white: 0.45, alpha: 1)

    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let captionFont = NSFont.systemFont(ofSize: 12)
    static let titleLineHeight = lineHeight(of: titleFont)
    static let captionLineHeight = lineHeight(of: captionFont)

    static let title: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: text, .paragraphStyle: oneLine()]
    static let placeholderTitle: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: tertiaryText, .paragraphStyle: oneLine()]
    static let caption: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: secondaryText, .paragraphStyle: oneLine(.center)]

    static let glyph: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [border]))
        return NSImage(systemSymbolName: Subboard.systemImage, accessibilityDescription: "Subboard")?.withSymbolConfiguration(configuration)
    }()

    /// "Empty", "1 shape", "1,200 shapes".
    static func caption(of count: Int) -> String {
        switch count {
        case 0: "Empty"
        case 1: "1 shape"
        default: "\(count.formatted()) shapes"
        }
    }

    /// Whether a frame has room for the plates: the card left above them as tall as the header, and
    /// the back one as wide as the card is tall. A card sized smaller is the whole frame.
    static func hasPlates(_ frame: CGRect) -> Bool {
        frame.height >= headerHeight + plateStep * 2 && frame.width >= plateInset * 4 + headerHeight
    }

    /// The card: the frame less the plates showing below it.
    static func card(of frame: CGRect) -> CGRect {
        guard hasPlates(frame) else { return frame }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - plateStep * 2)
    }

    /// The plates behind the card, the back one first: each narrower, and lower by a step, than the
    /// one in front, the back one's foot on the frame's.
    static func plates(of frame: CGRect) -> [CGRect] {
        guard hasPlates(frame) else { return [] }
        let card = card(of: frame)
        return [2, 1].map { (n: CGFloat) in
            CGRect(x: card.minX + plateInset * n, y: card.minY + plateStep * n, width: card.width - plateInset * n * 2, height: card.height)
        }
    }

    /// The header band across the card's top, no taller than the card.
    static func header(of card: CGRect) -> CGRect {
        CGRect(x: card.minX, y: card.minY, width: card.width, height: min(headerHeight, card.height))
    }

    static func body(of card: CGRect, below header: CGRect) -> CGRect {
        CGRect(x: card.minX, y: header.maxY, width: card.width, height: max(0, card.maxY - header.maxY))
    }

    /// Where the board's preview is fitted: the body, inset.
    static func preview(in body: CGRect) -> CGRect {
        body.insetBy(dx: previewInset, dy: previewInset)
    }

    static func path(_ rect: CGRect, radius: CGFloat = cornerRadius) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func oneLine(_ alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        return style
    }

    /// A line's height as the card lays text out: string drawing's, rounded up.
    private static func lineHeight(of font: NSFont) -> CGFloat {
        NSAttributedString(string: "X", attributes: [.font: font])
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
            .height.rounded(.up)
    }
}
