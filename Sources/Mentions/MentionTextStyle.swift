import AppKit
import Canvas
import Palette

/// Where mention text is shown, which says how its pills are colored: on a shape's surface (a
/// note), in the text's own color, since a tint on a tinted shape would vanish; or on a neutral
/// one (a panel, the picker), in the system's colors, with the target's tint on its symbol; or as a
/// value that points at a shape, where a pill is a white one with a hairline outline and no symbol.
public enum MentionSurface: Hashable, Sendable {
    case shape
    case neutral
    case outlined
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
    /// How its lines are set across the box: the writing direction's own unless a kind says (an
    /// arrow's label is centered).
    public let alignment: NSTextAlignment
    /// What `attributes` returns, made once.
    private let madeAttributes: [NSAttributedString.Key: Any]

    public init(font: NSFont, color: NSColor, lineHeight: CGFloat? = nil, surface: MentionSurface = .shape, alignment: NSTextAlignment = .natural) {
        self.font = font
        self.color = color
        self.lineHeight = lineHeight
        self.surface = surface
        self.alignment = alignment
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if lineHeight != nil || alignment != .natural {
            let paragraph = NSMutableParagraphStyle()
            if let lineHeight {
                paragraph.minimumLineHeight = lineHeight
                paragraph.maximumLineHeight = lineHeight
            }
            paragraph.alignment = alignment
            attributes[.paragraphStyle] = paragraph.copy()
        }
        madeAttributes = attributes
    }

    /// The text's attributes: its font, its color, and its fixed line height, if it has one. What a
    /// text view types with.
    public var attributes: [NSAttributedString.Key: Any] { madeAttributes }

    public static func == (a: MentionTextStyle, b: MentionTextStyle) -> Bool {
        a.font == b.font && a.color == b.color && a.lineHeight == b.lineHeight && a.surface == b.surface && a.alignment == b.alignment
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(font)
        hasher.combine(color)
        hasher.combine(lineHeight)
        hasher.combine(surface)
        hasher.combine(alignment)
    }

    /// The text as it's drawn and edited: its text runs with `attributes`, and each mention one
    /// character (U+FFFC) with them, holding a `MentionAttachment`, the pill, as `resolve` says it
    /// shows now. A pill that isn't live carries a tooltip ("Deleted"), which text views show.
    /// Text without mentions is one plain run, as a string drawn with `attributes` alone would be.
    public func attributedString<S>(_ text: ScopedMentionText<S>, resolve: (PartAddress) -> MentionResolution) -> NSAttributedString {
        attributedString(text, width: nil, resolve: resolve)
    }

    /// The same, for text laid out `width` points wide: no pill is wider than that.
    public func attributedString<S>(_ text: ScopedMentionText<S>, width: CGFloat?, resolve: (PartAddress) -> MentionResolution) -> NSAttributedString {
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
    ///
    /// `names`, if given, are the names the mentions show now, one for each, in order
    /// (`ShapeContext.mentionNames`: a layout input that follows a rename, which writes nothing to
    /// the text), and measure in place of the names the text holds.
    public func measuredString<S>(_ text: ScopedMentionText<S>, width: CGFloat?, names: [String]? = nil) -> NSAttributedString {
        let held = text.runs.compactMap { run -> String? in
            if case .mention(_, let label) = run { label } else { nil }
        }
        var next = 0
        func label() -> String {
            defer { next += 1 }
            if let names, next < names.count { return names[next] }
            return next < held.count ? held[next] : ""
        }
        // Its symbol is drawn nowhere, so it names none: the slot is the same. A row's lead isn't known from the text alone, so a
        // row's pill that leads with a word in capitals (an endpoint's "POST /orders") is measured with its chip, which is
        // narrower than the symbol's slot and the word's letters in the label's size.
        return attributedString(text, width: width) { target in
            let shown = label()
            return .live(MentionAppearance(label: shown, systemImage: "", kindName: "", detail: "",
                                           lead: target.part == nil ? .none : Self.measuredLead(of: shown)))
        }
    }

    /// The chip a row's pill measured from its label is taken to lead with: the label's first word, when it's in capitals and
    /// something follows it ("POST /orders/{id}"); no lead otherwise. Its color is the pill's, not its width.
    private static func measuredLead(of label: String) -> PartLead {
        guard let space = label.firstIndex(of: " ") else { return .none }
        let word = label[..<space]
        guard word.count >= 2, word.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return .none }
        return .chip(String(word), fill: RGB(0.5, 0.5, 0.5))
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
