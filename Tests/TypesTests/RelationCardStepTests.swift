import AppKit
import Adornments
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Types

// the row card's one step under each way of closing, a far arrow's Redo, the chip's tone through
// changes with no commit to the arrow, two sessions of one card.

@MainActor
private func cardSession(closing: String, _ close: (RowCardRig) -> Void) throws {
    let r = try RowCardRig()
    defer { r.close() }
    let zed = r.s.addLayerNote("Zed"), alpha = r.s.addLayerNote("Alpha"), third = r.s.addLayerNote("Third")
    let a1 = r.s.relate(r.s.note, alpha), a2 = r.s.relate(r.s.note, zed)
    let start = r.editor.document
    let startBytes = try r.s.bytes()
    expect(try r.open(), closing)
    let form = try require(r.form, closing)
    form.focus(r.stop(0, 1))
    r.window.type("eng")
    form.focus(r.stop(1, 2))
    r.window.type("2021")
    form.focus(r.stop(2, 0))
    r.window.type("Thi")
    r.window.pressReturn()
    _ = third
    let made = r.arrows.first { ![a1, a2].contains($0) }
    expect(made != nil, "\(closing): the pick drew an arrow")
    // Typing in the new line's first cell right after the pick.
    if let made, let line = form.sheet.lines.indices.first(where: { form.sheet.lines[$0].owner == made }) {
        form.focus(r.stop(line, 1))
        r.window.type("new")
        expectEqual(r.values(made).value(at: FieldPath(field: "role")), "new", "\(closing): the new line's cell")
    }
    close(r)
    expect(r.cards.openTarget == nil, "\(closing): the card is closed")
    expectEqual(r.editor.undoHistory.undoName, "Change In", closing)
    let after = r.editor.document
    let afterBytes = try r.s.bytes()
    r.editor.undo()
    expectEqual(r.editor.document, start, "\(closing): one Undo")
    expect(try r.s.bytes() == startBytes, "\(closing): one Undo, bytes")
    r.editor.redo()
    expectEqual(r.editor.document, after, "\(closing): Redo")
    expect(try r.s.bytes() == afterBytes, "\(closing): Redo, bytes")
}

@MainActor let relationCardStepTests = Suite("A row's card, as steps", [
    test("row card closed by Escape is one step") {
        try cardSession(closing: "esc") { r in
            for _ in 0..<3 where r.cards.openTarget != nil { r.window.pressEscape() }
        }
    },
    test("row card closed by Tab off the last stop is one step") {
        try cardSession(closing: "tab") { r in
            guard let form = r.form else { return }
            let last = form.sheet.stops.last!
            form.focus(last)
            r.window.press("\t", code: 48)
        }
    },
    test("row card closed by a press elsewhere is one step") {
        try cardSession(closing: "press") { r in
            r.editor.closeCard(.pressedElsewhere)
        }
    },
    test("two sessions of one card are two steps") {
        let r = try RowCardRig()
        defer { r.close() }
        let a1 = r.s.relate(r.s.note, r.s.layerNote)
        expect(try r.open())
        r.form?.focus(r.stop(0, 1))
        r.window.type("one")
        r.cards.close()
        expect(try r.open())
        r.form?.focus(r.stop(0, 2))
        r.window.type("two")
        r.cards.close()
        expectEqual(r.values(a1).value(at: FieldPath(field: "role")), "one")
        r.editor.undo()
        expectEqual(r.values(a1).value(at: FieldPath(field: "since")), nil, "second session undone alone")
        expectEqual(r.values(a1).value(at: FieldPath(field: "role")), "one", "first session kept")
    },
    test("a far arrow's values: redo restores both boards") {
        let r = try RowCardRig()
        defer { r.close() }
        let s = r.s
        s.setOpen(s.note)
        let pill = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(x: 40, y: 400, width: 100, height: 32), stands: [s.note], says: "Sign in")))
        var far = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: pill.id, to: s.awayLayer)))
        far[IsAProperty.self] = [TypeLink(s.rel)]
        let farArrow = far
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(pill); $0.insert(farArrow) }
        let near = s.relate(s.note, s.layerNote)
        let start = try s.bytes()
        expect(try r.open())
        let form = try require(r.form)
        let farLine = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == far.id })
        form.focus(r.stop(farLine, 1))
        r.window.type("remote")
        let nearLine = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == near })
        form.focus(r.stop(nearLine, 1))
        r.window.type("local")
        // Remove the far line.
        form.focus(r.stop(farLine, 0))
        r.window.press("\u{7f}", code: 51)
        r.cards.close()
        let after = try s.bytes()
        expectEqual(s.editor.undoHistory.undoName, "Change In")
        s.editor.undo()
        expect(try s.bytes() == start, "undo")
        s.editor.redo()
        expect(try s.bytes() == after, "redo")
        s.editor.undo()
        expect(try s.bytes() == start, "undo again")
    },
    test("a read-only note's card writes nothing: type, Return, Backspace") {
        let log = RefusalLog()
        let r = try RowCardRig(more: [FreezingPlugin(log: log)])
        defer { r.close() }
        let a1 = r.s.relate(r.s.note, r.s.layerNote)
        r.editor.freeze([r.s.note])
        let before = r.editor.document
        let bytes = try r.s.bytes()
        expect(try r.open())
        let form = try require(r.form)
        for stop in form.sheet.stops {
            form.focus(stop)
            r.window.type("zz")
            r.window.press("\u{7f}", code: 51)
        }
        expectEqual(r.editor.document, before)
        expect(try r.s.bytes() == bytes)
        expect(r.arrows.contains(a1))
    },
])

