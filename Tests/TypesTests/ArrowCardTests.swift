import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Foundation
import Geometry
import Selection
import TestKit
import Types

// The card of an arrow's relationship: the chip of a relationship type that has fields opens it, with the arrow
// selected, hung under the arrow's anchor, a line a field of the arrow's types, each field its own undo step; a click on
// any other chip is the menu it was. Over bonds, in `RelationScene`'s editor, with a canvas in an unshown window so the
// host's part (the place, the keyboard) is the real one.

let roleSchema = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}}}"#

/// A Feature note related to a Layer note by an arrow of `in`, a relationship type that holds a role and a date, in an editor
/// shown in an unshown window.
@MainActor
final class ArrowCardRig {
    let s: RelationScene
    let arrow: ShapeID
    let window: NSWindow
    let canvas: CanvasView
    var editor: CanvasEditor { s.editor }
    var cards: FieldCards { editor.fieldCards! }

    init(fields: String? = roleSchema, more: [any CanvasPlugin] = []) throws {
        let scene = try RelationScene(more: more)
        let rel = scene.rel
        if let fields { scene.editor.transact { $0.update(rel) { $0[TypeSchemaProperty.self] = SchemaText(fields) } } }
        scene.fromEnd()
        scene.toEnd()
        s = scene
        arrow = scene.relate(scene.note, scene.layerNote)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: s.editor)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
    }

    func close() { window.close() }

    var form: FieldFormView? { cards.openForm }
    var chips: [AdornmentFrame] { arrowChips(of: arrow, in: editor) }
    var values: FieldValues { editor.fieldWriter?.values(of: arrow) ?? FieldValues() }
    func advance() { s.harness.scheduler.advance(by: .zero) }

    /// A click on the chip with this text, as the canvas passes it to the adornment.
    func click(_ text: String? = nil, on shape: ShapeID? = nil) throws -> AdornmentClick {
        let id = shape ?? arrow
        let frames = arrowChips(of: id, in: editor)
        let frame = try require(frames.first { text == nil || $0.label.text == text }, "no chip \(text ?? "") on \(frames.map { $0.label.text ?? "" })")
        return AdornmentClick(shape: id, tag: frame.tag, rect: frame.rect, isOverflow: frame.isOverflow)
    }

    /// A click on the pill or chip with this text, passed to the adornment that is it: the relationship's pill leads the
    /// arrow's label, a plain type's chip is above it.
    func press(_ text: String? = nil, on shape: ShapeID? = nil) throws {
        let id = shape ?? arrow
        let frame = try require(arrowChips(of: id, in: editor).first { text == nil || $0.label.text == text }, "no pill or chip \(text ?? "")")
        let click = try self.click(text, on: id)
        if frame.adornment == .of(RelationshipPill.self) { RelationshipPill.click(click, in: editor) } else { TypeChips.click(click, in: editor) }
    }
}

/// The titles of a menu's items, in order ("-" for a separator).
@MainActor private func menuItems(_ menu: NSMenu?) -> [String] {
    (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title }
}

