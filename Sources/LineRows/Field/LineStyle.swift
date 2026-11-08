import AppKit
import TextEditing

/// How a kind's lines look while they're typed, in world units: its fonts and inks (the kind's at rest, so nothing moves
/// as editing starts), where a line's text starts in its row, the gutter, and the band behind the row with the caret.
/// What each span's look is drawn in follows from them (`attributes(for:)`, `highlight(of:)`).
@MainActor
public struct LineStyle {
    /// A row's name, and words nothing reads.
    public var font: NSFont
    /// Code (a type) and the grammar's own words.
    public var codeFont: NSFont
    public var ink: NSColor
    /// The grammar's own words (`null`, `default`).
    public var secondaryInk: NSColor
    /// From a row's left edge to where its text starts.
    public var textInset: CGFloat
    /// From a row's right edge to where its text may reach.
    public var trailingInset: CGFloat
    /// From a row's left edge to the middle of its gutter's mark.
    public var gutterMiddle: CGFloat
    /// The gutter's mark's size.
    public var markSize: CGFloat
    /// The band behind the row with the caret, and how far in from the paper's sides it is.
    public var band: NSColor
    public var bandInset: CGFloat

    public init(font: NSFont, codeFont: NSFont, ink: NSColor, secondaryInk: NSColor, textInset: CGFloat, trailingInset: CGFloat,
                gutterMiddle: CGFloat, markSize: CGFloat, band: NSColor = LineStyle.defaultBand, bandInset: CGFloat = 8) {
        self.font = font
        self.codeFont = codeFont
        self.ink = ink
        self.secondaryInk = secondaryInk
        self.textInset = textInset
        self.trailingInset = trailingInset
        self.gutterMiddle = gutterMiddle
        self.markSize = markSize
        self.band = band
        self.bandInset = bandInset
    }

    /// The band the frames draw behind the row with the caret: the accent, faint, over the paper.
    public static let defaultBand = NSColor(srgbRed: 0.84, green: 0.90, blue: 0.98, alpha: 1)

    /// What a line's characters are drawn in, before any span says otherwise.
    public var plain: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: ink] }

    /// What a span's characters are drawn in.
    public func attributes(for look: LineLook) -> [NSAttributedString.Key: Any] {
        switch look {
        case .name, .plain: plain
        case .code: [.font: codeFont, .foregroundColor: ink]
        case .keyword: [.font: codeFont, .foregroundColor: secondaryInk]
        case .pill(_, let ink), .dashedPill(_, let ink), .chip(_, let ink): [.font: codeFont, .foregroundColor: ink]
        case .tinted(let color): [.font: font, .foregroundColor: color]
        }
    }

    /// What's drawn under a span: a pill or a chip; nil for text drawn as it is.
    public func highlight(of span: LineSpan) -> TextHighlight? {
        switch span.look {
        case .pill(let fill, _), .chip(let fill, _): TextHighlight(range: span.range, fill: fill)
        case .dashedPill(let color, _): TextHighlight(range: span.range, fill: .clear, stroke: color, isDashed: true)
        default: nil
        }
    }
}
