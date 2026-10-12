import Canvas
import CoreGraphics
import Foundation
import Mentions
import ProseMaps

// What a type's words say of its schema, a few words at a time: a prose map of the words into the
// schema (`ProseMapService`, the target `SchemaTarget`), asked for once the shape is drawn in full and
// the two are in step, so its render can color the words, a field's one way and a rule's another, and
// show each part of the schema on its words. A link holds its words as the words were written, found
// again in the text as it is now, so words typed around them keep theirs, and a JSON Pointer, followed
// in the schema as it is now, so a part renamed or taken out loses its words' color. None of it is in
// the document: it's what the model said of words and a schema, kept by their text, never saved and
// never an undo step, since the two texts are what it follows from.

/// A type's schema, as its words are mapped into it: a part is where a JSON
/// Pointer (RFC 6901) leads, the root for the thing itself, a property or a list's items for a field
/// (an element), any other keyword for a rule (`role(of:)`). What the model is told of it is
/// `SchemaPrompts.highlightsGuide`.
public enum SchemaTarget {}

extension SchemaTarget: ProseTarget {
    public typealias Address = JSONPointer
    public static let name = "schema"
    public static var guide: String { SchemaPrompts.highlightsGuide }

    /// Where each pointer leads in `schema` (`JSONPointer.resolve`): from the member's key to the end
    /// of its value, the whole text for the root; nil in a text that isn't JSON.
    public static func locate(_ pointers: [JSONPointer], in schema: String) -> [Range<String.Index>?] {
        guard let root = try? JSONReader.read(schema) else { return pointers.map { _ in nil } }
        let utf8 = schema.utf8
        return pointers.map { pointer in
            // A `$` key under the root's `properties` is a directive, not a field: nothing there to color.
            if pointer.tokens.count >= 2, pointer.tokens[0] == "properties", !SchemaDirectives.isField(pointer.tokens[1]) { return nil }
            guard let part = pointer.resolve(in: root)?.range else { return nil }
            return utf8.index(utf8.startIndex, offsetBy: part.lowerBound)..<utf8.index(utf8.startIndex, offsetBy: part.upperBound)
        }
    }

    /// What words pointing there say: an element (a field) when the pointer leads, through places
    /// that hold the data (a property, a list's items, a definition), to a schema, or to what names
    /// one (its title, its description); a rule when it leads to any other keyword (a bound, a
    /// pattern, choices, `required`, `default`), or goes through one that combines schemas or
    /// conditions on them (`anyOf`, `if`, `not`).
    public static func role(of pointer: JSONPointer) -> LinkRole {
        enum Place { case schema, names, list, value }
        var place = Place.schema
        var rule = false
        for token in pointer.tokens {
            switch place {
            case .names, .list:
                place = .schema
            case .value:
                break
            case .schema:
                if namesSchemas.contains(token) {
                    place = .names
                } else if holdsData.contains(token) {
                    place = .schema
                } else if token == "prefixItems" {
                    place = .list
                } else if combines.contains(token) {
                    rule = true
                    place = .list
                } else if conditions.contains(token) {
                    rule = true
                } else {
                    if !namesIt.contains(token) { rule = true }
                    place = .value
                }
            }
        }
        return rule ? .rule : .element
    }

    /// Keywords whose members are schemas by name.
    private static let namesSchemas: Set<String> = ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]
    /// Keywords whose value is a schema of the data's own.
    private static let holdsData: Set<String> = ["items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems", "additionalItems"]
    /// Keywords whose value is a list of schemas the data matches some of.
    private static let combines: Set<String> = ["allOf", "anyOf", "oneOf"]
    /// Keywords whose value is a schema the data is tested against.
    private static let conditions: Set<String> = ["not", "if", "then", "else", "contains", "propertyNames"]
    /// Keywords that name or describe the schema they're in.
    private static let namesIt: Set<String> = ["title", "description", "$comment"]
}

/// A highlight as a shape draws it: its words in its text as it's drawn, and its part in the JSON's
/// text.
public struct PlacedHighlight: Equatable, Sendable {
    /// Where its words are in the text as it's drawn (each mention one character, its pill), in
    /// UTF-16, as AppKit's text ranges are.
    public var range: NSRange
    public var role: LinkRole
    public var pointer: JSONPointer
    /// Where its part is in the JSON's text the highlights follow (a type's `SchemaReadings.shownText`),
    /// in UTF-8 offsets (`JSONPointer.Target.range`).
    public var part: Range<Int>
}

/// What a shape shows of words mapped into JSON (a target whose addresses are JSON Pointers: a
/// type's schema, `SchemaTarget`), as its render, its editor and its popovers read them: its map
/// (`ProseMapService.map`) moved onto its text as it's drawn. The model reads the text with each
/// mention of a type `@` and a word of the name it holds, and the JSON with each `$ref` to a type it
/// mentions that word (`SchemaReferenceNames`), as the sync shows them; its words are found in that,
/// and moved to the text as it's drawn, words in a mention's word its pill
/// (`MentionReading.drawnRange`). A pair with no answer is asked about once `ready` says (a type's:
/// in step, its schema's text a JSON object), so what's linked is what both say.
///
/// Kept per shape and target while nothing it goes by changes (its texts, its map), since the canvas
/// reads it every frame: the texts the model reads are the same strings for as long as the shape's
/// are, so the map's read costs a lookup.
@MainActor
public enum ProseHighlights {
    private struct Key: Hashable {
        let shape: ShapeID
        let target: ObjectIdentifier
    }

    /// What the model reads of a shape's texts, and what's said of the types they name.
    private struct Read {
        let words: MentionText
        let json: String
        let text: MentionReading
        let modelJSON: String
        let context: String
    }

