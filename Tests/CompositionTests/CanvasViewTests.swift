import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import CoreGraphics
import Geometry
import Keyboard
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import SwiftUI
import TestKit
import Titles

/// A canvas view in an unshown window, which is enough for first responders, field editors and
/// sendEvent.
@MainActor func windowed(_ editor: CanvasEditor) -> (NSWindow, CanvasView) {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas = CanvasView(editor: editor)
    window.contentView = canvas
    return (window, canvas)
}

extension CanvasEditor {
    /// Inserts a shape named `title` (the property Titles keeps), in a transaction of its own.
    @discardableResult
    func add<P: ShapeProps>(_ props: P, title: String) -> ShapeID {
        var shape = ShapeRecord(props)
        shape[TitleProperty.self] = title
        transact { $0.insert(shape) }
        return shape.id
    }
}

/// Records the standard actions that reach it up the responder chain.
final class ActionLog: NSView {
    var actions: [String] = []
    override func moveRight(_ sender: Any?) { actions.append("moveRight:") }
    override func insertTab(_ sender: Any?) { actions.append("insertTab:") }
}

/// A pill in a note's text, as Mentions' will be: a face (Selection's `ShapeFaces`) 60 × 20, 10 in
/// from the note's top-left corner, naming `PillBoard.target`. It carries where it is, since a face's
/// click isn't given the press.
struct NotePill: Hashable, Sendable {
    let note: ShapeID
    let rect: CGRect
    let target: ShapeID
}

/// The shape every note's pill names.
@MainActor final class PillBoard {
    var target: ShapeID?
}

/// Pills in notes: the pointer over one hovers what it names, a click edits the note from the pill
/// (`beginEditing(_:at:)`), and a double-click goes to what it names (`goTo`), as Mentions' will. A
/// click on a read-only note's pill (a locked one) doesn't try to edit it: a refused edit is a try
/// to change it, which Selection shakes, and a click isn't one.
@MainActor func pillsPlugin(_ board: PillBoard) -> Contributor {
    Contributor(id: "pills") { r in
        let find: @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> NotePill? = { _, shape, point in
            guard shape.kind == StickyNote.kind, let frame = shape.box, let target = board.target else { return nil }
            let rect = CGRect(x: frame.minX + 10, y: frame.minY + 10, width: 60, height: 20)
            return rect.contains(point) ? NotePill(note: shape.id, rect: rect, target: target) : nil
        }
        r.shapeFaces(at: find,
                     click: { pill, editor in
                         if !editor.isReadOnly(pill.note) { editor.beginEditing(pill.note, at: CGPoint(x: pill.rect.midX, y: pill.rect.midY)) }
                     },
                     doubleClick: { pill, editor in editor.goTo([pill.target]) },
                     hovering: { pill, _ in pill.target })
    }
}

