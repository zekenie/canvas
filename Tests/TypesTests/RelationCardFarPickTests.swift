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

// a pick of a far note on the blank line of a row's card, then a value on the new line, then one Undo.

@MainActor let relationCardFarPickTests = Suite("A far pick on a row's card", [
    test("a far pick on the card's blank line, a value on its line and a near line: one Undo returns both boards byte for byte, Redo restores") {
        let r = try RowCardRig()
        defer { r.close() }
        let s = r.s
        let near = s.relate(s.note, s.layerNote)
        let start = try s.bytes()
        expect(try r.open())
        let form = try require(r.form)
        form.focus(r.stop(1, 0))
        r.window.type("Down")
        r.window.pressReturn()
        let made = r.arrows.first { $0 != near }
        expect(made != nil, "the far pick drew an arrow: \(r.arrows.count)")
        if let made, let line = form.sheet.lines.indices.first(where: { form.sheet.lines[$0].owner == made }) {
            form.focus(r.stop(line, 1))
            r.window.type("far")
            expectEqual(r.values(made).value(at: FieldPath(field: "role")), "far")
        }
        let nearLine = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == near })
        form.focus(r.stop(nearLine, 1))
        r.window.type("near")
        r.cards.close()
        let after = try s.bytes()
        expectEqual(s.editor.undoHistory.undoName, "Change In")
        s.editor.undo()
        expect(try s.bytes() == start, "one Undo returns both boards")
        s.editor.redo()
        expect(try s.bytes() == after, "Redo restores")
    },
])
