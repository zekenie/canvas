import Canvas
import Foundation
import SlashCommands
import Titles

/// What a row of `/is-a`'s list stands for, kept in the row's `id`: `type` (make the shape a type),
/// or one of the file's types, by id.
enum TypeChoice {
    case type
    case existing(ShapeID)
    /// A new type of this name, put beside the shape (`newType`).
    case new(String)
    case none

    static let typeID = "type"
    static let newPrefix = "new:"

    init(_ choice: SlashChoice) {
        if choice.id == Self.typeID {
            self = .type
        } else if choice.id.hasPrefix(Self.newPrefix) {
            self = .new(String(choice.id.dropFirst(Self.newPrefix.count)))
        } else if let uuid = UUID(uuidString: choice.id) {
            self = .existing(ShapeID(uuid))
        } else {
            self = .none
        }
    }
}

/// The rows of `/is-a`'s list for a shape.
@MainActor
enum TypeChoices {
    /// `Type` (group 0) while the shape can be one and isn't, then the file's types the shape may be
    /// (group 1), by name, the first the one highlighted when nothing is typed. Asked once when the
    /// list opens.
    static func rows(for owner: ShapeID, in editor: CanvasEditor) -> [SlashChoice] {
        var rows: [SlashChoice] = []
        if let record = editor.document[owner], record[TypeSchemaProperty.self] == nil, editor.registry.canBeType(record.kind) {
            rows.append(SlashChoice(TypeChoice.typeID, title: TypesStyle.typeChoice, symbol: TypesStyle.typeSymbol, group: 0, step: TypesStyle.makeType,
                                    chip: TypesStyle.grayChip))
        }
        for (index, type) in (editor.types?.choices(for: owner) ?? []).enumerated() {
            // A type's color, `Untitled` gray: what its pill and the chips of its instances are.
            rows.append(SlashChoice(type.type.rawValue.uuidString, title: type.name ?? TypesStyle.untitledType, symbol: TypesStyle.typeSymbol,
                                    group: 1, step: TypesStyle.addType, isPreferred: index == 0,
                                    chip: type.name == nil ? TypesStyle.grayChip : TypeColors.base(type.type)))
        }
        return rows
    }

    /// The one row offered for what was typed, when no row is titled so (the list puts it last): a new
    /// type of that name, beside the shape. Nil for nothing typed, a name over a title's limit, no kind
    /// that can be a type, or one with nothing to place it with.
    static func newRow(typed: String, owner: ShapeID, editor: CanvasEditor) -> SlashChoice? {
        guard let name = newTypeName(typed), let kind = editor.newTypeKind(for: owner), editor.registry.placement(for: kind) != nil else { return nil }
        return SlashChoice(TypeChoice.newPrefix + name, title: TypesStyle.newTypeRow(name), step: TypesStyle.newType)
    }

    /// What the typed text names a new type: trimmed, its spaces folded, the first letter a capital,
    /// the rest as typed. Nil for none, over a title's limit, or the list's own word (`Type`, case
    /// aside): `/is-a type` makes a shape a type, and on one that is a type already it makes nothing.
    static func newTypeName(_ typed: String) -> String? {
        guard let name = TitleProperty.folded(typed), let first = name.first, name.unicodeScalars.count <= TitleProperty.maxLength,
              name.caseInsensitiveCompare(TypesStyle.typeChoice) != .orderedSame else { return nil }
        return first.uppercased() + name.dropFirst()
    }
}
