import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Frames
import Geometry
import LanguageModels
import Locking
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types
import Validation

// Board 1 of the relationships wireframes, the first minute's drag, on the shipped list with real notes and real
// arrows: a Feature type and a Layer type, a Feature note and a Layer note with a value each and no title and no words.
// A port's drag from one type to the other puts a relationship type between them, drawn small and selected, with the card
// that names it open; every Feature note has a `layer` row and every Layer note a `feature` row; the name is typed; one
// Undo, once the card is dismissed, returns the board to the start. Then a drag from the Feature note to the Layer note
// takes the type at once, in the press's step, and opens no list. (The rows' list and its pick are the next slice's.)

@MainActor
final class Minute {
    let pasteboard = NSPasteboard.withUniqueName()
    let model = ScriptedLanguageModel()
    let h: EditorHarness
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    let feature = ShapeID(), layer = ShapeID(), featureNote = ShapeID(), layerNote = ShapeID()

    init(featureAt: CGPoint = CGPoint(x: 40, y: 40), layerAt: CGPoint = CGPoint(x: 1000, y: 40)) throws {
        let pasteboard = self.pasteboard, model = self.model
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: model) }
        editor = h.editor
        (window, canvas) = windowed(editor)
        window.isReleasedWhenClosed = false
        editor.viewportDidResize(to: CGSize(width: 1600, height: 900))
        editor.addTypeNote(#"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#,
                           text: "A feature in a software system, has a purpose.", title: "Feature", frame: CGRect(origin: featureAt, size: CGSize(width: 200, height: 200)), id: feature)
        editor.addTypeNote(#"{"type": "object", "properties": {"order": {"type": "number"}, "purpose": {"type": "string"}, "title": {"type": "string"}}}"#,
                           text: "A layer in a software system, has an order, a purpose and a title.", title: "Layer",
                           frame: CGRect(origin: layerAt, size: CGSize(width: 200, height: 200)), id: layer)
        func note(_ id: ShapeID, of type: ShapeID, at origin: CGPoint, _ values: JSONObject) -> AnyShapeRecord {
            var record = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: ""))
            record[IsAProperty.self] = [TypeLink(type)]
            record[FieldValuesProperty.self] = FieldValues(values)
            return AnyShapeRecord(record)
        }
        let notes = [note(featureNote, of: feature, at: CGPoint(x: 40, y: 500), ["purpose": "sign in with no password"]),
                     note(layerNote, of: layer, at: CGPoint(x: 1000, y: 500), ["order": 1, "purpose": "expose foobar", "title": "foundation"])]
        editor.transact { transaction in for record in notes { transaction.insert(record) } }
        editor.selectedShapeIDs = []
        // The board as it is at step 0 is the one an Undo returns to.
        h.editor.replaceDocument(with: editor.document)
        h.scheduler.advance(by: .zero)
    }

    func close() {
        window.close()
        pasteboard.releaseGlobally()
    }

    var rows: RowBook { editor.rowBook! }
    var arrows: [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }
    func frame(_ id: ShapeID) throws -> CGRect { try require(editor.shapeContext.frame(of: id)) }
    func center(_ id: ShapeID) throws -> CGPoint { let f = try frame(id); return CGPoint(x: f.midX, y: f.midY) }

    /// A port's drag from the right dot of `from` (12 points out from the middle of its right side) to the middle of `to`,
    /// as the person's: hover, press the dot, drag fast, release.
    func drag(from: ShapeID, to: ShapeID, release: Bool = true) throws {
        let source = try frame(from)
        h.move(to: h.view(CGPoint(x: source.midX, y: source.midY)))
        h.move(to: h.view(CGPoint(x: source.maxX + 12, y: source.midY)))
        h.press()
        h.drag(to: h.view(try center(to)), speed: 3)
        if release { h.release() }
    }

    func bytes() throws -> Data { try BoardCodec(registry: editor.registry).encode(editor.file) }

    /// A frame round both types, as a person's board would have one.
    func frameAround(locked: Bool = false) -> ShapeID {
        var frame = ShapeRecord(Frame(frame: CGRect(x: 0, y: 0, width: 1300, height: 320)))
        frame[TitleProperty.self] = "Everything"
        editor.transact { $0.insert(frame) }
        editor.put([feature, layer], in: frame.id)
        if locked { editor.lock([frame.id]) }
        editor.undoHistory.seal()
        h.editor.replaceDocument(with: editor.document)
        return frame.id
    }

    func names(of note: ShapeID) -> [String] { rows.rows(of: note).map(\.name) }
    var cardField: NSTextView? { editor.card.flatMap { $0.view.subviews.compactMap { $0 as? NSTextView }.first } }
}

