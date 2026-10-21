import Canvas
import Foundation
import SlashCommands
import Titles

/// What a row of `/is-a`'s list stands for, kept in the row's `id`: `type` (make the shape a type),
/// or one of the file's types, by id.
enum TypeChoice {
    case type
    /// Make the shape a relationship type.
    case relationshipType
    case existing(ShapeID)
    /// A new type of this name, put beside the shape (`newType`).
    case new(String)
    case none

    static let typeID = "type"
    static let relationshipTypeID = "relationship-type"
    static let newPrefix = "new:"

    init(_ choice: SlashChoice) {
        if choice.id == Self.typeID {
            self = .type
        } else if choice.id == Self.relationshipTypeID {
            self = .relationshipType
        } else if choice.id.hasPrefix(Self.newPrefix) {
            self = .new(String(choice.id.dropFirst(Self.newPrefix.count)))
        } else if let uuid = UUID(uuidString: choice.id) {
            self = .existing(ShapeID(uuid))
        } else {
            self = .none
        }
    }
}

/// How a type fits an arrow it may be given: `taken` (both sides hold and one fits by a drawn end: a port's
/// release takes it), `open` (no end is drawn on either side, or the arrow is not bound at both ends: offered, never
/// taken alone), `no` (the arrow would be a misfit). Every other owner's choices are `open`: nothing to fit.
public enum ChoiceFit: Sendable, Hashable {
    case taken, open, no
}

/// What a shape is to the lists of types: the role partition. An arrow that is an end of a relationship type is of
/// nothing; any other arrow of a kind that relates is offered relationship types; a type's own note, every type; any
/// other shape, plain types.
enum TypeRole {
    case end, arrow, type, plain

    @MainActor
    init(of record: AnyShapeRecord, in editor: CanvasEditor) {
        if editor.relationships?.end(record.id) != nil {
            self = .end
        } else if editor.registry.relates(record.kind) {
            self = .arrow
        } else if record[TypeSchemaProperty.self] != nil {
            self = .type
        } else {
            self = .plain
        }
    }

    /// What a pick on the shape takes the place of: an arrow's relationship types, since it is of one at a time
    /// (`setRelationshipType`), so a relationship type its own builds on is offered in its place; nothing for any
    /// other shape, which a pick adds to.
    @MainActor
    func replacing(_ shape: ShapeID, in index: TypeIndex) -> Set<ShapeID> {
        guard self == .arrow else { return [] }
        return Set(index.links(of: shape).map(\.shape)).intersection(index.graph.relationshipTypes)
    }

    /// Whether the role is offered the type.
    @MainActor
    func offers(_ type: ShapeID, in index: TypeIndex) -> Bool {
        switch self {
        case .end: false
        case .arrow: index.graph.relationshipTypes.contains(type)
        case .type: true
        case .plain: index.canBeEmbedded(type)
        }
    }
}

extension CanvasEditor {
    /// The types the shape may be, for `/is-a`'s list and Is a ▸ (the role partition, `TypeRole`): an arrow's
    /// relationship types, the fitting first (`taken`, then `open`, then `no`), each by name, untitled last; any
    /// other shape's plain types; a type's own note's every type; an end's none. `TypeIndex.choices(for:)` keeps
    /// listing every type that `admits` and knows nothing of relationships.
    public func typeChoices(for owner: ShapeID) -> [(type: ShapeID, name: String?, fit: ChoiceFit)] {
        guard let types, let record = shape(inFile: owner) else { return [] }
        let role = TypeRole(of: record, in: self)
        let offered = types.choices(for: owner, replacing: role.replacing(owner, in: types)).filter { role.offers($0.type, in: types) }
        guard role == .arrow else { return offered.map { ($0.type, $0.name, .open) } }
        let graph = relationships?.graph
        let fitting = relationships?.subjects(of: owner).flatMap { graph?.fitting(from: $0.from.reading, to: $0.to.reading) }
        let bound = relationships?.subjects(of: owner) != nil
        func fit(_ type: ShapeID) -> ChoiceFit {
            guard bound else { return .open }
            if fitting?.taken.contains(type) == true { return .taken }
            return fitting?.open.contains(type) == true ? .open : .no
        }
        let fits = offered.map { (type: $0.type, name: $0.name, fit: fit($0.type)) }
        return [ChoiceFit.taken, .open, .no].flatMap { wanted in fits.filter { $0.fit == wanted } }
    }

