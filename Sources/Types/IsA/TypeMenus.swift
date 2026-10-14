import Canvas
import Foundation
import ContextMenus
import Selection

/// The line inside Is a ▸, between `Type` and the file's types.
enum IsATypesMenuGroup {}
extension IsATypesMenuGroup: MenuGroup {
    static var order: Int { 1 }
}

/// The line inside Is a ▸ after the file's types: where the arrow's relationship types are.
enum IsAGoToMenuGroup {}
extension IsAGoToMenuGroup: MenuGroup {
    static var order: Int { 2 }
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
    /// Every shape can hold the mark: `Relationship Type` is in the menu.
    let canBeRelationshipTypes: Bool
    /// Every shape is a relationship type: `Relationship Type` is checked.
    let allAreRelationshipTypes: Bool
    /// The types some shape is or may be, by name.
    let types: [(type: ShapeID, name: String?)]
    /// The types every shape is: checked.
    let had: Set<ShapeID>
    /// The relationship types of the one shape the menu is for that are in the file: an arrow's chip opens its card, so the
    /// chip's `Go to` is here.
    let goTos: [(type: ShapeID, name: String)]

    init(_ shapes: [ShapeID], in editor: CanvasEditor) {
        self.editor = editor
        let records = shapes.compactMap { editor.document[$0] }
        // An arrow that is an end of a relationship type is of nothing.
        applies = !shapes.isEmpty && records.count == shapes.count && records.allSatisfy { editor.registry.isTypeable($0.kind) && editor.relationships?.end($0.id) == nil }
        canBeTypes = applies && records.allSatisfy { editor.registry.canBeType($0.kind) }
        allAreTypes = canBeTypes && records.allSatisfy { $0[TypeSchemaProperty.self] != nil }
        canBeRelationshipTypes = applies && records.allSatisfy { editor.registry.canBeRelationshipType($0.kind) }
        allAreRelationshipTypes = canBeRelationshipTypes && records.allSatisfy { $0[TypeSchemaProperty.self] != nil && $0[RelationshipProperty.self] == true }
        types = applies ? editor.typeMenuChoices(for: shapes) : []
        var common: Set<ShapeID>?
        for record in records {
            let links = Set((record[IsAProperty.self] ?? []).map(\.shape))
            common = common.map { $0.intersection(links) } ?? links
        }
        had = common ?? []
        if applies, records.count == 1, let types = editor.types, let relationships = editor.relationships {
            goTos = (records[0][IsAProperty.self] ?? []).filter { relationships.graph.isRelationshipType($0.shape) && editor.file.record($0.shape) != nil }
                .map { ($0.shape, TypesStyle.menuName(types.name(of: $0))) }
        } else {
            goTos = []
        }
    }
}

/// Is a ▸ in every shape's menu, beside Lock (`StateMenuGroup`, with no line between them): `Type`
/// (only when every shape can be one), `Relationship Type` (only when every shape can be one that
/// relates), a line, then the file's types, a check by what every shape is. An unchecked item gives it to
/// the shapes that don't have it and may ("Make Type", "Make Relationship Type", "Add Type": an arrow's
/// relationship type is replaced); a checked one takes it from all ("Remove Type"; `Relationship Type`
/// takes the mark off alone, "Make Plain Type", and the shape stays a type). Never dimmed: a read-only shape is
/// refused by the core and shakes, while the rest of the selection changes in the one step. Left out
/// where it would hold nothing, and where a selected shape holds no `is` (a frame, a subboard).
@MainActor
func registerTypeMenus(into registrar: inout PluginRegistrar) {
    // The offer on a pill in a type's words (`RelateOffers`), where the menu was asked for: `Relate to Layer`, the same item
    // the click on the pill opens. Left out at a skeleton's zoom, where no pill is drawn, and off every other point.
    registrar.contextMenuForCanvas {
        MenuItems(in: ShapeMenuGroup.self, id: "relate") { subject in
            if subject.shapes.count == 1, let id = subject.shapes.first, !subject.editor.drawsSkeleton(of: id), let record = subject.editor.document[id],
               let face = RelateOffers.find(at: subject.point, on: record, in: subject.editor) {
                MenuItem(RelateOffers.title(for: face, in: subject.editor), in: ShapeMenuGroup.self, id: "relate-\(face.target.rawValue.uuidString)",
                         stepName: TypesStyle.newRelationshipType) { _, editor in
                    editor.acceptRelateOffer(face)
                }
            }
        }
    }
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
                    if menu.canBeRelationshipTypes {
                        MenuItem(TypesStyle.relationshipTypeChoice, in: ShapeMenuGroup.self, id: "relationship-type",
                                 isChecked: { _ in menu.allAreRelationshipTypes },
                                 stepName: menu.allAreRelationshipTypes ? TypesStyle.makePlainType : TypesStyle.makeRelationshipType) { ids, editor in
                            if menu.allAreRelationshipTypes { editor.makePlainTypes(ids) } else { editor.makeRelationshipTypes(ids) }
                        }
                    }
                    for entry in menu.types {
                        let type = entry.type, has = menu.had.contains(type)
                        MenuItem(entry.name ?? TypesStyle.untitledType, in: IsATypesMenuGroup.self, id: type.rawValue.uuidString,
                                 isChecked: { _ in has }, stepName: has ? TypesStyle.removeType : TypesStyle.addType) { ids, editor in
                            if has { editor.removeTypeLink(type, from: ids) } else { editor.giveType(type, to: ids) }
                        }
                    }
                    for entry in menu.goTos {
                        let type = entry.type
                        MenuItem(TypesStyle.goTo(entry.name), in: IsAGoToMenuGroup.self, id: "go-to-" + type.rawValue.uuidString) { _, editor in editor.goTo([type]) }
                    }
                }
            }
        }
    }
}
