import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Draw
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import TestKit
import Titles
import Topology
import Types
import Validation

// The offer: a click on a pill in a type's words that names another type, not yet related to it and not embedded by it, opens
// `Relate to <Type>`, which makes the relationship type between the two types in one step, as the drag between them does,
// and writes neither the words nor the schema of either (no model is asked). Where it does not apply the pill is Mentions':
// no menu. The same offers are in the canvas's context menu and the selection's, under Relate to ▸. Over slips (types that show rows), bonds and relays,
// with the engine of `canvas draw` making the arrows; the shipped notes are CompositionTests'.

@MainActor private func drawing() -> [any CanvasPlugin] {
    [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()]
}

/// A slip that is a type, saying `words`.
@MainActor private func slipType(_ schema: String, words: MentionText, title: String, at origin: CGPoint, id: ShapeID) -> AnyShapeRecord {
    var props = RowSlip(frame: CGRect(origin: origin, size: CGSize(width: 320, height: RowSlipStyle.emptyHeight)), text: words)
    RowSlipStyle.fit(&props)
    var record = ShapeRecord(id: id, props)
    record[TypeSchemaProperty.self] = SchemaText(schema)
    record[TitleProperty.self] = title
    return AnyShapeRecord(record)
}

/// What the Feature type's words mention.
private enum Says {
    case layer, itself, far, relationshipType, plainNote, gone, nothing
}

/// A Feature type whose words mention the Layer type, the Layer type, a relationship type `in` with no end, a Feature note, a
/// plain note, and a pocket holding a Company type, so a type can be on another board.
@MainActor
private struct Offer {
    let harness: EditorHarness
    let model = ScriptedLanguageModel()
    let log = RefusalLog()
    let feature = ShapeID(), layer = ShapeID(), rel = ShapeID(), note = ShapeID(), plain = ShapeID(), pocket = ShapeID(), far = ShapeID(), nowhere = ShapeID()
    var editor: CanvasEditor { harness.editor }

    init(says: Says = .layer, drawing draws: Bool = true) throws {
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "in", at: CGPoint(x: 240, y: 700), id: rel)
        related[RelationshipProperty.self] = true
        let target: (id: ShapeID, label: String)? = switch says {
        case .layer: (layer, "Layer")
        case .itself: (feature, "Feature")
        case .far: (far, "Company")
        case .relationshipType: (rel, "in")
        case .plainNote: (plain, "Foundation")
        case .gone: (nowhere, "Garden")
        case .nothing: nil
        }
        let words = target.map { MentionText([.text("A feature has a purpose and is in a "), .mention($0.id, label: $0.label), .text(".")]) } ?? MentionText(plain: "A feature")
        let file = CanvasFile(root: CanvasDocument(shapes: [
            slipType(featureRowsSchema, words: words, title: "Feature", at: CGPoint(x: 40, y: 40), id: feature),
            slipTypeRecord(layerRowsSchema, words: "A layer", title: "Layer", at: CGPoint(x: 600, y: 40), id: layer),
            related,
            slipRecord("Sign in", of: [feature], at: CGPoint(x: 40, y: 500), id: note),
            slipRecord("Foundation", at: CGPoint(x: 600, y: 500), id: plain),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100)))),
        ]), children: [pocket: CanvasDocument(shapes: [slipTypeRecord(TypeSchemaProperty.starter, words: "A company", title: "Company", at: CGPoint(x: 200, y: 0), id: far)])])
        let model = model, log = log
        let more: [any CanvasPlugin] = [BondsPlugin(), RelaysPlugin(), PocketsPlugin(), FreezingPlugin(log: log)] + (draws ? drawing() : [])
        harness = try EditorHarness { scheduler in try rowEditor(scheduler: scheduler, model: model, file: file, more: more) }
        harness.editor.viewportDidResize(to: CGSize(width: 1_400, height: 900))
        // The pocket's board is entered once, so what it holds is laid out where the editor keeps it.
        expect(editor.showBoard(BoardID(owner: pocket)))
        expect(editor.showBoard(.root))
    }

    var pocketBoard: BoardID { BoardID(owner: pocket) }

    /// The words of a note, written as a person writes them.
    func say(_ id: ShapeID, _ words: MentionText) {
        editor.transact { $0.update(id, as: RowSlip.self) { $0.props.text = words; RowSlipStyle.fit(&$0.props) } }
    }

    /// Where the shape's first pill is.
    func pill(of id: ShapeID) throws -> CGRect { try require(editor.mentionPills(of: id).first?.frame, "a pill in the words") }

    func middle(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// A click on the pill of a shape.
    func click(on id: ShapeID, count: Int = 1) throws { harness.click(at: middle(try pill(of: id)), clickCount: count) }

    /// The menu waiting to pop up.
    var waiting: NSMenu? { editor.menuToPopUp?.menu }

    /// Every bond on the root.
    func bonds() -> [ShapeRecord<Bond>] { editor.contents(of: .root).shapes.compactMap { $0.typed(as: Bond.self) } }
    func relays() -> [ShapeRecord<Relay>] { editor.contents(of: .root).shapes.compactMap { $0.typed(as: Relay.self) } }

    /// The Feature type's end and the Layer type's: Feature into `in`, and `in` out to Layer.
    func drawEnds() {
        editor.addBond(feature, rel)
        editor.addBond(rel, layer)
    }

    func bytes() throws -> Data { try BoardCodec(registry: editor.registry).encode(editor.file) }

    /// The shapes with an id the board did not have.
    func added(since known: Set<ShapeID>) -> [AnyShapeRecord] { editor.document.shapes.filter { !known.contains($0.id) } }
    var ids: Set<ShapeID> { Set(editor.document.shapes.map(\.id)) }
}

