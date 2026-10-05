import Canvas
import DrawScript

// A kind as `canvas draw` and `canvas kinds` see it: the attributes a script can write on its
// shapes, read off the kind's schema (its own properties and those added to it), what each takes,
// said briefly (`todo|doing|blocked|done`, `text (≤ 80)`), and a value as written read as the JSON
// the property is.

/// The keys the language keeps on an edge: `from:`, `to:` and `style:` (which an edge can't take).
let languageEdgeKeys: Set<String> = Set(EdgeKey.allCases.map(\.rawValue) + [LanguageKey.style.rawValue])

/// A value a script wrote that its property can't take: what's wrong, and what to write.
struct ValueRefusal: Error {
    let message: String
    let hint: String?
}

/// A kind's attributes, from its schema (the core's reading of it, `KindSchema`): every property but
/// those a script can't set, which are the one its titles are written to (a title goes after the
/// kind, in quotes), the ones that say where a shape is (a frame, a point: there are no coordinates
/// in the language), and any named like one of the language's keys. What each takes, and a value
/// read as its property is, are the schema's; the words when one can't be are draw's.
@MainActor
struct KindVocabulary {
    let kind: ShapeKind
    /// The kind's schema, read.
    let schema: KindSchema
    /// The property a title is written to; nil if its shapes can't be given one.
    let namingProperty: String?
    /// Properties that hold a place (the core's rect or point, or something that holds one).
    let coordinates: Set<String>
    /// Properties named like a language key (`size`, `title`), which a script can't reach.
    let collisions: Set<String>

    init(_ kind: ShapeKind, in registry: Registry) {
        self.kind = kind
        let schema = KindSchema(registry.schema(for: kind) ?? JSONSchema([:]))
        self.schema = schema
        let naming = registry.drawNaming?.namingProperty(kind, registry)
        namingProperty = naming
        let keys = Set(LanguageKey.allCases.map(\.rawValue))
        coordinates = Set(schema.properties.keys.filter(schema.holdsPlace))
        collisions = Set(schema.properties.keys.filter { keys.contains($0) && $0 != naming })
    }

    /// The kind's whole schema, whose `$defs` its properties refer to.
    var root: JSONObject { schema.root }
    /// Each property of the schema, own and added, by name.
    var properties: JSONObject { schema.properties }

    /// Whether a script can write it: not the one titles are written to, a place, one named like a
    /// language key, or one the schema marks `readOnly` (what the app fills in, an id or a mirror
    /// of other text: `Property.readOnly()`).
    func isAttribute(_ name: String) -> Bool {
        properties[name] != nil && name != namingProperty && !coordinates.contains(name) && !collisions.contains(name) && !isReadOnly(name)
    }

    /// Whether the schema marks it `readOnly`: filled in by the app, never by a script.
    func isReadOnly(_ name: String) -> Bool {
        properties[name].map { schema.resolved($0)["readOnly"]?.boolValue == true } ?? false
    }

    /// Whether a property's text is a query in the query language: a string whose JSON Schema
    /// `format` is `x-canvas-query`.
    func isQuery(_ name: String) -> Bool {
        if case .string(let format, _, _)? = schema.shape(of: name) { return format == Self.queryFormat }
        return false
    }

    /// The JSON Schema `format` of a string that holds a query.
    static let queryFormat = "x-canvas-query"

    /// What a script can write on the kind's shapes, by name, sorted.
    var attributes: [String] { properties.keys.filter(isAttribute).sorted() }

    /// Everything a script can write on one of its shapes: the language's keys (`title` only if
    /// its shapes can be named), then its attributes.
    var everything: [String] {
        LanguageKey.allCases.filter { $0 != .title || namingProperty != nil }.map(\.rawValue) + attributes
    }

    // MARK: What each takes

    /// What a property takes, said briefly: `todo|doing|blocked|done`, `number ≥ 0`, `text (≤ 80)`,
    /// `true|false`, `date (YYYY-MM-DD or date-time)`, `JSON {blue, green, red: 0…1}`,
    /// `JSON [{isDone, text}]`.
    func compactType(of name: String) -> String { schema.compactType(of: name) }

    /// The members a script writes of the object at `path` inside a property's value (an element
    /// of a list: its items'); nil where there's no object.
    func members(of name: String, at path: some Collection<JSONPathComponent>) -> [String]? {
        schema.members(of: name, at: path)
    }

    static func number(_ value: Double) -> String { KindSchema.number(value) }

    // MARK: Reading a value

    /// A value as written, read by its property's schema (`KindSchema.value(ofLiteral:quoted:for:)`):
    /// a word or quoted text for text (and a date alone for a date-time, midnight UTC); a word among
    /// the choices for one of some words; a bare number; `true` or `false`; JSON for anything else;
    /// and `null`, the property's default. JSON written where a property takes a word is refused
    /// here, saying what it takes.
    func value(of attribute: Attribute) throws(ValueRefusal) -> JSONValue {
        let name = attribute.key, written = attribute.value.written
        guard let shape = schema.shape(of: name) else { throw notAnAttribute(name) }
        let takes = "\(name): takes \(compactType(of: name))"
        func refuse(_ why: String? = nil) -> ValueRefusal {
            ValueRefusal(message: "\(name): \(written) \(why ?? "isn't what \(name): takes")", hint: takes)
        }
        let literal: String, quoted: Bool
        switch attribute.value {
        case .word(let text): (literal, quoted) = (text, false)
        case .quoted(let text): (literal, quoted) = (text, true)
        case .json(let text):
            switch shape {
            case .string(_, _, _?): throw refuse()
            case .string: throw refuse("isn't text: quote it")
            case .number: throw refuse("isn't a number")
            case .boolean: throw refuse("isn't true or false")
            case .array, .object, .json: (literal, quoted) = (text, false)
            }
        }
        do throws(KindSchema.Refusal) {
            return try schema.value(ofLiteral: literal, quoted: quoted, for: name)
        } catch {
            switch error {
            case .notAProperty:
                throw notAnAttribute(name)
            case .required:
                throw ValueRefusal(message: "\(name): can't be null: \(indefinite(kind)) always has one", hint: takes)
            case .notAChoice(let choices):
                let guess = Suggestions.closest(to: literal, among: choices, limit: 1).first
                throw ValueRefusal(message: "\(name): \(written) isn't one of \(choices.joined(separator: ", "))",
                                   hint: (guess.map { "did you mean \($0)? " } ?? "") + takes)
            case .notFinite:
                throw refuse("isn't a number")
            case .notJSON:
                throw refuse(attribute.value.isJSON ? "isn't JSON" : "isn't JSON: write it as JSON, as \(name): [ … ] or { … }")
            case .notA:
                switch shape {
                case .number(integer: true) where !quoted && Double(literal)?.isFinite == true: throw refuse("isn't a whole number")
                case .number: throw refuse("isn't a number")
                case .boolean: throw refuse("isn't true or false")
                case .array, .object: throw refuse("is text, and \(name): takes JSON: write it without quotes")
                case .string, .json: throw refuse()
                }
            }
        }
    }

    private func notAnAttribute(_ name: String) -> ValueRefusal {
        ValueRefusal(message: "\(name): isn't one of \(indefinite(kind))'s attributes", hint: nil)
    }
}

extension Attribute.Value {
    var isJSON: Bool {
        if case .json = self { true } else { false }
    }
}