@MainActor let relationshipReleaseShippedTests = Suite("The first minute's drag, shipped", [
    test("board 1, steps 0 to 5 and 9: a drag from Feature to Layer puts a small relationship type between them, selected, with its name card; every Feature has a layer row and every Layer a feature row; the name is typed; one Undo returns the board; a drag between the notes takes the type") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        // Step 0: Feature's note has one row and no dashed line, Layer's has three; no arrows, no issues.
        expectEqual(m.names(of: m.featureNote), ["purpose"])
        expectEqual(m.names(of: m.layerNote), ["order", "purpose", "title"])
        expectEqual(m.arrows.count, 0)
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: m.featureNote)?.issues.map(\.message) ?? [], [])
        let start = editor.document
        let featureNote = start[m.featureNote], layerNote = start[m.layerNote]
        // Steps 1 and 2: the pointer on the Feature type shows its dots; the right one pressed and dragged onto Layer's note.
        let source = try m.frame(m.feature)
        m.h.move(to: m.h.view(CGPoint(x: source.midX, y: source.midY)))
        // Step 3: released.
        try m.drag(from: m.feature, to: m.layer)
        let made = try require(editor.document.shapes.last { $0[RelationshipProperty.self] == true }, "the relationship type").id
        expectEqual(editor.document.shapes.count, start.shapes.count + 3, "three shapes the board did not have")
        expectEqual(m.arrows.count, 2)
        expect(!m.arrows.contains { $0.props.start.binding?.shapeID == m.feature && $0.props.end.binding?.shapeID == m.layer }, "no arrow from Feature to Layer")
        let relationship = try require(editor.document[made])
        expectEqual(relationship[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
        expectEqual(relationship.typed(as: StickyNote.self)?.props.text.stored, "")
        expectEqual(relationship[TitleProperty.self], nil)
        expectEqual(try m.frame(made).size, CGSize(width: 160, height: 34), "drawn small")
        let box = try m.frame(made), featureBox = try m.frame(m.feature), layerBox = try m.frame(m.layer)
        expect(!box.intersects(featureBox) && !box.intersects(layerBox), "overlapping neither: \(box)")
        let toIt = try require(m.arrows.first { $0.props.start.binding?.shapeID == m.feature && $0.props.end.binding?.shapeID == made })
        let fromIt = try require(m.arrows.first { $0.props.start.binding?.shapeID == made && $0.props.end.binding?.shapeID == m.layer })
        expect(toIt.props.endArrowhead && !toIt.props.startArrowhead && fromIt.props.endArrowhead && !fromIt.props.startArrowhead, "one head each")
        expectEqual(editor.selectedShapeIDs, [made])
        expect(editor.editingShapeID == nil, "selected and not edited")
        expect(editor.titlePillRect(of: made) != nil, "its pill shows")
        expectEqual(editor.undoHistory.undoName, "New Relationship Type", "one step")
        expect(editor.card != nil && editor.card?.shape == made, "its name card is open")
        // Step 4: at once, before a name, the rows.
        expectEqual(m.names(of: m.featureNote), ["purpose", "layer"])
        expectEqual(m.names(of: m.layerNote), ["order", "purpose", "title", "feature"])
        expectEqual(try require(m.rows.rows(of: m.featureNote).last).content, .empty("add layer"))
        expectEqual(try require(m.rows.rows(of: m.layerNote).last).content, .empty("add feature"))
        expectEqual(editor.document[m.featureNote], featureNote, "neither note's record changed")
        expectEqual(editor.document[m.layerNote], layerNote)
        expectEqual(m.rows.rows(of: m.feature).last?.content, .relationType(direction: "→", chips: [m.layer], more: 0), "the type notes say the way it runs")
        // Step 5: `in`, Return.
        let field = try require(m.cardField)
        field.insertText("in", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expect(editor.card == nil, "Return dismisses the card")
        expectEqual(editor.document[made]?[TitleProperty.self], "in")
        expectEqual(editor.undoHistory.undoName, "New Relationship Type")
        let named = editor.document
        editor.undo()
        expectEqual(editor.document.shapes.map(\.id), start.shapes.map(\.id), "one Undo: the board as at step 0")
        expectEqual(editor.document, start)
        expect(!editor.canUndo, "and nothing before it")
        expectEqual(m.names(of: m.featureNote), ["purpose"])
        editor.redo()
        expectEqual(editor.document, named, "Redo brings all three back, named")
        expectEqual(m.names(of: m.featureNote), ["purpose", "layer"])
        // Step 9: a drag from the Feature note to the Layer note takes the type at once, in the press's step, with no list.
        editor.selectedShapeIDs = []
        editor.undoHistory.seal()
        let before = editor.document
        try m.drag(from: m.featureNote, to: m.layerNote)
        let relationshipArrow = try require(m.arrows.first { $0.props.start.binding?.shapeID == m.featureNote })
        expectEqual(relationshipArrow[IsAProperty.self]?.map(\.shape), [made], "of `in` at once")
        expect(editor.menuToPopUp == nil, "no list")
        expectEqual(editor.undoHistory.undoName, "Add Arrow")
        expect(editor.card == nil)
        if case .related(let pills, 0)? = m.rows.rows(of: m.featureNote).last?.content {
            expectEqual(pills.count, 1, "the Feature note's layer row holds the Layer note's pill")
        } else {
            expect(false, "a row of pills: \(String(describing: m.rows.rows(of: m.featureNote).last?.content))")
        }
        expectEqual(editor.document[m.layerNote]?[TitleProperty.self], nil, "the Layer note never has a title")
        expectEqual(editor.document[m.featureNote]?[FieldValuesProperty.self], featureNote?[FieldValuesProperty.self], "no copy is stored in the note")
        editor.undo()
        expectEqual(editor.document, before, "one Undo takes back the arrow and its type together")
        expect(m.model.requests.isEmpty, "no step asked the model")
    },
    test("the same drag with the name card left open, and a press elsewhere: the type stays untitled and the Undo is still one") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let start = editor.document
        try m.drag(from: m.feature, to: m.layer)
        expect(editor.card != nil)
        // Escape in the field: the card closes, the type stays with both arrows, untitled.
        try require(m.cardField).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expect(editor.card == nil)
        let made = try require(editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        expectEqual(editor.document[made]?[TitleProperty.self], nil)
        expectEqual(m.arrows.count, 2)
        editor.undo()
        expectEqual(editor.document, start)
    },
])

