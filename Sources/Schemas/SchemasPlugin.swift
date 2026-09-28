import Canvas
import CoreGraphics
import Keyboard
import Ports
import SwiftUI
import TableOfContents
import Titles
import Validation

extension PluginID {
    public static let schemas: PluginID = "schemas"
}

/// Schema cards: the Schema tool (S), which places an empty card; the card, which lists a JSON
/// Schema's fields; its name, the schema's `"title"` (Titles, without the pill: the card draws its
/// name); its row in the table of contents; validation's rules for a schema that isn't one; its
/// panel, where it's described in words and written as JSON; the sync that keeps the two saying the
/// same thing through the editor's language model (`SchemaSync`); and ports, whose arrows link a
/// schema to a schema (`SchemaLink`).
public struct SchemasPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .schemas }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { SchemaSync(editor: $0) }
        registrar.shape(SchemaCardDefinition()) { schema in
            let place = schema.placement(size: SchemaCard.defaultSize) { SchemaCard() }
            schema.tool(label: "Schema", systemImage: "curlybraces", shortcut: "s", placing: place)
            schema.validate { shape, _ in SchemaReadings.reading(of: shape).issues }
            schema.title(pill: false) { SchemaReadings.reading(of: $0).shown.title }
            schema.contentsRow { shape in
                let shown = SchemaReadings.reading(of: shape).shown
                return ContentsLabel(shown.title ?? "", placeholder: SchemaCard.untitled, systemImage: "curlybraces",
                                     color: Color(nsColor: SchemaStyle.accent), badge: shown.fields.isEmpty ? nil : "\(shown.fields.count)")
            }
            schema.schemaPanel()
            schema.schemaLinks()
        }
        registrar.channel(SchemaLink.self)
    }

    #if DEBUG
    /// How many times a card's schema has been read (parsed) in this process, debug builds only:
    /// tests hold a frame to reading only the cards whose text changed.
    public static var schemasRead: Int { SchemaReadings.made }
    #endif
}

/// Each card's schema read once: the card, its name, its row, its rules and its panel all read the
/// same text, the card every frame, so a reading is kept per card and read again only when the
/// card's text changes (typing replaces the card's reading, never adds one). So a frame of cards
/// that didn't change parses and measures nothing, however many are in view, and however many
/// texts they have between them. A reading costs what its text's length does. The readings of
/// cards that went, or were read again from disk, are dropped (`forget`, which the sync calls), and
/// past `capacity` those used longest ago.
///
/// While a card's text isn't a JSON object (a keystroke in the middle of a member breaks it), what
/// the card shows stays what its last one said (`shown`): its rows and name on the card, its row in
/// the table of contents, its title, its panel's header. So typing doesn't make the card flicker;
/// Validation's outline says it's broken. What acts on the text (Validation's rules, the sync, the
/// editor's colors, a rename) reads the text itself (`document`).
@MainActor
final class SchemaReadings {
    /// The text read, to tell whether a card's text is still this one: the record's own string
    /// compares at once (the same storage), another with the same text once, and is kept after.
    private(set) var text: String
    let document: SchemaDocument
    /// While `document` isn't a JSON object, the card's last reading that was, this session.
    private let lastObject: SchemaDocument?
    /// The layouts of the last few sizes asked (a card being resized), the latest last: of `shown`.
    private var layouts: [(size: CGSize, layout: SchemaCardLayout)] = []
    private(set) lazy var issues: [ValidationIssue] = SchemaReadings.issues(of: document)
    /// When it was last asked for, counted in lookups.
    private var used = 0

    private init(_ text: String, after previous: SchemaReadings?) {
        self.text = text
        let document = SchemaDocument(text)
        self.document = document
        if document.isObject {
            lastObject = nil
        } else {
            lastObject = previous.flatMap { $0.document.isObject ? $0.document : $0.lastObject }
            // The same reading shown: its layouts still hold.
            if lastObject != nil, let previous { layouts = previous.layouts }
        }
        #if DEBUG
        Self.made += 1
        #endif
    }

    /// What the card shows: the text's reading while it's a JSON object, else its last one that was
    /// (none: the text's, which says why there are no rows).
    var shown: SchemaDocument { lastObject ?? document }

    private static var kept: [ShapeID: SchemaReadings] = [:]
    private static var lookups = 0
    /// At most this many readings are kept, a card each: past it, the quarter used longest ago
    /// goes. (More cards than this in view at once would read some again every frame.)
    static let capacity = 4096
    #if DEBUG
    static var made = 0
    #endif

    /// The reading of a card's schema.
    static func reading(of card: ShapeRecord<SchemaCard>) -> SchemaReadings { reading(of: card.props.schema, for: card.id) }

