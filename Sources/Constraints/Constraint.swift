import Canvas
import Foundation

// What a place accepts: a constraint is a few words a person wrote ("only tasks", "no bugs") and the stored query they
// were turned into, which every shape within its reach must match. A frame or a subboard holds a list of them as an
// added property (`ConstraintsProperty`, on the kinds that opt in with `constrainable()`), the root board as a file
// value (`RootConstraintsProperty`), and a shape that keeps a list its own way (a type, P9's) through the holders'
// point. One codec reads and writes every list.

/// How far into a place a constraint reaches: the shapes directly in it (in a frame directly; on a board in no
/// container), or every shape under it in Topology's one containment tree, boards included.
public enum ConstraintReach: String, Codable, Hashable, Sendable, CaseIterable, SchemaCases {
    case children
    case descendants

    public var schemaTitle: String {
        switch self {
        case .children: ConstraintsStyle.directlyInside
        case .descendants: ConstraintsStyle.anywhereInside
        }
    }
}

/// One constraint: what a person wrote, the query it became (nil until the words are interpreted: it checks nothing and
/// refuses nothing), how far it reaches, and the shapes the titles in its query named when it was written. Its JSON is
/// `{"says": "only tasks", "query": ":is-a(\"Task\")", "reach": "children", "names": {"Task": "7C1E…"}}`; a missing `reach`
/// reads `children`, and `names` is left out while there are none. A constraint is named by its value, never its place
/// in a list, so what lands later for one finds the one it was for, or nothing.
///
/// `names` is the binding (`QueryState.bindNames(in:)`): a constraint is judged by those shapes whatever they are called
/// now (`ConstraintIndex`), so renaming a type writes nothing and changes no verdict. Only the writer sets it, as it writes
/// a query; a list written some other way (an agent's, a person's hand in a type's schema) has none and is judged by its
/// titles as written.
public struct Constraint: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<Constraint>(definition: "constraints.constraint") {
        Property("says", \.says).required().description("What a person wrote the place accepts.")
        Property("query", \.query).description("The stored query the words became; none until they are interpreted.")
        Property("reach", \.reach).description("The shapes it holds to: directly inside the place, or anywhere inside it.")
        Property("names", \.names).description("The shapes the query's titles named when it was written, by title, as ids; it is judged by those shapes whatever they are called now.")
    }

    /// The words, on one line.
    public var says: String
    /// The stored query, trimmed; nil for words not interpreted yet (never empty).
    public var query: String?
    public var reach: ConstraintReach
    /// Which shape each title head in `query` named when it was written, by the head as the query writes it
    /// (`QueryState.bindNames(in:)`); empty for none, and for words not interpreted.
    public var names: [String: ShapeID]

    public init() {
        says = ""
        query = nil
        reach = .children
        names = [:]
    }

    /// The words folded to one line and the query trimmed, an empty one none; names only where there is a query.
    public init(says: String, query: String? = nil, reach: ConstraintReach = .children, names: [String: ShapeID] = [:]) {
        self.says = Constraint.folded(says)
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed?.isEmpty == false ? trimmed : nil
        self.reach = reach
        self.names = self.query == nil ? [:] : names
    }

    /// Whether its words have become a query: one that has none checks nothing and refuses nothing.
    public var isInterpreted: Bool { query != nil }

    /// Runs of whitespace and line breaks as one space, trimmed.
    static func folded(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The same constraint as a list keeps it (`Constraint(says:query:reach:names:)` over its members); nil for one with no
    /// words.
    var normalized: Constraint? {
        let made = Constraint(says: says, query: query, reach: reach, names: names)
        return made.says.isEmpty ? nil : made
    }

    // MARK: Coding

    private enum Key: String, CodingKey {
        case says, query, reach, names
    }

    /// `names` is read as an object of ids by title, and anything else (a value that isn't one, an entry whose id doesn't
    /// read) is none: a board written by hand is never refused for it.
    private struct LenientNames: Decodable {
        let names: [String: ShapeID]

        init(from decoder: any Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode([String: String].self)) ?? [:]
            names = raw.compactMapValues { UUID(uuidString: $0).map { ShapeID($0) } }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init()
        says = try container.decode(String.self, forKey: .says)
        if container.contains(.query), try !container.decodeNil(forKey: .query) { query = try container.decode(String.self, forKey: .query) }
        if container.contains(.reach), try !container.decodeNil(forKey: .reach) { reach = try container.decode(ConstraintReach.self, forKey: .reach) }
        names = (try? container.decodeIfPresent(LenientNames.self, forKey: .names))??.names ?? [:]
    }

    /// What a constraint writes, in the order a person reads it: the words, the query while there is one, the reach, and `names`
    /// while there are some, so a constraint with neither is written as it always was. The one place that says which members a
    /// constraint has and when they are left out; the codec and the text of a list in a schema (`ConstraintList.jsonText`) both
    /// write what it says.
    private var members: [(key: Key, value: Member)] {
        var found: [(Key, Member)] = [(.says, .text(says))]
        if let query { found.append((.query, .text(query))) }
        found.append((.reach, .text(reach.rawValue)))
        if !names.isEmpty { found.append((.names, .object(names.mapValues(\.description)))) }
        return found
    }

    fileprivate enum Member {
        case text(String)
        case object([String: String])
    }

    fileprivate var jsonText: String {
        let items = members.map { "\"\($0.key.rawValue)\": " + Self.json($0.value) }
        return "{\(items.joined(separator: ", "))}"
    }

    /// A member as JSON: a string as the codec writes one (slashes as they are), an object's keys sorted.
    private static func json(_ member: Member) -> String {
        switch member {
        case .text(let text): quoted(text)
        case .object(let entries): "{" + entries.sorted { $0.key < $1.key }.map { "\(quoted($0.key)): \(quoted($0.value))" }.joined(separator: ", ") + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (key, member) in members {
            switch member {
            case .text(let text): try container.encode(text, forKey: key)
            case .object(let entries): try container.encode(entries, forKey: key)
            }
        }
    }
}

/// A list of constraints, in order, each once. Read leniently, so a board written by hand is never refused for it: a
/// member that doesn't read as a constraint, or has no words, is dropped, and a second of the same value too, never the
/// list. Written in order, each member's keys sorted, as every board value is.
public struct ConstraintList: Hashable, Sendable {
    public var constraints: [Constraint]

    public init(_ constraints: [Constraint] = []) {
        var seen: Set<String> = []
        self.constraints = constraints.compactMap(\.normalized).filter { seen.insert($0.says).inserted }
    }

    public var isEmpty: Bool { constraints.isEmpty }
}

extension ConstraintList: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Constraint...) { self.init(elements) }
}

