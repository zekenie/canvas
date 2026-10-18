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
import Titles
import Types

// The pill that leads the label of an arrow of a relationship type, through changes with no commit to the arrow. It says the
// type's name and the first value the arrow holds, in the order of the fields of its types (`owner · 2021`), and no number of
// fields: that belongs to the type-level pill. The rest of the values are in the card, which a click on the pill opens.

private let threeFields = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}, "hours": {"type": "number"}}}"#

@MainActor private func chip(_ text: String, of arrow: ShapeID, in editor: CanvasEditor) -> AdornmentFrame? {
    arrowChips(of: arrow, in: editor).first { $0.label.text == text }
}

/// The pill on an arrow, as the editor lays it out.
@MainActor private func pill(of arrow: ShapeID, in editor: CanvasEditor) -> AdornmentFrame? {
    editor.adornmentFrames(of: arrow).first { $0.adornment == .of(RelationshipPill.self) }
}

@MainActor let chipCountTests = Suite("The pill between notes, and the pills, through changes", [
    test("the pill says the name alone with nothing filled in, then the first filled value in the order of the fields, and nothing else of them") {
        let r = try ArrowCardRig()
        defer { r.close() }
        let empty = try require(pill(of: r.arrow, in: r.editor))
        expectEqual(empty.label.text, "in")
        expectEqual(empty.label.note, nil, "nothing filled: the name alone")
        expectEqual(empty.label.count, nil, "no field count on a pill between notes")
        r.editor.fieldWriter?.set("2021", at: FieldPath(field: "since"), of: r.arrow)
        expectEqual(pill(of: r.arrow, in: r.editor)?.label.note, "2021", "the only value filled")
        r.editor.fieldWriter?.set("engineer", at: FieldPath(field: "role"), of: r.arrow)
        expectEqual(pill(of: r.arrow, in: r.editor)?.label.note, "engineer", "the first field in the chain's order wins, whatever order they were filled in")
        let frames = r.editor.adornmentFrames(of: r.arrow)
        expect(frames.allSatisfy { $0.adornment == .of(RelationshipPill.self) }, "the pill alone: the other values are in the card, \(frames.map(\.adornment))")
        expect(frames.allSatisfy { $0.label.count == nil })
    },
    test("the pill follows the type with no commit to the arrow: a rename, a field taken away or added before the first filled one, and undo") {
        let r = try ArrowCardRig()
        defer { r.close() }
        r.editor.fieldWriter?.set("engineer", at: FieldPath(field: "role"), of: r.arrow)
        r.editor.fieldWriter?.set("2021", at: FieldPath(field: "since"), of: r.arrow)
        let arrow = r.editor.document[r.arrow]
        @MainActor func lead() -> CGRect? { r.editor.shapeContext.geometry(of: r.arrow)?.labelLead }
        let before = try require(lead())
        // The type is renamed: the name is longer, the room kept for it wider, the arrow not written.
        r.editor.transact("Name") { $0.update(r.s.rel) { $0[TitleProperty.self] = "inside of" } }
        expectEqual(pill(of: r.arrow, in: r.editor)?.label.text, "inside of")
        expect(try require(lead()).width > before.width, "the room follows the name: \(before) then \(String(describing: lead()))")
        expectEqual(r.editor.document[r.arrow], arrow, "nothing was written to the arrow")
        // The first field goes: the first filled value is the next one's.
        r.editor.transact("Schema") { $0.update(r.s.rel) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"since": {"type": "string"}}}"#) } }
        expectEqual(pill(of: r.arrow, in: r.editor)?.label.note, "2021")
        // A field before the first filled one holds nothing: the value is the same; one with a value changes it.
        r.editor.transact("Schema") { $0.update(r.s.rel) { $0[TypeSchemaProperty.self] = SchemaText(threeFields) } }
        expectEqual(pill(of: r.arrow, in: r.editor)?.label.note, "engineer", "role, the first of the three, is filled")
        r.editor.undo()
        expectEqual(pill(of: r.arrow, in: r.editor)?.label.note, "2021", "back by the undo")
        let wide = try require(lead())
        r.editor.undo()
        r.editor.undo()
        expectEqual(pill(of: r.arrow, in: r.editor)?.label.text, "in")
        expect(try require(lead()).width < wide.width, "and the room is as narrow as the name was")
    },
    test("a misfit's pill is red and keeps its value; a plain type's chip beside it and a note's chip have no note") {
        let s = try RelationScene()
        s.editor.transact { $0.update(s.rel) { $0[TypeSchemaProperty.self] = SchemaText(roleSchema) } }
        s.fromEnd()
        s.toEnd()
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let misfit = s.relate(s.note, other)
        s.editor.fieldWriter?.set("engineer", at: FieldPath(field: "role"), of: misfit)
        let red = try require(chip("in", of: misfit, in: s.editor))
        expect(red.label.isWrong, "a misfit")
        expectEqual(red.label.note, "engineer")
        expectEqual(red.label.count, nil)
        let plain = s.editor.addSlipType(roleSchema, title: "Plain", at: CGPoint(x: 40, y: 1300))
        s.editor.addTypeLink(plain, to: misfit)
        expectEqual(chip("Plain", of: misfit, in: s.editor)?.label.note, nil, "a plain type on an arrow holds nothing of the relationship")
        expectEqual(chip("Plain", of: misfit, in: s.editor)?.adornment, .of(TypeChips.self), "above the label, as a chip is")
        let note = try require(arrowChips(of: s.note, in: s.editor).first, "the note's chip")
        expectEqual(note.label.count, nil, "a note's fields are its rows")
        // A relationship type a script put on a note: a plain chip there, never red and never a pill.
        s.editor.addTypeLink(s.rel, to: s.note)
        let marked = try require(chip("in", of: s.note, in: s.editor), "the relationship type's chip on the note")
        expectEqual(marked.adornment, .of(TypeChips.self))
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
        expect(try s.pills(s.note, "in").pills.allSatisfy { !$0.isWrong }, "both are Layers")
        s.editor.removeTypeLink(s.layer, from: other)
        let pills = try s.pills(s.note, "in").pills
        expect(pills.contains { $0.isWrong }, "other lost Layer: red. pills=\(pills.map { ($0.label, $0.isWrong) })")
        s.editor.undo()
        expect(try s.pills(s.note, "in").pills.allSatisfy { !$0.isWrong }, "healed by the undo")
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
