import AppKit
import Canvas
import DetailPanel
import Mentions
import ProseMaps

/// What resting the pointer on a highlight's words shows, on the card (Selection's `ShapePopovers`)
/// or in its editor (`EditContext.hoverPopover`): the part of the schema they say, as a person reads
/// it (`SchemaHighlightsShown.excerpt`), colored as the panel colors JSON (`DetailStyle.code`). A
/// part that refers to another card's schema (`{"$ref": "urn:uuid:…"}`, what a mention of the card
/// is written as) shows that schema, or the part of it the `$ref` points to, while the card is in the
/// file.
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

    /// The card's highlight's popover, beside `anchor`; `lookup` finds the cards its part refers to.
    static func popover(of highlight: PlacedHighlight, in card: ShapeRecord<SchemaCard>, anchor: CGRect,
                        lookup: (ShapeID) -> AnyShapeRecord?) -> CanvasPopover {
        CanvasPopover(id: About(card: card.id, location: highlight.range.location, pointer: highlight.pointer.description),
                      anchor: anchor, text: text(of: highlight, in: card, lookup: lookup))
    }

    /// The popover a world point on the card shows: that of the highlight whose words are there, as
    /// the canvas draws them (`SchemaHighlightsShown.lines`), beside the line the point is on.
    static func popover(at point: CGPoint, on card: ShapeRecord<SchemaCard>, in editor: CanvasEditor) -> CanvasPopover? {
        guard SchemaStyle.textBox(of: card.frame).contains(point) else { return nil }
        let maps = editor.proseMaps, sync = editor.schemaSync
        let placed = SchemaHighlightsShown.placed(for: card, maps: maps, sync: sync)
        guard !placed.isEmpty else { return nil }
        let lookup = { (id: ShapeID) in editor.shape(inFile: id) }
        let lines = SchemaHighlightsShown.lines(of: card, maps: maps, sync: sync) { editor.registry.mentionResolution(of: $0, lookup: lookup) }
        for (highlight, lines) in zip(placed, lines) {
            guard let line = lines.first(where: { $0.contains(point) }) else { continue }
            return popover(of: highlight, in: card, anchor: line, lookup: lookup)
        }
        return nil
    }

    /// The last text made, and what from: the pointer asks again as it moves over the same words.
    private static var last: (source: String, part: Range<Int>, text: NSAttributedString)?

    /// What a highlight's popover says: its part of the schema (or of the schema it refers to), its
    /// first `maxLines` lines.
    static func text(of highlight: PlacedHighlight, in card: ShapeRecord<SchemaCard>, lookup: (ShapeID) -> AnyShapeRecord?) -> NSAttributedString {
        let (source, part) = shown(highlight, in: card, lookup: lookup)
        if let last, last.part == part, last.source == source { return last.text }
        var fragment = SchemaHighlightsShown.excerpt(part, of: source)
        let lines = fragment.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false)
        if lines.count > maxLines { fragment = lines.prefix(maxLines).joined(separator: "\n") + "\n…" }
        let text = DetailStyle.code(fragment, spans: SchemaCodeColors.spans(in: fragment))
        last = (source, part, text)
        return text
    }

    /// The text a highlight's popover shows a part of, and where the part is in it (UTF-8): the
    /// card's schema and its part, or, for a part that is a `$ref` to a card in the file whose schema
    /// is a JSON object, that schema and what the `$ref` points to in it (the whole of it, or its
    /// fragment's part).
    static func shown(_ highlight: PlacedHighlight, in card: ShapeRecord<SchemaCard>, lookup: (ShapeID) -> AnyShapeRecord?) -> (String, Range<Int>) {
        let reading = SchemaReadings.reading(of: card)
        let own = (reading.shownText, highlight.part)
        guard let root = reading.shownRoot, let ref = highlight.pointer.resolve(in: root)?.value["$ref"]?.string,
              let target = SchemaReferences.target(of: ref), let referred = lookup(target.card)?.typed(as: SchemaCard.self),
              let pointer = JSONPointer(target.fragment) else { return own }
        let other = SchemaReadings.reading(of: referred)
        guard let otherRoot = other.shownRoot, let found = pointer.resolve(in: otherRoot) else { return own }
        return (other.shownText, found.range)
    }
}