extension ConstraintList: Codable {
    /// Anything an unkeyed container steps over without reading.
    private struct Skipped: Decodable {}

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [Constraint] = []
        while !container.isAtEnd {
            // A failed decode leaves the container where it was: step over the member.
            guard let member = try? container.decode(Constraint.self) else {
                _ = try container.decode(Skipped.self)
                continue
            }
            kept.append(member)
        }
        self.init(kept)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for constraint in constraints { try container.encode(constraint) }
    }
}

extension ConstraintList {
    /// The list as JSON text a person reads and edits (a type's schema keeps it so: `$constraints`): an array, a constraint to an
    /// item, each an object of the members the codec writes (`says`, `query`, `reach`, `names`) in that order, spaced as typed
    /// (`": "`, `", "`), the keys of `names` sorted. What `JSONDecoder` reads back as this list.
    public var jsonText: String { "[" + constraints.map(\.jsonText).joined(separator: ", ") + "]" }

    /// One step so far, for the one codec every list shares: a constraint holds `names`, left out while there are none, so
    /// nothing is rewritten.
    static let migrations = [PropertyMigration("a constraint holds the shapes its query's titles named")]
}

/// The shapes a list's constraints name (`names`), so a copy of a container that is pasted with the shapes they name holds
/// the copies' ids, as `is` does, and a name of a shape that isn't copied stays. The list is coded by hand, a leaf the
/// registry can't look inside.
extension ConstraintList: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        for constraint in constraints { for id in constraint.names.values { body(id) } }
    }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> ConstraintList {
        ConstraintList(constraints.map { constraint in
            var renamed = constraint
            renamed.names = constraint.names.mapValues { rename($0) ?? $0 }
            return renamed
        })
    }
}

extension ConstraintList: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        [Constraint].schema(in: &definitions)
    }
}

/// A container's own constraints: an added property of the kinds that opt in (`constrainable()`), none until one is
/// added. Constraints' own, so no language lists it (`unlisted()`): a person writes it with `/constrain` and the
/// Rules tab, and an agent a type's (P9's `$constraints`).
public enum ConstraintsProperty {}

extension ConstraintsProperty: ShapeProperty {
    public static let key: PropertyKey = "constraints"
    public static var defaultValue: ConstraintList? { nil }
    public static var keywords: PropertyKeywords<ConstraintList> {
        PropertyKeywords().description("What the place accepts: each shape within a constraint's reach must match its query.").unlisted()
    }
    public static func isNone(_ value: ConstraintList) -> Bool { value.isEmpty }
    public static var migrations: [PropertyMigration] { ConstraintList.migrations }
}

/// The root board's constraints: a file value (the root is no shape), none until one is added.
public enum RootConstraintsProperty {}

extension RootConstraintsProperty: FileProperty {
    public static let key: PropertyKey = "constraints"
    public static var defaultValue: ConstraintList { ConstraintList() }
    public static var migrations: [PropertyMigration] { ConstraintList.migrations }
}

extension AnyShapeRecord {
    /// The constraints the shape holds itself (`ConstraintsProperty`): none for a shape that holds none.
    public var ownConstraints: [Constraint] { self[ConstraintsProperty.self]?.constraints ?? [] }
}
