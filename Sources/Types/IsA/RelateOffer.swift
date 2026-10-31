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
    public static func relate(to name: String) -> String { "\(relateTo) \(name)" }
    /// The submenu of the offers in a type's words.
    public static let relateTo = "Relate to"
}

/// A pill in a type's words that offers to relate its type to the type it names (world units).
struct RelateFace: Hashable, Sendable {
    let shape: ShapeID
    let target: ShapeID
    let frame: CGRect

    /// What the offer is, whatever its pill's frame: the part's id stays the same when the type moves or its pills reflow.
    struct Offer: Hashable, Sendable {
        let shape: ShapeID
        let target: ShapeID
    }
    var offer: Offer { Offer(shape: shape, target: target) }
}

@MainActor
enum RelateOffers {
    /// The face under `point` on `record`, or nil. It is asked on every move over a shape, so the cheap tests come first
    /// and a note that is no type costs one lookup of an added value.
    static func find(at point: CGPoint, on record: AnyShapeRecord, in editor: CanvasEditor) -> RelateFace? {
        guard editor.editingShapeID != record.id, let schema = record[TypeSchemaProperty.self], canOffer(on: record, in: editor) else { return nil }
        guard let pill = editor.mentionPills(of: record.id).last(where: { $0.frame.contains(point) }) else { return nil }
        return offer(pill, on: record, schema: schema, in: editor)
    }

    /// Every offer in `record`'s words, in the order its pills are laid out, one for each type they name: what Relate to ▸ lists
    /// and ⌥Tab reaches, with no point.
    static func offers(on record: AnyShapeRecord, in editor: CanvasEditor) -> [RelateFace] {
        guard editor.editingShapeID != record.id, let schema = record[TypeSchemaProperty.self], canOffer(on: record, in: editor) else { return [] }
        var named = Set<ShapeID>()
        return editor.mentionPills(of: record.id).compactMap { pill in
            guard !named.contains(pill.target), let face = offer(pill, on: record, schema: schema, in: editor) else { return nil }
            named.insert(pill.target)
            return face
        }
    }

    /// Whether Relate to ▸ lists `record` itself, which no words need to name: the drag from a type back onto it, by keys, as
    /// often as it is asked (a type may be related to itself more than once, as a drag makes another each time). Not while its
    /// words are edited, when its words' offers are not listed either.
    static func offersItself(_ record: AnyShapeRecord, in editor: CanvasEditor) -> Bool {
        editor.editingShapeID != record.id && editor.canRelateToItself(record) && canOffer(on: record, in: editor)
    }

    /// Whether `record`, a type, offers anything: a board that can change, the index and relationships, and no relationship type
    /// (its pills name its ends, which are arrows; it relates to nothing).
    private static func canOffer(on record: AnyShapeRecord, in editor: CanvasEditor) -> Bool {
        guard !editor.isBoardReadOnly, editor.types != nil, let relationships = editor.relationships, editor.registry.drawsConnections else { return false }
        return !relationships.graph.isRelationshipType(record.id)
    }

    /// The offer of one pill, or nil: a live pill naming a type that can be embedded, on the board shown or one a pill can stand
    /// for, that the type neither holds in place nor is joined to by a relationship type.
    private static func offer(_ pill: MentionPillFrame, on record: AnyShapeRecord, schema: SchemaText, in editor: CanvasEditor) -> RelateFace? {
        guard pill.isLive, let types = editor.types, let relationships = editor.relationships, types.canBeEmbedded(pill.target) else { return nil }
        // The type the pill names: on the board shown, or on another, which a pill can stand for.
        if editor.document[pill.target] == nil {
            guard FarVerdicts(editor).verdict(of: pill.target) != .cannot else { return nil }
        }
        // The two that cost: a type that holds the other's fields in place is not related to it, and neither is one that a
        // relationship type already joins to it.
        if SchemaReferences.refs(in: schema.text).contains(where: { $0.shape == pill.target }) { return nil }
        guard relationships.graph.relationshipTypes(joining: record.id, and: pill.target).isEmpty else { return nil }
        return RelateFace(shape: record.id, target: pill.target, frame: pill.frame)
    }

    /// What a type is called in an offer: `Layer`, with what a pick of a type on another board does first.
    static func name(of target: ShapeID, in editor: CanvasEditor) -> String {
        let record = editor.shape(inFile: target)
        var name = record.flatMap { editor.registry.mentionAppearance(of: $0)?.label } ?? editor.types?.name(of: target) ?? TypesStyle.untitledType
        if editor.document[target] == nil, case .fulfils(let needs) = editor.farVerdict(of: target) {
            name += " · " + TypesStyle.willBeMade(needs)
        }
        return name
    }

    /// The item's title: `Relate to Layer`, with what a pick of a type on another board does first.
    static func title(for face: RelateFace, in editor: CanvasEditor) -> String {
        TypesStyle.relate(to: name(of: face.target, in: editor))
    }

    /// The menu a click opens: one item.
    static func menu(for face: RelateFace, in editor: CanvasEditor) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: title(for: face, in: editor)) { [weak editor] in editor?.acceptRelateOffer(face) })
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

    /// The drag from a type back onto it, by keys (Relate to ▸ and its own name): a relationship type from it to itself, with
    /// two arrows, however many it has already. A refusal shakes the type; one that stopped being a type changes nothing.
    @discardableResult
    func relateToItself(_ type: ShapeID) -> Bool {
        guard let record = document[type], canRelateToItself(record) else { return false }
        guard newRelationshipType(from: type, to: type) != nil else {
            refuseChanges(to: [type])
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
    // The same by keys: each offer is a part of the type (⌥Tab), whose press opens the menu the click opens.
    registrar.forShapes(holding: TypeSchemaProperty.self) { typeKinds in
        typeKinds.shapeParts(named: "RelateFace") { editor, record in
            guard record[TypeSchemaProperty.self] != nil, !editor.drawsSkeleton(of: record.id) else { return [] }
            return RelateOffers.offers(on: record, in: editor).map { face in
                ShapePart(id: face.offer, title: RelateOffers.title(for: face, in: editor), role: .menuButton, rect: face.frame) { editor in
                    let menu = RelateOffers.menu(for: face, in: editor)
                    editor.popUpMenu(menu, below: face.frame, highlighting: menu.items.first)
                }
            }
        }
    }
}