@MainActor let chipToneThroughTests = Suite("The chip's tone through changes", [
    test("chip red/plain through an unmarked relationship type, a deleted end arrow, and their undo") {
        let s = try RelationScene()
        let from = s.fromEnd()
        s.toEnd()
        let other = s.editor.addSlip("Another", of: [s.feature], at: CGPoint(x: 40, y: 900))
        let misfit = s.relate(s.note, other)
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { $0.label.isWrong }, "misfit at start")
        // delete the "from" end arrow? from side = Feature; the "to" end Layer remains -> Another (Feature) misfit remains.
        // Delete the to end: the to side has no type -> fits anything.
        let toArrow = try require(s.editor.document.shapes.first { record in
            guard let bond = record.typed(as: Bond.self) else { return false }
            return bond.props.from == s.rel
        }?.id)
        s.editor.transact("Delete") { $0.delete([toArrow]) }
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { !$0.label.isWrong }, "the to end deleted: the side is open, it fits")
        s.editor.undo()
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { $0.label.isWrong }, "and the undo")
        _ = from
        // Unmark the relationship type.
        s.editor.transact("Unmark") { $0.update(s.rel) { $0[RelationshipProperty.self] = nil } }
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { !$0.label.isWrong }, "unmarked: plain")
        s.editor.undo()
        expect(arrowChips(of: misfit, in: s.editor).allSatisfy { $0.label.isWrong }, "marked again: red")
    },
    test("chip follows a far note's type change on another board") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        // arrow from a root note to the pocket's Down (a Layer) by a pill, then retype Down.
        s.setOpen(s.awayLayer)
        let pill = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(x: 800, y: 400, width: 100, height: 32), stands: [s.awayLayer], says: "Down")))
        s.editor.transact("Draw") { $0.insert(pill) }
        let arrow = s.relate(s.note, pill.id)
        expect(arrowChips(of: arrow, in: s.editor).allSatisfy { !$0.label.isWrong }, "a Layer through the pill fits")
        s.editor.transact(on: s.pocketBoard, "Retype") { $0.update(inFile: s.awayLayer) { $0[IsAProperty.self] = [] } }
        expect(arrowChips(of: arrow, in: s.editor).allSatisfy { $0.label.isWrong }, "the far note lost its type")
        s.editor.undo()
        expect(arrowChips(of: arrow, in: s.editor).allSatisfy { !$0.label.isWrong }, "undone")
    },
])
