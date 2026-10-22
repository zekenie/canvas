import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Types

// The menu bar's keys reaching the board while something else has the keyboard: Edit's Cut, Paste, Delete and
// Select All act on the board's shapes, so while a note is edited and a box row (no text) has the keyboard they
// are off, and the key does nothing; the plain-key items (`]`, `[`, ⇧1) answer only the canvas, the window and
// a list, never a panel's control.

/// A checkbox stand-in for the panel's: takes the keyboard whatever the setting for Keyboard navigation.
@MainActor private final class PanelBox: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

@MainActor let editMenuLeakTests = Suite("Menu keys that would leak into the board", [
    test("with a box row focused in an edited note, ⌘X, ⌘V, ⌘A, Delete and Select All do nothing: the board is unchanged and editing continues") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        let kinds = FieldFixtures.everyKind.a
        w.editor.addTypeNote(kinds.schema, text: MentionText(plain: kinds.words), title: kinds.title, frame: CGRect(x: 600, y: 1200, width: 200, height: 200), id: kinds.id)
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 1200, width: 200, height: 200), text: "Ann"))
        note[IsAProperty.self] = [TypeLink(kinds.id)]
        let record = AnyShapeRecord(note)
        w.editor.transact { $0.insert(record) }
        let id = record.id
        w.editor.selection = id
        w.window.makeFirstResponder(w.canvas)
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let edit = try require(menus.main.item(withTitle: "Edit")?.submenu)
        for item in edit.items { item.target = w.controller }
        let book = try require(w.editor.rowBook)
        let row = try require(book.rows(of: id).first { $0.name == "name" })
        expect(w.editor.beginEditing(id, at: CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)))
        w.window.settle()
        let driver = KeyDriver(w.window, menu: menus.main)
        var guardrail = 0
        while w.canvas.descendants(RowsView.self).first?.focusedRow != "done", guardrail < 12 {
            driver.send(.tab)
            guardrail += 1
        }
        expectEqual(w.canvas.descendants(RowsView.self).first?.focusedRow, "done", "the box row has the keyboard")
        expect(!(w.window.firstResponder is NSText))
        // The items are off, so a key goes on rather than acting on the shapes.
        for title in ["Cut", "Copy", "Paste", "Delete", "Select All"] {
            let item = try require(edit.item(withTitle: title))
            expect(!w.controller.validateMenuItem(item), "\(title) is off while a box row is focused")
            if let action = item.action, action == #selector(CanvasView.delete(_:)) || action == #selector(NSResponder.selectAll(_:)) {
                expect(!w.canvas.validateMenuItem(item), "\(title) is off on the canvas too")
            }
        }
        let revision = w.editor.revision
        let before = w.editor.document.shapes.map(\.id)
        for chord in [Chord("x", .command), Chord("v", .command), Chord("a", .command), Chord("c", .command), Chord.delete] {
            driver.send(chord)
        }
        expectEqual(w.editor.revision, revision, "nothing changed")
        expectEqual(w.editor.document.shapes.map(\.id), before)
        expectEqual(w.editor.editingShapeID, id, "and editing continues")
        // Back in the words, the text has the keyboard and its own items work as ever.
        driver.send(.escape)
        w.editor.selection = id
        w.editor.endEditing()
        w.window.makeFirstResponder(w.canvas)
        expect(w.controller.validateMenuItem(try require(edit.item(withTitle: "Select All"))), "idle again: the board's items are on")
    },
    test("`]` with a panel checkbox focused does nothing; with the canvas, the window itself, or a list focused it still restacks") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let arrange = try require(menus.main.item(withTitle: "Arrange")?.submenu)
        for item in arrange.items { item.target = w.controller }
        @MainActor func note(_ x: CGFloat) -> ShapeID { w.editor.add(StickyNote(frame: CGRect(x: x, y: 1000, width: 200, height: 200), text: "")) }
        let (x, y, z) = (note(0), note(100), note(150))
        let mine: Set<ShapeID> = [x, y, z]
        @MainActor func order() -> [ShapeID] { w.editor.document.shapes.map(\.id).filter(mine.contains) }
        let content = try require(w.window.contentView)
        let box = PanelBox(checkboxWithTitle: "", target: nil, action: nil)
        box.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        content.addSubview(box)
        let list = NSTableView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        content.addSubview(list)
        let bring = w.window.keyEvent("]", code: 30)
        w.editor.selection = x
        expect(w.window.makeFirstResponder(box))
        expect(!menus.main.performKeyEquivalent(with: bring), "a checkbox's key is its own")
        expectEqual(order(), [x, y, z], "nothing moved")
        w.window.makeFirstResponder(w.canvas)
        expect(menus.main.performKeyEquivalent(with: bring))
        expectEqual(order(), [y, z, x], "the canvas: Bring to Front")
        w.editor.selection = y
        expect(w.window.makeFirstResponder(list))
        expect(menus.main.performKeyEquivalent(with: bring), "a list, as the table of contents is")
        expectEqual(order(), [z, x, y])
        w.editor.selection = z
        expect(w.window.makeFirstResponder(w.window))
        expect(menus.main.performKeyEquivalent(with: bring), "the window itself")
        expectEqual(order(), [x, y, z])
    },
])