@MainActor let relationshipReleaseEdgeTests = Suite("The drag between two types, at its edges", [
    test("the small relationship type sits across the gap on the line between the two types, with room for each arrow, and not above it for the box it stores") {
        let m = try Minute()
        defer { m.close() }
        let line = (try m.frame(m.feature).midY + m.frame(m.layer).midY) / 2
        try m.drag(from: m.feature, to: m.layer)
        let made = try require(m.editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        let box = try m.frame(made), feature = try m.frame(m.feature), layer = try m.frame(m.layer)
        expectEqual(box.size, CGSize(width: 160, height: 34))
        // The line is the one between the types as they will be once each gains a row, half that row's room lower.
        let expected = line + TypesStyle.relationshipRowGrowth / 2
        expect(abs(box.midY - expected) <= 1, "its middle \(box.midY) is on the line between the types (\(expected))")
        expect(box.minX >= feature.maxX + TypesStyle.endArrowRoom - 0.5 && box.maxX <= layer.minX - TypesStyle.endArrowRoom + 0.5, "with the arrows' room each side: \(box)")
        m.editor.closeCard()
    },
    test("both types in a frame: the relationship type is in the frame too, and one Undo returns the file's bytes") {
        let m = try Minute()
        defer { m.close() }
        let frame = m.frameAround()
        let start = try m.bytes()
        try m.drag(from: m.feature, to: m.layer)
        let made = try require(m.editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        expectEqual(m.editor.shapeContext.container(of: made), frame)
        m.editor.closeCard()
        m.editor.undo()
        expect(try m.bytes() == start, "the board as it was")
        expect(!m.editor.canUndo)
    },
    test("both types in a locked frame: nothing is made, the dragged arrow is kept, no hold is left and no card shows") {
        let m = try Minute()
        defer { m.close() }
        _ = m.frameAround(locked: true)
        let before = m.editor.document
        try m.drag(from: m.feature, to: m.layer)
        expectEqual(m.editor.document.shapes.count, before.shapes.count + 1, "only the plain arrow the drag drew")
        expectEqual(m.arrows.count, 1)
        expect(m.editor.card == nil)
        #if DEBUG
        expectEqual(m.editor.relationships?.heldConnections, [])
        #endif
    },
    test("a step that fails after the arrow is deleted and the type inserted puts everything back and leaves no step: the settle refuses in a locked frame") {
        let m = try Minute()
        defer { m.close() }
        func bound(_ id: ShapeID) -> ArrowTerminal { .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
        let arrow = AnyShapeRecord(ShapeRecord(Arrow(start: bound(m.feature), end: bound(m.layer))))
        m.editor.transact { $0.insert(arrow) }
        _ = m.frameAround(locked: true)
        let before = m.editor.document
        let steps = m.editor.undoHistory.undoName
        expectEqual(m.editor.newRelationshipType(from: m.feature, to: m.layer, replacing: arrow.id), nil)
        expectEqual(m.editor.document, before, "the arrow is back and nothing was inserted")
        expectEqual(m.editor.undoHistory.undoName, steps, "no step")
        expect(m.editor.card == nil)
    },
    test("zoomed out to 20%, where no card shows, the drag makes the type small, selected and untitled, and one Undo returns the bytes") {
        let m = try Minute(featureAt: CGPoint(x: 40, y: 40), layerAt: CGPoint(x: 400, y: 40))
        defer { m.close() }
        m.editor.camera.setZoom(0.2, around: .zero)
        let start = try m.bytes()
        let made = try require(m.editor.newRelationshipType(from: m.feature, to: m.layer))
        expect(m.editor.card == nil, "no card")
        expectEqual(m.editor.selectedShapeIDs, [made])
        expectEqual(m.editor.document[made]?[TitleProperty.self], nil)
        m.editor.undo()
        expect(try m.bytes() == start)
    },
    test("on a read-only board, with nothing done: a locked subboard's types are not related by the writer") {
        let m = try Minute()
        defer { m.close() }
        var subboard = ShapeRecord(Subboard(frame: CGRect(x: 40, y: 900, width: 240, height: 160)))
        subboard[TitleProperty.self] = "Plans"
        m.editor.transact { $0.insert(subboard) }
        let board = BoardID(owner: subboard.id)
        m.editor.lock([subboard.id])
        m.editor.selection = subboard.id
        m.editor.perform(.openSelection)
        expectEqual(m.editor.board, board)
        expect(m.editor.isBoardReadOnly)
        let inside = ShapeID(), other = ShapeID()
        m.editor.addTypeNote(TypeSchemaProperty.starter, text: "", title: "A", frame: CGRect(x: 40, y: 40, width: 200, height: 200), id: inside)
        m.editor.addTypeNote(TypeSchemaProperty.starter, text: "", title: "B", frame: CGRect(x: 1000, y: 40, width: 200, height: 200), id: other)
        expectEqual(m.editor.newRelationshipType(from: inside, to: other), nil)
    },
    test("an end locked relates as any other: the type is made, and both arrows bind to it") {
        let m = try Minute()
        defer { m.close() }
        m.editor.lock([m.feature])
        try m.drag(from: m.feature, to: m.layer)
        let made = try require(m.editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        expectEqual(m.arrows.count, 2)
        expect(m.arrows.contains { $0.props.start.binding?.shapeID == m.feature && $0.props.end.binding?.shapeID == made })
        m.editor.closeCard()
    },
    test("Feature and a pill that stands for Feature: the type is made between them, the second arrow runs to the pill, and Feature's notes have the row") {
        let m = try Minute()
        defer { m.close() }
        m.editor.transact { $0.update(m.feature) { $0[PublicProperty.self] = true } }
        var props = Reference(frame: CGRect(x: 1000, y: 600, width: Reference.defaultSize.width, height: Reference.defaultSize.height))
        ReferenceEdits.pick(&props, ReferenceTarget(id: m.feature, label: "Feature"))
        let pill = AnyShapeRecord(ShapeRecord(props))
        m.editor.transact { $0.insert(pill) }
        let made = try require(m.editor.newRelationshipType(from: m.feature, to: pill.id))
        expect(m.arrows.contains { $0.props.start.binding?.shapeID == made && $0.props.end.binding?.shapeID == pill.id }, "the literal end is the pill")
        expectEqual(m.editor.relationships?.graph.sides(of: made).from.map(\.type), [m.feature])
        expectEqual(m.editor.relationships?.graph.sides(of: made).to.map(\.type), [m.feature])
        m.editor.closeCard()
    },
])
