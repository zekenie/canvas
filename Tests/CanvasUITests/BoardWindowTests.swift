import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Geometry
import TestKit

/// Text that keeps an undo manager of its own, as a SwiftUI field's editor may.
final class TextWithOwnUndo: NSTextView {
    let ownUndo = UndoManager()
    override var undoManager: UndoManager? { ownUndo }
}

/// A board's window, unshown: the canvas above, an editable text view and a button below it.
@MainActor final class BoardWindowFixture {
    let h: EditorHarness
    let window = BoardWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas: CanvasView
    let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
    let button = NSButton(checkboxWithTitle: "Done", target: nil, action: nil)

    init() throws {
        h = try EditorHarness(plugins: [FixturesPlugin()])
        canvas = CanvasView(editor: h.editor)
        canvas.frame = CGRect(x: 0, y: 200, width: 800, height: 400)
        text.allowsUndo = true
        button.frame = CGRect(x: 500, y: 0, width: 100, height: 30)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        for view in [canvas, text, button] as [NSView] { content.addSubview(view) }
        window.contentView = content
        window.editor = h.editor
        window.makeFirstResponder(canvas)
    }

    /// A box added as a step of its own, "Add Box".
    @discardableResult
    func addBox() -> ShapeID {
        let box = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.transact("Add Box") { $0.insert(box) }
        return box.id
    }

    /// Edit › Undo or Redo as the menu shows it now: its title, and whether it's enabled.
    func menuItem(_ action: String) -> (title: String, enabled: Bool) {
        let item = NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "")
        let enabled = window.validateMenuItem(item)
        return (item.title, enabled)
    }

    /// Who answers an action sent to the first responder, up the responder chain as AppKit looks.
    func target(of action: String) -> AnyObject? {
        let selector = NSSelectorFromString(action)
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: selector) { return current }
            responder = current.nextResponder
        }
        return nil
    }
}