// The AppKit shell, in an unshown window: NSEvents in, the editing view's life cycle out.
@MainActor let canvasViewTests = Suite("Canvas view", [
    test("double-click makes a note whose editor takes focus, follows the camera, and hands focus back") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
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
        textView.insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(editor.document[id]?.typed(as: StickyNote.self)?.props.text, "Hi")
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expect(window.firstResponder === canvas)
        expect(canvas.subviews == [canvas.zoomIndicator], "its editor gone")
    },
    test("typed past its eighth line, a note grows, and its editor with it, so the caret and the text stay in view") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 300, y: 250), clicks: 2, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 300, y: 250), clicks: 2, time: 1.05))
        let id = try require(editor.editingShapeID)
        let textView = try require(window.firstResponder as? NSTextView)
        let host = try require(canvas.subviews.first { !($0 is MinimapView) })
        for line in 1...12 { textView.insertText(line == 1 ? "1" : "\n\(line)", replacementRange: textView.selectedRange()) }
        let box = try require(editor.document[id]?.box)
        expectEqual(box.height, 12 * 19 + 33)
        expectEqual(host.frame, editor.camera.toView(box), "the editor over all of it")
        expectEqual(host.bounds.size, box.size)
        expect(textView.frame.height >= box.height, "its text view too, the last line in it: \(textView.frame)")
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.undoHistory.undoName, "Add Note", "placing, typing and growing: one step")
    },
    test("typed near the window's bottom, a note grows past it, and the camera follows the caret, so nothing's typed blind; as an arrow key moves it too") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 300, y: 480), clicks: 2, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 300, y: 480), clicks: 2, time: 1.05))
        let id = try require(editor.editingShapeID)
        let textView = try require(window.firstResponder as? NSTextView)
        /// The caret, in the canvas's points.
        @MainActor func caret() -> CGRect {
            let screen = textView.firstRect(forCharacterRange: NSRange(location: NSMaxRange(textView.selectedRange()), length: 0), actualRange: nil)
            return canvas.convert(window.convertFromScreen(screen), from: nil)
        }
        let start = editor.camera
        for line in 1...15 {
            textView.insertText(line == 1 ? "1" : "\n\(line)", replacementRange: textView.selectedRange())
            expect(canvas.bounds.insetBy(dx: 15, dy: 15).contains(caret()), "line \(line)'s caret in view: \(caret())")
        }
        expect(editor.camera.origin.y > start.origin.y, "the camera went down with it")
        expectEqual(editor.camera.zoom, start.zoom, "no zoom")
        let box = try require(editor.document[id]?.box)
        expect(editor.camera.toView(box).maxY > 600 - 20, "the note's bottom, with the caret, at the window's")
        textView.moveToBeginningOfDocument(nil)
        editor.camera = start
        textView.moveToEndOfDocument(nil)
        expect(canvas.bounds.insetBy(dx: 15, dy: 15).contains(caret()), "the caret moved to where it's out of view: shown")
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.undoHistory.undoName, "Add Note", "the camera's moves are no step")
        // A long note whose end has never been in view: the caret sent there (⌘↓), the camera goes there.
        let long = (1...40).map(String.init).joined(separator: "\n")
        let tall = editor.add(StickyNote(frame: CGRect(x: 500, y: 100, width: 200, height: 200), text: MentionText(plain: long)))
        editor.camera = start
        editor.selection = tall
        let onFirstLine = editor.camera.toView(CGPoint(x: 520, y: 125))
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: onFirstLine, clicks: 1, time: 5))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: onFirstLine, clicks: 1, time: 5.05))
        expectEqual(editor.editingShapeID, tall)
        let top = editor.camera
        let end = try require(window.firstResponder as? NSTextView)
        end.moveToEndOfDocument(nil)
        let screen = end.firstRect(forCharacterRange: NSRange(location: (end.string as NSString).length, length: 0), actualRange: nil)
        expect(editor.camera.origin.y > top.origin.y + 200, "the camera went down to it: \(top.origin.y) to \(editor.camera.origin.y)")
        expect(screen != .zero && canvas.bounds.insetBy(dx: 15, dy: 15).contains(canvas.convert(window.convertFromScreen(screen), from: nil)),
               "at its end, in view: \(screen)")
    },
    test("a double-click on a note's word edits it with that word selected; a click on the selected note, with the caret where it's clicked") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Buy milk and bread"))
        // The first line's middle, 16 points in and 9 down past the padding: on "Buy", then on "milk".
        let onBuy = CGPoint(x: 100 + 16 + 12, y: 100 + 16 + 9), onMilk = CGPoint(x: 100 + 16 + 52, y: 100 + 16 + 9)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: onBuy, clicks: 1, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: onBuy, clicks: 1, time: 1.05))
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: onBuy, clicks: 2, time: 1.1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: onBuy, clicks: 2, time: 1.15))
        expectEqual(editor.editingShapeID, note)
        expectEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 3), "Buy")
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.selection, note)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: onMilk, clicks: 1, time: 3))
        expectEqual(editor.editingShapeID, nil, "not on the press")
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: onMilk, clicks: 1, time: 3.05))
        expectEqual(editor.editingShapeID, note, "on the release")
        let caret = try require((window.firstResponder as? NSTextView)?.selectedRange())
        expect(caret.length == 0 && (4...8).contains(caret.location), "in milk: \(caret)")
        expectEqual(editor.hovered, nil, "released over its text")
    },
    test("a titled note's pill isn't its text: a click there on the note selected doesn't edit it, and a double-click edits it with the caret at the end") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Milk and bread"), title: "Groceries")
        // The pill: the row 9 to 27 points above the note's top edge, from its left end.
        let pill = CGPoint(x: 120, y: 82)
        expectEqual(editor.selectableShape(at: pill), note, "the pill is the note's for the select tool")
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: pill, clicks: 1, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: pill, clicks: 1, time: 1.05))
        expectEqual(editor.selection, note)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: pill, clicks: 1, time: 3))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: pill, clicks: 1, time: 3.05))
        expectEqual(editor.editingShapeID, nil, "a click on the selected note's pill only selects it")
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: pill, clicks: 2, time: 3.1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: pill, clicks: 2, time: 3.15))
        expectEqual(editor.editingShapeID, note)
        expectEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 14, length: 0), "at the end, no word selected")
    },
    test("the click that brings a board's window forward, on its only selected note, only brings it forward; the next click edits it") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Hi"))
        editor.selection = note
        expect(!window.isKeyWindow)
        let press = window.mouse(.leftMouseDown, at: CGPoint(x: 200, y: 200), time: 1)
        expect(canvas.acceptsFirstMouse(for: press), "it takes the click")
        canvas.mouseDown(with: press)
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 200, y: 200), time: 1.05))
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.selection, note)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 200, y: 200), time: 3))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 200, y: 200), time: 3.05))
        expectEqual(editor.editingShapeID, note)
    },
    test("opening a note too short for its text grows it, and its editor with it, to show all of it before anything's typed; Escape and Undo put it back") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let long = (1...12).map(String.init).joined(separator: "\n")
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 50, width: 200, height: 200), text: MentionText(plain: long)))
        editor.selection = note
        window.makeFirstResponder(canvas)
        window.pressReturn()
        expectEqual(editor.editingShapeID, note)
        let box = try require(editor.document[note]?.box)
        expectEqual(box.height, 12 * 19 + 33)
        let host = try require(canvas.subviews.first { !($0 is MinimapView) })
        expectEqual(host.frame, editor.camera.toView(box), "the editor over all of it")
        let textView = try require(window.firstResponder as? NSTextView)
        expect(textView.frame.height >= box.height, "its text view too: \(textView.frame)")
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.undoHistory.undoName, "Typing")
        editor.undo()
        expectEqual(editor.document[note]?.box?.height, 200)
    },
    test("a double-click on an arrow edits its label in a view laid over it, which grows with what's typed; Return is a new line, Escape ends it, one step") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let id = editor.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 600, y: 300))))
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 200, y: 300), clicks: 1, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 200, y: 300), clicks: 1, time: 1.05))
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 200, y: 300), clicks: 2, time: 1.2))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 200, y: 300), clicks: 2, time: 1.25))
        expectEqual(editor.editingShapeID, id)
        let host = try require(canvas.subviews.first { !($0 is MinimapView) })
        let empty = try require(editor.editingFrame)
        expectEqual(host.frame, editor.camera.toView(empty), "over the label, halfway")
        window.type("calls")
        let arrow = { editor.document[id]?.typed(as: Arrow.self)?.props }
        expectEqual(arrow()?.text, "calls")
        let typed = try require(editor.editingFrame)
        expect(typed.width > empty.width, "grown: \(typed)")
        expectEqual(host.frame, editor.camera.toView(typed), "and the view with it")
        expectEqual(host.bounds.size, typed.size)
        window.sendEvent(window.keyEvent("\r", code: 36))
        window.type("back")
        expectEqual(arrow()?.text, "calls\nback", "Return is a new line")
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.editingShapeID, nil)
        expect(window.firstResponder === canvas)
        expectEqual(editor.undoHistory.undoName, "Typing")
        editor.undo()
        expectEqual(arrow()?.text, "")
    },
    test("canvas draw writing an arrow's text while its label is typed into ends the typing first, so the next key doesn't type over it") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        editor.add(StickyNote(frame: CGRect(x: 100, y: 200, width: 200, height: 200)), title: "A")
        editor.add(StickyNote(frame: CGRect(x: 500, y: 200, width: 200, height: 200)), title: "B")
        let commands = editor.registry.hostCommands
        let spec = try require(commands.specs.first { $0.name == "draw" })
        @MainActor func draw(_ script: String) throws {
            let params = try spec.params(from: ["-"], standardInput: { script })
            _ = try awaitResult { try await commands.run(spec.name, .object(params), editor) }
        }
        try draw(#"edge "A" -> "B""#)
        let id = try require(editor.document.shapes.first { $0.kind == Arrow.kind }?.id)
        let text = { editor.document[id]?.typed(as: Arrow.self)?.props.text }
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 400, y: 300), clicks: 2, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 400, y: 300), clicks: 2, time: 1.05))
        expectEqual(editor.editingShapeID, id)
        window.type("foo")
        try draw(#"edge "A" -> "B" from: right"#)
        expectEqual(editor.editingShapeID, id, "re-aimed, nothing typed changes")
        try draw(#"edge "A" -> "B" text: "foo""#)
        expectEqual(editor.editingShapeID, id, "what it says already")
        try draw(#"edge "A" -> "B" text: "calls""#)
        expectEqual(editor.editingShapeID, nil)
        expectEqual(text(), "calls")
        window.type("x")
        expectEqual(text(), "calls", "the next key isn't the label's")
        editor.undo()
        expectEqual(text(), "foo", "the typing was a step of its own")
    },
    test("⌘↩ in a note's text ends editing and hands the canvas the keyboard, as a key equivalent and as a key") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        for (x, asKeyEquivalent) in [(200.0, true), (500, false)] {
            canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: x, y: 300), clicks: 2, time: 1))
            canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: x, y: 300), clicks: 2, time: 1.05))
            let id = try require(editor.editingShapeID)
            window.type("Hi")
            let event = window.keyEvent("\r", code: 36, modifiers: .command)
            if asKeyEquivalent { expect(window.performKeyEquivalent(with: event), "taken before the menus") } else { window.sendEvent(event) }
            expectEqual(editor.editingShapeID, nil, "as a key equivalent: \(asKeyEquivalent)")
            expect(window.firstResponder === canvas)
            expectEqual(editor.document[id]?.typed(as: StickyNote.self)?.props.text, "Hi")
        }
    },
    test("a note being edited isn't hovered under its text, released or moved there; on the canvas, what's under the pointer is, and it too once editing ends") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let other = editor.add(StickyNote(frame: CGRect(x: 500, y: 100, width: 200, height: 200), text: "Other"))
        @MainActor func move(to point: CGPoint, at time: TimeInterval) {
            canvas.mouseMoved(with: window.mouse(.mouseMoved, at: point, clicks: 0, time: time))
        }
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 300, y: 300), clicks: 2, time: 1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 300, y: 300), clicks: 2, time: 1.05))
        let note = try require(editor.editingShapeID)
        expectEqual(editor.hovered, nil, "released over its text")
        move(to: CGPoint(x: 310, y: 300), at: 1.1)
        expectEqual(editor.hovered, nil, "moved over its text")
        move(to: CGPoint(x: 600, y: 200), at: 1.2)
        expectEqual(editor.hovered, other)
        move(to: CGPoint(x: 300, y: 300), at: 1.3)
        expectEqual(editor.hovered, nil, "back over its text")
        expect(!editor.isHovered(note) && !editor.isHovered(other))
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.editingShapeID, nil)
        move(to: CGPoint(x: 310, y: 300), at: 1.4)
        expectEqual(editor.hovered, note)
    },
    test("a pill in a note, a face: the pointer over it hovers what it names; a click edits the note from the pill, and the note isn't hovered under its text; locked, a click only selects it (it doesn't shake), a double-click goes to what it names, and Back returns") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let board = PillBoard()
        let registry = try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel()) + [pillsPlugin(board)])
        let scheduler = ManualScheduler()
        let editor = CanvasEditor(registry: registry, document: CanvasDocument(), scheduler: scheduler)
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "See the other"))
        let far = CGRect(x: 2000, y: 1500, width: 200, height: 200)
        let target = editor.add(StickyNote(frame: far, text: "The other"))
        board.target = target
        @MainActor func click(clicks: Int, at time: TimeInterval) {
            let pill = CGPoint(x: 130, y: 120)                  // on the pill: 110 to 170 across, 110 to 130 down
            canvas.mouseDown(with: window.mouse(.leftMouseDown, at: pill, clicks: clicks, time: time))
            canvas.mouseUp(with: window.mouse(.leftMouseUp, at: pill, clicks: clicks, time: time + 0.05))
        }
        canvas.mouseMoved(with: window.mouse(.mouseMoved, at: CGPoint(x: 130, y: 120), clicks: 0, time: 1))
        expectEqual(editor.hovered, target, "the pill hovers what it names")
        click(clicks: 1, at: 1.1)
        expectEqual(editor.selection, note)
        expectEqual(editor.editingShapeID, note, "a click on the pill edits the note")
        expectEqual(editor.editingStartPoint, CGPoint(x: 140, y: 120), "from the pill, which says where it is")
        expectEqual(editor.hovered, nil, "released over the note's text, which has the pointer")
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.editingStartPoint, nil)

        editor.lock([note])
        click(clicks: 1, at: 2)
        expectEqual(editor.editingShapeID, nil, "a locked note isn't edited")
        expectEqual(editor.selection, note)
        scheduler.advance(by: .milliseconds(16))
        expectEqual(editor.drawingOffset(of: note), .zero, "a click isn't a try to change it, so it doesn't shake")
        click(clicks: 2, at: 2.2)
        expectEqual(editor.selection, target, "a double-click goes to what the pill names")
        scheduler.advance(by: .milliseconds(16))
        expectEqual(editor.drawingOffset(of: note), .zero, "nor does a double-click")
        let shown = editor.cameraTarget.toWorld(CGRect(origin: .zero, size: editor.viewportSize))
        expect(shown.contains(far), "brought into view: \(shown)")
        editor.goBack()
        expectEqual(editor.selection, note, "and Back returns to the note")
    },
    test("a key typed on the canvas switches tools; typed in a note, it goes into the note") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        window.press("b")
        expectEqual(editor.currentToolID, ToolID(placing: "subboard"))
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
        window.press("b")
        expectEqual(editor.currentToolID, ToolID(placing: Subboard.kind))
    },
    test("CanvasFocus.take makes the canvas first responder again, after a panel's field took it") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
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
        window.press("b")
        expectEqual(editor.currentToolID, ToolID(placing: Subboard.kind))
        expectEqual(field.stringValue, "")
    },
    test("⌘A, Return, Delete and Escape typed on the canvas are Keyboard's shortcuts; Edit › Select All and Edit › Delete run the same commands") {
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()]), scheduler: ManualScheduler())
        let (window, canvas) = windowed(editor)
        let box = editor.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let card = editor.add(Card(CGRect(x: 100, y: 100, width: 100, height: 60)))
        let other = editor.add(Box(CGRect(x: 500, y: 100, width: 100, height: 100)))
        window.makeFirstResponder(canvas)
        window.press("a", modifiers: .command)
        expectEqual(editor.selectedShapeIDs, [box, card, other])
        editor.selection = nil
        canvas.selectAll(nil)
        expectEqual(editor.selectedShapeIDs, [box, card, other])
        editor.selection = card
        window.pressReturn()
        expectEqual(editor.editingShapeID, card)
        editor.endEditing()
        expect(window.firstResponder === canvas)
        editor.selection = box
        window.pressDelete()
        editor.selection = other
        canvas.delete(nil)
        expectEqual(editor.document.shapes.map(\.id), [card])
        editor.setTool(ToolID(placing: Card.kind))
        window.pressEscape()
        expectEqual(editor.currentToolID, .select)
    },
    test("a ⌘ key a menu item also has is the canvas's shortcut while it has the keyboard, in the app's SwiftUI hosting too; with a field focused, the canvas passes it on") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let focus = CanvasFocus()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: CanvasRepresentable(editor: editor, focus: focus))
        host.frame = CGRect(x: 0, y: 0, width: 540, height: 600)
        let field = NSTextField(frame: CGRect(x: 540, y: 560, width: 260, height: 22))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        root.addSubview(host)
        root.addSubview(field)
        window.contentView = root
        host.layoutSubtreeIfNeeded()
        let canvas = try require(focus.canvas)
        window.makeFirstResponder(canvas)
        // AppKit asks the key window's views for a key equivalent before the menu bar (Edit › Select All has ⌘A).
        let commandA = window.keyEvent("a", modifiers: .command)
        expect(window.performKeyEquivalent(with: commandA))
        expectEqual(editor.selectedShapeIDs, editor.document.shapes.map(\.id))
        editor.selection = nil
        window.makeFirstResponder(field)
        expect(!window.performKeyEquivalent(with: commandA), "the menu's, to select the field's text")
        expectEqual(editor.selectedShapeIDs, [])
    },
    test("⌃⌘M isn't the canvas's while it has the keyboard: it goes on to the menu bar, where it's View › Show Minimap") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        window.makeFirstResponder(canvas)
        expect(!window.performKeyEquivalent(with: window.keyEvent("m", modifiers: [.command, .control])))
        let view = try require(BoardMenus.make(appName: "Infinite Canvas").main.item(withTitle: "View")?.submenu)
        let item = try require(view.item(withTitle: "Show Minimap"))
        expectEqual(item.keyEquivalent, "m")
        expectEqual(item.keyEquivalentModifierMask, [.command, .control])
    },
    test("the standard actions AppKit's key bindings send come back to the shortcuts as their keys: ⌃H is Delete, cancelOperation: Escape") {
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()]), scheduler: ManualScheduler())
        let (window, canvas) = windowed(editor)
        let box = editor.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let card = editor.add(Card(CGRect(x: 100, y: 100, width: 100, height: 60)))
        let other = editor.add(Box(CGRect(x: 500, y: 100, width: 100, height: 100)))
        window.makeFirstResponder(canvas)
        editor.selection = box
        window.sendEvent(window.keyEvent("\u{8}", ignoringModifiers: "h", code: 4, modifiers: .control))     // deleteBackward:, as an emacs binding
        expectEqual(editor.document.shapes.map(\.id), [card, other])
        editor.selection = other
        canvas.deleteForward(nil)
        expectEqual(editor.document.shapes.map(\.id), [card])
        editor.selection = card
        canvas.insertNewline(nil)
        expectEqual(editor.editingShapeID, card)
        editor.endEditing()
        editor.setTool(ToolID(placing: Card.kind))
        canvas.cancelOperation(nil)
        expectEqual(editor.currentToolID, .select)
    },
    test("a key no shortcut takes goes on to AppKit's key bindings: their moves and typing stop at the canvas, and any other action goes up the responder chain, as from any view") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let parent = ActionLog(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let canvas = CanvasView(editor: editor)
        canvas.frame = parent.bounds
        parent.addSubview(canvas)
        window.contentView = parent
        window.makeFirstResponder(canvas)
        window.press("\u{F703}", code: 124, modifiers: [.numericPad, .function])       // →, with nothing to nudge
        window.press("q", code: 12)
        window.press("\t", code: 48)
        expectEqual(parent.actions, ["insertTab:"], "→'s moveRight: stops at the canvas, so it doesn't beep")
        expectEqual(editor.currentToolID, .select)
        expect(window.firstResponder === canvas)
    },
    test("an editing view that saves as editing ends: pressing the canvas saves; deleting its shape doesn't trap") {
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin()]), scheduler: ManualScheduler())
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
        expect(canvas.subviews == [canvas.zoomIndicator], "its field gone")
        expect(window.firstResponder === canvas)
    },
    test("V, then a mouse drag on the background, brushes: it selects the note it crosses and never pans") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
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
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler(), model: ScriptedLanguageModel())
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
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel())
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
    test("a right-click opens a shape's context menu through the view; where there's nothing to offer, it and a Control-click do nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let arrow = CGPoint(x: 190, y: 300), card = CGPoint(x: 520, y: 140), empty = CGPoint(x: 190, y: 500)
        // An empty board, with nothing to paste, has nothing to offer. AppKit sends a Control-click to
        // mouseDown only when menu(for:) has nothing: it isn't a press, so it does nothing.
        expect(canvas.menu(for: window.mouse(.rightMouseDown, at: empty, time: 1)) == nil)
        let revision = editor.revision
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: empty, modifiers: .control, time: 1.5))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: empty, modifiers: .control, time: 1.55))
        expectEqual(editor.revision, revision)
        editor.add(Arrow(start: .free(CGPoint(x: 40, y: 300)), end: .free(CGPoint(x: 340, y: 300))))
        let subboard = editor.add(Subboard(frame: CGRect(x: 400, y: 40, width: 240, height: 160)), title: "Ship")
        // Every shipped shape has something to offer (Cut, Copy, Lock, Delete, at least); empty canvas
        // on a board with shapes, Select All.
        expectEqual(try require(canvas.menu(for: window.mouse(.rightMouseDown, at: empty, time: 2))).outline, ["Select All"])
        let menu = try require(canvas.menu(for: window.mouse(.rightMouseDown, at: card, time: 2.5)))
        expectEqual(menu.outline.first, "Open")
        expectEqual(menu.outline.last, "Delete")
        expectEqual(editor.selectedShapeIDs, [subboard])
        expect(canvas.menu(for: window.mouse(.leftMouseDown, at: card, modifiers: .control, time: 4)) != nil)
        // An arrow's menu is the clipboard's (nothing to paste yet), Lock, its colors and Delete: Arrange leaves
        // out what's painted by anchor.
        expectEqual(try require(canvas.menu(for: window.mouse(.rightMouseDown, at: arrow, time: 5))).outline,
                    ["Cut", "Copy", "Duplicate", "—", "Lock", "Color ▸", "  Gray", "  Red", "  Orange", "  Yellow", "  Green", "  Teal", "  Blue", "  Indigo", "  Purple", "  Pink", "  —", "  ✓ None", "—", "Delete"])
        // Asked with some other event (the accessibility Show Menu action), there's no click to go by.
        let key = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 5, windowNumber: window.windowNumber,
                                               context: nil, characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46))
        expect(canvas.menu(for: key) == nil)
    },
    test("in the hand tool, a Control-press is a press with ⌃: no menu, and its drag pans") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        editor.add(Subboard(frame: CGRect(x: 400, y: 40, width: 240, height: 160)), title: "Ship")
        window.press("h")
        let down = window.mouse(.leftMouseDown, at: CGPoint(x: 520, y: 140), modifiers: .control, time: 1)
        expect(canvas.menu(for: down) == nil)
        let origin = editor.camera.origin
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 700, y: 400), modifiers: .control, time: 1.2))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 700, y: 400), modifiers: .control, time: 1.3))
        expect(editor.camera.origin != origin, "it panned")
        expectEqual(editor.selectedShapeIDs, [])
    },
    test("an arrow key from the keyboard nudges the selection; with nothing selected it, a letter no tool has and Page Down go no further than the canvas") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let spy = ResponderSpy()
        canvas.nextResponder = spy
        window.makeFirstResponder(canvas)
        let arrowKey: NSEvent.ModifierFlags = [.function, .numericPad]
        let note = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Here"))
        editor.selection = note
        window.press("\u{F703}", code: 124, modifiers: arrowKey)
        window.press("\u{F701}", code: 125, modifiers: arrowKey.union(.shift))
        expectEqual(editor.document[note]?.box?.origin, CGPoint(x: 1, y: 10))
        editor.selection = nil
        window.press("\u{F703}", code: 124, modifiers: arrowKey)
        window.press("\u{F703}", code: 124, modifiers: arrowKey.union(.command))
        window.press("q", code: 12)
        window.press("\u{F72D}", code: 121, modifiers: .function)
        expectEqual(spy.heard, [], "AppKit's moves and typing stop at the canvas, so nothing beeps")
        window.press("\u{1b}", code: 53)
        expectEqual(spy.heard, [], "Escape is the canvas's too")
        expectEqual(editor.document[note]?.box?.origin, CGPoint(x: 1, y: 10))
    },
])

