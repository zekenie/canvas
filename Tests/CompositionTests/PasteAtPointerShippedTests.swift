import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Geometry
import Selection
import TestKit

// Edit › Paste at Pointer (⇧⌘V) in the app's window, over the nested file, on a pasteboard of the test's
// own: ⇧⌘V reaches Clipboard's command through the canvas, and the menu item through the window's controller.

@MainActor let pasteAtPointerShippedTests = Suite("Paste at Pointer, shipped", [
    test("⇧⌘V on the canvas puts the copy centered where the pointer is, ⌘V where it was copied from; the menu item does as ⇧⌘V does") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        w.editor.copySelection()
        w.window.makeFirstResponder(w.canvas)
        let point = CGPoint(x: 400, y: 330)
        w.move(to: point, time: 2)
        expect(w.editor.isPointerOverCanvas)
        let target = w.editor.camera.toWorld(point)
        var before = w.editor.document
        expect(w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command, .shift])), "the canvas's shortcut takes it")
        var pasted = try require(w.editor.document.shapes.first { before[$0.id] == nil })
        expectEqual(pasted.box?.center, target, "its middle on the pointer")
        expectEqual(w.editor.selectedShapeIDs, [pasted.id])
        before = w.editor.document
        expect(w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command])))
        pasted = try require(w.editor.document.shapes.first { before[$0.id] == nil })
        expectEqual(pasted.box, w.editor.document[note]?.box, "⌘V: where it was copied from")
        let edit = try require(BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry).main.item(withTitle: "Edit")?.submenu)
        let item = try require(edit.item(withTitle: "Paste at Pointer"))
        item.target = w.controller
        expectEqual(KeyboardShortcutSection.key(of: item), "⇧⌘V")
        expect(w.controller.validateMenuItem(item))
        before = w.editor.document
        w.controller.runCommand(item)
        pasted = try require(w.editor.document.shapes.first { before[$0.id] == nil })
        expectEqual(pasted.box?.center, target)
        expectEqual(edit.items.map(\.title).firstIndex(of: "Paste at Pointer"), (edit.items.map(\.title).firstIndex(of: "Paste") ?? 0) + 1, "after Paste")
    },
    test("with the pointer off the canvas the menu item pastes as ⌘V does, and with a panel field holding the keyboard it's off, so ⇧⌘V is the field's") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        w.editor.copySelection()
        w.move(to: CGPoint(x: 400, y: 330), time: 2)
        w.editor.pointerExited()
        var before = w.editor.document
        w.controller.runCommand(commandItem(.pasteAtPointer))
        let pasted = try require(w.editor.document.shapes.first { before[$0.id] == nil })
        expectEqual(pasted.box, w.editor.document[note]?.box, "off the canvas: in place, as ⌘V")
        let edit = try require(BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry).main.item(withTitle: "Edit")?.submenu)
        let item = try require(edit.item(withTitle: "Paste at Pointer"))
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        expect(!w.controller.validateMenuItem(item), "text has the keyboard")
        before = w.editor.document
        w.window.makeFirstResponder(w.canvas)
        expect(w.controller.validateMenuItem(item))
    },
])
