import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import TextEditing
import Titles
import Types
import Validation

// Board 1 of the relationships wireframes, steps 6 to 8, on the shipped list with real notes and real arrows, after the
// drag of step 3 and the name of step 5: a click on the Feature note's `layer` value opens a list with the untitled Layer
// note in it by its values; Return draws the arrow; one Undo takes it and both pills away. And the keys of a relation row:
// typing, Space, Escape, Tab, Backspace on nothing, ← → and the two Backspaces that take a relationship away.

extension Minute {
    /// The drag between the two types, and the name `in` typed and dismissed: the first minute's steps 1 to 5.
    func nameTheType(_ name: String = "in") throws -> ShapeID {
        try drag(from: feature, to: layer)
        let made = try require(editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        let field = try require(pillField)
        field.insertText(name, replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.selectedShapeIDs = []
        editor.undoHistory.seal()
        return made
    }

    var rowsView: RowsView? { canvas.descendants(RowsView.self).first }

    /// A click on the value of a note's row, as the person's: the note is selected and its editing begins in the row, and the
    /// list opens on the scheduler's next turn.
    @discardableResult
    func click(row name: String, of note: ShapeID, dx: CGFloat = 8) throws -> Bool {
        let row = try require(rows.rows(of: note).first { $0.name == name }, "a row \(name) in \(names(of: note))")
        editor.selection = note
        let began = editor.beginEditing(note, at: CGPoint(x: row.valueRect.minX + dx, y: row.rect.midY))
        h.scheduler.advance(by: .zero)
        return began
    }

    /// The titles of the open list's lines.
    var listed: [String]? { rowsView?.openList?.rows.compactMap { $0.item?.title } }
    func pills(of note: ShapeID, _ name: String) throws -> [ShownPill] {
        guard case .related(let pills, _)? = rows.rows(of: note).first(where: { $0.name == name })?.content else { return [] }
        return pills
    }
}

@MainActor let relationshipPickShippedTests = Suite("The row's list and its pick, shipped", [
    test("board 1, steps 6 to 8: a click on the Feature note's layer value opens a list with the untitled Layer note by its values, never `No Layer notes`; Return draws the arrow with its pills; one Undo takes the arrow and both pills away, and Redo brings them back") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let made = try m.nameTheType()
        let start = editor.document
        let featureBefore = start[m.featureNote], layerBefore = start[m.layerNote]
        // Step 6.
        expect(try m.click(row: "in", of: m.featureNote))
        expectEqual(editor.selection, m.featureNote)
        expectEqual(m.listed, ["1 · expose foobar · foundation"], "exactly one line: the Layer note, by its values")
        expectEqual(m.rowsView?.openList?.highlighted, 0)
        expect(m.rowsView?.openList?.rows.first != .empty("No Layer notes"))
        expectEqual(m.rowsView?.focusedRow, "in")
        // Step 7.
        m.window.pressReturn()
        let arrow = try require(m.arrows.first { $0.props.start.binding?.shapeID == m.featureNote }, "an arrow from the Feature note")
        expectEqual(arrow.props.end.binding?.shapeID, m.layerNote)
        expect(arrow.props.endArrowhead && !arrow.props.startArrowhead, "one head, at the Layer")
        expectEqual(arrow[IsAProperty.self]?.map(\.shape), [made])
        expectEqual(arrow[FieldValuesProperty.self], nil, "no values")
        expectEqual(editor.undoHistory.undoName, "Add Relationship")
        expectEqual(m.arrows.count, 3)
        let featurePills = try m.pills(of: m.featureNote, "in"), layerPills = try m.pills(of: m.layerNote, "feature")
        expectEqual(featurePills.count, 1)
        expect(featurePills.first?.label.hasPrefix("1 · expose foobar") == true, "\(String(describing: featurePills.first?.label))")
        expectEqual(layerPills.count, 1)
        expect(layerPills.first?.label.hasPrefix("sign in with no") == true, "\(String(describing: layerPills.first?.label))")
        expectEqual(editor.document[m.featureNote]?[FieldValuesProperty.self], featureBefore?[FieldValuesProperty.self], "no copy is stored in either note")
        expectEqual(editor.document[m.layerNote]?[FieldValuesProperty.self], layerBefore?[FieldValuesProperty.self])
        expectEqual(editor.document[m.layerNote]?[TitleProperty.self], nil, "the Layer note never has a title")
        expectEqual(editor.validation?.result(for: arrow.id)?.isValid ?? true, true, "no issues")
        expect(m.rowsView?.openList == nil, "the list went with the pick")
        expectEqual(m.rowsView?.focusedRow, "in", "the row stays focused")
        expect(m.model.requests.isEmpty, "no step asked the model")
        // Step 8.
        editor.endEditing()
        let done = editor.document
        editor.undo()
        expectEqual(editor.document, start, "one Undo: the arrow, and with it both pills")
        expectEqual(try m.pills(of: m.featureNote, "in").count, 0)
        expectEqual(try require(m.rows.rows(of: m.featureNote).last).content, .empty("add in"))
        expectEqual(try require(m.rows.rows(of: m.layerNote).last).content, .empty("add feature"))
        editor.redo()
        expectEqual(editor.document, done)
        expectEqual(try m.pills(of: m.layerNote, "feature").count, 1)
    },
    test("the same pick from the Layer note's row draws the arrow from the Feature note: the row's side sets the direction") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.nameTheType()
        expect(try m.click(row: "feature", of: m.layerNote))
        expectEqual(m.listed, ["sign in with no password"])
        m.window.pressReturn()
        let arrow = try require(m.arrows.first { $0.props.end.binding?.shapeID == m.layerNote })
        expectEqual(arrow.props.start.binding?.shapeID, m.featureNote)
    },
    test("typing on a focused relation row opens the list with the characters, Space with none, Escape closes it and keeps the row, Tab never picks, Backspace on nothing closes, Return with no line is swallowed") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.nameTheType()
        let start = m.editor.document
        expect(try m.click(row: "in", of: m.featureNote))
        // Escape: closed, the row focused and nothing stored.
        m.window.pressEscape()
        expect(m.rowsView?.openList == nil)
        expectEqual(m.rowsView?.focusedRow, "in")
        expect(m.editor.editingShapeID == m.featureNote, "still editing")
        // Typing opens it with the characters.
        m.window.type("exp")
        expectEqual(m.listed, ["1 · expose foobar · foundation"])
        m.window.type("zzz")
        expectEqual(m.rowsView?.openList?.rows.first, .empty("No matches"))
        // Return with no line is taken and does nothing.
        m.window.pressReturn()
        expectEqual(m.editor.document, start, "nothing was picked, nothing stored")
        expect(m.rowsView?.openList != nil, "the list stays")
        // Backspace through the query, then on an empty one closes.
        for _ in 0..<7 { m.window.pressDelete() }
        expect(m.rowsView?.openList == nil, "Backspace on nothing closes it")
        // Space opens it with nothing typed.
        m.window.press(" ", code: 49)
        expectEqual(m.listed, ["1 · expose foobar · foundation"])
        // Tab never picks: the list closes, the note is as it was.
        m.window.press("\t", code: 48)
        expect(m.rowsView?.openList == nil)
        expectEqual(m.editor.document, start, "Tab picked nothing")
        expectEqual(m.arrows.count, 2)
    },
    test("a click on a locked note's row opens no list and the note shakes; a note with no engine that draws connections opens none either") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.nameTheType()
        m.editor.lock([m.featureNote])
        m.editor.undoHistory.seal()
        let before = m.editor.document
        _ = try? m.click(row: "in", of: m.featureNote)
        expect(m.rowsView?.openList == nil)
        expectEqual(m.editor.document, before)
    },
    test("← → move a focus between pills, Backspace focuses the last, a second removes the relationship in one step, Escape clears a focus before it ends editing; a locked relationship is refused") {
        let m = try Minute()
        defer { m.close() }
        let made = try m.nameTheType()
        @MainActor func layerNote(_ order: Double, at y: Double) -> ShapeID {
            var note = ShapeRecord(StickyNote(frame: CGRect(x: 1000, y: y, width: 200, height: 200), text: ""))
            note[IsAProperty.self] = [TypeLink(m.layer)]
            note[FieldValuesProperty.self] = FieldValues(["order": .number(order)])
            let record = AnyShapeRecord(note)
            m.editor.transact { $0.insert(record) }
            return record.id
        }
        let two = layerNote(2, at: 800), three = layerNote(3, at: 1050)
        let row0 = try require(m.editor.relationships?.rows(for: [m.feature], isType: false).first)
        let first = try require(m.editor.relate(m.featureNote, to: two, in: row0))
        let secondArrow = try require(m.editor.relate(m.featureNote, to: three, in: row0))
        expectEqual(try m.pills(of: m.featureNote, "in").count, 2)
        _ = made
        m.editor.undoHistory.seal()
        // The row focused with its pills (a click off them): the list opens; Escape closes it.
        let row = try require(m.rows.rows(of: m.featureNote).first { $0.name == "in" })
        let off = row.valueRect.minX + 8
        m.editor.selection = m.featureNote
        expect(m.editor.beginEditing(m.featureNote, at: CGPoint(x: off, y: row.rect.midY)))
        m.h.scheduler.advance(by: .zero)
        m.window.pressEscape()
        expectEqual(m.rowsView?.focusedRow, "in")
        expectEqual(m.rowsView?.focusedPill, nil)
        // ← from nothing focuses the last pill, ← again the first, → the next, and the ends are clamped.
        m.window.press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
        expectEqual(m.rowsView?.focusedPill, 1)
        m.window.press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
        m.window.press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
        expectEqual(m.rowsView?.focusedPill, 0)
        m.window.press(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        m.window.press(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        expectEqual(m.rowsView?.focusedPill, 1)
        // Escape clears the focus first.
        m.window.pressEscape()
        expectEqual(m.rowsView?.focusedPill, nil)
        expect(m.editor.editingShapeID == m.featureNote)
        // Backspace focuses the last pill, a second removes its relationship.
        let before = m.editor.document
        m.window.pressDelete()
        expectEqual(m.rowsView?.focusedPill, 1)
        expectEqual(m.editor.document, before, "the first Backspace shows which goes")
        m.window.pressDelete()
        expectEqual(m.editor.undoHistory.undoName, "Remove Relationship")
        expectEqual(try m.pills(of: m.featureNote, "in").count, 1)
        expectEqual(m.arrows.count, 3)
        expect(m.arrows.contains { $0.id == first })
        m.editor.undo()
        expectEqual(m.editor.document, before, "one step")
        expectEqual(try m.pills(of: m.featureNote, "in").count, 2)
        // A locked relationship is refused whole: nothing goes.
        m.editor.lock([secondArrow])
        m.editor.undoHistory.seal()
        let locked = m.editor.document
        m.editor.endEditing()
        m.editor.selection = m.featureNote
        expect(m.editor.beginEditing(m.featureNote, at: CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)))
        m.h.scheduler.advance(by: .zero)
        m.window.pressEscape()
        expectEqual(m.rowsView?.focusedRow, "in")
        m.window.pressDelete()
        expectEqual(m.rowsView?.focusedPill, 1)
        m.window.pressDelete()
        expectEqual(m.editor.document, locked, "the locked relationship stays, and so does everything else")
    },
])

