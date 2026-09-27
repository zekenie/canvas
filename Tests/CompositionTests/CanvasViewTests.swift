import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Geometry
import StickyNotes
import SwiftUI
import TestKit
import Validation

/// A canvas view in an unshown window, which is enough for first responders, field editors and
/// sendEvent.
@MainActor func windowed(_ editor: CanvasEditor) -> (NSWindow, CanvasView) {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas = CanvasView(editor: editor)
    window.contentView = canvas
    return (window, canvas)
}

// The AppKit shell, in an unshown window: NSEvents in, the editing view's life cycle out.
@MainActor let canvasViewTests = Suite("Canvas view", [
    test("double-click makes a note whose editor takes focus, follows the camera, and hands focus back") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler())
        let (window, canvas) = windowed(editor)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 300, y: 300), clicks: 2, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 300, y: 300), clicks: 2, time: 1.05))
        let id = try require(editor.editingShapeID)
        let textView = try require(window.firstResponder as? NSTextView)
        let host = try require(canvas.subviews.first)
        expectEqual(host.frame, CGRect(x: 200, y: 200, width: 200, height: 200))
        editor.camera.setZoom(2, around: .zero)
        expectEqual(host.frame, CGRect(x: 400, y: 400, width: 400, height: 400))
        expectEqual(host.bounds.size, CGSize(width: 200, height: 200))
        expectEqual(editor.validation?.result(for: id)?.worst, .warning)
        textView.insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(editor.document[id]?.typed(as: StickyNote.self)?.props.text, "Hi")
        expect(editor.validation?.result(for: id) == nil)
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expect(window.firstResponder === canvas)
        expect(canvas.subviews.isEmpty)
    },
    test("a key typed on the canvas switches tools; typed in a note, it goes into the note") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler())
        let (window, canvas) = windowed(editor)
        window.press("o")
        expectEqual(editor.currentToolID, ToolID(placing: "ellipse"))
        window.press("v")
        expectEqual(editor.currentToolID, .select)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 300, y: 300), clicks: 2, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 300, y: 300), clicks: 2, time: 1.05))
        let note = try require(editor.editingShapeID)
        expect(window.firstResponder is NSTextView)
        window.press("a")
        expectEqual(editor.document[note]?.typed(as: StickyNote.self)?.props.text, "a")
        expectEqual(editor.currentToolID, .select)
        window.makeFirstResponder(canvas)
        window.press("a")
        expectEqual(editor.currentToolID, .arrow)
    },
    test("CanvasFocus.take makes the canvas first responder again, after a panel's field took it") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler())
        let focus = CanvasFocus()
        focus.take()      // no canvas yet: nothing to do
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: CanvasRepresentable(editor: editor, focus: focus))
        host.frame = CGRect(x: 0, y: 0, width: 540, height: 600)
        let field = NSTextField(frame: CGRect(x: 540, y: 560, width: 260, height: 22))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        root.addSubview(host)
        root.addSubview(field)
        window.contentView = root
        host.layoutSubtreeIfNeeded()
        let canvas = try require(focus.canvas, "the representable hands its canvas view to the focus")
        window.makeFirstResponder(field)
        expect(window.firstResponder is NSTextView, "the field is editing")
        focus.take()
        expect(window.firstResponder === canvas)
        window.press("a")
        expectEqual(editor.currentToolID, .arrow)
        expectEqual(field.stringValue, "")
    },
    test("an editing view that saves as editing ends: pressing the canvas saves; deleting its shape doesn't trap") {
        let editor = CanvasEditor(registry: try Registry(plugins: [CardsPlugin()]), scheduler: ManualScheduler())
        let (window, canvas) = windowed(editor)
        let card = ShapeRecord(Card(CGRect(x: 100, y: 100, width: 100, height: 60), text: "old"))
        editor.transact { $0.insert(card) }
        editor.selection = card.id
        editor.editSelection()
        let field = try require(canvas.subviews.first as? CardField)
        let fieldEditor = try require(field.currentEditor() as? NSTextView, "editing for real, in the window's field editor")
        fieldEditor.insertText("new", replacementRange: NSRange(location: 0, length: fieldEditor.string.count))
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 500, y: 500), time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 500, y: 500), time: 1.05))
        expectEqual(field.saves, 1)
        expectEqual(editor.document[card.id]?.typed(as: Card.self)?.props.text, "new")
        expectEqual(editor.editingShapeID, nil)

        // Deleting ends editing as the transaction commits, and the field saves as it resigns: into
        // a new transaction, after the first has ended (so no "transactions don't nest" trap).
        editor.selection = card.id
        editor.editSelection()
        let second = try require(canvas.subviews.first as? CardField)
        expect(second.currentEditor() != nil)
        editor.deleteSelection()
        expectEqual(second.saves, 1)
        expect(editor.document.shapes.isEmpty)
        expectEqual(editor.editingShapeID, nil)
        expect(canvas.subviews.isEmpty)
        expect(window.firstResponder === canvas)
    },
    test("V, then a mouse drag on the background, brushes: it selects the note it crosses and never pans") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler())
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 320, y: 320, width: 200, height: 200)))
        window.press("h")
        window.press("v")
        expectEqual(editor.currentToolID, .select)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 300, y: 300), time: 1))
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 350, y: 350), time: 1.016))
        expectEqual(editor.brush, CGRect(x: 300, y: 300, width: 50, height: 50))
        expectEqual(editor.selectedShapeIDs, [note])
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 350, y: 350), time: 1.032))
        expectEqual(editor.brush, nil)
        expectEqual(editor.selectedShapeIDs, [note])
        expectEqual(editor.camera, Camera())
    },
    test("Select All (the standard selectAll: action) selects every shape on the canvas; in a note being edited, its text") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler())
        let (window, canvas) = windowed(editor)
        canvas.selectAll(nil)
        expectEqual(editor.selectedShapeIDs, editor.document.shapes.map(\.id))
        editor.selection = nil
        expect(window.firstResponder === canvas)
        expect(canvas.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil), "down the responder chain, as the menu item sends it")
        expectEqual(editor.selectedShapeIDs.count, 9)

        let note = try require(editor.document.shapes.first { $0.kind == StickyNote.kind }?.id)
        editor.selection = note
        editor.editSelection()
        let text = try require(window.firstResponder as? NSTextView)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        expect(text.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil))
        expectEqual(text.selectedRange(), NSRange(location: 0, length: (text.string as NSString).length))
        expectEqual(editor.selectedShapeIDs, [note])
        expectEqual(editor.editingShapeID, note)
    },
    test("H, then a mouse drag, pans the camera; a flung release slides on, and a scrollWheel event stops it") {
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler)
        let (window, canvas) = windowed(editor)
        window.press("h")
        expectEqual(editor.currentToolID, .hand)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 300, y: 300), time: 1))
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 330, y: 320), time: 1.016))
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 360, y: 340), time: 1.032))
        expectEqual(editor.camera.origin, CGPoint(x: -60, y: -40))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 360, y: 340), time: 1.033))
        scheduler.advance(by: .milliseconds(16))
        expect(editor.camera.origin.x < -60 && editor.camera.origin.y < -40, "sliding on down and to the right")
        expectEqual(scheduler.pendingCount, 1)
        let wheel = try require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 5, wheel2: 0, wheel3: 0))
        canvas.scrollWheel(with: try require(NSEvent(cgEvent: wheel)))
        expectEqual(scheduler.pendingCount, 0)
        let scrolled = editor.camera
        scheduler.advance(by: .milliseconds(100))
        expectEqual(editor.camera, scrolled)
    },
])
