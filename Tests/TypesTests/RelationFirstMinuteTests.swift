@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// Board 1 of the relationships wireframes, the first minute, over bonds (arrows of the tests' own: no Connections import):
// a drag from the Feature type to the Layer type makes a relationship type and two bonds, both types' notes gain their
// rows, the Layer note with no title and no words is listed by its values, a pick makes the bond, and one Undo takes it
// away. The shipped notes and arrows are CompositionTests'.

private struct Failure: Error {
    let message: String
}

@MainActor private func drawing() -> [any CanvasPlugin] {
    [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()]
}

@MainActor let relationshipFirstMinuteTests = Suite("The first minute, over bonds", [
    test("board 1: a drag from Feature to Layer makes a relationship type and two bonds, both types' notes gain their rows, the untitled Layer note is listed by its values, a pick makes the bond, and one Undo of the pick leaves the rest") {
        let s = try RelationScene(more: drawing())
        s.set(s.note, ["purpose": "sign in with no password"])
        let layerNote = s.addValued(["order": 1, "purpose": "expose foobar", "title": "foundation"], at: CGPoint(x: 800, y: 1500))
        s.editor.undoHistory.seal()
        let begun = s.editor.document
        // Step 0: no rows beyond the fields.
        expectEqual(s.names(s.note), ["purpose"])
        expectEqual(s.names(layerNote), ["order", "purpose", "title"])
        // Steps 2 and 3: the drag draws a bond from Feature to Layer; the release makes the relationship type and two bonds.
        let dragged = s.editor.addBond(s.feature, s.layer)
        let outcome = s.editor.connectionDrawn(dragged)
        guard case .madeRelationshipType(let made) = outcome else { throw Failure(message: "a relationship type: \(outcome)") }
        s.editor.closeCard()
        expect(s.editor.document[dragged] == nil, "the dragged arrow is replaced")
        expectEqual(s.bonds().filter { $0.props.from == s.feature && $0.props.to == s.layer }.count, 0, "no arrow runs from one type to the other")
        // Step 4: at once, both notes gain their rows.
        expectEqual(s.names(s.note), ["purpose", "layer"])
        expectEqual(s.names(layerNote), ["order", "purpose", "title", "feature"])
        expectEqual(try s.row(s.note, "layer").content, .empty("add layer"))
        // Step 6: the list, by the note's values, never `No Layer notes`.
        let row = try require(s.index.rows(for: [s.feature], isType: false).first)
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: row)
        expect(s.lines(picker).map(\.title).contains("1 · expose foobar · foundation"), "\(s.lines(picker))")
        expect(!s.lines(picker).contains { $0.title.hasPrefix("No ") })
        let steps = s.editor.undoHistory.undoName
        // Step 7: the pick draws the arrow, bound from the Feature note to the Layer note, of the type, no values.
        let arrow = try require(s.editor.relate(s.note, to: layerNote, in: row))
        expectEqual(s.editor.undoHistory.undoName, "Add Relationship")
        let bond = try require(s.editor.document[arrow]?.typed(as: Bond.self))
        expectEqual(bond.props.from, s.note)
        expectEqual(bond.props.to, layerNote)
        expectEqual(bond[IsAProperty.self]?.map(\.shape), [made])
        expectEqual(bond[FieldValuesProperty.self], nil)
        expectEqual(try s.pills(s.note, "layer").pills.count, 1)
        expectEqual(try s.pills(layerNote, "feature").pills.count, 1)
        expectEqual(s.editor.document[s.note]?[FieldValuesProperty.self], FieldValues(["purpose": "sign in with no password"]), "no copy is stored")
        expectEqual(s.editor.issues(arrow).map(\.message), [], "no issues")
        // Step 8: one Undo takes the arrow and both pills; the type and its ends stay.
        s.editor.undo()
        expectEqual(try s.row(s.note, "layer").content, .empty("add layer"))
        expectEqual(try s.row(layerNote, "feature").content, .empty("add feature"))
        expectEqual(s.editor.undoHistory.undoName, steps)
        // And the gesture's own step takes the type and both bonds back with it.
        s.editor.undo()
        expect(s.editor.document[dragged] != nil && s.editor.document[made] == nil, "the drag's own arrow is back, the type and both bonds are gone")
        s.editor.undo()
        expectEqual(s.editor.document, begun)
    },
    test("a note is named by its keys, not by the order its type lists its rows in") {
        let s = try RelationScene(more: drawing())
        let wide = s.editor.addSlipType(#"{"type": "object", "properties": {"zeta": {"type": "string"}, "alpha": {"type": "string"}}}"#, title: "Wide", at: CGPoint(x: 800, y: 40))
        s.editor.addBond(s.feature, s.rel)
        s.editor.addBond(s.rel, wide)
        s.addValued(["zeta": "last", "alpha": "first"], of: wide, at: CGPoint(x: 800, y: 1500))
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try require(s.index.rows(for: [s.feature], isType: false).first))
        expectEqual(s.lines(picker).map(\.title), ["first · last"], "alpha before zeta, though the type lists zeta first")
    },
])
