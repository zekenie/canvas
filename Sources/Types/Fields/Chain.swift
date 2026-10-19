import Canvas
import CanvasRPC
import Foundation

// The chain: what an instance's types say to it, in the one order they are read in. Pure: it reads a
// catalog (the types of a file, as values) and answers with values, so the same answer serves a shape,
// every shape with the same types, and a test with no editor at all.
//
// The order is `TypeOrder`'s: a type before every type it builds on, and where a list leaves a choice,
// the one added last first. The first type in it to name a field gives all of it, `required` with it
// (nothing is merged: override, never `allOf`), and rows are laid out the other way round, the most
// general type's fields first, a field restated by a more specific type staying where the more general
// one put it.

/// A field a type names: a property of its schema that isn't a `$` key.
public struct ChainField: Equatable, Sendable {
    /// The key, as written.
    public var name: String
    /// The property's schema as the type wrote it, its `#` references written out.
    public var schema: SchemaValue
    /// Whether the type's own root `required` names it.
    public var isRequired: Bool
    /// A reference was dropped because it led back into itself (or was followed too deep).
    public var holdsItself: Bool

    public init(name: String, schema: SchemaValue, isRequired: Bool = false, holdsItself: Bool = false) {
        self.name = name
        self.schema = schema
        self.isRequired = isRequired
        self.holdsItself = holdsItself
    }
}

/// What one type says: the fields it names, and what else its root holds.
public struct ChainLevel: Equatable, Sendable {
    /// The root's `properties`, in the order written; none starts with `$`.
    public var fields: [ChainField]
    /// The root's keywords across fields (`allOf`, `anyOf`, `oneOf`, `not`, `if`, `then`, `else`,
    /// `dependentRequired`, `dependentSchemas`), as written, `#` references written out. Not the root's
    /// `patternProperties`, `$ref`, `additionalProperties`, `unevaluatedProperties`, `propertyNames`,
    /// `minProperties` and `maxProperties`: a pattern property is no row, and the others say which names
    /// or how many members the whole object may hold, which laid over every type's fields and over
    /// values no field names would make wrong what is never wrong.
    public var rules: [SchemaMember]
    /// The root `properties` whose key starts `$` and has more after it (`$title`), the key without the
    /// `$`, the value as written. `TitleSource` reads `title`.
    public var directives: [SchemaMember]

    /// Says nothing.
    public init(fields: [ChainField] = [], rules: [SchemaMember] = [], directives: [SchemaMember] = []) {
        self.fields = fields
        self.rules = rules
        self.directives = directives
    }

    /// What a type's schema text says; nil for text that isn't a JSON object.
    public init?(schema text: String) {
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        self.init(root: root)
    }

    /// What a type's schema says. Nothing for a root that isn't an object.
    init(root: JSONNode) {
        guard root.isObject else {
            self.init()
            return
        }
        let required = Set((root["required"]?.elements ?? []).compactMap(\.string))
        var fields: [ChainField] = [], directives: [SchemaMember] = []
        let properties = root["properties"].map { SchemaValue($0) }?.members ?? []
        for member in properties {
            var inliner = SchemaInliner(root: root)
            let schema = inliner.written(member.value)
            if let name = SchemaDirectives.name(member.key) {
                directives.append(SchemaMember(key: name, value: schema))
            } else if SchemaDirectives.isField(member.key) {
                fields.append(ChainField(name: member.key, schema: schema, isRequired: required.contains(member.key), holdsItself: inliner.holdsItself))
            }
        }
        var rules: [SchemaMember] = []
        for member in SchemaValue(root).members ?? [] where Self.ruleKeywords.contains(member.key) {
            var inliner = SchemaInliner(root: root)
            // (The member is walked as a schema's own, so the places inside its value are found.)
            let written = inliner.written(.object([member])).members?.first?.value
            rules.append(SchemaMember(key: member.key, value: written ?? member.value))
        }
        self.init(fields: fields, rules: rules, directives: directives)
    }

    private static let ruleKeywords: Set<String> = ["allOf", "anyOf", "oneOf", "not", "if", "then", "else", "dependentRequired", "dependentSchemas"]
}

