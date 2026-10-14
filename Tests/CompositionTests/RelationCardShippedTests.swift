import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Connections
import Foundation
import Geometry
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Types

// A relationship's data is reachable from the arrow and from the note, through one writer, on the shipped list with real notes
// and real arrows (board 1's Feature and Layer, after the first minute: the type `in` between them, here holding a role and a
// date): the chip of the arrow says how many fields and opens its card; a value typed there shows in the card the Feature note's
// row opens (the `›` on its `layer` row), and nowhere on the board; a value typed in that card is the arrow's, and one Undo takes
// the whole session of the row's card back.

private let roleAndDate = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}}}"#

extension Minute {
    /// The number on an arrow's chip, nil for none.
    func chipNumber(of arrow: ShapeID) -> Int? {
        editor.adornmentFrames(of: arrow).first { $0.adornment == .of(TypeChips.self) }?.label.count
    }

    /// The center of the `›` of a note's row, where a person would press.
    func chevron(of note: ShapeID, _ name: String) throws -> CGPoint {
        let row = try require(rows.rows(of: note).first { $0.name == name }, "a row \(name) in \(names(of: note))")
        let rect = try require(rows.chevronRect(of: row), "the row \(name) holds no relationship")
        return CGPoint(x: rect.midX, y: row.rect.midY)
    }
}

@MainActor let relationCardShippedTests = Suite("A relationship's data, from the arrow and from the note, shipped", [
    test("the menu of an arrow that holds a relationship has Go to its relationship type in Is a, as its chip's click opens the card instead; an arrow that holds none has none") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let made = try m.nameTheType()
        editor.transact("Fields") { $0.update(made) { $0[TypeSchemaProperty.self] = SchemaText(roleAndDate) } }
        expect(try m.click(row: "layer", of: m.featureNote))
        m.window.pressReturn()
        editor.endEditing()
        let arrow = try require(m.arrows.first { $0.props.start.binding?.shapeID == m.featureNote }).id
        let anchor = try require(editor.adornmentAnchor(of: arrow))
        let spot = CGPoint(x: anchor.midX, y: anchor.midY)
        let menu = try require(m.h.secondaryClick(at: spot))
        expectEqual(editor.selectedShapeIDs, [arrow], "the menu is the arrow's")
        expect(menu.outline.contains { $0.hasPrefix("  Go to") }, "\(menu.outline)")
        editor.removeTypeLink(made, from: arrow)
        let bare = try require(m.h.secondaryClick(at: spot))
        expect(!bare.outline.contains { $0.contains("Go to") }, "\(bare.outline)")
    },
    test("the chip says how many fields and opens the arrow's card, and a value typed there shows in the card the note's row opens; a value typed in that card is the arrow's, and one Undo takes the whole card session back") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let made = try m.nameTheType()
        editor.transact("Fields") { $0.update(made) { $0[TypeSchemaProperty.self] = SchemaText(roleAndDate) } }
        // The relationship, drawn from the row (first minute, steps 6 and 7).
        expect(try m.click(row: "layer", of: m.featureNote))
        m.window.pressReturn()
        editor.endEditing()
        let arrow = try require(m.arrows.first { $0.props.start.binding?.shapeID == m.featureNote }).id
        expectEqual(m.chipNumber(of: arrow), 2, "the chip says the relationship's two fields")
        expect(editor.adornmentFrames(of: arrow).allSatisfy { $0.adornment == .of(TypeChips.self) }, "and nothing else of them is on the board")
        // The chip opens the arrow's card, with the arrow selected.
        let chip = try require(editor.adornmentFrames(of: arrow).first { $0.adornment == .of(TypeChips.self) })
        TypeChips.click(AdornmentClick(shape: arrow, tag: chip.tag, rect: chip.rect, isOverflow: false), in: editor)
        expectEqual(editor.fieldCards?.openTarget?.shape, arrow)
        expectEqual(editor.fieldCards?.openTarget?.target, .shape)
        expectEqual(editor.selectedShapeIDs, [arrow])
        m.window.type("engineer")
        expectEqual(editor.fieldWriter?.values(of: arrow).value(at: FieldPath(field: "role")), "engineer")
        expectEqual(editor.undoHistory.undoName, "Change Role")
        m.window.pressEscape()
        expect(editor.fieldCards?.openTarget == nil)
        editor.undoHistory.seal()
        expectEqual(m.chipNumber(of: arrow), 2, "a value typed changes no number")
        // The note's row ends in › and opens a card whose line holds it.
        editor.endEditing()
        let beforeSession = editor.document
        editor.selection = m.featureNote
        let began = editor.beginEditing(m.featureNote, at: try m.chevron(of: m.featureNote, "layer"))
        expect(began)
        m.h.scheduler.advance(by: .zero)
        let open = try require(editor.fieldCards?.openTarget, "the card of the row")
        expectEqual(open.shape, m.featureNote)
        guard case .relations(let key) = open.target else { throw Failure("a row's card") }
        expectEqual(key.type, made)
        let form = try require(editor.fieldCards?.openForm)
        expectEqual(form.sheet.lines.compactMap(\.owner), [arrow], "the line of the relationship")
        expectEqual(form.sheet.lines[0].cells.map(\.shown).dropFirst(), ["engineer", ""], "the value typed on the arrow, in the row's card")
        // A value typed there is the arrow's.
        form.focus(FieldStop(line: 0, column: 1))
        m.window.type("lead")
        form.focus(FieldStop(line: 0, column: 2))
        m.window.type("2021")
        expectEqual(editor.fieldWriter?.values(of: arrow).value(at: FieldPath(field: "role")), "lead")
        expectEqual(editor.fieldWriter?.values(of: arrow).value(at: FieldPath(field: "since")), "2021")
        expectEqual(editor.undoHistory.undoName, "Change Layer", "named for the row")
        expectEqual(editor.document[m.featureNote]?[FieldValuesProperty.self], beforeSession[m.featureNote]?[FieldValuesProperty.self], "nothing is stored on the note")
        editor.fieldCards?.close()
        editor.endEditing()
        editor.undo()
        expectEqual(editor.fieldWriter?.values(of: arrow).value(at: FieldPath(field: "role")), "engineer", "one Undo: the whole session of the row's card")
        expectEqual(editor.fieldWriter?.values(of: arrow).value(at: FieldPath(field: "since")), nil)
        expectEqual(editor.document[arrow], beforeSession[arrow])
    },
])

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
