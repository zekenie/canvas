import AppKit
import Canvas
import DetailPanel

/// What resting the pointer on a highlight's words shows, on the card (Selection's `ShapePopovers`)
/// or in its editor (`EditContext.hoverPopover`): the part of the schema they say, as a person reads
/// it (`SchemaHighlightAnswers.fragment`), colored as the panel colors JSON (`DetailStyle.code`).
@MainActor
enum SchemaHighlightPopovers {
    /// A highlight, as its popover is about it: the card, where its words start, and its part.
    struct About: Hashable, Sendable {
        let card: ShapeID
        let location: Int
        let pointer: String
    }

    /// The most lines of a part shown; "…" on a line after them says there's more.
    static let maxLines = 40

    /// The card's highlight's popover, beside `anchor`.
    static func popover(of highlight: PlacedHighlight, in card: ShapeRecord<SchemaCard>, anchor: CGRect) -> CanvasPopover {
        CanvasPopover(id: About(card: card.id, location: highlight.range.location, pointer: highlight.pointer.description),
                      anchor: anchor, text: text(of: highlight, in: card))
    }

    /// The popover a world point on the card shows: that of the highlight whose words are there, as
    /// the canvas draws them (`SchemaHighlightAnswers.lines`), beside the line the point is on.
    static func popover(at point: CGPoint, on card: ShapeRecord<SchemaCard>) -> CanvasPopover? {
        guard SchemaStyle.textBox(of: card.frame).contains(point) else { return nil }
        let placed = SchemaHighlightAnswers.placed(for: card)
        guard !placed.isEmpty else { return nil }
        for (highlight, lines) in zip(placed, SchemaHighlightAnswers.lines(of: card)) {
            guard let line = lines.first(where: { $0.contains(point) }) else { continue }
            return popover(of: highlight, in: card, anchor: line)
        }
        return nil
    }

    /// The last text made, and what from: the pointer asks again as it moves over the same words.
    private static var last: (schema: String, part: Range<Int>, text: NSAttributedString)?

    /// What a highlight's popover says: its part of the schema, its first `maxLines` lines.
    static func text(of highlight: PlacedHighlight, in card: ShapeRecord<SchemaCard>) -> NSAttributedString {
        let schema = card.props.schema
        if let last, last.part == highlight.part, last.schema == schema { return last.text }
        var fragment = SchemaHighlightAnswers.fragment(of: highlight, in: card)
        let lines = fragment.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false)
        if lines.count > maxLines { fragment = lines.prefix(maxLines).joined(separator: "\n") + "\n…" }
        let text = DetailStyle.code(fragment, spans: SchemaCodeColors.spans(in: fragment))
        last = (schema, highlight.part, text)
        return text
    }
}

/// Where a card's highlights' words are as the canvas draws its description: laid out as string
/// drawing lays it out (a layout manager with the 10.2 typesetter, as Mentions finds its pills), each
/// highlight's rects a line each, where string drawing fills behind them (its glyphs on the line, the
/// line's height), in the text box's coordinates, none on a line past the box.
@MainActor
enum SchemaHighlightRects {
    static func rects(of placed: [PlacedHighlight], in prompt: String, size: CGSize) -> [[CGRect]] {
        let storage = NSTextStorage(string: prompt, attributes: SchemaStyle.textAttributes)
        let manager = NSLayoutManager()
        manager.typesetterBehavior = .behavior_10_2_WithCompatibility
        let container = NSTextContainer(size: CGSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let length = storage.length
        return placed.map { highlight -> [CGRect] in
            guard NSMaxRange(highlight.range) <= length else { return [] }
            let glyphs = manager.glyphRange(forCharacterRange: highlight.range, actualCharacterRange: nil)
            var lines: [CGRect] = []
            manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, onLine, stop in
                guard line.maxY <= size.height + 0.01 else {
                    stop.pointee = true
                    return
                }
                let part = NSIntersectionRange(glyphs, onLine)
                if part.length > 0 { lines.append(manager.boundingRect(forGlyphRange: part, in: container)) }
            }
            return lines
        }
    }
}
