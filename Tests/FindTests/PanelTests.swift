import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Find
import Geometry
import Keyboard
import Selection
import SwiftUI
import TestKit
import Topology

/// The canvas beside the detail panel, Find's panel in its takeover slot, as Composition places
/// them, in an unshown window: the real `TaskScheduler`, so the panel's updates and the index's
/// slices land while the main run loop runs.
@MainActor
final class FindWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView
    let hosting: NSView
    private(set) var exits = 0
    private var time: TimeInterval = 1

    init(_ file: CanvasFile) throws {
        editor = CanvasEditor(registry: try Registry(plugins: findPlugins()), file: file, scheduler: TaskScheduler())
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 1000 - DetailStyle.idealWidth, height: 700)
        let editor = editor
        var exit: @MainActor () -> Void = {}
        let panel = DetailPanelView(editor: editor, onExit: { exit() }, takeover: DetailTakeover(isActive: { $0.find?.isActive ?? false },
                                                                                              onEscape: { editor.find?.close() }) {
            FindPanel(editor: editor, onExit: { exit() })
        })
        hosting = NSHostingView(rootView: panel)
        hosting.frame = CGRect(x: 1000 - DetailStyle.idealWidth, y: 0, width: DetailStyle.idealWidth, height: 700)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        // Weak: the panel may hand the keyboard back a turn after the test let this go.
        exit = { [weak self] in
            guard let self else { return }
            exits += 1
            window.makeFirstResponder(canvas)
        }
        window.makeFirstResponder(canvas)
        window.settle()
    }

    var find: FindState { editor.find! }
    var field: NSTextField? { hosting.descendants(NSTextField.self).first { $0.isEditable && $0.placeholderString == "Find" } }
    var fieldHasKeyboard: Bool {
        guard let editor = window.firstResponder as? NSTextView, let field else { return false }
        return editor.delegate === field
    }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }

    /// ⌘F on the canvas, as the canvas answers it.
    func commandF() {
        window.makeFirstResponder(canvas)
        _ = canvas.performKeyEquivalent(with: window.keyEvent("f", code: 3, modifiers: .command))
    }

    /// The rows' buttons, top first: under the header, as tall as a row.
    var rows: [NSButton] {
        hosting.descendants(NSButton.self)
            .filter { $0.convert($0.bounds, to: hosting).height >= 30 }
            .sorted { $0.convert($0.bounds, to: hosting).minY < $1.convert($1.bounds, to: hosting).minY }
    }

    /// Done: the button at the header's trailing end, on the field's line (SwiftUI's buttons' titles
    /// are views of their own).
    var done: NSButton? {
        hosting.descendants(NSButton.self).filter { $0.convert($0.bounds, to: hosting).maxY < 30 }
            .max { $0.convert($0.bounds, to: hosting).maxX < $1.convert($1.bounds, to: hosting).maxX }
    }

    /// A press and its release where a click on a view's middle lands, as the window sends them
    /// (`sendEvent`'s mouse-downs don't reach views in an unshown window, so they're handed over).
    func click(_ view: NSView) throws {
        guard let top = window.contentView?.superview else { return }
        let location = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let target = try require(top.hitTest(location))
        time += 0.5
        func event(_ type: NSEvent.EventType, at time: TimeInterval) throws -> NSEvent {
            try require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApplication.shared.postEvent(try event(.leftMouseUp, at: time + 0.05), atStart: true)
        target.mouseDown(with: try event(.leftMouseDown, at: time))
        if let up = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) {
            target.mouseUp(with: up)
        }
    }
}

