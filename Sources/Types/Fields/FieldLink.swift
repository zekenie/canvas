import Canvas
import Mentions
import Topology

// A pointer's value: one mention token in a string of `fieldValues`, the note it points at and the name it
// held when it was written. Mentions spells the token (`MentionToken`); this reads and writes it as a
// value, tells the core which shape it names (`FieldValues: ShapeNaming`) and derives the edge it is.

/// A pointer's value: one mention token in a string of `fieldValues`.
public struct FieldLink: Hashable, Sendable {
    public var target: ShapeID
    /// The label the token holds: the target's name when it was picked.
    public var stored: String

    public init(target: ShapeID, stored: String) {
        self.target = target
        self.stored = stored
    }

    /// A string value that is exactly one token (`MentionToken.read`); nil for any other value.
    public init?(_ value: JSONValue) {
        guard let text = value.stringValue, let token = MentionToken.read(text) else { return nil }
        self.init(target: token.id, stored: token.label)
    }

    /// The value to store: `MentionToken.write(target, label: stored)`.
    public var value: JSONValue { .string(MentionToken.write(target, label: stored)) }

    /// The value that points at `record`, its label the name a mention of it shows now.
    @MainActor public static func pointing(at record: AnyShapeRecord, in editor: CanvasEditor) -> FieldLink {
        let label = editor.mentions?.resolve(record.id).appearance?.label ?? editor.registry.mentionAppearance(of: record)?.label ?? ""
        return FieldLink(target: record.id, stored: label)
    }

    /// Calls `body` with each link `value` holds, at any depth (an object's members and an array's
    /// items; a string that is not exactly one token is passed over), in order but for an object's
    /// members. The one walk the naming, the edges and the checks share.
    static func forEach(in value: JSONValue, _ body: (FieldLink) -> Void) {
        switch value {
        case .string(let text):
            if let token = MentionToken.read(text) { body(FieldLink(target: token.id, stored: token.label)) }
        case .array(let items):
            for item in items { forEach(in: item, body) }
        case .object(let members):
            for key in members.keys.sorted() { forEach(in: members[key]!, body) }
        case .null, .bool, .number:
            break
        }
    }
}

/// Which notes a pointer to `type` may point at: a shape whose chain reaches the type (an Employee is a
/// Person), and never a type's own note. The picker lists these, and the check holds a value to it.
@MainActor
public enum FieldLinks {
    public static func admits(_ target: ShapeID, as type: ShapeID, in index: TypeIndex) -> Bool {
        !index.isType(target) && index.isType(type) && index.graph.reaches(type, from: target)
    }

    /// Every shape that may be pointed at, file-wide: `index.affected(by: [type])` less the types. O(the answer).
    public static func targets(of type: ShapeID, in index: TypeIndex) -> [ShapeID] {
        guard index.isType(type) else { return [] }
        return index.affected(by: [type]).filter { !index.isType($0) }
    }
}

// MARK: Naming

/// Coded by hand: a string anywhere in the object that is exactly one mention token (`FieldLink`) names its
/// shape, so a copy, a cut, a paste and a delete do to a pointer what they do to a mention, by the core's own
/// code. No schema is read: a token in a text field names its shape too (only an agent or a paste makes one).
extension FieldValues: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        for key in values.keys.sorted() { FieldLink.forEach(in: values[key]!) { body($0.target) } }
    }

    /// Itself, but for each token whose id `rename` changes: written again with the label it held, the
    /// id canonical. Any other byte is kept as stored.
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self {
        var changed = false
        func renamed(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text):
                guard let token = MentionToken.read(text), let new = rename(token.id), new != token.id else { return value }
                changed = true
                return .string(MentionToken.write(new, label: token.label))
            case .array(let items):
                return .array(items.map(renamed))
            case .object(let members):
                return .object(members.mapValues(renamed))
            case .null, .bool, .number:
                return value
            }
        }
        let new = values.mapValues(renamed)
        return changed ? FieldValues(new) : self
    }
}

// MARK: The edge

/// A pointer as an edge in Topology's graph: from the note that holds it to the note it points at, in the slot
/// of the field's top-level key, once for each time the field holds it. Under `mention`, so a query that says
/// `mention` and the mention lights take it in; Mentions' own readers filter `mention` exactly and leave it out.
public enum FieldLinkEdge {}

extension FieldLinkEdge: EdgeType {
    public static let id: EdgeTypeID = "field-link"
    public static let parent: EdgeTypeID? = MentionEdge.id
    public static let summary: String? = "a field's link to a note, from the note that holds it to the note it names"
}

/// Types' edge source: every pointer in the values of every kind that can be an instance.
@MainActor
func registerFieldLinkEdges(into registrar: inout PluginRegistrar) {
    registrar.edgeType(FieldLinkEdge.self)
    registrar.edgesForEveryShape(where: { kind, registry in registry.isTypeable(kind) }) { record, _, sink in
        guard let values = record[FieldValuesProperty.self] else { return }
        for key in values.values.keys.sorted() {
            FieldLink.forEach(in: values.values[key]!) { sink.emit(FieldLinkEdge.id, from: record.id, to: $0.target, slot: key) }
        }
    }
}
