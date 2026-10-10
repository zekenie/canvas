import Canvas
import Foundation
import SlashCommands

/// What a row of `/is-a`'s list stands for, kept in the row's `id`: `type` (make the shape a type),
/// or one of the file's types, by id.
enum TypeChoice {
    case type
    case existing(ShapeID)
    case none

    static let typeID = "type"

    init(_ choice: SlashChoice) {
        if choice.id == Self.typeID {
            self = .type
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
            rows.append(SlashChoice(TypeChoice.typeID, title: TypesStyle.typeChoice, symbol: TypesStyle.typeSymbol, group: 0, step: TypesStyle.makeType))
        }
        for (index, type) in (editor.types?.choices(for: owner) ?? []).enumerated() {
            rows.append(SlashChoice(type.type.rawValue.uuidString, title: type.name ?? TypesStyle.untitledType, symbol: TypesStyle.typeSymbol,
                                    group: 1, step: TypesStyle.addType, isPreferred: index == 0))
        }
        return rows
    }
}
