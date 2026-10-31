import AppKit
import Canvas
import DetailPanel
import Mentions
import ProseMaps

/// A type's highlights: its words linked to the parts of its schema they say (`ProseHighlights` over
/// `SchemaTarget`), drawn by its kind's render under its words (`fillTypeHighlights`), while they're
/// edited too (the editor draws no background), and shown in a popover where the pointer rests on
/// them, on the canvas (Selection's `ShapePopovers`) or in the editor (`EditContext.hoverPopover`):
/// the part of the schema they say, as a person reads it (`ProseHighlights.excerpt`), colored as the
/// panel colors JSON (`DetailStyle.code`). A part that refers to another type's schema
/// (`{"$ref": "urn:uuid:…"}`, what a mention of the type is written as) shows that schema, or the
/// part of it the `$ref` points to, while the type is in the file. A shape that isn't a type costs
/// one lookup of an added value.
@MainActor
public enum TypeHighlights {
    /// A highlight, as its popover is about it: the shape, where its words start, and its part.
    struct About: Hashable, Sendable {
        let shape: ShapeID
        let location: Int
        let pointer: String
    }

    /// The type's highlights, in its words' order (none for a shape that isn't a type, or whose
    /// schema has never been a JSON object), its map asked for once the sync says it's in step.
    static func placed(for record: AnyShapeRecord, words: MentionText, maps: ProseMapService?, sync: TypeSync<TypeSchemaProperty>?,
                       types: TypeIndex?) -> [PlacedHighlight] {
        guard let maps, let reading = SchemaReadings.reading(of: record), let root = reading.shownRoot else { return [] }
        return ProseHighlights.placed(SchemaTarget.self, of: record.id, words: words, json: reading.shownModelText(holding: types?.editor?.registry.heldDirectives ?? HeldDirectives()), root: root, maps: maps,
                                      references: SchemaPrompts.highlightsReferences, isType: { types?.canBeEmbedded($0) ?? true },
                                      askingIf: { sync?.isInStep(record.id) == true && reading.document.isObject })
    }

    /// The type's highlights as its words are drawn (`ProseHighlights.placed`), in their order: none
    /// for a shape that isn't a type, or whose words aren't drawn now.
    public static func placed(for record: AnyShapeRecord, in editor: CanvasEditor) -> [PlacedHighlight] {
        guard let placement = editor.registry.typeWords(of: record.kind)?.placement(record, editor.shapeContext) else { return [] }
        return placed(for: record, words: placement.text, maps: editor.proseMaps, sync: editor.typeSync, types: editor.types)
    }

    /// Where the type's highlights (`placed(for:in:)`'s) are drawn, in world units: a rect a line.
    public static func lines(for record: AnyShapeRecord, in editor: CanvasEditor) -> [[CGRect]] {
        guard let placement = editor.registry.typeWords(of: record.kind)?.placement(record, editor.shapeContext) else { return [] }
        let placed = placed(for: record, in: editor)
        return ProseHighlights.lines(SchemaTarget.self, of: record.id, placed: placed, in: placement) {
            editor.registry.mentionResolution(of: $0, lookup: { editor.shape(inFile: $0) })
        }
    }

    /// The popover a world point on a type shows: that of the highlight whose words are there, as
    /// the canvas draws them, beside the line the point is on (its anchor less `origin`: an editing
    /// view's coordinates have the shape's frame at theirs); nil anywhere else, and on a shape that
    /// isn't a type.
    public static func popover(at point: CGPoint, on record: AnyShapeRecord, in editor: CanvasEditor, origin: CGPoint = .zero) -> CanvasPopover? {
        guard record[TypeSchemaProperty.self] != nil, let placement = editor.registry.typeWords(of: record.kind)?.placement(record, editor.shapeContext),
              placement.box.contains(point) else { return nil }
        let maps = editor.proseMaps
        let placed = placed(for: record, words: placement.text, maps: maps, sync: editor.typeSync, types: editor.types)
        guard !placed.isEmpty else { return nil }
        let lookup = { (id: ShapeID) in editor.shape(inFile: id) }
        let lines = ProseHighlights.lines(SchemaTarget.self, of: record.id, placed: placed, in: placement) {
            editor.registry.mentionResolution(of: $0, lookup: lookup)
        }
        for (highlight, lines) in zip(placed, lines) {
            guard let line = lines.first(where: { $0.contains(point) }) else { continue }
            return CanvasPopover(id: About(shape: record.id, location: highlight.range.location, pointer: highlight.pointer.description),
                                 anchor: line.offsetBy(dx: -origin.x, dy: -origin.y), text: text(of: highlight, in: record, lookup: lookup))
        }
        return nil
    }

