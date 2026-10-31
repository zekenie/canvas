import Canvas
import CanvasRPC
import Validation

/// Each type's schema read once: its rules, the sync, its highlights and its panel all read the same
/// text, so a reading is kept per shape and text, and read again only when the shape's schema
/// changes. A reading costs what its text's length does. A shape keeps the readings of up to
/// `versionsPerShape` texts, by its id: ids are unique within a file, not across files, so a file
/// duplicated in Finder and opened beside its original has the same shapes, whose texts may differ
/// once one is edited, and each window's are kept beside the other's rather than taking their place
/// as each is read. Typing adds a reading, and the shape's used longest ago goes. The readings of
/// shapes that went, or were read again from disk, are dropped (`forget`, which the sync calls).
/// The readings of every shape of every file open are kept, with room for the texts typed and the
/// copies (`capacity` follows what the open files' indexes say they hold: `expect`, never fewer than
/// `minimumCapacity`), so opening a file of 10,000 types reads each once; past `capacity` the one used
/// longest ago goes, one at a time (`oldest`: the readings are a list in the order they were used,
/// each use moving one to the front in a step or two, so the cost of a lookup or of letting one go
/// is the same however many are kept). The shape itself shows its words, and reads none.
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
    /// The shape whose schema it is: the key its readings are kept under.
    private let id: ShapeID
    /// While `document` isn't a JSON object, the shape's last reading that was, this session.
    private var showing: SchemaReadings?
    private(set) lazy var issues: [ValidationIssue] = SchemaReadings.issues(of: document)
    /// When it was last asked for, counted in lookups: which of one shape's readings went longest ago.
    private var used = 0
    /// Its place in the order readings were used (`newest` to `oldest`), while it has one: the one
    /// used just before it, and just after. `older` holds the next, so the chain from `newest` holds
    /// every reading in it; `newer` only points back, and is set only while this one is in the chain.
    private var older: SchemaReadings?
    private unowned(unsafe) var newer: SchemaReadings?

    private init(_ text: String, for id: ShapeID, after previous: SchemaReadings?) {
        self.text = text
        self.id = id
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
    /// `shownText` as the model is sent it: without the directives held aside (`held.stripped`: its `$color`,
    /// `$autofill` and what other plugins keep there), which are no business of the model's, so a type given
    /// another color asks it nothing again.
    func shownModelText(holding held: HeldDirectives) -> String { showing?.modelText(holding: held) ?? modelText(holding: held) }
    private var modelTexts: (keys: [String], text: String)?
    private func modelText(holding held: HeldDirectives) -> String {
        let keys = held.all.map(\.key)
        if let kept = modelTexts, kept.keys == keys { return kept.text }
        let made = held.isAbsent(from: document.root) ? text : held.stripped(text)
        modelTexts = (keys, made)
        return made
    }

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
    /// The readings in the order they were used: the one used last, and the one used longest ago.
    private static var newest: SchemaReadings?
    private static var oldest: SchemaReadings?
    /// At most this many a shape: the same shape in up to three copies of its file open beside it
    /// read nothing again; one typed into keeps the texts it had last.
    static let versionsPerShape = 4
    /// The fewest readings kept: room for the types of a file of a few thousand, and for the readings of
    /// types that aren't in any file (a card being made).
    static var minimumCapacity = 4096
    /// How many types each open file's index holds, by index (`expect`), and in all: what `capacity`
    /// follows.
    private static var expectations: [ObjectIdentifier: Int] = [:]
    private static var expected = 0
    #if DEBUG
    static var made = 0
    static var keptCount: Int { count }
    #endif

    /// At most this many readings are kept: a reading for every type of every file open and a quarter
    /// more for the texts typed and the copies (a file duplicated in Finder and opened beside its
    /// original is two indexes of the same ids, and its types are counted twice), and no fewer than
    /// `minimumCapacity`. A fixed number would have a file with more types than it read again and
    /// again, each time the sync or a panel asked, as every one it kept was gone by the time it came
    /// round to it.
    static var capacity: Int { max(minimumCapacity, expected + expected / 4) }

    /// A file's index says how many types it holds now (`count`, 0 when it goes): the readings kept
    /// follow the files open. Let go of past the new `capacity`, the ones used longest ago.
    static func expect(types count: Int, from index: ObjectIdentifier) {
        let before = (count == 0 ? expectations.removeValue(forKey: index) : expectations.updateValue(count, forKey: index)) ?? 0
        expected += count - before
        if count < before { trim() }
    }

    /// The reading of a type's schema; nil for a shape that isn't one.
    static func reading(of shape: AnyShapeRecord) -> SchemaReadings? {
        shape[TypeSchemaProperty.self].map { reading(of: $0.text, for: shape.id) }
    }

    /// The reading of `text`, the schema of the shape `id`: the one kept for the shape with this
    /// text, else read now and kept with them, in place of the shape's used longest ago once it
    /// has `versionsPerShape`. While the text isn't a JSON object, it shows what the shape's reading
    /// used last showed (`shown`), whether it's read now or the shape went back to it. Either way it
    /// is the one used last now.
    static func reading(of text: String, for id: ShapeID) -> SchemaReadings {
        lookups += 1
        let versions = kept[id] ?? []
        if let found = versions.first(where: { $0.text == text }) {
            if !found.document.isObject, let last = versions.max(by: { $0.used < $1.used }), last !== found { found.follow(last) }
            found.text = text
            found.used = lookups
            makeNewest(found)
            return found
        }
        let reading = SchemaReadings(text, for: id, after: versions.max { $0.used < $1.used })
        reading.used = lookups
        if versions.count < versionsPerShape {
            kept[id, default: []].append(reading)
            count += 1
        } else if let replaced = versions.indices.min(by: { versions[$0].used < versions[$1].used }) {
            unlink(versions[replaced])
            kept[id]?[replaced] = reading
        }
        makeNewest(reading)
        trim()
        return reading
    }

    /// Puts a reading first in the order of use (in it already, or new).
    private static func makeNewest(_ reading: SchemaReadings) {
        guard newest !== reading else { return }
        unlink(reading)
        reading.older = newest
        newest?.newer = reading
        newest = reading
        if oldest == nil { oldest = reading }
    }

    /// Takes a reading out of the order of use, if it's in it.
    private static func unlink(_ reading: SchemaReadings) {
        let newer = reading.newer, older = reading.older
        guard newer != nil || older != nil || newest === reading else { return }
        if let newer { newer.older = older } else { newest = older }
        if let older { older.newer = newer } else { oldest = newer }
        reading.newer = nil
        reading.older = nil
    }

    /// Lets go of the reading used longest ago, until no more than `capacity` are kept.
    private static func trim() {
        let capacity = capacity
        while count > capacity, let last = oldest {
            unlink(last)
            if let index = kept[last.id]?.firstIndex(where: { $0 === last }) {
                kept[last.id]?.remove(at: index)
                if kept[last.id]?.isEmpty == true { kept[last.id] = nil }
                count -= 1
            }
        }
    }

    /// Drops the readings of a shape that went, or was read again from disk, or is no longer a type,
    /// and the last one it showed.
    static func forget(_ id: ShapeID) {
        guard let readings = kept.removeValue(forKey: id) else { return }
        for reading in readings { unlink(reading) }
        count -= readings.count
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
            // At the root a `$` key is a directive, which a field can't be required by.
            let names = Set(properties.map(\.key).filter { !path.isEmpty || SchemaDirectives.isField($0) })
            var seen: Set<String> = []
            for name in required.compactMap(\.string) where !names.contains(name) && seen.insert(name).inserted {
                guard issues.count < maxWarnings else { return }
                let place = path.isEmpty ? "" : " of \(path)"
                issues.append(.warning("“\(name)” is required, but isn’t a property\(place).", field: "schema"))
            }
        }
        if TypeColorDirective.reading(of: root) == .notAColor, issues.count < maxWarnings {
            issues.append(.warning("“\(TypeColorDirective.key)” isn’t a color.", field: "schema"))
        }
        if TypeAutofillDirective.reading(of: root) == .notABool, issues.count < maxWarnings {
            issues.append(.warning("“\(TypeAutofillDirective.key)” isn’t true or false.", field: "schema"))
        }
        for violation in metaValidator.violations(of: SchemaValue(root).json) where issues.count < maxWarnings {
            // A type's name is the rule above's, said once.
            guard violation.path.last != .member("type") else { continue }
            issues.append(.warning(violation.message, field: "schema"))
        }
        return issues
    }

    /// The meta-schema compiled by the core's validator, once.
    private static let metaValidator: SchemaValidator = {
        guard case .object(let schema) = SchemaValue(MetaSchema.root).json else { preconditionFailure("the meta-schema's root isn't an object") }
        return SchemaValidator(JSONSchema(schema))
    }()

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