/// One shape the chain can visit: a type.
public struct ChainNode: Equatable, Sendable {
    public var level: ChainLevel
    /// The shapes the chain visits next: a type's own types, later first.
    public var parents: [ShapeID]

    public init(level: ChainLevel, parents: [ShapeID] = []) {
        self.level = level
        self.parents = parents
    }
}

/// The shapes a chain is read over: nil for a shape that is none (gone, or not a type), whose branch
/// ends there.
public protocol ChainCatalog {
    func node(_ id: ShapeID) -> ChainNode?
}

/// What the types of an instance give it: its fields, in the order rows show them, and where each came from.
public struct Resolved: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var field: ChainField
        /// The type whose definition wins: the first in `order` that names it.
        public var source: ShapeID
        /// The most general type that names it: where its row sits.
        public var introducedBy: ShapeID

        public init(field: ChainField, source: ShapeID, introducedBy: ShapeID) {
            self.field = field
            self.source = source
            self.introducedBy = introducedBy
        }
    }

    /// A type's rules across fields; a rule has no name to win, so none is overridden.
    public struct Rule: Equatable, Sendable {
        public var source: ShapeID
        public var members: [SchemaMember]

        public init(source: ShapeID, members: [SchemaMember]) {
            self.source = source
            self.members = members
        }
    }

    public struct Directive: Equatable, Sendable {
        public var name: String
        public var value: SchemaValue
        public var source: ShapeID

        public init(name: String, value: SchemaValue, source: ShapeID) {
            self.name = name
            self.value = value
            self.source = source
        }
    }

    /// The types, most specific first; only those the catalog has.
    public var order: [ShapeID] = []
    /// Each field once, in row order: the most general type's first, in the order written, a field a
    /// more specific type restates staying where the more general one put it, with the winner's whole
    /// definition.
    public var fields: [Field] = []
    /// Every type's, in row order of their types.
    public var rules: [Rule] = []
    /// One per name, the winner's (first in `order`), in `order`.
    public var directives: [Directive] = []
    /// One object schema over the fields and the rules, as written, for the check: `properties`,
    /// `required` (the winners'), `allOf` of each type's rules; a part with nothing in it is left out.
    public var schema: JSONObject = ["type": "object"]

    /// What no types give: nothing.
    public init() {}

    public func field(named name: String) -> Field? { fields.first { $0.field.name == name } }
}

public enum Chain {
    /// What `types` give, over `catalog`: `types` are an instance's own list, in the order they were
    /// added (the last is read first).
    public static func resolve(types: [ShapeID], in catalog: some ChainCatalog) -> Resolved {
        var nodes: [ShapeID: ChainNode] = [:], gone: Set<ShapeID> = []
        func node(_ id: ShapeID) -> ChainNode? {
            if let found = nodes[id] { return found }
            guard !gone.contains(id) else { return nil }
            guard let found = catalog.node(id) else {
                gone.insert(id)
                return nil
            }
            nodes[id] = found
            return found
        }
        var named: Set<ShapeID> = []
        let heads = types.reversed().filter { named.insert($0).inserted }
        var resolved = Resolved()
        // A shape the catalog has nothing for (gone, or not a type) ends its branch and is not listed.
        resolved.order = TypeOrder.linearized(heads, parents: { node($0)?.parents ?? [] }).filter { node($0) != nil }

        var winners: [String: (field: ChainField, source: ShapeID)] = [:]
        for type in resolved.order {
            for field in node(type)?.level.fields ?? [] where winners[field.name] == nil { winners[field.name] = (field, type) }
        }
        var placed: Set<String> = []
        for type in resolved.order.reversed() {
            let level = node(type)?.level ?? ChainLevel()
            for field in level.fields where placed.insert(field.name).inserted {
                guard let winner = winners[field.name] else { continue }
                resolved.fields.append(.init(field: winner.field, source: winner.source, introducedBy: type))
            }
            if !level.rules.isEmpty { resolved.rules.append(.init(source: type, members: level.rules)) }
        }
        var directed: Set<String> = []
        for type in resolved.order {
            for directive in node(type)?.level.directives ?? [] where directed.insert(directive.key).inserted {
                resolved.directives.append(.init(name: directive.key, value: directive.value, source: type))
            }
        }
        resolved.schema = schema(of: resolved)
        return resolved
    }