// Edit › Undo and Redo in a board's window: the text's own while text has the keyboard, the board's
// anywhere else; and the window's part in ending runs of panel writes.
@MainActor let boardWindowTests = Suite("Board window", [
    test("with the canvas or a control first responder, Undo and Redo reach the window and run the board's steps, named") {
        let f = try BoardWindowFixture()
        expect(f.target(of: "undo:") === f.window)
        expect(f.target(of: "redo:") === f.window)
        expect(f.menuItem("undo:") == ("Undo", false), "\(f.menuItem("undo:"))")
        let box = f.addBox()
        expect(f.menuItem("undo:") == ("Undo Add Box", true), "\(f.menuItem("undo:"))")
        f.window.makeFirstResponder(f.button)
        expect(f.target(of: "undo:") === f.window)
        f.window.undo(nil)
        expect(f.h.editor.document[box] == nil)
        expect(f.menuItem("undo:") == ("Undo", false), "\(f.menuItem("undo:"))")
        expect(f.menuItem("redo:") == ("Redo Add Box", true), "\(f.menuItem("redo:"))")
        f.window.redo(nil)
        expect(f.h.editor.document[box] != nil)
        expect(f.menuItem("redo:") == ("Redo", false), "\(f.menuItem("redo:"))")
    },
    test("with text first responder, Undo and Redo are the text's own, and never reach the board") {
        let f = try BoardWindowFixture()
        let box = f.addBox()
        f.window.makeFirstResponder(f.text)
        expect(f.window.undoManager === f.window.textUndo)
        expect(f.text.undoManager === f.window.textUndo, "the only undo manager text sees")
        expect(f.menuItem("undo:") == ("Undo", false), "nothing typed yet: \(f.menuItem("undo:"))")
        f.window.type("hi")
        f.window.settle()
        expectEqual(f.text.string, "hi")
        expect(f.menuItem("undo:") == ("Undo Typing", true), "\(f.menuItem("undo:"))")
        f.window.undo(nil)
        expectEqual(f.text.string, "")
        expect(f.h.editor.document[box] != nil, "the board's step is still there")
        expect(f.menuItem("redo:") == ("Redo Typing", true), "\(f.menuItem("redo:"))")
        f.window.redo(nil)
        expectEqual(f.text.string, "hi")
        f.window.undo(nil)
        f.window.undo(nil)
        expect(f.h.editor.document[box] != nil, "text's undo doesn't fall through to the board")
        expect(f.h.editor.canUndo)
    },
    test("text that loses the keyboard forgets what it could undo") {
        let f = try BoardWindowFixture()
        f.window.makeFirstResponder(f.text)
        f.window.type("abc")
        f.window.settle()
        expect(f.window.textUndo.canUndo)
        f.window.makeFirstResponder(f.canvas)
        expect(!f.window.textUndo.canUndo)
        expect(f.menuItem("undo:") == ("Undo", false), "\(f.menuItem("undo:"))")
    },
    test("text with an undo manager of its own forgets what it could undo too, once it loses the keyboard") {
        let f = try BoardWindowFixture()
        let text = TextWithOwnUndo(frame: CGRect(x: 0, y: 100, width: 400, height: 100))
        f.window.contentView?.addSubview(text)
        f.window.makeFirstResponder(text)
        text.ownUndo.groupsByEvent = false
        text.ownUndo.beginUndoGrouping()
        text.ownUndo.registerUndo(withTarget: text) { _ in }
        text.ownUndo.endUndoGrouping()
        expect(text.ownUndo.canUndo)
        expect(f.menuItem("undo:").enabled, "Undo is the text's own")
        f.window.makeFirstResponder(f.canvas)
        expect(!text.ownUndo.canUndo, "its own undo, forgotten")
    },
    test("a click in a window that isn't a board's (the color panel) ends every board's run of writes") {
        let f = try BoardWindowFixture()
        let box = f.addBox()
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        defer { panel.close() }
        @MainActor func write(_ x: CGFloat) {
            f.h.editor.transact("Change Color", coalescing: "x") { $0.update(box, as: Box.self) { $0.frame.origin.x = x } }
        }
        write(1)
        write(2)
        NSApp.sendEvent(panel.mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), time: 1))
        NSApp.sendEvent(panel.mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100), time: 1.1))
        write(3)
        f.h.editor.undo()
        expectEqual(f.h.editor.document[box]?.box?.origin.x, 2, "the pick after the click is a step of its own")
        f.h.editor.undo()
        expectEqual(f.h.editor.document[box]?.box?.origin.x, 0)
    },
    test("a click anywhere, or a key where neither text nor the canvas has the keyboard, ends a run of writes; the keyboard moving does too") {
        let f = try BoardWindowFixture()
        let box = f.addBox()
        @MainActor func write(_ x: CGFloat) {
            f.h.editor.transact("Change Box", coalescing: "x") { $0.update(box, as: Box.self) { $0.frame.origin.x = x } }
        }
        @MainActor func steps() -> Int {
            var n = 0
            while f.h.editor.canUndo { f.h.editor.undo(); n += 1 }
            while f.h.editor.canRedo { f.h.editor.redo() }
            return n
        }
        write(1)
        write(2)
        expectEqual(steps(), 2, "the add, and one run")
        write(3)
        f.window.sendEvent(f.window.mouse(.leftMouseDown, at: CGPoint(x: 450, y: 450), time: 1))
        write(4)
        expectEqual(steps(), 4, "a click ended the run")
        f.window.makeFirstResponder(f.button)
        write(5)
        f.window.press(" ")
        write(6)
        expectEqual(steps(), 6, "a key on a control ended it; so did the keyboard moving to the control")
        f.window.makeFirstResponder(f.text)
        write(7)
        f.window.type("a")
        write(8)
        expectEqual(steps(), 7, "typing in text doesn't end it")
    },
])
