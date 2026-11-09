import AppKit

/// A range of an `EditingTextView`'s text drawn on a rounded background, under the text, as a
/// mention's pill is: how a view marks text that means something to its owner (slash commands mark
/// the `/name` typed on a line, and what it's given; a rule's chips). Set on the view as `highlights`,
/// or derived from its text (`highlighting`); the view draws them, so a host forwards nothing.
/// UTF-16, as `NSRange` is.
public struct TextHighlight: Equatable {
    public var range: NSRange
    /// Drawn as it is: an owner that marks text on a surface it doesn't know takes the text's own
    /// color at a low alpha, as a pill does.
    public var fill: NSColor
    /// A symbol drawn at its start, in room the text makes for it before the range (a kern on the
    /// character before it, an indent of its line where it starts one), so the characters stay as they are.
    public var symbol: String?
    /// A line round it, in this color (a pill's edge), nil for none.
    public var stroke: NSColor?
    /// Whether that line is dashed: what's named but matches nothing yet (a body's type before its note exists).
    public var isDashed: Bool
    /// How tall it is and how round its corners, where the owner draws the same mark at rest in a shape of its own (an
    /// endpoint's method chip, 18 tall with corners of 3), so nothing moves as editing starts; nil: a pill's, from the font.
    public var height: CGFloat?
    public var cornerRadius: CGFloat?

    public init(range: NSRange, fill: NSColor, symbol: String? = nil, stroke: NSColor? = nil, isDashed: Bool = false,
                height: CGFloat? = nil, cornerRadius: CGFloat? = nil) {
        self.range = range
        self.fill = fill
        self.symbol = symbol
        self.stroke = stroke
        self.isDashed = isDashed
        self.height = height
        self.cornerRadius = cornerRadius
    }
}