@MainActor let chipClickTests = Suite("A click on a chip", [
    test("the chip of a relationship type with fields opens the arrow's card and selects the arrow; no menu, no step") {
        let r = try ArrowCardRig()
        defer { r.close() }
        let undo = r.editor.undoHistory.undoName
        try r.press("in")
        expect(r.editor.menuToPopUp == nil, "a card, not a menu")
        expectEqual(r.cards.openTarget?.shape, r.arrow)
        expectEqual(r.cards.openTarget?.target, .shape)
        expectEqual(r.editor.selectedShapeIDs, [r.arrow], "the arrow is selected")
        expectEqual(r.editor.card?.shape, r.arrow)
        expectEqual(r.editor.undoHistory.undoName, undo, "opening it makes no step")
    },
    test("a relationship type with no fields, a plain type, a note's chip, \"+N\" and a type that is gone keep the menu") {
        let r = try ArrowCardRig(fields: nil)
        defer { r.close() }
        // In: no fields, so no card.
        try r.press("in")
        expect(r.cards.openTarget == nil, "no card")
        expectEqual(menuItems(r.editor.menuToPopUp?.menu), ["Go to “in”", "Remove “in”"])
        r.editor.menuDidPopUp()
        // A plain type on the arrow, with fields, is a chip as any: the menu.
        let plain = r.editor.addSlipType(roleSchema, title: "Plain", at: CGPoint(x: 40, y: 1300))
        r.editor.addTypeLink(plain, to: r.arrow)
        try r.press("Plain")
        expect(r.cards.openTarget == nil)
        expectEqual(menuItems(r.editor.menuToPopUp?.menu), ["Go to “Plain”", "Remove “Plain”"])
        r.editor.menuDidPopUp()
        // A note's chip.
        try r.press("Feature", on: r.s.note)
        expect(r.cards.openTarget == nil)
        expectEqual(menuItems(r.editor.menuToPopUp?.menu), ["Go to “Feature”", "Remove “Feature”"])
        r.editor.menuDidPopUp()
        // A relationship type that is gone: a dashed chip, the menu (Remove alone).
        r.editor.transact("Delete") { $0.delete([r.s.rel]) }
        try r.press("in")
        expect(r.cards.openTarget == nil, "a type that is gone has no card")
        expectEqual(menuItems(r.editor.menuToPopUp?.menu), ["Remove “in”"])
        r.editor.menuDidPopUp()
    },
    test("with fields, a click opens the card though the plain type beside it has none; the plain chip's click is its menu") {
        let r = try ArrowCardRig()
        defer { r.close() }
        let plain = r.editor.addSlipType(roleSchema, title: "Plain", at: CGPoint(x: 40, y: 1300))
        r.editor.addTypeLink(plain, to: r.arrow)
        try r.press("Plain")
        expect(r.cards.openTarget == nil && r.editor.menuToPopUp != nil, "the plain chip is a menu")
        r.editor.menuDidPopUp()
        try r.press("in")
        expectEqual(r.cards.openTarget?.target, .shape, "the relationship type's is the card")
        expectEqual(r.form?.sheet.lines.map(\.name), ["role", "since"], "the fields of both types, the shape's own")
    },
    test("a locked arrow's card opens to be read; zoomed out, where the chip is no more, none opens") {
        let log = RefusalLog()
        let r = try ArrowCardRig(more: [FreezingPlugin(log: log)])
        defer { r.close() }
        r.editor.freeze([r.arrow])
        try r.press("in")
        let form = try require(r.form)
        expect(form.isReadOnly, "read-only")
        expect(form.sheet.lines.allSatisfy { $0.cells.allSatisfy { !$0.isEditable } }, "nothing to type in")
        r.cards.close()
        r.editor.freeze([r.arrow], false)
        r.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(!r.editor.openRelationshipCard(for: r.arrow), "a card is refused among skeletons")
        expect(r.cards.openTarget == nil)
    },
])