@MainActor let relateOfferTests = Suite("The offer to relate two types", [
    test("a click on a pill in a type's words that names another type queues one menu under it, Relate to Layer, highlighted; the type is selected, not edited, and nothing is written") {
        let s = try Offer()
        let pill = try s.pill(of: s.feature)
        let feature = s.editor.document[s.feature], layer = s.editor.document[s.layer]
        try s.click(on: s.feature)
        let queued = try require(s.editor.menuToPopUp, "a menu")
        expectEqual(queued.menu.items.map(\.title), ["Relate to Layer"])
        expectEqual(queued.rect, pill, "under the pill")
        expect(s.editor.menuItemToHighlight === queued.menu.items[0], "highlighted, so Return takes it")
        expectEqual(s.editor.selectedShapeIDs, [s.feature])
        expect(s.editor.editingShapeID == nil, "the click does not begin editing there")
        expectEqual(s.editor.document[s.feature], feature, "neither side of Feature, words or schema")
        expectEqual(s.editor.document[s.layer], layer)
        expect(s.bonds().isEmpty && s.editor.card == nil, "words never draw")
    },
    test("the pointer over the pill hovers the type it names, as Mentions' does, and over the rest of the note hovers the note") {
        let s = try Offer()
        let pill = try s.pill(of: s.feature)
        s.harness.move(to: s.middle(pill))
        expectEqual(s.editor.hovered, s.layer)
        let box = try require(s.editor.document[s.feature]?.box)
        s.harness.move(to: CGPoint(x: box.minX + 4, y: box.minY + 4))
        expectEqual(s.editor.hovered, s.feature, "off the pill")
        s.harness.move(to: s.middle(try s.pill(of: s.feature)))
        expectEqual(s.editor.hovered, s.layer)
        expect(s.editor.menuToPopUp == nil, "a hover opens nothing")
    },
    test("a double-click on the pill of an unlocked type whose kind has no editing view goes to the type, as Mentions' face does without the offer") {
        let with = try Offer()
        try with.click(on: with.feature, count: 2)
        with.harness.wait(50)
        let without = try Offer(drawing: false)
        try without.click(on: without.feature, count: 2)
        without.harness.wait(50)
        expectEqual(with.editor.selectedShapeIDs, [with.layer], "followed to the type")
        expect(with.editor.editingShapeID == nil && with.waiting == nil && with.bonds().isEmpty)
        expectEqual(without.editor.selectedShapeIDs, [without.layer], "as without the offer")
    },
    test("a double-click on the pill of a read-only type goes to the type (an editable one begins editing: CompositionTests') and no menu is left waiting") {
        let s = try Offer()
        s.editor.freeze([s.feature])
        try s.click(on: s.feature)
        expect(s.editor.menuToPopUp != nil, "the first press of the pair queues it")
        try s.click(on: s.feature, count: 2)
        s.harness.wait(50)
        expect(s.editor.menuToPopUp == nil, "the second press drops it")
        expectEqual(s.editor.selectedShapeIDs, [s.layer], "and the read-only type follows the pill to the type")
        expect(s.bonds().isEmpty)
    },
    test("choosing it makes the relationship type between the two, as the drag between them does: a type and two arrows in one step New Relationship Type, the name asked, neither type's words nor schema written, the model not asked; one Undo takes them back and the offer returns") {
        let s = try Offer()
        s.editor.undoHistory.seal()
        let before = s.editor.document, bytes = try s.bytes(), known = s.ids
        try s.click(on: s.feature)
        try require(s.waiting).choose("Relate to Layer")
        s.editor.menuDidPopUp()
        let made = s.added(since: known)
        expectEqual(made.count, 3, "a relationship type and its two arrows: \(made.map(\.kind))")
        let type = try require(made.first { $0[RelationshipProperty.self] == true })
        let bonds = made.compactMap { $0.typed(as: Bond.self)?.props }
        expectEqual(bonds.map(\.from), [s.feature, type.id], "from the type whose words mention, through the new type")
        expectEqual(bonds.map(\.to), [type.id, s.layer])
        expectEqual(s.editor.selectedShapeIDs, [type.id], "the new type is selected")
        expect(s.editor.editingShapeID == nil, "a memo has no editing view: the shipped note's tests hold the name typed in its pill")
        expect(s.editor.card == nil, "and no card asks it")
        expectEqual(s.editor.document[s.feature], before[s.feature], "Feature's words and schema")
        expectEqual(s.editor.document[s.layer], before[s.layer])
        expectEqual(s.editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        s.harness.wait(10_000)
        expectEqual(s.model.requests.count, 0, "no model was asked, by the click or by the sync after it")
        expectEqual(s.editor.typeSync?.status(of: s.feature), .idle)
        let graph = try require(s.editor.relationships?.graph)
        expectEqual(graph.relationshipTypes(joining: s.feature, and: s.layer), [type.id])
        // The offer is gone for the pill: it is Mentions' again, and no menu is queued.
        try s.click(on: s.feature)
        expect(s.waiting == nil, "related already: no offer")
        s.editor.undo()
        expectEqual(s.editor.document, before)
        expect(try s.bytes() == bytes, "the board byte for byte")
        try s.click(on: s.feature)
        expectEqual(s.waiting?.items.map(\.title), ["Relate to Layer"], "and the offer is back")
    },
    test("a menu chosen again after it related the two changes nothing: one relationship type, no second step, no shake") {
        let s = try Offer()
        s.editor.undoHistory.seal()
        try s.click(on: s.feature)
        let menu = try require(s.waiting)
        try menu.choose("Relate to Layer")
        s.editor.menuDidPopUp()
        s.editor.closeCard()
        s.editor.undoHistory.seal()
        let after = s.editor.document, revision = s.editor.revision
        try menu.choose("Relate to Layer")
        expectEqual(s.editor.document, after)
        expectEqual(s.editor.revision, revision, "nothing was written")
        expectEqual(try require(s.editor.relationships?.graph).relationshipTypes(joining: s.feature, and: s.layer).count, 1)
        expect(s.editor.card == nil, "no name is asked")
    },
    test("it is not offered, and the click is not the offer's, for a note that is no type, a pill that names a note that is no type, a relationship type, a dead pill, a type with a $ref to the type, a relationship type's own note, a pill of a type that is joined to it already, in either direction, and at a skeleton's zoom") {
        let cases: [(String, @MainActor () throws -> (Offer, ShapeID))] = [
            ("a note that is no type", {
                let s = try Offer()
                s.say(s.note, MentionText([.text("in a "), .mention(s.layer, label: "Layer")]))
                return (s, s.note)
            }),
            ("a pill naming a note that is no type", { let s = try Offer(says: .plainNote); return (s, s.feature) }),
            ("a pill naming a relationship type", { let s = try Offer(says: .relationshipType); return (s, s.feature) }),
            ("a dead pill", {
                let s = try Offer(says: .gone)
                return (s, s.feature)
            }),
            ("a pill whose type was deleted", {
                let s = try Offer()
                s.editor.transact("Delete") { $0.delete([s.layer]) }
                return (s, s.feature)
            }),
            ("a type that embeds the type", {
                let s = try Offer()
                s.editor.transact { $0.update(s.feature) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"layer": {"$ref": "\#(SchemaReferences.uri(of: s.layer))"}}}"#) } }
                return (s, s.feature)
            }),
            ("a relationship type's own note", {
                let s = try Offer()
                s.editor.transact { $0.update(s.feature) { $0[RelationshipProperty.self] = true } }
                return (s, s.feature)
            }),
            ("a pair a relationship type joins", { let s = try Offer(); s.drawEnds(); return (s, s.feature) }),
            ("a pair a relationship type joins, the other way round", {
                let s = try Offer()
                s.drawEnds()
                s.say(s.layer, MentionText([.text("is in a "), .mention(s.feature, label: "Feature")]))
                return (s, s.layer)
            }),
            ("a list with no engine that draws", { let s = try Offer(drawing: false); return (s, s.feature) }),
        ]
        for (name, make) in cases {
            let (s, shape) = try make()
            try s.click(on: shape)
            expect(s.waiting == nil, "\(name): no menu")
            expectEqual(s.editor.selectedShapeIDs, [shape], "\(name): the press selects the shape as any press does")
        }
        let s = try Offer()
        let pill = try s.pill(of: s.feature)
        s.editor.camera.setZoom(0.2, around: .zero)
        s.harness.click(at: s.harness.view(s.middle(pill)))
        expect(s.waiting == nil, "a skeleton shows no pill, so nothing is offered")
    },
    test("a pair a relationship type joins is offered again once none joins them: the ends taken away, or the mark") {
        let s = try Offer()
        s.drawEnds()
        try s.click(on: s.feature)
        expect(s.waiting == nil)
        s.editor.transact("Delete") { $0.delete(Set(s.bonds().map(\.id))) }
        try s.click(on: s.feature)
        expectEqual(s.waiting?.items.map(\.title), ["Relate to Layer"], "no end joins them")
        s.editor.menuDidPopUp()
        s.drawEnds()
        s.editor.transact { $0.update(s.rel) { $0[RelationshipProperty.self] = nil } }
        try s.click(on: s.feature)
        expectEqual(s.waiting?.items.map(\.title), ["Relate to Layer"], "unmarked, it is a type and joins nothing")
    },
    test("the pill of a type that builds on an end's type counts as it: a relationship type that joins Feature and Layer is one that joins Feature and a type built on Layer") {
        let s = try Offer()
        s.drawEnds()
        let sub = s.editor.addSlipType(layerRowsSchema, words: "A sub", title: "Sub", at: CGPoint(x: 1_000, y: 40))
        let graph = { try require(s.editor.relationships?.graph) }
        expectEqual(try graph().relationshipTypes(joining: s.feature, and: sub), [])
        s.editor.addTypeLink(s.layer, to: sub)
        expectEqual(try graph().relationshipTypes(joining: s.feature, and: sub), [s.rel], "Sub is a Layer")
        expectEqual(try graph().relationshipTypes(joining: sub, and: s.feature), [s.rel])
        expectEqual(try graph().relationshipTypes(joining: s.layer, and: sub), [])
        s.say(s.feature, MentionText([.text("is in a "), .mention(sub, label: "Sub")]))
        try s.click(on: s.feature)
        expect(s.waiting == nil, "a pill naming a type built on an end's is related already")
    },
    test("a read-only board offers nothing, and a locked type is offered: the click changes no record of its own") {
        let s = try Offer()
        let inside = ShapeID(), layerInside = ShapeID()
        s.editor.transact(on: s.pocketBoard, "Draw") { transaction in
            transaction.insert(slipType(featureRowsSchema, words: MentionText([.text("in a "), .mention(layerInside, label: "Layer")]), title: "Feature2", at: CGPoint(x: 40, y: 400), id: inside))
            transaction.insert(slipTypeRecord(layerRowsSchema, words: "A layer", title: "Layer2", at: CGPoint(x: 500, y: 400), id: layerInside))
        }
        s.editor.freeze([s.pocket])
        expect(s.editor.showBoard(s.pocketBoard))
        expect(s.editor.isBoardReadOnly, "a locked subboard's board")
        try s.click(on: inside)
        expect(s.waiting == nil, "a read-only board: nothing is offered")
        expect(s.editor.showBoard(.root))
        s.editor.freeze([s.pocket], false)
        s.editor.freeze([s.feature])
        try s.click(on: s.feature)
        expectEqual(s.waiting?.items.map(\.title), ["Relate to Layer"], "a locked type is offered")
        try require(s.waiting).choose("Relate to Layer")
        s.editor.menuDidPopUp()
        s.editor.closeCard()
        expect(s.relationshipTypesMade() == 1, "and its ports draw arrows as any")
    },
    test("the canvas's context menu on the type, anywhere on it, and the selection's menu hold Relate to ▸ with the offer, needing no point; a note that is no type has none; choosing it is the click's item") {
        let s = try Offer()
        let pill = try s.pill(of: s.feature)
        s.editor.selection = s.feature
        let on = try require(s.harness.secondaryClick(at: s.middle(pill)))
        expect(on.outline.contains("Relate to ▸") && on.outline.contains("  Layer"), "\(on.outline)")
        let off = try require(s.harness.secondaryClick(at: CGPoint(x: pill.minX - 8, y: pill.midY)))
        expect(off.outline.contains("Relate to ▸"), "off the pill too: \(off.outline)")
        s.editor.selection = s.feature
        let selection = try require(s.editor.menuForSelection(omitting: []))
        expect(selection.outline.contains("Relate to ▸") && selection.outline.contains("  Layer"), "the Shape menu: \(selection.outline)")
        // A note that is no type has no pill to relate, whatever its words mention.
        s.say(s.note, MentionText([.text("in a "), .mention(s.layer, label: "Layer")]))
        let note = try require(s.harness.secondaryClick(at: s.middle(try s.pill(of: s.note))))
        expect(!note.outline.contains("Relate to ▸"), "\(note.outline)")
        // Chosen from the menu: the same step, the same three shapes.
        s.editor.undoHistory.seal()
        let known = s.ids
        s.editor.selection = s.feature
        let again = try require(s.harness.secondaryClick(at: s.middle(pill)))
        try again.choose("Relate to", "Layer")
        s.editor.closeCard()
        expectEqual(s.added(since: known).count, 3)
        expectEqual(s.editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        s.editor.undo()
        expect(s.added(since: known).isEmpty, "one Undo")
    },
    test("a type that mentions itself, \"friends with another @Person\", offers Relate to Person and is made a type related to itself: two arrows, never a two-headed one; the offer goes and one Undo takes it back") {
        let s = try Offer(says: .itself)
        s.editor.undoHistory.seal()
        let before = s.editor.document, known = s.ids
        try s.click(on: s.feature)
        expectEqual(s.waiting?.items.map(\.title), ["Relate to Feature"])
        try require(s.waiting).choose("Relate to Feature")
        s.editor.menuDidPopUp()
        let made = s.added(since: known)
        expectEqual(made.count, 3)
        let type = try require(made.first { $0[RelationshipProperty.self] == true })
        let bonds = made.compactMap { $0.typed(as: Bond.self)?.props }
        expectEqual(bonds.map(\.from), [s.feature, type.id])
        expectEqual(bonds.map(\.to), [type.id, s.feature])
        let graph = try require(s.editor.relationships?.graph)
        expectEqual(graph.sides(of: type.id).from.map(\.type), [s.feature])
        expectEqual(graph.sides(of: type.id).to.map(\.type), [s.feature])
        expectEqual(graph.relationshipTypes(joining: s.feature, and: s.feature), [type.id])
        s.editor.closeCard()
        try s.click(on: s.feature)
        expect(s.waiting == nil, "related to itself already: no offer")
        s.editor.undo()
        expectEqual(s.editor.document, before)
    },
    test("a type on another board is offered through the far path: the item says it will be made open, the pill lands beyond the new type, the far type is made open in the same step, one Undo returns both boards byte for byte") {
        let s = try Offer(says: .far)
        s.editor.undoHistory.seal()
        let bytes = try s.bytes(), known = s.ids
        let pill = try s.pill(of: s.feature)
        s.harness.move(to: s.middle(pill))
        expectEqual(s.editor.hovered, s.feature, "a type on another board is not outlined here: the note is hovered")
        try s.click(on: s.feature)
        expectEqual(s.waiting?.items.map(\.title), ["Relate to Company · will be made open"])
        try require(s.waiting).choose("Relate to Company · will be made open")
        s.editor.menuDidPopUp()
        s.editor.closeCard()
        let type = try require(s.added(since: known).first { $0[RelationshipProperty.self] == true })
        let relay = try require(s.relays().first, "a pill for the far type")
        expectEqual(relay.props.stands.map(\.shape), [s.far])
        expectEqual(s.editor.file.record(s.far)?.meta[Open.self], true, "made open in the step")
        let graph = try require(s.editor.relationships?.graph)
        expectEqual(graph.sides(of: type.id).from.map(\.type), [s.feature])
        expectEqual(graph.sides(of: type.id).to.map(\.type), [s.far], "the end is read through the pill")
        expectEqual(s.editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        s.editor.undo()
        expect(try s.bytes() == bytes, "both boards, byte for byte")
        // A far type that cannot be picked is not offered: private and locked, it cannot be made open.
        s.editor.transact { $0.update(inFile: s.far) { $0[Frozen.self] = true } }
        try s.click(on: s.feature)
        expect(s.waiting == nil, "the far type cannot be made open")
    },
])

extension Offer {
    /// How many relationship types the board has.
    fileprivate func relationshipTypesMade() -> Int {
        editor.document.shapes.filter { $0[RelationshipProperty.self] == true && $0.id != rel }.count
    }
}
