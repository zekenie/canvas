import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Types

// The number on a relationship's chip, and the pill's tone through changes with no commit to the arrow. A relationship's
// values are shown nowhere on the board: its chip says how many fields its type gives the arrow, and opens the card.

private let threeFields = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}, "hours": {"type": "number"}}}"#

@MainActor private func chip(_ text: String, of arrow: ShapeID, in editor: CanvasEditor) -> AdornmentFrame? {
    arrowChips(of: arrow, in: editor).first { $0.label.text == text }
}

@MainActor let chipCountTests = Suite("The number on a relationship's chip, and the pills, through changes", [
    test("a relationship's chip says how many fields its type gives the arrow, whatever is filled in, and nothing else is shown of them") {
        let r = try ArrowCardRig()
        defer { r.close() }
        expectEqual(chip("in", of: r.arrow, in: r.editor)?.label.count, 2)
        r.editor.fieldWriter?.set("engineer", at: FieldPath(field: "role"), of: r.arrow)
        expectEqual(chip("in", of: r.arrow, in: r.editor)?.label.count, 2, "a value filled in changes no number")
        let frames = r.editor.adornmentFrames(of: r.arrow)
        expect(frames.allSatisfy { $0.adornment == .of(TypeChips.self) }, "the chip alone: no values on the board, \(frames.map(\.adornment))")
        expect(!frames.contains { ($0.label.text ?? "").contains("engineer") }, "the value is in the card, not on the arrow")
    },
    test("the number follows the type with no commit to the arrow: a field added, every field taken away, and undo") {
        let r = try ArrowCardRig()
        defer { r.close() }
        r.editor.transact("Schema") { $0.update(r.s.rel) { $0[TypeSchemaProperty.self] = SchemaText(threeFields) } }
        expectEqual(chip("in", of: r.arrow, in: r.editor)?.label.count, 3)
        r.editor.transact("Schema") { $0.update(r.s.rel) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object"}"#) } }
        expectEqual(chip("in", of: r.arrow, in: r.editor)?.label.count, nil, "no fields: no number")
        r.editor.undo()
        expectEqual(chip("in", of: r.arrow, in: r.editor)?.label.count, 3, "back by the undo")
    },
    test("a misfit's chip is red and keeps its number; a plain type's chip beside it and a note's chip have none") {
        let s = try RelationScene()
        s.editor.transact { $0.update(s.rel) { $0[TypeSchemaProperty.self] = SchemaText(roleSchema) } }
        s.fromEnd()
        s.toEnd()
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let misfit = s.relate(s.note, other)
        let red = try require(chip("in", of: misfit, in: s.editor))
        expect(red.label.isWrong, "a misfit")
        expectEqual(red.label.count, 2)
        let plain = s.editor.addSlipType(roleSchema, title: "Plain", at: CGPoint(x: 40, y: 1300))
        s.editor.addTypeLink(plain, to: misfit)
        expectEqual(chip("Plain", of: misfit, in: s.editor)?.label.count, nil, "a plain type on an arrow holds nothing of the relationship")
        let note = try require(arrowChips(of: s.note, in: s.editor).first, "the note's chip")
        expectEqual(note.label.count, nil, "a note's fields are its rows")
        // A relationship type a script put on a note: a plain chip there, no number, never red.
        s.editor.addTypeLink(s.rel, to: s.note)
        let marked = try require(chip("in", of: s.note, in: s.editor), "the relationship type's chip on the note")
        expectEqual(marked.label.count, nil)
        expect(!marked.label.isWrong)
    },
    test("the pill in the row turns with a verdict the far note's type moved, with no commit to the arrow") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let fits = s.relate(s.note, s.layerNote)
        _ = fits
        // Give the Feature `other` a Layer type too, then take it away: its pill goes plain, then red.
        s.editor.addTypeLink(s.layer, to: other)
        let arrow = s.relate(s.note, other)
        _ = arrow
        expect(try s.pills(s.note, "layer").pills.allSatisfy { !$0.isWrong }, "both are Layers")
        s.editor.removeTypeLink(s.layer, from: other)
        let pills = try s.pills(s.note, "layer").pills
        expect(pills.contains { $0.isWrong }, "other lost Layer: red. pills=\(pills.map { ($0.label, $0.isWrong) })")
        s.editor.undo()
        expect(try s.pills(s.note, "layer").pills.allSatisfy { !$0.isWrong }, "healed by the undo")
    },
    test("a pill standing for a gone note: its line in the card has a keyboard stop to remove it") {
        let r = try RowCardRig()
        defer { r.close() }
        let zed = r.s.addLayerNote("Zed")
        r.s.setOpen(zed)
        let pill = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(x: 800, y: 400, width: 100, height: 32), stands: [zed], says: "Zed pill")))
        r.editor.transact("Draw") { $0.insert(pill) }
        let viaPill = r.s.relate(r.s.note, pill.id)
        r.editor.transact("Delete") { $0.delete([zed]) }
        expect(try r.open())
        let form = try require(r.form)
        let line = form.sheet.lines.indices.first { form.sheet.lines[$0].owner == viaPill }
        expect(line != nil, "a line for the arrow to the pill of a gone note: \(form.sheet.lines.map { $0.cells.map(\.shown) })")
        if let line {
            expect(form.sheet.stops.contains(FieldStop(line: line, column: 0)), "the line's pill is a stop, so Backspace can remove the line: \(form.sheet.stops)")
        }
    },
])