    /// The last text made, and what from: the pointer asks again as it moves over the same words.
    private static var last: (source: String, part: Range<Int>, text: NSAttributedString)?

    /// What a highlight's popover says: its part of the schema (or of the schema it refers to), its
    /// first `TypesStyle.popoverMaxLines` lines.
    static func text(of highlight: PlacedHighlight, in record: AnyShapeRecord, lookup: (ShapeID) -> AnyShapeRecord?) -> NSAttributedString {
        let (source, part) = shown(highlight, in: record, lookup: lookup)
        if let last, last.part == part, last.source == source { return last.text }
        var fragment = ProseHighlights.excerpt(part, of: source)
        let maxLines = TypesStyle.popoverMaxLines
        let lines = fragment.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false)
        if lines.count > maxLines { fragment = lines.prefix(maxLines).joined(separator: "\n") + "\n…" }
        let text = DetailStyle.code(fragment, spans: SchemaCodeColors.spans(in: fragment))
        last = (source, part, text)
        return text
    }

    /// The text a highlight's popover shows a part of, and where the part is in it (UTF-8): the
    /// type's schema and its part, or, for a part that is a `$ref` to a type in the file whose
    /// schema is a JSON object, that schema and what the `$ref` points to in it (the whole of it, or
    /// its fragment's part).
    static func shown(_ highlight: PlacedHighlight, in record: AnyShapeRecord, lookup: (ShapeID) -> AnyShapeRecord?) -> (String, Range<Int>) {
        guard let reading = SchemaReadings.reading(of: record) else { return ("", highlight.part) }
        let own = (reading.shownText, highlight.part)
        guard let root = reading.shownRoot, let ref = highlight.pointer.resolve(in: root)?.value["$ref"]?.string,
              let target = SchemaReferences.target(of: ref), let referred = lookup(target.shape).flatMap(SchemaReadings.reading(of:)),
              let pointer = JSONPointer(target.fragment) else { return own }
        guard let otherRoot = referred.shownRoot, let found = pointer.resolve(in: otherRoot) else { return own }
        return (referred.shownText, found.range)
    }
}

extension RenderContext {
    /// Fills a type's highlights behind its words, where `placement` draws them (the placement the
    /// kind's render draws its words in), a field's one way and a rule's another: under its editor
    /// too, whose text lays out as the render's does. Reading them asks for them once the shape is
    /// drawn in full and in step (`ProseHighlights`). A shape that isn't a type costs one lookup.
    public func fillTypeHighlights<P: ShapeProps>(of shape: ShapeRecord<P>, in placement: MentionTextPlacement) {
        guard shape[TypeSchemaProperty.self] != nil, !placement.text.stored.isEmpty, !placement.box.isEmpty else { return }
        let record = AnyShapeRecord(shape)
        let maps = proseMaps
        let placed = TypeHighlights.placed(for: record, words: placement.text, maps: maps,
                                           sync: service(TypeSync<TypeSchemaProperty>.self), types: service(TypeIndex.self))
        guard !placed.isEmpty else { return }
        let registry = shapes.registry
        let lines = ProseHighlights.lines(SchemaTarget.self, of: shape.id, placed: placed, in: placement) {
            registry.mentionResolution(of: $0, lookup: { self.shape(inFile: $0) })
        }
        for (highlight, lines) in zip(placed, lines) {
            cg.setFillColor(TypesStyle.highlightColor(highlight.role))
            for line in lines { cg.fill(TypesStyle.highlightFill(line)) }
        }
    }
}

extension TypeIndex {
    /// The popover a point on a type shows (`TypeHighlights.popover`), for its editing view, which
    /// has no editor of its own to ask with (a note's, as the pointer rests on its words): `point`
    /// and the popover's anchor in the view's coordinates, world units with the shape's frame
    /// at `origin`.
    public func popover(at point: CGPoint, on id: ShapeID, origin: CGPoint) -> CanvasPopover? {
        guard let editor, let record = editor.shape(inFile: id) else { return nil }
        return TypeHighlights.popover(at: CGPoint(x: point.x + origin.x, y: point.y + origin.y), on: record, in: editor, origin: origin)
    }
}
