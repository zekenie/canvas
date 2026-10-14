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

// The card a relation row holding a relationship opens: a line for each relationship in the row (the note at the other end,
// then the relationship type's fields, each cell the arrow's), a blank line that picks a note and draws the arrow, a line
// taken out with Backspace. Everything done in it while it stays open is one step named for the row (`Change Layer`): cells
// on several arrows, a pick, a removal. A far arrow's values are edited there too. Over bonds, in `RelationScene.drawn()`'s
// editor, with a canvas in an unshown window so the host's part (the place, the keyboard) is the real one.

/// A Feature note related to Layer notes by arrows of `in`, a relationship type that holds a role and a date, with a card's window.
@MainActor
final class RowCardRig {
    let s: RelationScene
    let window: NSWindow
    let canvas: CanvasView
    var editor: CanvasEditor { s.editor }
    var cards: FieldCards { editor.fieldCards! }
    var form: FieldFormView? { cards.openForm }
    var row: RelationshipRow { (try? s.featureRow()) ?? { fatalError("no row") }() }

    init(fields: String? = roleSchema, more: [any CanvasPlugin] = []) throws {
        let scene = try RelationScene.drawn(more: more)
        let rel = scene.rel
        if let fields { scene.editor.transact { $0.update(rel) { $0[TypeSchemaProperty.self] = SchemaText(fields) } } }
        s = scene
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: scene.editor)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
    }

    func close() { window.close() }

    /// Opens the card of the Feature note's row, as the rows do (the same request, a rect near the note's row).
    @discardableResult
    func open(of note: ShapeID? = nil, readOnly: Bool = false) throws -> Bool {
        let note = note ?? s.note
        var request = FieldCardRequest(shape: note, target: .relations(row.key), mode: .values, isReadOnly: readOnly, rowRect: CGRect(x: 60, y: 700, width: 240, height: 22),
                                       closed: {}, tabbedOut: { _ in })
        request.makePicker = s.book.makePicker
        return cards.open(request)
    }

    /// The arrows of `in` between the Feature note and others.
    var arrows: [ShapeID] { s.relationships().map(\.id) }

    func values(_ arrow: ShapeID) -> FieldValues { editor.fieldWriter?.values(of: arrow) ?? FieldValues() }
    func advance() { s.harness.scheduler.advance(by: .zero) }
    func stop(_ line: Int, _ column: Int = 0) -> FieldStop { FieldStop(line: line, column: column) }
}

