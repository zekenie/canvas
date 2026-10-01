import AppKit

/// The card's look. World units. Its colors follow the appearance it's drawn in, resolved as it's
/// drawn (each `NSColor` is dynamic, its `cgColor` read in the render), since a subboard is a
/// place on the canvas, not a sheet of paper as a note is: light on the light canvas, dark on the
/// dark one.
@MainActor
enum SubboardStyle {
    static let cornerRadius: CGFloat = 10
    static let padding: CGFloat = 10
    /// Between the card's edges and the board's preview.
    static let previewInset: CGFloat = 12
    /// The board's preview is drawn at most this fraction of its size, as the canvas shows it at
    /// 10%: a board of one note shows a small note in the middle, and one of hundreds fills the
    /// card, so the two don't look alike.
    static let previewMaxScale: CGFloat = 0.1
    static let borderWidth: CGFloat = 1.5
    /// Between the symbol and the caption under it, where the card says what its board holds.
    static let captionSpacing: CGFloat = 6

    /// The kind's indigo: its border, its symbol, its row's symbol and its mentions' tint.
    static let border = NSColor.systemIndigo
    /// The card: a faint indigo over white in the light, a raised indigo-gray in the dark, a step
    /// up from the canvas as a panel is.
    static let cardFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.19, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.98, blue: 1, alpha: 1)
    }
    static let secondaryText = NSColor.secondaryLabelColor

    static let captionFont = NSFont.systemFont(ofSize: 12)
    static let captionLineHeight = lineHeight(of: captionFont)
    static let caption: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: secondaryText, .paragraphStyle: oneLine(.center)]

    /// The kind's symbol over "Empty", on a card whose board has nothing.
    static let glyph: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
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

    /// Where the board's preview is fitted: the card, inset.
    static func preview(in card: CGRect) -> CGRect {
        card.insetBy(dx: previewInset, dy: previewInset)
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

extension NSAppearance {
    fileprivate var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