@MainActor let relationshipLandingShippedTests = Suite("A relationship type lands clear of what is around it", [
    test("another note in the gap between the two types, in the middle of it and filling it: the new type lands clear of that note and of both types, as any shape the placing lands is") {
        let m = try Minute()
        defer { m.close() }
        let filler = ShapeID()
        let record = AnyShapeRecord(ShapeRecord(id: filler, StickyNote(frame: CGRect(x: 420, y: 0, width: 520, height: 400), text: MentionText(plain: "In the way"))))
        m.editor.transact { $0.insert(record) }
        m.editor.undoHistory.seal()
        try m.drag(from: m.feature, to: m.layer)
        let made = try require(m.editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        let box = try m.frame(made)
        for (name, id) in [("the note in the gap", filler), ("Feature", m.feature), ("Layer", m.layer)] {
            let other = try m.frame(id)
            expect(!box.intersects(other), "the new type \(box) overlaps \(name) \(other)")
        }
        m.editor.closeCard()
    },
    test("the same with the gap filled by a note on a frame's board of notes: more than one thing in the middle") {
        let m = try Minute()
        defer { m.close() }
        var ids: [ShapeID] = []
        for index in 0..<3 {
            let id = ShapeID()
            ids.append(id)
            let record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(x: 400 + 190 * Double(index), y: 20, width: 170, height: 360), text: MentionText(plain: "Wall \(index)"))))
            m.editor.transact { $0.insert(record) }
        }
        m.editor.undoHistory.seal()
        try m.drag(from: m.feature, to: m.layer)
        let made = try require(m.editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        let box = try m.frame(made)
        for id in ids + [m.feature, m.layer] {
            let other = try m.frame(id)
            expect(!box.intersects(other), "the new type \(box) overlaps \(other)")
        }
        m.editor.closeCard()
    },
])