@MainActor let relationCardTests = Suite("The card of a relation row", [
    test("a line for each relationship under the relationship type's chip: the note at the other end, then a cell a field of the type, every cell the arrow's; a blank line last that picks, its other cells waiting") {
        let r = try RowCardRig()
        defer { r.close() }
        let zed = r.s.addLayerNote("Zed"), alpha = r.s.addLayerNote("Alpha")
        let first = r.s.relate(r.s.note, zed), second = r.s.relate(r.s.note, alpha)
        r.editor.fieldWriter?.set("engineer", at: FieldPath(field: "role"), of: second)
        expect(try r.open())
        let form = try require(r.form)
        let sheet = form.sheet
        expectEqual(sheet.chip, r.s.rel, "the relationship type's chip")
        expectEqual(sheet.back, nil)
        expectEqual(sheet.layout, .table(["Layer", "role", "since"]), "headed by the one type at the other end, then the type's fields")
        expectEqual(sheet.lines.count, 3, "two relationships and the blank line")
        // By the name each shows, as the row's pills are: Alpha, then Zed.
        expectEqual(sheet.lines.compactMap(\.owner), [second, first])
        expectEqual(sheet.lines.prefix(2).map { $0.cells[0].control }, [.note(alpha), .note(zed)])
        expectEqual(sheet.lines.prefix(2).map { $0.cells[0].shown }, ["Alpha", "Zed"])
        expect(sheet.lines.prefix(2).allSatisfy { $0.cells.allSatisfy { $0.owner == $0.owner && $0.owner != nil } }, "every cell has an arrow")
        expectEqual(sheet.lines[0].cells.map(\.owner), Array(repeating: second, count: 3))
        expectEqual(sheet.lines[0].cells[1].shown, "engineer")
        expectEqual(sheet.lines[0].cells[2].placeholder, "add since")
        expect(sheet.lines[0].cells[1].isEditable && sheet.lines[0].cells[2].isEditable)
        expect(!sheet.lines[0].cells[0].isEditable, "a stored line's note is not re-pointed: remove and add")
        let blank = sheet.lines[2]
        expectEqual(blank.cells[0].control, .note(nil))
        expect(blank.cells[0].isEditable, "the blank line picks")
        expectEqual(blank.cells[0].placeholder, "add")
        expect(blank.cells.dropFirst().allSatisfy { !$0.isEditable }, "and the rest wait for the pick")
        expectEqual(blank.owner, nil)
        // Where the keyboard stops: each pill, each editable cell, the blank line's note.
        expectEqual(sheet.stops, [FieldStop(line: 0, column: 0), FieldStop(line: 0, column: 1), FieldStop(line: 0, column: 2),
                                  FieldStop(line: 1, column: 0), FieldStop(line: 1, column: 1), FieldStop(line: 1, column: 2), FieldStop(line: 2, column: 0)])
        // Nothing is stored on either note.
        expectEqual(r.editor.document[r.s.note]?[FieldValuesProperty.self], nil)
    },
    test("a cell writes its own arrow; values on two arrows, a pick on the blank line and a line removed are one step named for the row, and one Undo takes the whole session back") {
        let r = try RowCardRig()
        defer { r.close() }
        let zed = r.s.addLayerNote("Zed"), alpha = r.s.addLayerNote("Alpha"), third = r.s.addLayerNote("Third")
        let a1 = r.s.relate(r.s.note, alpha), a2 = r.s.relate(r.s.note, zed)
        let start = r.editor.document
        expect(try r.open())
        let form = try require(r.form)
        let undo = r.editor.undoHistory.undoName
        // A cell on the first arrow, a cell on the second.
        form.focus(r.stop(0, 1))
        r.window.type("eng")
        r.window.type("ineer")
        expectEqual(r.values(a1).value(at: FieldPath(field: "role")), "engineer", "the first line is Alpha's arrow")
        expectEqual(r.values(a2).value(at: FieldPath(field: "role")), nil)
        form.focus(r.stop(1, 2))
        r.window.type("2021")
        expectEqual(r.values(a2).value(at: FieldPath(field: "since")), "2021", "the second line is Zed's")
        // A pick on the blank line: the arrow is drawn from the note to the Third.
        let blank = r.stop(2, 0)
        form.focus(blank)
        r.window.type("Thi")
        r.window.pressReturn()
        let made = try require(r.arrows.first { ![a1, a2].contains($0) }, "the arrow the pick drew")
        expectEqual(r.s.bonds().first { $0.id == made }?.props.to, third)
        expectEqual(form.sheet.lines.compactMap(\.owner).count, 3, "a line for it")
        expect(form.sheet.lines.compactMap(\.owner).contains(made))
        // A line removed: Zed's pill, then Backspace.
        let zedLine = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == a2 })
        form.focus(r.stop(zedLine, 0))
        r.window.press("\u{7f}", code: 51)
        expectEqual(r.arrows.contains(a2), false, "the arrow and its values are gone")
        expectEqual(form.sheet.lines.compactMap(\.owner).count, 2)
        // One step, named for the row.
        expectEqual(r.editor.undoHistory.undoName, "Change Layer")
        expect(r.editor.undoHistory.undoName != undo)
        r.cards.close()
        r.editor.undo()
        expectEqual(r.editor.document, start, "one Undo: every cell, the pick and the removal")
        r.editor.redo()
        expectEqual(r.arrows.contains(made), true)
        expectEqual(r.arrows.contains(a2), false)
    },
    test("a commit from elsewhere splits the card's step: what is typed after it is a step of its own") {
        let r = try RowCardRig()
        defer { r.close() }
        let a1 = r.s.relate(r.s.note, r.s.layerNote)
        expect(try r.open())
        let form = try require(r.form)
        form.focus(r.stop(0, 1))
        r.window.type("a")
        r.editor.transact("Elsewhere") { $0.update(r.s.layerNote) { _ in } }
        r.editor.transact("Elsewhere") { $0.update(r.s.layerNote, as: RowSlip.self) { $0.props.text = MentionText(plain: "Renamed") } }
        r.window.type("b")
        expectEqual(r.values(a1).value(at: FieldPath(field: "role")), "ab")
        r.editor.undo()
        expectEqual(r.values(a1).value(at: FieldPath(field: "role")), "a", "the second step alone")
    },
    test("the card follows the file: an arrow of the row drawn or taken away from elsewhere, a value written to a line's arrow, a note renamed") {
        let r = try RowCardRig()
        defer { r.close() }
        let a1 = r.s.relate(r.s.note, r.s.layerNote)
        expect(try r.open())
        let form = try require(r.form)
        expectEqual(form.sheet.lines.count, 2)
        let zed = r.s.addLayerNote("Zed")
        let a2 = r.s.relate(r.s.note, zed)
        expectEqual(form.sheet.lines.compactMap(\.owner).count, 2, "a relationship drawn by hand is a line at once")
        r.editor.fieldWriter?.set("lead", at: FieldPath(field: "role"), of: a2)
        let zedLine = try require(form.sheet.lines.first { $0.owner == a2 })
        expectEqual(zedLine.cells[1].shown, "lead", "a value written elsewhere shows")
        r.editor.transact("Rename") { $0.update(zed, as: RowSlip.self) { $0.props.text = MentionText(plain: "Zebra") } }
        r.advance()
        expectEqual(form.sheet.lines.first { $0.owner == a2 }?.cells[0].shown, "Zebra", "a note renamed")
        r.editor.transact("Delete") { $0.delete([a1]) }
        expectEqual(form.sheet.lines.compactMap(\.owner), [a2], "an arrow taken away is a line less")
        r.editor.transact("Delete") { $0.delete([a2]) }
        expectEqual(form.sheet.lines.compactMap(\.owner), [])
        expectEqual(form.sheet.lines.count, 1, "the blank line stays")
    },
    test("a far arrow's values are edited in the card's step: an arrow on another board, at a pill that stands for the note") {
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
        expect(form.sheet.lines.compactMap(\.owner).contains(far.id), "the relationship drawn on another board is a line")
        expectEqual(s.editor.board, .root)
        let farLine = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == far.id })
        form.focus(r.stop(farLine, 1))
        r.window.type("remote")
        expectEqual(r.values(far.id).value(at: FieldPath(field: "role")), "remote", "written on the pocket's board")
        expect(s.editor.document[far.id] == nil, "and the board shown is still the root")
        let nearLine = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == near })
        form.focus(r.stop(nearLine, 1))
        r.window.type("local")
        expectEqual(r.values(near).value(at: FieldPath(field: "role")), "local")
        r.cards.close()
        s.editor.undo()
        expect(try s.bytes() == start, "one Undo returns both boards")
        expectEqual(r.values(far.id).value(at: FieldPath(field: "role")), nil)
    },
    test("a locked arrow's line is read-only and its Backspace is refused, the card stays; a locked note's card opens to be read, with no blank line") {
        let log = RefusalLog()
        let r = try RowCardRig(more: [FreezingPlugin(log: log)])
        defer { r.close() }
        let a1 = r.s.relate(r.s.note, r.s.layerNote), a2 = r.s.relate(r.s.note, r.s.addLayerNote("Zed"))
        r.editor.freeze([a1])
        expect(try r.open())
        let form = try require(r.form)
        let locked = try require(form.sheet.lines.first { $0.owner == a1 }), free = try require(form.sheet.lines.first { $0.owner == a2 })
        expect(locked.cells.dropFirst().allSatisfy { !$0.isEditable }, "the locked arrow's cells are read")
        expect(free.cells.dropFirst().allSatisfy { $0.isEditable })
        let lockedLine = try require(form.sheet.lines.indices.first { form.sheet.lines[$0].owner == a1 })
        form.focus(r.stop(lockedLine, 0))
        let before = r.editor.document
        r.window.press("\u{7f}", code: 51)
        expectEqual(r.editor.document, before, "nothing goes")
        expect(log.refusals.contains { $0.contains(r.s.note) }, "the note that asked shakes")
        r.cards.close()
        r.editor.freeze([a1], false)
        r.editor.freeze([r.s.note])
        expect(try r.open())
        let reading = try require(r.form)
        expect(reading.isReadOnly, "read-only")
        expectEqual(reading.sheet.lines.count, 2, "no blank line")
        expect(reading.sheet.lines.allSatisfy { $0.cells.allSatisfy { !$0.isEditable } })
    },
    test("Return on a line's note goes to it; Esc closes the card; a relationship type with no fields has a column of notes and the blank line") {
        let r = try RowCardRig(fields: nil)
        defer { r.close() }
        r.s.relate(r.s.note, r.s.layerNote)
        expect(try r.open())
        let form = try require(r.form)
        expectEqual(form.sheet.layout, .table(["Layer"]))
        expectEqual(form.sheet.lines.count, 2)
        expectEqual(form.sheet.stops, [FieldStop(line: 0, column: 0), FieldStop(line: 1, column: 0)])
        form.focus(r.stop(0, 0))
        r.window.pressReturn()
        r.advance()
        expectEqual(r.editor.selection, r.s.layerNote, "Return on a pill goes to the note")
        expect(try r.open(), "and the card opens again")
        r.window.pressEscape()
        expect(r.cards.openTarget == nil && r.editor.card == nil, "Esc closes it")
    },
    test("a row that is gone closes its card: its relationship type unmarked, the note retyped") {
        let r = try RowCardRig()
        defer { r.close() }
        r.s.relate(r.s.note, r.s.layerNote)
        expect(try r.open())
        r.editor.removeTypeLink(r.s.feature, from: r.s.note)
        r.advance()
        expect(r.cards.openTarget == nil, "the note is not a Feature any more: no row")
    },
])
