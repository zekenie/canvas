import AppKit
import Palette

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

    /// The kind's indigo: its tint (its row's symbol, its mentions'), and the card's border and symbol
    /// only where no color book is installed.
    static let border = NSColor.systemIndigo
    /// The card's look with no color (and what Titles' cover matches): a faint indigo over white in the light, a raised indigo-gray in the dark, a step
    /// up from the canvas as a panel is.
    static let cardFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.19, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.98, blue: 1, alpha: 1)
    }
    static let secondaryText = NSColor.secondaryLabelColor

    static let captionFont = NSFont.systemFont(ofSize: 12)
    static let captionLineHeight = lineHeight(of: captionFont)
    static let caption: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: secondaryText, .paragraphStyle: oneLine(.center)]

    /// The kind's symbol over "Empty", on a card whose board has nothing, in `solid` (the card's
    /// color, in the appearance being drawn). One image a color and appearance, made when first
    /// asked for and kept, since tinting as it draws would remake the symbol's alpha mask each
    /// frame; a color the file changes is another key. Plain indigo with no color.
    static func glyph(in solid: CGColor?) -> NSImage? {
        let color = solid.flatMap { NSColor(cgColor: $0) } ?? border
        let key = glyphKey(color)
        if let known = glyphs[key] { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: Subboard.systemImage, accessibilityDescription: "Subboard")?.withSymbolConfiguration(configuration)
        if glyphs.count >= glyphCapacity { glyphs.removeAll(keepingCapacity: true) }
        glyphs[key] = image
        return image
    }

    private static let glyphCapacity = 64
    private static var glyphs: [UInt32: NSImage?] = [:]

    /// A color's sRGB components, packed to 8 bits each.
    private static func glyphKey(_ color: NSColor) -> UInt32 {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ x: CGFloat) -> UInt32 { UInt32((min(max(x, 0), 1) * 255).rounded()) }
        return byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
    }

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