/// Where a schema holds a schema: the keywords whose value is one, or an object of them, or a list. What
/// walks a schema (`SchemaWalk`) and what rewrites one (`Chain`'s reading of a level) go by this one
/// list, so they agree on where a schema is.
enum SchemaPositions {
    /// Objects whose members are the schemas of names.
    static let named = ["properties", "patternProperties", "dependentSchemas"]
    /// Objects whose members are schemas kept to be referred to.
    static let definitions = ["$defs", "definitions"]
    /// A keyword whose value is a schema.
    static let single = ["items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames",
                         "unevaluatedProperties", "unevaluatedItems", "additionalItems"]
    /// A keyword whose value is a list of schemas.
    static let lists = ["allOf", "anyOf", "oneOf", "prefixItems", "items"]
}

/// Goes through every place in a schema that holds a schema, with a path a person can read
/// (`customer`, `items[]`, `$defs/money`): what validation checks.
enum SchemaWalk {
    static func schemas(in root: JSONNode, _ visit: (JSONNode, String) -> Void) {
        walk(root, path: "", depth: 0, visit)
    }

    private static func walk(_ schema: JSONNode, path: String, depth: Int, _ visit: (JSONNode, String) -> Void) {
        guard schema.isObject, depth < JSONReader.maxDepth else { return }
        visit(schema, path)
        func joined(_ name: String) -> String { path.isEmpty ? name : "\(path).\(name)" }
        for key in ["properties", "patternProperties"] + SchemaPositions.definitions + ["dependentSchemas"] {   // the order warnings were first kept in
            for member in schema[key]?.members ?? [] {
                let name = key == "properties" ? member.key : key == "patternProperties" ? "/\(member.key)/" : "\(key)/\(member.key)"
                walk(member.value, path: key.hasPrefix("$") || key == "definitions" ? name : joined(name), depth: depth + 1, visit)
            }
        }
        for key in SchemaPositions.single {
            guard let sub = schema[key], sub.isObject else { continue }
            walk(sub, path: key == "items" ? path + "[]" : path, depth: depth + 1, visit)
        }
        for key in SchemaPositions.lists {
            for sub in schema[key]?.elements ?? [] {
                walk(sub, path: key == "prefixItems" || key == "items" ? path + "[]" : path, depth: depth + 1, visit)
            }
        }
    }
}