    /// The types Is a ▸ lists for a selection: each some shape is already or is offered (`typeChoices`'s partition,
    /// shape by shape), by name, untitled last. A type a shape has stays listed, so it can be taken off.
    func typeMenuChoices(for shapes: [ShapeID]) -> [(type: ShapeID, name: String?)] {
        guard let types else { return [] }
        let roles = shapes.compactMap { id in shape(inFile: id).map { (id: id, role: TypeRole(of: $0, in: self)) } }
        let replacing = Dictionary(roles.map { ($0.id, $0.role.replacing($0.id, in: types)) }, uniquingKeysWith: { a, _ in a })
        return types.menuChoices(for: shapes, replacing: replacing).filter { entry in
            roles.contains { shape in
                types.links(of: shape.id).contains(TypeLink(entry.type))
                    || (shape.role.offers(entry.type, in: types) && types.admits(entry.type, for: shape.id, replacing: replacing[shape.id] ?? []))
            }
        }
    }
}

/// The rows of `/is-a`'s list for a shape.
@MainActor
enum TypeChoices {
    /// `Type` and `Relationship Type` (group 0) while the shape can be one and isn't, then the types the shape may be
    /// (`typeChoices`: the fitting in group 1, an arrow's misfits in group 2), by name, the first the one highlighted
    /// when nothing is typed. Asked once when the list opens. An arrow that is an end has none.
    static func rows(for owner: ShapeID, in editor: CanvasEditor) -> [SlashChoice] {
        var rows: [SlashChoice] = []
        guard let record = editor.document[owner], editor.relationships?.end(owner) == nil else { return rows }
        if record[TypeSchemaProperty.self] == nil, editor.registry.canBeType(record.kind) {
            rows.append(SlashChoice(TypeChoice.typeID, title: TypesStyle.typeChoice, symbol: TypesStyle.typeSymbol, group: 0, step: TypesStyle.makeType,
                                    chip: TypesStyle.grayChip))
        }
        if record[RelationshipProperty.self] != true || record[TypeSchemaProperty.self] == nil, editor.registry.canBeRelationshipType(record.kind) {
            rows.append(SlashChoice(TypeChoice.relationshipTypeID, title: TypesStyle.relationshipTypeChoice, symbol: TypesStyle.relationshipTypeSymbol, group: 0,
                                    step: TypesStyle.makeRelationshipType, chip: TypesStyle.grayChip))
        }
        let marked = editor.types?.graph.relationshipTypes ?? []
        for (index, type) in editor.typeChoices(for: owner).enumerated() {
            // A type's color, `Untitled` gray: what its pill and the chips of its instances are.
            let look = editor.types?.look(of: type.type)
            rows.append(SlashChoice(type.type.rawValue.uuidString, title: type.name ?? TypesStyle.untitledType,
                                    symbol: marked.contains(type.type) ? TypesStyle.relationshipTypeSymbol : TypesStyle.typeSymbol,
                                    group: type.fit == .no ? 2 : 1, step: TypesStyle.addType, isPreferred: index == 0,
                                    chip: type.name == nil ? TypesStyle.grayChip : (look?.row ?? TypesStyle.grayChip),
                                    chipInk: type.name == nil ? nil : look?.rowInk))
        }
        return rows
    }

    /// The one row offered for what was typed, when no row is titled so (the list puts it last): a new
    /// type of that name, beside the shape (a relationship type, for an arrow). Nil for nothing typed, a name over a
    /// title's limit, no kind that can be a type or has nothing to place it with, and an arrow that is an end.
    static func newRow(typed: String, owner: ShapeID, editor: CanvasEditor) -> SlashChoice? {
        guard editor.relationships?.end(owner) == nil, let name = newTypeName(typed), let kind = editor.newTypeKind(for: owner),
              editor.registry.placement(for: kind) != nil else { return nil }
        let relationship = editor.document[owner].map { editor.registry.relates($0.kind) } ?? false
        return SlashChoice(TypeChoice.newPrefix + name, title: TypesStyle.newTypeRow(name),
                           step: relationship && editor.registry.canBeRelationshipType(kind) ? TypesStyle.newRelationshipType : TypesStyle.newType)
    }

    /// What the typed text names a new type: trimmed, its spaces folded, the first letter a capital,
    /// the rest as typed. Nil for none, over a title's limit, or the list's own words (`Type` and `Relationship
    /// Type`, case aside): `/is-a type` makes a shape a type, and on one that is a type already it makes nothing.
    static func newTypeName(_ typed: String) -> String? {
        guard let name = TitleProperty.folded(typed), let first = name.first, name.unicodeScalars.count <= TitleProperty.maxLength,
              name.caseInsensitiveCompare(TypesStyle.typeChoice) != .orderedSame,
              name.caseInsensitiveCompare(TypesStyle.relationshipTypeChoice) != .orderedSame else { return nil }
        return first.uppercased() + name.dropFirst()
    }
}