@MainActor let panningViewTests = Suite("Panning the canvas view", [
    test("Space held on the canvas holds the hand, the note tool staying; its key-up, the canvas losing the keyboard or the window stopping being key let go") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        window.makeFirstResponder(canvas)
        window.press("n", code: 45)
        window.press(" ", code: 49)
        expect(editor.isHandHeld)
        expectEqual(editor.cursor, .openHand)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), time: 1))
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 160, y: 140), time: 1.2))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 160, y: 140), time: 1.5))
        expectEqual(editor.camera.origin, CGPoint(x: -60, y: -40))
        expectEqual(editor.document.shapes, [], "no note placed")
        window.sendEvent(try require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber,
                                                      context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
        expect(!editor.isHandHeld)
        expectEqual(editor.currentToolID, ToolID(placing: StickyNote.kind), "the tool stayed")
        window.press(" ", code: 49)
        window.makeFirstResponder(nil)
        expect(!editor.isHandHeld, "the canvas lost the keyboard")
        window.makeFirstResponder(canvas)
        window.press(" ", code: 49)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        expect(!editor.isHandHeld, "the window stopped being key")
    },
    test("Space let go while ⌘ is held, whose release NSApplication keeps from the window, or while a menu tracks, lets go of the hand") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        window.makeFirstResponder(canvas)
        window.press(" ", code: 49)
        expect(editor.isHandHeld)
        NSApp.sendEvent(try require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 2, windowNumber: window.windowNumber,
                                                     context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
        expect(!editor.isHandHeld, "let go with ⌘ held (a ⌘-scroll zoom while panning)")
        window.press(" ", code: 49)
        expect(editor.isHandHeld)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        expect(!editor.isHandHeld, "a menu's loop takes the key's release")
        expect(window.isVisible == false && window.firstResponder === canvas, "the canvas kept the keyboard")
    },
    test("a middle-button pan begun and released over the note being edited leaves nothing hovered there, and editing goes on") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Pan"))
        editor.selection = note
        expect(editor.beginEditing(note))
        let text = CGPoint(x: 200, y: 200)
        canvas.mouseMoved(with: window.mouse(.mouseMoved, at: text, time: 1))
        expectEqual(editor.pointerOverCanvas, nil, "over the text, off the canvas")
        canvas.otherMouseDown(with: try middleButton(window.mouse(.otherMouseDown, at: text, time: 1.1)))
        canvas.otherMouseDragged(with: try middleButton(window.mouse(.otherMouseDragged, at: CGPoint(x: 220, y: 210), time: 1.2)))
        expectEqual(editor.camera.origin, CGPoint(x: -20, y: -10))
        canvas.otherMouseUp(with: try middleButton(window.mouse(.otherMouseUp, at: CGPoint(x: 220, y: 210), time: 1.3)))
        expectEqual(editor.hovered, nil)
        expectEqual(editor.pointerOverCanvas, nil, "no port dots around the note")
        expectEqual(editor.editingShapeID, note)
        canvas.mouseMoved(with: window.mouse(.mouseMoved, at: CGPoint(x: 225, y: 212), time: 1.4))
        expectEqual(editor.pointerOverCanvas, nil, "still over its text")
    },
    test("a left press during a middle-button pan ends the pan and is the press: its drag moves what it pressed, and the middle button's release doesn't end it") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Pan"))
        editor.selection = note
        window.makeFirstResponder(canvas)
        canvas.otherMouseDown(with: try middleButton(window.mouse(.otherMouseDown, at: CGPoint(x: 150, y: 150), time: 1)))
        canvas.otherMouseDragged(with: try middleButton(window.mouse(.otherMouseDragged, at: CGPoint(x: 160, y: 150), time: 1.1)))
        expectEqual(editor.camera.origin, CGPoint(x: -10, y: 0))
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 160, y: 150), time: 1.2))
        canvas.otherMouseUp(with: try middleButton(window.mouse(.otherMouseUp, at: CGPoint(x: 160, y: 150), time: 1.3)))
        expect(editor.session != nil, "the left press goes on")
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 170), time: 1.4))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 200, y: 170), time: 1.5))
        expectEqual(editor.camera.origin, CGPoint(x: -10, y: 0), "the pan ended at the left press")
        expectEqual(editor.document[note]?.box?.origin, CGPoint(x: 140, y: 120), "the drag moved the note")
        expectEqual(editor.editingShapeID, nil, "a drag, not a click that edits")
        expectEqual(editor.undoHistory.undoName, "Move")
        // The other order: the left press let go first; the middle button's drags and release are dropped.
        canvas.otherMouseDown(with: try middleButton(window.mouse(.otherMouseDown, at: CGPoint(x: 600, y: 500), time: 2)))
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 600, y: 500), time: 2.1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 600, y: 500), time: 2.2))
        let camera = editor.camera
        canvas.otherMouseDragged(with: try middleButton(window.mouse(.otherMouseDragged, at: CGPoint(x: 650, y: 520), time: 2.3)))
        canvas.otherMouseUp(with: try middleButton(window.mouse(.otherMouseUp, at: CGPoint(x: 650, y: 520), time: 2.4)))
        expectEqual(editor.camera, camera, "the middle button's pan ended at the left press")
        expect(editor.session == nil)
    },
    test("a middle-button drag pans the canvas, whatever the tool") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        window.press("n", code: 45)
        @MainActor func middle(_ type: CGEventType, _ point: CGPoint) throws -> NSEvent {
            try require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center).flatMap(NSEvent.init(cgEvent:)))
        }
        canvas.otherMouseDown(with: try middle(.otherMouseDown, CGPoint(x: 300, y: 300)))
        canvas.otherMouseDragged(with: try middle(.otherMouseDragged, CGPoint(x: 350, y: 330)))
        expectEqual(editor.camera.origin, CGPoint(x: -50, y: -30), "a Quartz point's y is down, as the canvas's is")
        canvas.otherMouseUp(with: try middle(.otherMouseUp, CGPoint(x: 350, y: 330)))
        expectEqual(editor.document.shapes, [], "no note placed")
        expectEqual(editor.currentToolID, ToolID(placing: StickyNote.kind))
    },
])

/// `event` (a mouse event made for a window) as the middle button's: button 2, where it was. (Made
/// through a Quartz event, which has no window: its location is put where the window's would be.)
@MainActor func middleButton(_ event: NSEvent) throws -> NSEvent {
    let cg = try require(event.cgEvent)
    cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    // Quartz's y is down, so the Cocoa y it reads as goes up as it goes down.
    let off = try require(NSEvent(cgEvent: cg)).locationInWindow.y - event.locationInWindow.y
    cg.location.y += off
    let middle = try require(NSEvent(cgEvent: cg))
    expectEqual(middle.buttonNumber, 2)
    expectEqual(middle.locationInWindow, event.locationInWindow)
    return middle
}

/// The canvas's next responder, in place of the window: what the canvas passes on.
final class ResponderSpy: NSResponder {
    var heard: [String] = []
    override func doCommand(by selector: Selector) { heard.append(NSStringFromSelector(selector)) }
    override func insertText(_ insertString: Any) { heard.append("insertText:") }
    override func keyDown(with event: NSEvent) { heard.append("keyDown:") }
    override func noResponder(for eventSelector: Selector) { heard.append("noResponder: \(NSStringFromSelector(eventSelector))") }
}