@MainActor let panelTests = Suite("Find's panel", [
    test("⌘F takes the panel over and gives its field the keyboard; typing searches; Return and ⇧Return step") {
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(["pear one", "pear two", "plum"]))))
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        expect(w.find.isActive)
        w.window.type("pear")
        w.window.spin { w.find.total == 2 && w.find.isSettled }
        expectEqual(w.find.query, "pear")
        expectEqual(w.find.currentNumber, 1)
        w.window.pressReturn()
        w.window.spin { w.find.currentNumber == 2 }
        w.window.press("\r", code: 36, modifiers: .shift)
        w.window.spin { w.find.currentNumber == 1 }
        expect(w.fieldHasKeyboard, "stepping keeps the keyboard in the field")
        expectEqual(w.editor.currentToolID, .select, "typing never switched tools")
    },
    test("Escape in the field closes Find and gives the canvas the keyboard; the next ⌘F selects what's typed") {
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(["pear"]))))
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pear")
        w.window.spin { w.find.total == 1 }
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(!w.find.isActive)
        expectEqual(w.exits, 1)
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        let text = try require(w.window.firstResponder as? NSTextView)
        w.window.spin { text.selectedRange() == NSRange(location: 0, length: 4) }
    },
    test("Escape on the canvas and a click on a shape leave Find open; ⌘. in the field closes it") {
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(["pear"]))))
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.makeFirstResponder(w.canvas)
        w.window.pressEscape()
        w.window.settle()
        expect(w.find.isActive, "the canvas's own Escape")
        let memo = try require(w.editor.document.shapes.first?.id)
        w.canvas.mouseDown(with: w.window.mouse(.leftMouseDown, at: CGPoint(x: 150, y: 120), time: 5))
        w.canvas.mouseUp(with: w.window.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 120), time: 5.05))
        w.window.settle()
        expectEqual(w.editor.selectedShapeIDs, [memo], "the click selects")
        expect(w.find.isActive, "and Find stays, its panel in the selection's place")
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.pressCommandPeriod()
        w.window.spin { w.canvasHasKeyboard }
        expect(!w.find.isActive)
    },
    test("a row clicked makes its shape's hit current and keeps the keyboard in the field; Done closes") {
        let pockets = PocketFile(root: ["pear one", "pear two"], inA: ["pear three"], inA1: [], inB: [])
        let w = try FindWindow(pockets.file)
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pear")
        w.window.spin { w.find.total == 3 && w.find.isSettled }
        w.window.spin { w.rows.count == 3 }
        try w.click(w.rows[1])
        w.window.spin { w.find.currentHit?.shape == pockets.root[1].id }
        expect(w.fieldHasKeyboard, "the field keeps the keyboard")
        let done = try require(w.done, "\(w.hosting.descendants(NSButton.self).map { $0.convert($0.bounds, to: w.hosting) })")
        done.performClick(nil)
        w.window.spin { w.canvasHasKeyboard }
        expect(!w.find.isActive)
    },
    test("No matches for a query nothing matches") {
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(["pear"]))))
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("zzzz")
        w.window.spin { w.find.isSettled && w.find.query == "zzzz" }
        expect(w.find.results.isEmpty)
        expectEqual(w.find.total, 0)
        expect(w.rows.isEmpty)
    },
    test("Return while an input method is composing is the method's: it doesn't step") {
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(["pear one", "pear two"]))))
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pea")
        w.window.spin { w.find.total == 2 && w.find.isSettled }
        expectEqual(w.find.currentNumber, 1)
        let editor = try require(w.window.firstResponder as? NSTextView)
        editor.setMarkedText("r", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(editor.hasMarkedText())
        w.window.pressReturn()
        w.window.settle()
        expectEqual(w.find.currentNumber, 1, "composing: Return stepped nothing")
        editor.unmarkText()
        w.window.pressReturn()
        w.window.spin { w.find.currentNumber == 2 }
    },
    test("a row's snippet starts and ends on whole characters: an emoji's surrogate pair is never cut") {
        let face = "\u{1F600}"      // two UTF-16 units
        /// Whether `range` of `text` starts and ends between characters.
        func isWhole(_ range: Range<Int>, of text: String) -> Bool {
            let whole = NSRange(location: range.lowerBound, length: range.count)
            return (text as NSString).rangeOfComposedCharacterSequences(for: whole) == whole
        }
        // The start: 24 units before the hit is the middle of the 13th face (pairs start on even units).
        let early = String(repeating: face, count: 30) + "xpear"
        let earlyHit = 61..<65
        let start = FindSnippet.range(in: early, around: earlyHit)
        expectEqual(start.lowerBound, 36, "back to the pair's start, not into its middle (37)")
        expect(isWhole(start, of: early))
        // The end: 120 units on from the start is the middle of a face (pairs start on odd units).
        let late = "x" + String(repeating: face, count: 100)
        let end = FindSnippet.range(in: late, around: 0..<1)
        expectEqual(end.upperBound, 121, "on to the pair's end, not its middle (120)")
        expect(isWhole(end, of: late))
        // Text with no emoji is cut where it always was.
        let plain = String(repeating: "a", count: 300)
        expectEqual(FindSnippet.range(in: plain, around: 100..<104), 76..<196)
    },
])
