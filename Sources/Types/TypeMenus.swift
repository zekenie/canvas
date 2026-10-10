import Canvas
import Foundation
import ContextMenus

/// The line inside Is a ▸, between `Type` and the file's types.
enum IsATypesMenuGroup {}
extension IsATypesMenuGroup: MenuGroup {
    static var order: Int { 1 }
}

/// What Is a ▸ shows for a menu's shapes, read once when the menu opens.
@MainActor
struct IsAMenu {
    let editor: CanvasEditor
    /// Every shape holds `is`, so it can be something.
    let applies: Bool
    /// Every shape can be a type: `Type` is in the menu.
    let canBeTypes: Bool
    /// Every shape is one: `Type` is checked.
    let allAreTypes: Bool
    /// The types some shape is or may be, by name.
    let types: [(type: ShapeID, name: String?)]
    /// The types every shape is: checked.
    let had: Set<ShapeID>

    init(_ shapes: [ShapeID], in editor: CanvasEditor) {
        self.editor = editor
        let records = shapes.compactMap { editor.document[$0] }
        applies = !shapes.isEmpty && records.count == shapes.count && records.allSatisfy { editor.registry.isTypeable($0.kind) }
        canBeTypes = applies && records.allSatisfy { editor.registry.canBeType($0.kind) }
        allAreTypes = canBeTypes && records.allSatisfy { $0[TypeSchemaProperty.self] != nil }
        types = applies ? editor.types?.menuChoices(for: shapes) ?? [] : []
        var common: Set<ShapeID>?
        for record in records {
            let links = Set((record[IsAProperty.self] ?? []).map(\.shape))
            common = common.map { $0.intersection(links) } ?? links
        }
        had = common ?? []
    }
}

/// Is a ▸ in every shape's menu, beside Lock (`StateMenuGroup`, with no line between them): `Type`
/// (only when every shape can be one), a line, then the file's types, a check by what every shape
/// is. An unchecked item gives it to the shapes that don't have it and may ("Make Type", "Add
/// Type"); a checked one takes it from all ("Remove Type"). Never dimmed: a read-only shape is
/// refused by the core and shakes, while the rest of the selection changes in the one step. Left out
/// where it would hold nothing, and where a selected shape holds no `is` (a frame, a subboard).
@MainActor
func registerTypeMenus(into registrar: inout PluginRegistrar) {
    registrar.contextMenuForCanvas {
        MenuItems(in: StateMenuGroup.self, id: "is-a") { subject in
            let menu = IsAMenu(subject.shapes, in: subject.editor)
            if menu.applies {
                Submenu("Is a", in: StateMenuGroup.self, id: "is-a") {
                    if menu.canBeTypes {
                        MenuItem(TypesStyle.typeChoice, in: ShapeMenuGroup.self, id: "type", isChecked: { _ in menu.allAreTypes },
                                 stepName: menu.allAreTypes ? TypesStyle.removeType : TypesStyle.makeType) { ids, editor in
                            if menu.allAreTypes { editor.removeTypes(ids) } else { editor.makeTypes(ids) }
                        }
                    }
                    for entry in menu.types {
                        let type = entry.type, has = menu.had.contains(type)
                        MenuItem(entry.name ?? TypesStyle.untitledType, in: IsATypesMenuGroup.self, id: type.rawValue.uuidString,
                                 isChecked: { _ in has }, stepName: has ? TypesStyle.removeType : TypesStyle.addType) { ids, editor in
                            if has { editor.removeTypeLink(type, from: ids) } else { editor.addTypeLink(type, to: ids) }
                        }
                    }
                }
            }
        }
    }
}
