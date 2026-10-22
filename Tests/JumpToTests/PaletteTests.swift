import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import JumpTo
import Selection
import SwiftUI
import TestKit
import TextEditing

// The palette in a window: the canvas with the palette over it, as the app's chrome puts it, in an
// unshown window. The editor keeps a manual clock, so what lands is SwiftUI's updates (`window.spin`).

private struct PaletteHost: View {
    let editor: CanvasEditor
    let focus: CanvasFocus

    var body: some View {
        CanvasRepresentable(editor: editor, focus: focus)
            .overlay { JumpToPalette(editor: editor, onExit: focus.take) }
            .transaction { $0.disablesAnimations = true }
    }
}

@MainActor
private final class PaletteWindow {
    let h: EditorHarness
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    let focus = CanvasFocus()
    let host: NSHostingView<PaletteHost>
    let canvas: CanvasView
    var editor: CanvasEditor { h.editor }
    var state: JumpToState { h.jump }

    init(file: CanvasFile = storyFile()) throws {
        h = try EditorHarness(plugins: jumpPlugins(), file: file)
        host = NSHostingView(rootView: PaletteHost(editor: h.editor, focus: focus))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        canvas = try require(focus.canvas, "the representable hands its canvas view to the focus")
        window.settle()
        window.makeFirstResponder(canvas)
    }

    /// The palette's field, while it's open.
    var field: EditingTextView? { host.descendants(EditingTextView.self).first }
    var listWindow: CaretListWindow? { field?.caretListWindow }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }
    var fieldHasKeyboard: Bool { field.map { window.firstResponder === $0 } ?? false }

    /// ⌘K on the canvas, as the app's window gives it (the canvas's key equivalents, ahead of the menus),
    /// and the palette settled.
    func openWithKey() {
        window.makeFirstResponder(canvas)
        _ = canvas.performKeyEquivalent(with: window.keyEvent("k", code: 40, modifiers: .command))
        window.spin { self.fieldHasKeyboard }
    }

    func type(_ text: String) { window.type(text) }

    /// The field's frame from the canvas's top left, in points.
    var fieldFrame: CGRect? {
        guard let field else { return nil }
        let rect = host.convert(field.bounds, from: field)
        return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The field's rect on screen.
    var fieldOnScreen: CGRect? { field.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } }

    /// What a click at a point on the canvas (from its top left) would land on.
    func hit(_ point: CGPoint) -> NSView? {
        guard let frame = host.superview else { return nil }
        let inWindow = host.convert(CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y), to: nil)
        return host.hitTest(frame.convert(inWindow, from: nil))
    }

    func isCanvas(_ view: NSView?) -> Bool { view.map { $0 === canvas || $0.isDescendant(of: canvas) } ?? false }

    /// The scrim: the button over the whole canvas.
    var scrim: NSButton? { host.descendants(NSButton.self).first { $0.convert($0.bounds, to: host).width >= 900 } }

    var titles: [String] { state.rows.compactMap { $0.candidate?.title } }
}

private let arrowDown = "\u{F701}", arrowUp = "\u{F700}"