    private static func schema(of resolved: Resolved) -> JSONObject {
        var schema: JSONObject = ["type": "object"]
        if !resolved.fields.isEmpty {
            schema["properties"] = .object(Dictionary(resolved.fields.map { ($0.field.name, $0.field.schema.json) }, uniquingKeysWith: { _, last in last }))
        }
        let required = resolved.fields.filter(\.field.isRequired).map { JSONValue.string($0.field.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        if !resolved.rules.isEmpty {
            schema["allOf"] = .array(resolved.rules.map { SchemaValue.object($0.members).json })
        }
        return schema
    }
}

// MARK: Writing references out

/// A schema with each `#` reference written out: replaced by the schema it leads to, the siblings of the
/// `$ref` laid over it (they win, in the target's order, new keys after), followed up to `depth` deep and
/// never into one it is already in, and at most `follows` in all; a reference that leads nowhere is dropped, and so says nothing; one
/// that leads back into itself, too deep or past that count, is dropped and `holdsItself` set. A reference that doesn't
/// start with `#` (`urn:uuid:…`, a type) is kept as written. Only places that hold a schema are walked
/// (`SchemaPositions`): `enum`, `const`, `default`, `examples`, `contentSchema` and every keyword that
/// isn't a schema are copied. The definitions, and `$schema`, `$id` and `$anchor`, are left out of what
/// is written: nothing refers to them any more.
private struct SchemaInliner {
    let root: JSONNode
    private(set) var holdsItself = false
    /// How deep a reference is followed before it is taken to lead back to itself.
    private static let depth = 6
    /// How many references one field's writing follows in all. The depth stops a loop, not a fan-out:
    /// definitions that each refer to several others would be written out branching^depth times.
    private static let follows = 2_000
    private var followed = 0
    private static let dropped: Set<String> = ["$defs", "definitions", "$schema", "$id", "$anchor"]

    init(root: JSONNode) { self.root = root }

    mutating func written(_ schema: SchemaValue) -> SchemaValue {
        walk(schema, depth: 0, visiting: [])
    }

    private mutating func walk(_ schema: SchemaValue, depth: Int, visiting: Set<String>) -> SchemaValue {
        guard case .object(let members) = schema else { return schema }
        var out: [SchemaMember] = [], ref: String?
        for member in members {
            switch member.key {
            case "$ref":
                if case .string(let text) = member.value, text.hasPrefix("#") { ref = text } else { out.append(member) }
            case _ where Self.dropped.contains(member.key):
                continue
            case _ where SchemaPositions.named.contains(member.key):
                guard case .object(let named) = member.value else {
                    out.append(member)
                    continue
                }
                let walked = named.map { SchemaMember(key: $0.key, value: walk($0.value, depth: depth, visiting: visiting)) }
                out.append(SchemaMember(key: member.key, value: .object(walked)))
            case _ where SchemaPositions.single.contains(member.key) || SchemaPositions.lists.contains(member.key):
                switch member.value {
                case .object: out.append(SchemaMember(key: member.key, value: walk(member.value, depth: depth, visiting: visiting)))
                case .array(let list) where SchemaPositions.lists.contains(member.key):
                    out.append(SchemaMember(key: member.key, value: .array(list.map { walk($0, depth: depth, visiting: visiting) })))
                default: out.append(member)
                }
            default:
                out.append(member)
            }
        }
        guard let ref else { return .object(out) }
        followed += 1
        guard depth < Self.depth, followed <= Self.follows, !visiting.contains(ref) else {
            holdsItself = true
            return .object(out)
        }
        guard let target = JSONPointer(ref)?.resolve(in: root) else { return .object(out) }
        guard case .object(var laid) = walk(SchemaValue(target.value), depth: depth + 1, visiting: visiting.union([ref])) else { return .object(out) }
        for sibling in out {
            if let place = laid.firstIndex(where: { $0.key == sibling.key }) { laid[place].value = sibling.value } else { laid.append(sibling) }
        }
        return .object(laid)
    }
}
