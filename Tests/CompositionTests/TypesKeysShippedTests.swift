import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// What Types draws, by keys, on the shipped list with real notes and arrows in a window (keyboard navigation's P1, P3 and P5):
// a type's rows and a locked note's are parts of the shape (⌥Tab) whose Return opens the card a click opens, and Escape comes
// back one level at a time; Open Fields opens an arrow's card and a relationship type's, and the arrow's card closing by keys
// leaves the arrow selected with the canvas having the keyboard; Relate to ▸ relates from the selection's menu.

private let eventSchema = #"{"type": "object", "properties": {"status": {"enum": ["draft", "done"]}, "venue": {"type": "object", "properties": {"city": {"type": "string"}}}}}"#
private let roleAndSince = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}}}"#

extension Minute {
    /// A walk of the canvas whose keyboard can be on a part of the selected shape, named by its title.
    func partsWalk(names: [ShapeID: String]) -> KeyWalk {
        window.makeFirstResponder(canvas)
        let editor = editor
        return KeyWalk(window, editor: editor, readers: [.canvas(canvas, editor: editor, names: names, part: { editor.focusedPart?.title })],
                       settle: .both(h.scheduler))
    }

    /// An Event type, with a choice and a row with more in it, below the first minute's shapes.
    func addEvent() -> ShapeID {
        editor.addTypeNote(eventSchema, title: "Event", frame: CGRect(x: 500, y: 260, width: 200, height: 200))
    }
}