@MainActor let paletteTests = Suite("Jump To's palette", [
    test("the palette is one of the views the window puts over the canvas: over the whole of it, over the path, covering nothing a fit minds") {
        let registry = try Registry(plugins: jumpPlugins())
        expectEqual(registry.hostOverlays.map(\.alignment), [.top, .center], "Boards' path, then the palette over it")
        let palette = try require(registry.hostOverlays.last)
        expectEqual(palette.coveredTop(BoardID(owner: ShapeID())), 0)
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("jump-to ") })
        expect(line.hasSuffix(" host overlay"), String(line))
    },
    test("⌘K on the canvas opens it: a capsule at the top middle, 12 points down, its field with the keyboard and its placeholder, and nothing else") {
        let w = try PaletteWindow()
        expect(w.field == nil, "closed, it's nothing")
        w.openWithKey()
        expect(w.state.isOpen && w.fieldHasKeyboard && !w.canvasHasKeyboard)
        let field = try require(w.field)
        expectEqual(field.placeholder, "Jump To")
        let frame = try require(w.fieldFrame)
        expectClose(frame.midX, 500, within: 1)
        expectClose(frame.minY, 12, within: 1)
        expectClose(frame.width, 560 - 32, within: 1)
        expectEqual(w.state.top, 12)
        // Empty, it lists what's nearby on the root (the story's four titled shapes in view).
        expectEqual(w.state.rows.compactMap { $0.candidate?.title }, ["Delta", "Planned notes", "Plan note one", "Alpha"])
    },
    test("it's below what the host covers of the canvas's top, as that was as it opened") {
        let w = try PaletteWindow()
        w.editor.coveredTop = { _ in 35 }
        w.openWithKey()
        let frame = try require(w.fieldFrame)
        expectClose(frame.minY, 35 + 12, within: 1)
        w.editor.coveredTop = { _ in 80 }
        w.window.settle()
        expectClose(try require(w.fieldFrame).minY, 35 + 12, within: 1)
    },
    test("its list is the app's caret list under the capsule, as wide as it, its rows' count and look the list's") {
        let w = try PaletteWindow()
        w.openWithKey()
        let list = try require(w.listWindow)
        let capsule = try require(w.fieldOnScreen).insetBy(dx: -16, dy: 0)
        expectEqual(list.frame.width, 560)
        expectClose(list.frame.midX, capsule.midX, within: 1)
        expectClose(list.frame.maxY, capsule.minY - 6, within: 1)
        expect(!list.isVisible, "an unshown window's list is placed, never ordered in")
        w.type("checkout")
        expectEqual(w.state.query, "checkout")
        expectEqual(list.list.rows.count, 4)
        expectClose(list.frame.height, 4 * 28 + 10, within: 0.5)
        expectClose(list.frame.maxY, capsule.minY - 6, within: 1)
        expect(list.list === w.state.list)
        // Past ten rows it scrolls.
        let many = try PaletteWindow(file: CanvasFile(root: CanvasDocument(shapes: (0..<30).map { shape(1000 + $0, Box(frame(CGFloat($0) * 10, 0)), titled: "Item \($0)") })))
        many.openWithKey()
        many.type("item")
        expectClose(try require(many.listWindow).frame.height, 10 * 28 + 10, within: 0.5)
    },
    test("typing narrows the list as the field changes, and what's typed is one line") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("alpha gamma")
        expectEqual(w.titles, ["Gamma"], "Gamma, in Alpha › Beta, as a title alone")
        w.type(" checkout")
        expectEqual(w.titles, ["Checkout", "Checkout"])
        expectEqual(w.state.rows.compactMap { $0.candidate?.pathText }, ["Alpha › Beta › Gamma", "Alpha › Beta › Gamma › Epsilon"])
        let field = try require(w.field)
        field.string = "alpha\n\tgamma checkout"
        field.didChangeText()
        expectEqual(field.string, "alpha  gamma checkout")
        expectEqual(w.state.query, "alpha  gamma checkout")
        field.string = ""
        field.didChangeText()
        expect(w.state.rows.contains { if case .header = $0 { true } else { false } }, "empty again: what's nearby")
    },
    test("↓ ↑ ⌃N ⌃P move through the rows, wrapping, and Return picks the highlighted one: the palette closes, its shape is followed, the canvas has the keyboard") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("checkout")
        expectEqual(w.state.list.highlighted, 0)
        w.window.press(arrowDown, code: 125, modifiers: [.numericPad, .function])
        expectEqual(w.state.list.highlighted, 1)
        w.window.press("n", code: 45, modifiers: .control)
        expectEqual(w.state.list.highlighted, 2)
        w.window.press("p", code: 35, modifiers: .control)
        expectEqual(w.state.list.highlighted, 1)
        w.window.press(arrowUp, code: 126, modifiers: [.numericPad, .function])
        w.window.press(arrowUp, code: 126, modifiers: [.numericPad, .function])
        expectEqual(w.state.list.highlighted, 3, "wrapped to the last")
        w.window.pressReturn()
        expect(!w.state.isOpen)
        expectEqual(w.editor.board, BoardID(owner: id(23)), "the last Checkout, in Epsilon's board")
        expectEqual(w.editor.selectedShapeIDs, [id(31)])
        w.window.spin { w.field == nil && w.canvasHasKeyboard }
        expect(w.field == nil && w.canvasHasKeyboard, "the palette is gone and the canvas has the keyboard")
        expectEqual(w.state.recent, [id(31)])
        w.editor.goBack()
        expectEqual(w.editor.board, .root, "one step back")
    },
    test("Page Down and Page Up move a page of rows, stopping at the ends") {
        let w = try PaletteWindow(file: CanvasFile(root: CanvasDocument(shapes: (0..<30).map { shape(1000 + $0, Box(frame(CGFloat($0) * 10, 0)), titled: "Item \($0)") })))
        w.openWithKey()
        w.type("item")
        w.window.press("\u{F72D}", code: 121, modifiers: [.numericPad, .function])
        expectEqual(w.state.list.highlighted, 10)
        w.window.press("\u{F72D}", code: 121, modifiers: [.numericPad, .function])
        w.window.press("\u{F72D}", code: 121, modifiers: [.numericPad, .function])
        w.window.press("\u{F72D}", code: 121, modifiers: [.numericPad, .function])
        expectEqual(w.state.list.highlighted, 29, "stopped at the end")
        w.window.press("\u{F72C}", code: 116, modifiers: [.numericPad, .function])
        expectEqual(w.state.list.highlighted, 19)
    },
    test("Tab picks too; Return and Tab with nothing to pick insert nothing and leave it open") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("alpha")
        w.window.press("\t", code: 48)
        expect(!w.state.isOpen)
        expectEqual(w.editor.board, BoardID(owner: id(1)), "Alpha is a pocket: gone into")
        w.editor.goBack()
        w.openWithKey()
        w.type("zzzz")
        expectEqual(w.state.rows.count, 1)
        w.window.pressReturn()
        w.window.press("\t", code: 48)
        expect(w.state.isOpen)
        expectEqual(w.field?.string, "zzzz", "no new line, no tab")
        expect(w.fieldHasKeyboard)
    },
    test("⇧Tab moves the highlight up, wrapping, and the palette stays open") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("a")
        let rows = w.state.rows.count
        expect(rows > 1)
        expectEqual(w.state.list.highlighted, 0)
        w.window.press(.backTab)
        expect(w.state.isOpen && w.fieldHasKeyboard)
        expectEqual(w.state.list.highlighted, rows - 1, "up from the first wraps")
        w.window.press(.backTab)
        expectEqual(w.state.list.highlighted, rows - 2)
        w.window.press(.tab)
        expect(!w.state.isOpen, "Tab picks the highlighted row")
    },
    test("Escape closes it and gives the canvas the keyboard; so does ⌘.; neither goes anywhere") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("alpha")
        w.window.pressEscape()
        expect(!w.state.isOpen)
        w.window.spin { w.field == nil && w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard && w.field == nil)
        expectEqual(w.editor.board, .root)
        expectEqual(w.state.query, "", "what was typed goes with it")
        w.openWithKey()
        expectEqual(w.state.query, "")
        w.window.pressCommandPeriod()
        expect(!w.state.isOpen)
        w.window.spin { w.field == nil && w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard)
        expectEqual(w.editor.board, .root)
        expectEqual(w.state.recent, [])
    },
    test("⌘K while it's open asks for the keyboard again and selects what's typed") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("alpha")
        let field = try require(w.field)
        field.setSelectedRange(NSRange(location: 2, length: 0))
        expect(w.editor.perform(.jumpTo))
        w.window.settle()
        expect(w.state.isOpen && w.fieldHasKeyboard)
        expectEqual(field.selectedRange(), NSRange(location: 0, length: 5))
        expectEqual(w.state.query, "alpha")
        // The canvas's key, with the palette open, is the menu bar's: the field has the keyboard.
        w.window.type("x")
        expectEqual(w.state.query, "x", "typing replaces the selection")
    },
    test("it closes once anything else takes the keyboard (Find's field, the panel's), which keeps it") {
        let w = try PaletteWindow()
        w.openWithKey()
        let other = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        w.host.addSubview(other)
        w.window.makeFirstResponder(other)
        expect(!w.state.isOpen)
        expect(w.window.firstResponder is NSText, "the other field has the keyboard, not the canvas")
        w.window.spin { w.field == nil }
        expect(w.field == nil)
        other.removeFromSuperview()
    },
    test("a scrim covers the canvas while it's open: a click lands on it, not the canvas, closes the palette and goes no further") {
        let w = try PaletteWindow()
        expect(w.isCanvas(w.hit(CGPoint(x: 150, y: 150))), "closed: a click is the canvas's")
        w.openWithKey()
        w.window.settle()
        // Over a shape (Alpha, at 90, 100) and over empty canvas.
        for point in [CGPoint(x: 150, y: 150), CGPoint(x: 600, y: 600), CGPoint(x: 20, y: 680)] {
            expect(!w.isCanvas(w.hit(point)), "\(point): the scrim's")
        }
        expectEqual(w.editor.selectedShapeIDs, [])
        let scrim = try require(w.scrim, "no scrim button")
        scrim.performClick(nil)
        expect(!w.state.isOpen)
        expectEqual(w.editor.selectedShapeIDs, [], "the click didn't reach the canvas: Alpha isn't selected")
        expectEqual(w.editor.board, .root)
        w.window.spin { w.field == nil && w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "the canvas has the keyboard")
        expect(w.isCanvas(w.hit(CGPoint(x: 150, y: 150))), "closed again: the canvas's")
    },
    test("a click on a row picks it, as Return does; the pointer over a row highlights it") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("checkout")
        let list = try require(w.listWindow)
        let rows = try require(list.contentView?.descendants.first { $0.accessibilityRole() == .list })
        @MainActor func event(_ type: NSEvent.EventType, row: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: rows.convert(CGPoint(x: 200, y: CGFloat(row) * 28 + 14), to: nil), modifierFlags: [], timestamp: 1,
                               windowNumber: list.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        rows.mouseMoved(with: event(.mouseMoved, row: 2))
        expectEqual(w.state.list.highlighted, 2)
        rows.mouseDown(with: event(.leftMouseDown, row: 1))
        expect(!w.state.isOpen)
        expectEqual(w.editor.board, BoardID(owner: id(2)), "the second Checkout is Delta's: a box, on Delta's board")
        expectEqual(w.editor.selectedShapeIDs, [id(41)])
    },
    test("closed and opened again before the view has gone, it's the palette again: empty, with its list and the keyboard") {
        let w = try PaletteWindow()
        w.openWithKey()
        w.type("alp")
        w.window.pressEscape()
        expect(w.editor.perform(.jumpTo), "no turn of the run loop between")
        w.window.spin { w.fieldHasKeyboard }
        expect(w.state.isOpen && w.fieldHasKeyboard)
        expectEqual(w.field?.string, "", "what was typed went with the close")
        let list = try require(w.listWindow, "its list")
        expectEqual(list.list.rows.count, w.state.rows.count)
        w.type("delta")
        expectEqual(w.titles.first, "Delta")
        expectEqual(list.list.rows.count, w.state.rows.count, "following what's typed")
    },
    test("closing takes the list's window with it, at once; reopening starts empty, with what's recent first") {
        let w = try PaletteWindow()
        w.openWithKey()
        let list = try require(w.listWindow)
        w.window.pressEscape()
        expect(w.field?.caretListWindow == nil, "the field has let go of it")
        expect(list.parent == nil && !list.isVisible)
        w.window.spin { w.field == nil }
        w.editor.goBack()
        w.state.pick(id(41))
        w.editor.goBack()
        w.openWithKey()
        expectEqual(w.state.query, "")
        expectEqual(w.state.rows.first.map(EditorHarness.say), "# Recent")
    },
])
