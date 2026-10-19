import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Types

// drilling into a group field and a list field of a relationship, from a row's card: what is typed is the
// arrow's, never the note's, and the session is one step.

private let drillSchema = #"{"type": "object", "properties": {"role": {"type": "string"}, "address": {"type": "object", "properties": {"city": {"type": "string"}, "zip": {"type": "string"}}}, "tags": {"type": "array", "items": {"type": "string"}}}}"#

@MainActor let relationCardDrillTests = Suite("Drilling into a field of a relationship from a row's card", [
    test("a group field and a list field of a relationship, from the row's card: written to the arrow, one step, one Undo") {
        let r = try RowCardRig(fields: drillSchema)
        defer { r.close() }
        let zed = r.s.addLayerNote("Zed"), alpha = r.s.addLayerNote("Alpha")
        let a1 = r.s.relate(r.s.note, alpha), a2 = r.s.relate(r.s.note, zed)
        let start = r.editor.document
        let startBytes = try r.s.bytes()
        expect(try r.open())
        let form = try require(r.form)
        // The second line (Zed's arrow, a2): its address cell opens a level.
        let line = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == a2 })
        let columns = form.sheet.lines[line].cells.map { $0.field.field.name }
        let address = try require(columns.firstIndex(of: "address"))
        form.focus(r.stop(line, address))
        r.window.pressReturn()
        expect(form.depth == 1, "a level for the address: depth \(form.depth) stops \(form.sheet.stops)")
        if form.depth == 1 {
            form.focus(form.sheet.stops[0])
            r.window.type("Paris")
            expectEqual(r.values(a2).value(at: FieldPath(field: "address").key("city")), "Paris", "written to the arrow of the line, not another")
            expectEqual(r.values(a1).value(at: FieldPath(field: "address").key("city")), nil)
            expectEqual(r.editor.document[r.s.note]?[FieldValuesProperty.self], nil, "nothing on the note")
            form.goBack()
        }
        // The tags of the first line.
        let line0 = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == a1 })
        let tags = try require(form.sheet.lines[line0].cells.map { $0.field.field.name }.firstIndex(of: "tags"))
        form.focus(r.stop(line0, tags))
        r.window.pressReturn()
        if form.depth == 1 {
            form.focus(form.sheet.stops[0])
            r.window.type("one")
            expect(r.values(a1).value(at: FieldPath(field: "tags")) != nil, "a list item written to the arrow: \(r.values(a1))")
            expectEqual(r.editor.document[r.s.note]?[FieldValuesProperty.self], nil, "nothing on the note")
            form.goBack()
        } else {
            expect(false, "the tags level did not open: depth \(form.depth)")
        }
        r.cards.close()
        expectEqual(r.editor.undoHistory.undoName, "Change In")
        r.editor.undo()
        expectEqual(r.editor.document, start, "one Undo")
        expect(try r.s.bytes() == startBytes)
    },
])
