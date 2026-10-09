import AppKit
import Canvas

/// Where mention text is shown, which says how its pills are colored: on a shape's surface (a
/// note), in the text's own color, since a tint on a tinted shape would vanish; or on a neutral
/// one (a panel, the picker), in the system's colors, with the target's tint on its symbol.
public enum MentionSurface: Hashable, Sendable {
    case shape
    case neutral
}

/// How mention text looks: one style shared by a kind's render and its editing view, as a note's
/// attributes are, so the text is on the same lines in both. Its conformance to `Hashable` is
/// main-actor isolated, since `NSFont` isn't `Sendable` and a nonisolated `==` couldn't read it.
@MainActor
public struct MentionTextStyle: @MainActor Hashable {
    public let font: NSFont
    public let color: NSColor
    /// Every line this tall, in string drawing and TextKit 2 alike; nil for the font's own.
    public let lineHeight: CGFloat?
    public let surface: MentionSurface
    /// What `attributes` returns, made once.
    private let madeAttributes: [NSAttributedString.Key: Any]

    public init(font: NSFont, color: NSColor, lineHeight: CGFloat? = nil, surface: MentionSurface = .shape) {
        self.font = font
        self.color = color
        self.lineHeight = lineHeight
        self.surface = surface
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let lineHeight {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            attributes[.paragraphStyle] = paragraph.copy()
        }
        madeAttributes = attributes
    }

    /// The text's attributes: its font, its color, and its fixed line height, if it has one. What a
    /// text view types with.
    public var attributes: [NSAttributedString.Key: Any] { madeAttributes }

    public static func == (a: MentionTextStyle, b: MentionTextStyle) -> Bool {
        a.font == b.font && a.color == b.color && a.lineHeight == b.lineHeight && a.surface == b.surface
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(font)
        hasher.combine(color)
        hasher.combine(lineHeight)
        hasher.combine(surface)
    }

    /// The text as it's drawn and edited: its text runs with `attributes`, and each mention one
    /// character (U+FFFC) with them, holding a `MentionAttachment`, the pill, as `resolve` says it
    /// shows now. A pill that isn't live carries a tooltip ("Deleted"), which text views show.
    /// Text without mentions is one plain run, as a string drawn with `attributes` alone would be.
    public func attributedString<S>(_ text: ScopedMentionText<S>, resolve: (ShapeID) -> MentionResolution) -> NSAttributedString {
        attributedString(text, width: nil, resolve: resolve)
    }

    /// The same, for text laid out `width` points wide: no pill is wider than that.
    public func attributedString<S>(_ text: ScopedMentionText<S>, width: CGFloat?, resolve: (ShapeID) -> MentionResolution) -> NSAttributedString {
        if text.runs.count == 1, case .text(let only) = text.runs[0] {
            return NSAttributedString(string: only, attributes: madeAttributes)
        }
        let string = NSMutableAttributedString()
        for run in text.runs {
            switch run {
            case .text(let text):
                string.append(NSAttributedString(string: text, attributes: madeAttributes))
            case .mention(let id, let label):
                let attachment = MentionAttachment(target: id, storedLabel: label, resolution: resolve(id), style: self, width: width)
                string.append(pill(attachment))
            }
        }
        return string
    }

    /// The text as it's measured from itself alone, where no shape is looked up (a kind fitting its
    /// height to it as a pure function of its props, `DerivedProps`: a note made by `canvas draw`):
    /// each mention a live pill by the name it holds, which is as wide as the canvas draws it while
    /// its shape is called that, whatever its kind's symbol (a symbol has a slot of its own,
    /// `MentionStyle.symbolSlot`). One drawn missing or unavailable has no symbol, so it's narrower.
    public func measuredString<S>(_ text: ScopedMentionText<S>, width: CGFloat?) -> NSAttributedString {
        var labels = text.runs.lazy.compactMap { run -> String? in
            if case .mention(_, let label) = run { label } else { nil }
        }.makeIterator()
        // Its symbol is drawn nowhere, so it names none: the slot is the same.
        return attributedString(text, width: width) { _ in
            .live(MentionAppearance(label: labels.next() ?? "", systemImage: "", kindName: "", detail: ""))
        }
    }

    /// Where each of `ranges` of `string` (made by `attributedString`) is when the canvas draws it
    /// in a box of `size` (`drawMentionText`): a rect a line the range is on, from the box's
    /// top-left (down is +y), as wide as its glyphs and pills there and as tall as the line; none
    /// on a line past the box. For what a shape draws behind some of its words (a type's
    /// highlights).
    public func lineRects(of ranges: [NSRange], in string: NSAttributedString, size: CGSize) -> [[CGRect]] {
        MentionTextLayout.lineRects(of: ranges, in: string, size: size, style: self)
    }

    /// One pill: its attachment's character, with the text's attributes, so its line keeps its height.
    public func pill(_ attachment: MentionAttachment) -> NSAttributedString {
        let pill = NSMutableAttributedString(attachment: attachment)
        var attributes = madeAttributes
        if let help = attachment.help { attributes[.toolTip] = help }
        pill.addAttributes(attributes, range: NSRange(location: 0, length: pill.length))
        return pill
    }

    /// The inverse, canonical: each pill a mention of its target, named as it shows now (its live
    /// label, else the one it holds), the rest text as it reads. An attachment that isn't a pill
    /// (an image) is left out.
    public static func mentionText<S>(from string: NSAttributedString) -> ScopedMentionText<S> {
        var runs: [MentionRun] = []
        let characters = string.string as NSString
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let pill = value as? MentionAttachment {
                for _ in 0..<range.length { runs.append(.mention(pill.target, label: pill.writtenLabel)) }
            } else if value == nil {
                runs.append(.text(characters.substring(with: range)))
            } else {
                let text = characters.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                runs.append(.text(text))
            }
        }
        return ScopedMentionText(runs)
    }
}