@MainActor let typesKeysShippedTests = Suite("Types by keys, shipped", [
    test("a type's note: ⌥Tab walks its rows that answer a click, round and back; Return on a row with › opens its read-only card; Escape goes back to the part, then to the note") {
        let m = try Minute()
        defer { m.close() }
        let event = m.addEvent()
        m.editor.selection = event
        let walk = m.partsWalk(names: [event: "Event"])
        let parts = m.editor.shapeParts(of: event).map { "canvas/Event/\($0.title)" }
        expect(parts.contains("canvas/Event/status") && parts.contains("canvas/Event/venue"), "\(parts)")
        walk.press(.optionTab)
        walk.expectCycle(parts, forward: .optionTab, back: .optionBackTab)
        walk.go("canvas/Event/venue", by: .optionTab)
        walk.press(.return)
        expectEqual(m.editor.fieldCards?.openTarget?.shape, event)
        expectEqual(m.editor.fieldCards?.openTarget?.target, .field(FieldPath(field: "venue")))
        expectEqual(walk.press(.escape).id, "canvas/Event/venue", "the card closes on the part")
        expect(m.editor.fieldCards?.openTarget == nil)
        expectEqual(walk.press(.escape).id, "canvas/Event", "then the note")
    },
    test("a locked note that is one: its row with more in it is a part, and Return opens its card to be read; Escape, Escape back to the note") {
        let m = try Minute()
        defer { m.close() }
        let event = m.addEvent()
        var record = ShapeRecord(StickyNote(frame: CGRect(x: 500, y: 600, width: 200, height: 200), text: ""))
        record[IsAProperty.self] = [TypeLink(event)]
        let note = AnyShapeRecord(record)
        m.editor.transact { $0.insert(note) }
        m.editor.lock([note.id])
        m.editor.selection = note.id
        let walk = m.partsWalk(names: [note.id: "gig"])
        walk.press(.optionTab)
        walk.go("canvas/gig/venue", by: .optionTab)
        walk.press(.return)
        expectEqual(m.editor.fieldCards?.openTarget?.shape, note.id)
        expectEqual(m.editor.fieldCards?.openTarget?.target, .field(FieldPath(field: "venue")))
        expectEqual(m.editor.editingShapeID, nil, "read, not edited")
        walk.expectEscapeLadder(["canvas/gig/venue", "canvas/gig"])
    },
    test("Open Fields on an arrow of a relationship type with fields opens its card; Escape, and Tab off its last stop, leave the arrow selected with the canvas having the keyboard; on the relationship type's pill it opens the definition at its name") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let made = try m.nameTheType()
        editor.transact("Fields") { $0.update(made) { $0[TypeSchemaProperty.self] = SchemaText(roleAndSince) } }
        expect(try m.click(row: "in", of: m.featureNote))
        m.window.pressReturn()
        editor.endEditing()
        let arrow = try require(m.arrows.first { $0.props.start.binding?.shapeID == m.featureNote }).id
        editor.selection = arrow
        m.window.makeFirstResponder(m.canvas)
        let menu = try require(editor.menuForSelection(omitting: []))
        expect(menu.outline.contains("Open Fields"), "the Shape menu has it: \(menu.outline)")
        try menu.choose("Open Fields")
        m.window.settle()
        expectEqual(editor.fieldCards?.openTarget?.shape, arrow)
        let driver = KeyDriver(m.window)
        driver.send(.escape)
        m.window.settle()
        expect(editor.fieldCards?.openTarget == nil)
        expectEqual(editor.selectedShapeIDs, [arrow], "Escape leaves the arrow selected")
        expect(m.window.firstResponder === m.canvas, "the canvas has the keyboard")
        expect(editor.perform(.openFields))
        m.window.settle()
        for _ in 0..<10 where editor.fieldCards?.openTarget != nil {
            driver.send(.tab)
            m.window.settle()
        }
        expect(editor.fieldCards?.openTarget == nil, "Tab off the last stop")
        expectEqual(editor.selectedShapeIDs, [arrow])
        expect(m.window.firstResponder === m.canvas)
        // The relationship type's pill: its definition, at its name.
        editor.selection = made
        expect(editor.perform(.openFields))
        expectEqual(editor.definitionCards?.openType, made)
        expectEqual(editor.definitionCards?.openView?.focus, .title)
        expect(!editor.canPerform(.openFields), "open already: the item is off, and the command does not close the card")
        expect(!editor.perform(.openFields))
        expectEqual(editor.definitionCards?.openType, made)
        // An arrow whose relationship type has no fields, and a plain note, have nothing to open.
        editor.definitionCards?.close()
        editor.selection = m.featureNote
        expect(!editor.canPerform(.openFields))
    },
    test("an offer in a type's words is a part whose id stays the same when the type moves, so the focus on it stays") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        editor.transact("Typing") { $0.update(m.feature, as: StickyNote.self) { $0.props.text = MentionText([.text("is in a "), .mention(m.layer, label: "Layer")]) } }
        editor.selection = m.feature
        // The pill is two parts: following the mention (Go to Layer) and the offer (Relate to Layer), each a key's way to one action.
        expectEqual(editor.shapeParts(of: m.feature).map(\.title).filter { $0.contains("Layer") }.sorted(), ["Go to Layer", "Relate to Layer"])
        let before = editor.shapeParts(of: m.feature).filter { $0.title.hasPrefix("Relate to") }
        expectEqual(before.count, 1, "\(editor.shapeParts(of: m.feature).map(\.title))")
        editor.transact("Move") { $0.update(m.feature, as: StickyNote.self) { $0.frame.origin.x += 37; $0.frame.origin.y += 11 } }
        let after = editor.shapeParts(of: m.feature).filter { $0.title.hasPrefix("Relate to") }
        expectEqual(after.count, 1)
        expectEqual(after.first?.id, before.first?.id)
        expect(after.first?.rect != before.first?.rect, "the pill moved with it")
    },
    test("Relate to ▸ in the selection's menu lists the offers in the selected type's words, then the type itself, and a pick relates the two") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        editor.transact("Typing") { $0.update(m.feature, as: StickyNote.self) { $0.props.text = MentionText([.text("is in a "), .mention(m.layer, label: "Layer")]) } }
        editor.selection = m.feature
        let menu = try require(editor.menuForSelection(omitting: []))
        let relate = try require(menu.item(withTitle: TypesStyle.relateTo)?.submenu, "\(menu.outline)")
        expectEqual(relate.items.map(\.title), ["Layer", "Feature"])
        try menu.choose(TypesStyle.relateTo, "Layer")
        editor.endEditing()
        expectEqual(editor.relationships?.graph.relationshipTypes(joining: m.feature, and: m.layer).count, 1)
        expectEqual(editor.undoHistory.undoName, TypesStyle.newRelationshipType)
    },
])