    /// What a shape shows of a map, and where it's drawn, once asked.
    private struct Shown {
        let map: AnyObject
        let placed: [PlacedHighlight]
        var lines: (size: CGSize, pills: [MentionResolution], rects: [[CGRect]])?
    }

    /// By shape, then target: a shape that goes is dropped in one lookup.
    private static var read: [ShapeID: [ObjectIdentifier: Read]] = [:]
    private static var shown: [ShapeID: [ObjectIdentifier: Shown]] = [:]

    /// The shape's highlights, in its words' order: `words` mapped into `json` (whose reading is
    /// `root`, a JSON object), its map read from `maps` (nil: none) and asked for once `ready` says.
    /// `isType` says which mentions are of types (the rest read as their labels), and `references`
    /// is the request's context when the words name some.
    public static func placed<T: ProseTarget>(_ target: T.Type, of id: ShapeID, words: MentionText, json: String, root: JSONNode,
                                              maps: ProseMapService?, references: String, isType: (ShapeID) -> Bool,
                                              askingIf ready: () -> Bool) -> [PlacedHighlight] where T.Address == JSONPointer {
        guard let maps, !words.stored.isEmpty else { return [] }
        let key = Key(shape: id, target: ObjectIdentifier(target))
        let texts = texts(key, words: words, json: json, references: references, isType: isType)
        guard let map = maps.map(T.self, of: id, prose: texts.text.text, target: texts.modelJSON, context: texts.context, askingIf: ready)
        else { return [] }
        if let kept = shown[key.shape]?[key.target], kept.map === map { return kept.placed }
        var placed: [PlacedHighlight] = []
        var end = 0
        for link in map.links {
            // Words in one mention's word are its pill, which only the first of them takes. The
            // map's own text is what its ranges are of; it reads as the shape's (`ProseMapService.map`).
            let range = texts.text.drawnRange(of: NSRange(link.inProse, in: map.prose))
            guard range.length > 0, range.location >= end, let part = link.address.resolve(in: root)?.range else { continue }
            end = NSMaxRange(range)
            placed.append(PlacedHighlight(range: range, role: link.role, pointer: link.address, part: part))
        }
        shown[key.shape, default: [:]][key.target] = Shown(map: map, placed: placed)
        return placed
    }

    /// The shape's texts as the model reads them: its words' mentions of types as the names they
    /// hold (what the sync sends, and what a rename elsewhere doesn't change), and the types they
    /// name in its JSON by the same words.
    private static func texts(_ key: Key, words: MentionText, json: String, references: String, isType: (ShapeID) -> Bool) -> Read {
        if let kept = read[key.shape]?[key.target], sameText(kept.words.stored, words.stored), sameText(kept.json, json) { return kept }
        let names = SchemaReferenceNames(words: [words], schemas: [], name: { _ in nil }, isType: isType)
        let made = Read(words: words, json: json, text: names.modelText(of: words), modelJSON: names.modelSchema(json),
                        context: names.named.isEmpty ? "" : references)
        read[key.shape, default: [:]][key.target] = made
        return made
    }

    /// Where each of the shape's highlights (`placed`'s, in its order) is drawn, in world units: a
    /// rect a line, where the canvas fills behind its words (`MentionTextStyle.lineRects`), which its
    /// editor fills too, and the pointer is found on, each mention's pill as `resolve` says it shows.
    /// Kept with what the shape shows, for its text box's size and how its pills show.
    public static func lines<T: ProseTarget>(_ target: T.Type, of id: ShapeID, placed: [PlacedHighlight], in placement: MentionTextPlacement,
                                             resolve: (ShapeID) -> MentionResolution) -> [[CGRect]] {
        guard !placed.isEmpty else { return [] }
        let key = Key(shape: id, target: ObjectIdentifier(target))
        let box = placement.box
        var pills: [MentionResolution] = []
        for run in placement.text.runs {
            if case .mention(let target, _) = run { pills.append(resolve(target)) }
        }
        let rects: [[CGRect]]
        if let kept = shown[key.shape]?[key.target]?.lines, kept.size == box.size, kept.pills == pills {
            rects = kept.rects
        } else {
            var next = pills.makeIterator()
            let string = placement.style.attributedString(placement.text, width: box.width) { _ in next.next() ?? .missing }
            rects = placement.style.lineRects(of: placed.map(\.range), in: string, size: box.size)
            shown[key.shape]?[key.target]?.lines = (box.size, pills, rects)
        }
        return rects.map { lines in lines.map { $0.offsetBy(dx: box.minX, dy: box.minY) } }
    }

    /// The part of a JSON `text` at `part` (UTF-8 offsets) as a person reads it
    /// (`ProseMapText.excerpt`). Empty for a range outside the text.
    static func excerpt(_ part: Range<Int>, of text: String) -> String {
        let utf8 = text.utf8
        guard part.lowerBound >= 0, part.upperBound <= utf8.count else { return "" }
        return ProseMapText.excerpt(utf8.index(utf8.startIndex, offsetBy: part.lowerBound)..<utf8.index(utf8.startIndex, offsetBy: part.upperBound), of: text)
    }

    /// The same text, as a range in one is a range in the other: equal, and as long in UTF-8
    /// (strings `==` calls equal may be written differently, an accent as one scalar or two).
    private static func sameText(_ a: String, _ b: String) -> Bool { a == b && a.utf8.count == b.utf8.count }

    /// Drops what's kept of a shape that went, or is no longer what it was (its answers stay, by
    /// their text).
    public static func forget(_ id: ShapeID) {
        read[id] = nil
        shown[id] = nil
    }

    #if DEBUG
    /// Every shape forgotten, for tests that need none kept from one before.
    public static func forgetEverything() {
        read = [:]
        shown = [:]
    }
    #endif
}