extension EditingTextView {
    /// Where a highlight is drawn, in the view's coordinates: a rounded rect for each line its range
    /// reaches (a range that wraps is a rect a line), reaching a little past its text at both ends
    /// and as tall as a mention's pill in the text's font, centered in the line. Nothing for a range
    /// that is empty or isn't in the text, and, as for the caret's frame, nothing on TextKit 1.
    public func frames(of highlight: TextHighlight) -> [CGRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager, let storage = textStorage,
              highlight.range.length > 0, highlight.range.location >= 0, highlight.range.location <= storage.length,
              highlight.range.length <= storage.length - highlight.range.location,
              let start = content.location(content.documentRange.location, offsetBy: highlight.range.location),
              let end = content.location(start, offsetBy: highlight.range.length),
              let range = NSTextRange(location: start, end: end) else { return [] }
        layout.ensureLayout(for: range)
        let origin = textContainerOrigin
        let padding = TextEditingStyle.highlightPadding
        let highlightHeight = (highlightFontSize * TextEditingStyle.highlightHeight).rounded()
        var frames: [CGRect] = []
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            let height = highlight.height ?? min(segment.height, highlightHeight)
            let frame = CGRect(x: segment.minX - padding + origin.x, y: segment.midY - height / 2 + origin.y,
                               width: segment.width + 2 * padding, height: height)
            // A line can come in more than one segment (a wrapped line's trailing space, a run of other
            // attributes): one rect a line, or two translucent fills would overlap in a darker seam.
            if let last = frames.last, abs(last.midY - frame.midY) < max(height, 1) / 2 {
                frames[frames.count - 1] = last.union(frame)
            } else {
                frames.append(frame)
            }
            return true
        }
        return frames
    }

    /// Draws `highlights` with the view's background, so the text is drawn over them; one with a symbol reaches back
    /// over the room made for it, the symbol drawn there.
    func drawHighlights(in dirtyRect: NSRect) {
        guard !highlights.isEmpty else { return }
        let radius = (highlightFontSize * TextEditingStyle.highlightCornerRadius).rounded(.up)
        let room = symbolRoom
        for highlight in highlights {
            let radius = highlight.cornerRadius ?? radius
            var frames = frames(of: highlight)
            var image: NSImage?
            var symbolCenter: CGFloat?
            if let symbol = highlight.symbol, !frames.isEmpty {
                // At a line's start the room is an indent before the glyph; elsewhere a kern on the character before,
                // whose gap TextKit 2 splits between the two characters' segments, so the range's starts halfway in.
                let onLine = startsLine(highlight.range.location)
                let reach = onLine ? room : room / 2
                let glyphStart = frames[0].minX + TextEditingStyle.highlightPadding + (onLine ? 0 : room / 2)
                symbolCenter = glyphStart - room / 2
                frames[0].origin.x -= reach
                frames[0].size.width += reach
                let configuration = NSImage.SymbolConfiguration(pointSize: highlightFontSize * TextEditingStyle.highlightSymbolSize, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(hierarchicalColor: textColor ?? .labelColor))
                image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            }
            highlight.fill.setFill()
            for frame in frames where frame.intersects(dirtyRect) {
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            }
            if let stroke = highlight.stroke {
                // Inside the fill's edge, so a line one wide stays in the rect the fill is.
                let width = TextEditingStyle.highlightStrokeWidth
                stroke.setStroke()
                for frame in frames where frame.intersects(dirtyRect) {
                    let line = frame.insetBy(dx: width / 2, dy: width / 2)
                    let path = NSBezierPath(roundedRect: line, xRadius: max(0, radius - width / 2), yRadius: max(0, radius - width / 2))
                    path.lineWidth = width
                    if highlight.isDashed { path.setLineDash(TextEditingStyle.highlightDash, count: TextEditingStyle.highlightDash.count, phase: 0) }
                    path.stroke()
                }
            }
            if let image, let symbolCenter, let first = frames.first, first.intersects(dirtyRect) {
                let size = image.size
                let origin = CGPoint(x: symbolCenter - size.width / 2, y: first.midY - size.height / 2)
                image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: TextEditingStyle.highlightSymbolStrength,
                           respectFlipped: true, hints: nil)
            }
        }
    }

    /// The room a highlight's symbol takes before its text.
    var symbolRoom: CGFloat { (highlightFontSize * TextEditingStyle.highlightSymbolRoom).rounded() }

    /// Whether a highlight at `location` starts a line of the text (its start, or after a line break), where its symbol's
    /// room is an indent of the line; elsewhere it's a kern on the character before it.
    func startsLine(_ location: Int) -> Bool {
        guard let storage = textStorage, location > 0 else { return true }
        guard location <= storage.length else { return false }
        return CharacterSet.newlines.contains(Unicode.Scalar((storage.string as NSString).character(at: location - 1)) ?? " ")
    }

    /// Makes room before each highlight with a symbol: a kern on the character before it, or an indent of its line where
    /// it starts one; and takes back what was made for highlights there are no longer. Attributes only, never undone.
    func makeRoomForSymbols() {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let room = symbolRoom
        let starts = highlights.filter { $0.symbol != nil && $0.range.location <= storage.length }.map(\.range.location)
        var wanted: [Int: CGFloat] = [:]
        var indents: Set<Int> = []
        for start in starts {
            if startsLine(start) { if start < storage.length { indents.insert(start) } } else { wanted[start - 1] = room }
        }
        var kept: [Int: CGFloat] = [:]
        storage.enumerateAttribute(Self.symbolRoomKey, in: whole) { value, range, _ in
            guard value != nil else { return }
            for index in range.location..<NSMaxRange(range) { kept[index] = room }
        }
        var indented: Set<Int> = []
        storage.enumerateAttribute(Self.symbolIndentKey, in: whole) { value, range, _ in
            if value != nil { indented.insert(range.location) }
        }
        guard kept != wanted || indents != indented else { return }
        storage.beginEditing()
        for index in kept.keys where wanted[index] == nil {
            storage.removeAttribute(.kern, range: NSRange(location: index, length: 1))
            storage.removeAttribute(Self.symbolRoomKey, range: NSRange(location: index, length: 1))
        }
        for (index, value) in wanted where kept[index] == nil {
            storage.addAttributes([.kern: value, Self.symbolRoomKey: true], range: NSRange(location: index, length: 1))
        }
        let text = storage.string as NSString
        for start in indented.symmetricDifference(indents) {
            let line = text.paragraphRange(for: NSRange(location: start, length: 0))
            let style = ((storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle) ?? defaultParagraphStyle ?? .default)
                .mutableCopy() as! NSMutableParagraphStyle
            let indent = indents.contains(start)
            style.firstLineHeadIndent = indent ? room : 0
            storage.addAttribute(.paragraphStyle, value: style, range: line)
            // The mark is on the line's first character alone: two lines it holds never run together.
            if indent { storage.addAttribute(Self.symbolIndentKey, value: true, range: NSRange(location: line.location, length: 1)) }
            else { storage.removeAttribute(Self.symbolIndentKey, range: NSRange(location: line.location, length: 1)) }
        }
        storage.endEditing()
    }

    /// Marks what `makeRoomForSymbols` added, so it takes back only its own.
    static let symbolRoomKey = NSAttributedString.Key("TextEditing.symbolRoom")
    static let symbolIndentKey = NSAttributedString.Key("TextEditing.symbolIndent")

    /// The size of the text a highlight is made for: what the person types in, else the view's font.
    private var highlightFontSize: CGFloat {
        (typingAttributes[.font] as? NSFont)?.pointSize ?? font?.pointSize ?? NSFont.systemFontSize
    }
}
