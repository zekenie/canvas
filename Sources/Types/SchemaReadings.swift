import Canvas
import Validation

/// Each type's schema read once: its rules, the sync, its highlights and its panel all read the same
/// text, so a reading is kept per shape and text, and read again only when the shape's schema
/// changes. A reading costs what its text's length does. A shape keeps the readings of up to
/// `versionsPerShape` texts, by its id: ids are unique within a file, not across files, so a file
/// duplicated in Finder and opened beside its original has the same shapes, whose texts may differ
/// once one is edited, and each window's are kept beside the other's rather than taking their place
/// as each is read. Typing adds a reading, and the shape's used longest ago goes. The readings of
/// shapes that went, or were read again from disk, are dropped (`forget`, which the sync calls), and
/// past `capacity` those used longest ago. The shape itself shows its words, and reads none.
///
/// While a schema's text isn't a JSON object (a keystroke in the middle of a member breaks it), what
/// its highlights follow stays its last one that was (`shown`), so typing doesn't take them away;
/// Validation's outline says it's broken. What acts on the text (Validation's rules, the sync, the
/// editor's colors) reads the text itself (`document`).
@MainActor
final class SchemaReadings {
    /// The text read, to tell whether a shape's schema is still this one: the record's own string
    /// compares at once (the same storage), another with the same text once, and is kept after.
    private(set) var text: String
    let document: SchemaDocument
    /// While `document` isn't a JSON object, the shape's last reading that was, this session.
    private var showing: SchemaReadings?
    private(set) lazy var issues: [ValidationIssue] = SchemaReadings.issues(of: document)
    /// When it was last asked for, counted in lookups.
    private var used = 0

    private init(_ text: String, after previous: SchemaReadings?) {
        self.text = text
        document = SchemaDocument(text)
        if !document.isObject, let previous { follow(previous) }
        #if DEBUG
        Self.made += 1
        #endif
    }

    /// What's shown of the schema (its highlights' parts, a completion's count of a type's fields):
    /// the text's reading while it's a JSON object, else its last one that was (none: the text's).
    var shown: SchemaDocument { showing?.document ?? document }
    /// The schema a type's highlights are followed in (`shown`'s, while one is an object), and its
    /// text, which their parts are cut from.
    var shownRoot: JSONNode? { shown.isObject ? shown.root : nil }
    var shownText: String { showing?.text ?? text }

    /// Shows what `previous`, the shape's reading before this one, showed: its text, if that was a
    /// JSON object, else what it showed.
    private func follow(_ previous: SchemaReadings) {
        showing = previous.document.isObject ? previous : previous.showing
    }

    /// Each shape's readings, a text each: those of the same shape in files opened beside its own
    /// (a copy's), and its texts before the last while it's typed into, until they go.
    private static var kept: [ShapeID: [SchemaReadings]] = [:]
    /// How many readings `kept` holds, every shape's.
    private static var count = 0
    private static var lookups = 0
    /// At most this many readings are kept: past it, the quarter used longest ago goes.
    static let capacity = 4096
    /// At most this many a shape: the same shape in up to three copies of its file open beside it
    /// read nothing again; one typed into keeps the texts it had last.
    static let versionsPerShape = 4
    #if DEBUG
    static var made = 0
    #endif

    /// The reading of a type's schema; nil for a shape that isn't one.
    static func reading(of shape: AnyShapeRecord) -> SchemaReadings? {
        shape[TypeSchemaProperty.self].map { reading(of: $0.text, for: shape.id) }
    }

    /// The reading of `text`, the schema of the shape `id`: the one kept for the shape with this
    /// text, else read now and kept with them, in place of the shape's used longest ago once it
    /// has `versionsPerShape`. While the text isn't a JSON object, it shows what the shape's reading
    /// used last showed (`shown`), whether it's read now or the shape went back to it.
    static func reading(of text: String, for id: ShapeID) -> SchemaReadings {
        lookups += 1
        let versions = kept[id] ?? []
        if let found = versions.first(where: { $0.text == text }) {
            if !found.document.isObject, let last = versions.max(by: { $0.used < $1.used }), last !== found { found.follow(last) }
            found.text = text
            found.used = lookups
            return found
        }
        let reading = SchemaReadings(text, after: versions.max { $0.used < $1.used })
        reading.used = lookups
        if versions.count < versionsPerShape {
            kept[id, default: []].append(reading)
            count += 1
        } else if let oldest = versions.indices.min(by: { versions[$0].used < versions[$1].used }) {
            kept[id]?[oldest] = reading
        }
        if count > capacity { dropOldest() }
        return reading
    }

    /// Drops the quarter of `capacity` used longest ago, whatever shapes they're of.
    private static func dropOldest() {
        let all = kept.values.flatMap { $0 }.sorted { $0.used < $1.used }
        let dropped = Set(all.prefix(capacity / 4).map(ObjectIdentifier.init))
        kept = kept.compactMapValues { versions in
            let left = versions.filter { !dropped.contains(ObjectIdentifier($0)) }
            return left.isEmpty ? nil : left
        }
        count = all.count - dropped.count
    }

    /// Drops the readings of a shape that went, or was read again from disk, or is no longer a type,
    /// and the last one it showed.
    static func forget(_ id: ShapeID) {
        count -= kept.removeValue(forKey: id)?.count ?? 0
    }

    /// Validation's rules, about the text itself: a text that isn't JSON is an error at its line
    /// and column, as is a root that isn't an object; `required` naming a property the object
    /// doesn't have is a warning, as is a `type` that isn't one of JSON Schema's, and anything else
    /// JSON Schema's meta-schema refuses (a type's schema is held to it: `MetaSchema`, through the
    /// core's validator, a `type` left to the rule above), `maxWarnings` in all. The panel shows them
    /// under the JSON too, in these words.
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
        for violation in metaValidator.violations(of: json(root)) where issues.count < maxWarnings {
            // A type's name is the rule above's, said once.
            guard violation.path.last != .member("type") else { continue }
            issues.append(.warning(violation.message, field: "schema"))
        }
        return issues
    }

    /// The meta-schema compiled by the core's validator, once.
    private static let metaValidator: SchemaValidator = {
        guard case .object(let schema) = json(MetaSchema.root) else { preconditionFailure("the meta-schema's root isn't an object") }
        return SchemaValidator(JSONSchema(schema))
    }()

    /// A reading as the core's JSON, which its validator checks: an object's duplicate members as
    /// the last.
    private static func json(_ node: JSONNode) -> JSONValue {
        switch node.value {
        case .object(let members): .object(Dictionary(members.map { ($0.key, json($0.value)) }, uniquingKeysWith: { _, last in last }))
        case .array(let elements): .array(elements.map(json))
        case .string(let string): .string(string)
        case .number(let literal): .number(Double(literal) ?? .nan)
        case .bool(let bool): .bool(bool)
        case .null: .null
        }
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