@MainActor let arrowCardTests = Suite("The card of an arrow", [
    test("it holds a line for each field of the arrow's types in the chain's order under the type's chip, hangs 4 points under the pill that leads the arrow's label and has the caret in its first line") {
        let r = try ArrowCardRig()
        defer { r.close() }
        expect(r.editor.openRelationshipCard(for: r.arrow))
        let form = try require(r.form)
        expectEqual(form.sheet.lines.map(\.name), ["role", "since"])
        expectEqual(form.sheet.chip, r.s.rel, "the relationship type's chip is the card's header")
        expectEqual(form.sheet.back, nil, "no line back")
        expect(form.sheet.lines.allSatisfy { $0.cells.first?.placeholder.hasPrefix("add ") == true }, "an empty line says add and its name")
        let pill = try require(r.chips.first { $0.adornment == .of(RelationshipPill.self) }).rect
        let frame = try require(r.canvas.cardFrame)
        expectEqual(frame.minY, r.editor.camera.toView(pill).maxY + 4, "4 points under the pill")
        expect(r.window.firstResponder === form.cellEditor, "the caret is in the first line")
        expectEqual(form.focus, FieldStop(line: 0, column: 0))
        expectEqual(r.editor.selectedShapeIDs, [r.arrow])
    },
    test("each field is a step of its own named for it: Change Role coalesces its keystrokes, Tab goes on to Change Since, one Undo each") {
        let r = try ArrowCardRig()
        defer { r.close() }
        r.editor.openRelationshipCard(for: r.arrow)
        r.window.type("eng")
        r.window.type("ineer")
        expectEqual(r.values.value(at: FieldPath(field: "role")), "engineer")
        expectEqual(r.editor.undoHistory.undoName, "Change Role")
        r.window.press("\t", code: 48)
        r.window.type("2021")
        expectEqual(r.values.value(at: FieldPath(field: "since")), "2021")
        expectEqual(r.editor.undoHistory.undoName, "Change Since")
        r.editor.undo()
        expectEqual(r.values.value(at: FieldPath(field: "since")), nil)
        expectEqual(r.values.value(at: FieldPath(field: "role")), "engineer", "the role is its own step")
        r.editor.undo()
        expectEqual(r.values.value(at: FieldPath(field: "role")), nil)
        r.editor.redo()
        expectEqual(r.values.value(at: FieldPath(field: "role")), "engineer")
    },
    test("Return goes down a line and, off the last, closes; Esc closes; neither makes a step of its own") {
        let r = try ArrowCardRig()
        defer { r.close() }
        r.editor.openRelationshipCard(for: r.arrow)
        let undo = r.editor.undoHistory.undoName
        r.window.pressReturn()
        expectEqual(r.form?.focus, FieldStop(line: 1, column: 0), "the next line")
        r.window.pressEscape()
        expect(r.cards.openTarget == nil && r.editor.card == nil, "Esc closes it")
        expectEqual(r.editor.undoHistory.undoName, undo)
        expect(r.editor.openRelationshipCard(for: r.arrow), "and it opens again")
    },
    test("the card follows the arrow when a note it joins moves, and goes when the arrow does") {
        let r = try ArrowCardRig()
        defer { r.close() }
        r.editor.openRelationshipCard(for: r.arrow)
        let before = try require(r.editor.card).anchor
        r.editor.transact("Move") { $0.update(r.s.layerNote) { record in
            if var box = record.box { box.origin.x += 120; box.origin.y += 80; record.box = box }
        } }
        r.advance()
        let after = try require(r.editor.card).anchor
        expect(after != before, "the card hangs from where the arrow is now: \(before) \(after)")
        let pill = try require(r.chips.first { $0.adornment == .of(RelationshipPill.self) }).rect
        expectEqual(after.midX, pill.midX, "it hangs from the pill, which went with the arrow")
        expectEqual(after.minY, pill.minY)
        r.editor.transact("Delete") { $0.delete([r.arrow]) }
        r.advance()
        expect(r.cards.openTarget == nil && r.editor.card == nil, "an arrow that is gone has no card")
    },
    test("a type that loses its fields closes the card; one that gains a field adds its line") {
        let r = try ArrowCardRig()
        defer { r.close() }
        r.editor.openRelationshipCard(for: r.arrow)
        r.editor.transact("Schema") { $0.update(r.s.rel) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}, "hours": {"type": "number"}}}"#) } }
        r.advance()
        expectEqual(r.form?.sheet.lines.map(\.name), ["role", "since", "hours"])
        r.editor.transact("Schema") { $0.update(r.s.rel) { $0[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) } }
        r.advance()
        expect(r.cards.openTarget == nil, "nothing left to show")
    },
    test("an arrow of a relationship type that has no fields opens no card, and one with no relationship type either; nothing is selected or opened") {
        let r = try ArrowCardRig(fields: nil)
        defer { r.close() }
        r.editor.selection = nil
        expect(!r.editor.openRelationshipCard(for: r.arrow))
        expect(r.cards.openTarget == nil && r.editor.card == nil)
        expect(r.editor.selectedShapeIDs.isEmpty, "the selection is untouched")
        let plain = r.editor.addBond(r.s.note, r.s.layerNote)
        expect(!r.editor.openRelationshipCard(for: plain))
    },
    test("what the card writes is what the panel and the row hold: the arrow's own field values, and nothing is stored on either note") {
        let r = try ArrowCardRig()
        defer { r.close() }
        let notes = (r.editor.document[r.s.note], r.editor.document[r.s.layerNote])
        r.editor.openRelationshipCard(for: r.arrow)
        r.window.type("engineer")
        expectEqual(r.editor.document[r.arrow]?[FieldValuesProperty.self]?.value(at: FieldPath(field: "role")), "engineer")
        expectEqual(r.editor.document[r.s.note], notes.0)
        expectEqual(r.editor.document[r.s.layerNote], notes.1)
    },
])