    /// The reading of `text`, the schema of the card `id`: the one kept for the card while its text
    /// is still this one, else read now and kept in its place.
    static func reading(of text: String, for id: ShapeID) -> SchemaReadings {
        lookups += 1
        let previous = kept[id]
        if let previous, previous.text == text {
            previous.text = text
            previous.used = lookups
            return previous
        }
        let reading = SchemaReadings(text, after: previous)
        reading.used = lookups
        kept[id] = reading
        if kept.count > capacity {
            for (id, _) in kept.sorted(by: { $0.value.used < $1.value.used }).prefix(capacity / 4) { kept[id] = nil }
        }
        return reading
    }

    /// Drops the reading of a card that went, or was read again from disk, and the last one it
    /// showed.
    static func forget(_ id: ShapeID) { kept[id] = nil }

    /// What a card of `size` shows: `shown`, laid out.
    func layout(size: CGSize) -> SchemaCardLayout {
        if let kept = layouts.last(where: { $0.size == size }) { return kept.layout }
        let layout = SchemaCardLayout(shown, size: size)
        if layouts.count >= 4 { layouts.removeFirst() }
        layouts.append((size, layout))
        return layout
    }

    /// Validation's rules, about the text itself: a text that isn't JSON is an error at its line
    /// and column, as is a root that isn't an object; `required` naming a property the object
    /// doesn't have is a warning, as is a `type` that isn't one of JSON Schema's. The panel shows
    /// them under the JSON too, in these words.
    static func issues(of document: SchemaDocument) -> [ValidationIssue] {
        if let error = document.error {
            let reason = error.message.prefix(1).lowercased() + error.message.dropFirst()
            return [.error("Invalid JSON: \(reason) at line \(error.line), column \(error.column).", field: "schema")]
        }
        guard let root = document.root, root.isObject else {
            return [.error("A schema must be a JSON object.", field: "schema")]
        }
        var issues: [ValidationIssue] = []
        SchemaWalk.schemas(in: root) { schema, path in
            guard issues.count < maxWarnings else { return }
            for name in unknownTypes(of: schema) {
                guard issues.count < maxWarnings else { return }
                let place = path.isEmpty ? "" : " in \(path)"
                issues.append(.warning("“\(name)”\(place) isn’t a JSON Schema type.", field: "schema"))
            }
            guard schema["patternProperties"] == nil, let properties = schema["properties"]?.members,
                  let required = schema["required"]?.elements else { return }
            let names = Set(properties.map(\.key))
            var seen: Set<String> = []
            for name in required.compactMap(\.string) where !names.contains(name) && seen.insert(name).inserted {
                guard issues.count < maxWarnings else { return }
                let place = path.isEmpty ? "" : " of \(path)"
                issues.append(.warning("“\(name)” is required, but isn’t a property\(place).", field: "schema"))
            }
        }
        return issues
    }

    /// The names a schema's `type` gives that aren't JSON Schema's (`"ninteger"`), each once.
    private static func unknownTypes(of schema: JSONNode) -> [String] {
        guard let type = schema["type"] else { return [] }
        let names = type.string.map { [$0] } ?? type.elements?.compactMap(\.string) ?? []
        var seen: Set<String> = []
        return names.filter { !SchemaFieldType.jsonTypes.contains($0) && seen.insert($0).inserted }
    }

    /// At most this many warnings, however many names a schema gets wrong.
    static let maxWarnings = 20
}

/// Goes through every place in a schema that holds a schema, with a path a person can read
/// (`customer`, `items[]`, `$defs/money`): what validation checks.
enum SchemaWalk {
    static func schemas(in root: JSONNode, _ visit: (JSONNode, String) -> Void) {
        walk(root, path: "", depth: 0, visit)
    }

    private static let byName = ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]
    private static let single = ["items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames",
                                 "unevaluatedProperties", "unevaluatedItems", "additionalItems"]
    private static let lists = ["allOf", "anyOf", "oneOf", "prefixItems", "items"]

    private static func walk(_ schema: JSONNode, path: String, depth: Int, _ visit: (JSONNode, String) -> Void) {
        guard schema.isObject, depth < JSONReader.maxDepth else { return }
        visit(schema, path)
        func joined(_ name: String) -> String { path.isEmpty ? name : "\(path).\(name)" }
        for key in byName {
            for member in schema[key]?.members ?? [] {
                let name = key == "properties" ? member.key : key == "patternProperties" ? "/\(member.key)/" : "\(key)/\(member.key)"
                walk(member.value, path: key.hasPrefix("$") || key == "definitions" ? name : joined(name), depth: depth + 1, visit)
            }
        }
        for key in single {
            guard let sub = schema[key], sub.isObject else { continue }
            walk(sub, path: key == "items" ? path + "[]" : path, depth: depth + 1, visit)
        }
        for key in lists {
            for sub in schema[key]?.elements ?? [] {
                walk(sub, path: key == "prefixItems" || key == "items" ? path + "[]" : path, depth: depth + 1, visit)
            }
        }
    }
}
