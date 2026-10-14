import AppKit
import Canvas
import CoreGraphics
import Draw
import Mentions
import Selection

// The offer: words never draw, and one click does. A pill in a type's words that names another type, not yet related
// to it and not embedded by it, offers `Relate to <Type>` on a click: the one writer the drag between two types calls
// (`newRelationshipType`), no model asked, and neither the words nor the schema of either type changed. The offer is a
// face (Selection's), asked before Mentions' because Types is listed after Mentions, so a pill it does not apply to
// behaves as Mentions' does; and an item in the canvas's context menu on the same pill (`TypeMenus.swift`).

extension TypesStyle {
    /// The offer's one item: `Relate to Layer`.
    public static func relate(to name: String) -> String { "Relate to \(name)" }
}

/// A pill in a type's words that offers to relate its type to the type it names (world units).
struct RelateFace: Hashable, Sendable {
    let shape: ShapeID
    let target: ShapeID
    let frame: CGRect
}

@MainActor
enum RelateOffers {
    /// The face under `point` on `record`, or nil. It is asked on every move over a shape, so the cheap tests come first
    /// and a note that is no type costs one lookup of an added value.
    static func find(at point: CGPoint, on record: AnyShapeRecord, in editor: CanvasEditor) -> RelateFace? {
        // A type is a shape that holds a schema (this names no kind).
        guard editor.editingShapeID != record.id, let schema = record[TypeSchemaProperty.self] else { return nil }
        guard !editor.isBoardReadOnly, let types = editor.types, let relationships = editor.relationships else { return nil }
        // A relationship type's pills name its ends, which are arrows; it relates to nothing.
        guard !relationships.graph.isRelationshipType(record.id) else { return nil }
        guard let pill = editor.mentionPills(of: record.id).last(where: { $0.frame.contains(point) }), pill.isLive,
              types.canBeEmbedded(pill.target) else { return nil }
        // The type the pill names: on the board shown, or on another, which a pill can stand for.
        if editor.document[pill.target] == nil {
            guard FarVerdicts(editor).verdict(of: pill.target) != .cannot else { return nil }
        }
        guard editor.registry.drawsConnections else { return nil }
        // The two that cost: a type that holds the other's fields in place is not related to it, and neither is one that a
        // relationship type already joins to it.
        if SchemaReferences.refs(in: schema.text).contains(where: { $0.shape == pill.target }) { return nil }
        guard relationships.graph.relationshipTypes(joining: record.id, and: pill.target).isEmpty else { return nil }
        return RelateFace(shape: record.id, target: pill.target, frame: pill.frame)
    }

    /// The item's title: `Relate to Layer`, with what a pick of a type on another board does first.
    static func title(for face: RelateFace, in editor: CanvasEditor) -> String {
        let record = editor.shape(inFile: face.target)
        let name = record.flatMap { editor.registry.mentionAppearance(of: $0)?.label } ?? editor.types?.name(of: face.target) ?? TypesStyle.untitledType
        var title = TypesStyle.relate(to: name)
        if editor.document[face.target] == nil, case .fulfils(let needs) = editor.farVerdict(of: face.target) {
            title += " · " + TypesStyle.willBeMade(needs)
        }
        return title
    }

    /// The menu a click opens: one item.
    static func menu(for face: RelateFace, in editor: CanvasEditor) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let action = TypeMenuAction { [weak editor] in editor?.acceptRelateOffer(face) }
        let item = NSMenuItem(title: title(for: face, in: editor), action: #selector(TypeMenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action          // the item holds its target weakly
        menu.addItem(item)
        return menu
    }
}

extension CanvasEditor {
    /// What the item does: the type put between the two, as the drag between them puts one, from the type whose words
    /// mention to the type mentioned, and its name asked (`newRelationshipType`). A type mentioning itself
    /// ("friends with another @Person") is made related to itself, with two arrows. Nothing else is written, and no
    /// model is asked. A refusal shakes the type, as the core's refusal of any change does. A choice that is stale (the
    /// two were related, or one stopped being a type, after the menu was made) changes nothing.
    @discardableResult
    func acceptRelateOffer(_ face: RelateFace) -> Bool {
        guard let types, let relationships, types.isType(face.shape), types.canBeEmbedded(face.target),
              relationships.graph.relationshipTypes(joining: face.shape, and: face.target).isEmpty else { return false }
        guard newRelationshipType(from: face.shape, to: face.target) != nil else {
            refuseChanges(to: [face.shape])
            return false
        }
        return true
    }
}

/// Registers the offer's face: a click opens the menu, a double-click does what a click on a pill did before (begins
/// editing at the pill, or follows it on a type that cannot be edited: read-only, or of a kind with no editing view), and the pointer over it hovers the type it names, as
/// Mentions' faces do, so that only the single click changes.
@MainActor
func registerRelateOffer(into registrar: inout PluginRegistrar) {
    registrar.shapeFaces(at: { editor, record, point in RelateOffers.find(at: point, on: record, in: editor) },
                         click: { face, editor in
                             let menu = RelateOffers.menu(for: face, in: editor)
                             editor.popUpMenu(menu, below: face.frame, highlighting: menu.items.first)
                         },
                         doubleClick: { face, editor in
                             // A shape that cannot be edited (read-only, or of a kind with no editing view) follows the pill.
                             if editor.isReadOnly(face.shape)
                                 || !editor.beginEditing(face.shape, at: CGPoint(x: face.frame.midX, y: face.frame.midY)) {
                                 editor.mentions?.follow(face.target)
                             }
                         },
                         hovering: { face, editor in editor.document[face.target] != nil ? face.target : nil })
}
