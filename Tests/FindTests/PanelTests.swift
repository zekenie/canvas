import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Find
import Selection
import SwiftUI
import TestKit

/// The canvas beside the detail panel, Find's panel taking it over while Find is open
/// (`FindPanelPlugin`), as the app has them, in an unshown window: the real `TaskScheduler`, so the
/// panel's updates and the index's slices land while the main run loop runs.
@MainActor
final class FindWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView
    private(set) var hosting: NSView!
    private(set) var exits = 0
    private var time: TimeInterval = 1

    init(_ file: CanvasFile, more: [any CanvasPlugin] = []) throws {
        editor = CanvasEditor(registry: try Registry(plugins: findPlugins(more: [DetailPanelPlugin(), FindPanelPlugin()] + more)), file: file,
                              scheduler: TaskScheduler())
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 1000 - DetailStyle.idealWidth, height: 700)
        // Weak: the panel may hand the keyboard back a turn after the test let this go.
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: { [weak self] in
            guard let self else { return }
            exits += 1
            window.makeFirstResponder(canvas)
        }))
        hosting.frame = CGRect(x: 1000 - DetailStyle.idealWidth, y: 0, width: DetailStyle.idealWidth, height: 700)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
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
    test("a shape's name in its row is given its own width up to the cap, so a long one is cut in the middle inside it, never run on past it") {
        let short = FindStyle.rowNameWidth("orders API"), long = FindStyle.rowNameWidth(String(repeating: "customer_billing_address ", count: 2))
        expect(short > 20 && short < FindStyle.rowNameMost, "a short name keeps its own width: \(short)")
        expectEqual(long, FindStyle.rowNameMost, "a long one is held to the cap")
    },
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
    test("Up, Down, Page Up and Page Down in the field walk the results, wrapping, and change neither the selection nor the document") {
        let bodies = (1...12).map { "pear \($0)" }
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(bodies))))
        let keys = KeyDriver(w.window)
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pear")
        w.window.spin { w.find.total == 12 && w.find.isSettled }
        let first = try require(w.find.found.first)
        w.editor.selectedShapeIDs = [first]
        let before = w.editor.file
        expectEqual(w.find.currentNumber, 1)
        expect(!keys.send(.down).isUnhandled)
        w.window.spin { w.find.currentNumber == 2 }
        keys.send(.up)
        w.window.spin { w.find.currentNumber == 1 }
        keys.send(.up)
        w.window.spin { w.find.currentNumber == 12 }
        keys.send(.down)
        w.window.spin { w.find.currentNumber == 1 }
        keys.send(Chord(.pageDown))
        w.window.spin { w.find.currentNumber == 1 + 8 }
        keys.send(Chord(.pageUp))
        w.window.spin { w.find.currentNumber == 1 }
        keys.send(Chord(.pageUp))
        w.window.spin { w.find.currentNumber == 12 - 8 + 1 }
        expect(w.fieldHasKeyboard, "the field keeps the keyboard")
        expectEqual(w.editor.selectedShapeIDs, [first], "stepping selects nothing")
        expectEqual(w.editor.file, before, "and changes no document")
        expectEqual(w.editor.currentToolID, .select)
    },
    test("every row reads its text, kind, board and hit's number, and each step announces where it went") {
        let pockets = PocketFile(root: ["pear one", "pear two"], inA: ["pear three"], inA1: [], inB: [])
        let w = try FindWindow(pockets.file)
        let keys = KeyDriver(w.window)
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pear")
        w.window.spin { w.find.total == 3 && w.find.isSettled && w.rows.count == 3 }
        // SwiftUI's accessibility tree isn't built in an unshown window (the rows' buttons report no
        // label), so what the panel hands VoiceOver is read from Find's state, which it labels from.
        expectEqual((0..<3).map { w.find.rowLabel(of: $0) },
                    ["pear one, memo, hit 1 of 3", "pear two, memo, hit 2 of 3", "pear three, memo, hit 3 of 3"],
                    "a board with no name isn't said")
        expectEqual(w.find.announcement, "Hit 1 of 3, memo, pear one")
        expectEqual(w.find.stepCount, 0, "typing lands on a hit without a step, so VoiceOver is not talked over")
        keys.send(.down)
        w.window.spin { w.find.currentNumber == 2 }
        expectEqual(w.find.stepCount, 1, "a step is announced")
        expectEqual(w.find.rowLabel(of: 0), "pear one, memo, hit 1 of 3", "a row's label is the same asked again")
        expectEqual(w.find.announcement, "Hit 2 of 3, memo, pear two")
        keys.send(.down)
        w.window.spin { w.find.currentNumber == 3 }
        expectEqual(w.find.announcement, "Hit 3 of 3, memo, pear three")
    },
    test("⌘↩ closes Find, selects the hit's shape, gives the canvas the keyboard and adds one Back step; Escape, ⌘. and Done select nothing") {
        let pockets = PocketFile(root: ["pear one", "pear two"], inA: ["pear three"], inA1: [], inB: [])
        let w = try FindWindow(pockets.file)
        let keys = KeyDriver(w.window)
        @MainActor func open() {
            w.commandF()
            w.window.spin { w.fieldHasKeyboard }
            if w.find.query.isEmpty { w.window.type("pear") }
            w.window.spin { w.find.total == 3 && w.find.isSettled }
        }
        // The ways out that take nothing along.
        open()
        keys.send(.down)
        w.window.spin { w.find.currentNumber == 2 }
        keys.send(.escape)
        w.window.spin { w.canvasHasKeyboard }
        expect(!w.find.isActive)
        expectEqual(w.editor.selectedShapeIDs, [])
        open()
        keys.send(.commandPeriod)
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.editor.selectedShapeIDs, [])
        open()
        try require(w.done).performClick(nil)
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.editor.selectedShapeIDs, [], "Done")
        // ⌘↩ takes the hit along: on this board, then on another.
        open()
        keys.send(.up)
        w.window.spin { w.find.currentNumber == 3 }
        expectEqual(w.editor.board, pockets.aBoard, "stepping showed the hit's board")
        keys.send(Chord(.down))
        w.window.spin { w.find.currentNumber == 1 }
        keys.send(.commandReturn)
        w.window.spin { w.canvasHasKeyboard }
        expect(!w.find.isActive)
        expectEqual(w.editor.selectedShapeIDs, [pockets.root[0].id])
        expectEqual(w.editor.board, .root)
        keys.send(Chord("[", .command))     // Back: one step to where Find began
        w.window.settle()
        w.editor.goBack()
        expectEqual(w.editor.selectedShapeIDs, [], "one step back reaches where Find began")
        expect(!w.editor.canGoBack, "and there was one step")
    },
    test("⌘↩ on a hit on another board shows the board and selects the shape; Back returns to where Find began") {
        let pockets = PocketFile(root: ["plum"], inA: ["pear three"], inA1: [], inB: [])
        let w = try FindWindow(pockets.file)
        let keys = KeyDriver(w.window)
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pear")
        w.window.spin { w.find.total == 1 && w.find.isSettled }
        keys.send(.commandReturn)
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.editor.board, pockets.aBoard)
        expectEqual(w.editor.selectedShapeIDs, [pockets.inA[0].id])
        w.editor.goBack()
        expectEqual(w.editor.board, .root)
        expect(!w.editor.canGoBack)
    },
    test("Tab from the field never traps, and Escape gives the keyboard back") {
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(["pear one", "pear two"]))))
        let keys = KeyDriver(w.window)
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pear")
        w.window.spin { w.find.total == 2 && w.find.isSettled }
        let file = w.editor.file
        for _ in 0..<4 {
            keys.send(.tab)
            w.window.settle()
            expectEqual(w.editor.file, file)
        }
        keys.send(.escape)
        w.window.spin { w.canvasHasKeyboard }
        expect(!w.find.isActive)
    },
    test("FindPanelPlugin needs the detail panel, whose place it takes; Find alone needs neither") {
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailTakeovers", owner: .detailPanel, contributor: .findPanel)) {
            _ = try Registry(plugins: findPlugins(more: [FindPanelPlugin()]))
        }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear"]))))
        expectEqual(try search("pear", in: h).total, 1, "no panel, and Find finds as ever")
    },
    test("a row on another board is labeled with the board as a plugin calls it (the panel's board headings), and the board shown is not said") {
        let pockets = PocketFile(root: ["pear"], inA: ["pear"], inA1: [], inB: [])
        let naming = Contributor(id: "naming") { $0.boardHeading { board, _ in board.isRoot ? BoardHeading("Top") : BoardHeading("Pocket", systemImage: "tray") } }
        let h = try findHarness(pockets.file, more: [DetailPanelPlugin(), naming])
        let find = try search("pear", in: h)
        expectEqual(find.total, 2)
        expectEqual((0..<2).map { find.rowLabel(of: $0) }, ["pear, memo, hit 1 of 2", "pear, memo, Pocket, hit 2 of 2"])
        expectEqual(h.editor.boardHeading(of: pockets.aBoard), BoardHeading("Pocket", systemImage: "tray"), "the same heading the panel's rows have")
    },
    test("the panel heads each board's rows with the heading the editor gives, title and symbol") {
        let pockets = PocketFile(root: ["pear"], inA: ["pear"], inA1: [], inB: [])
        // The panel draws the heading as text (SwiftUI's, no view of its own), so it is read as pixels:
        // the same board headed another title, or another symbol, draws another picture.
        @MainActor func panel(_ title: String, _ symbol: String?) throws -> NSBitmapImageRep {
            let naming = Contributor(id: "naming") { $0.boardHeading { board, _ in board.isRoot ? BoardHeading("Top") : BoardHeading(title, systemImage: symbol) } }
            let w = try FindWindow(pockets.file, more: [naming])
            w.commandF()
            w.window.spin { w.fieldHasKeyboard }
            w.window.type("pear")
            w.window.spin { w.find.total == 2 && w.find.isSettled }
            w.window.settle()
            return snapshot(w.hosting)
        }
        let list = try panel("Pocket", "tray")
        let bounds = CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 700)
        expectEqual(changedPixels(list, try panel("Pocket", "tray"), in: bounds), 0, "drawn the same each time")
        expect(changedPixels(list, try panel("Cabin", "tray"), in: bounds) > 0, "another title is another picture")
        expect(changedPixels(list, try panel("Pocket", nil), in: bounds) > 0, "no symbol is another picture")
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
    test("a titled shape's row leads with its name, the snippet of a hit elsewhere in it after it; a hit in the name is the snippet alone") {
        // Every memo named "Basket" by a contribution that names its shapes, as a title does.
        let naming = Contributor(id: "basket-names") { registrar in
            registrar.findableTexts("name", of: Memo.self, names: true, texts: { _, _ in [FindableText(field: "name", text: "Basket")] },
                                    rects: { _, _, ranges, _ in ranges.map { _ in [] } })
        }
        let w = try FindWindow(CanvasFile(root: CanvasDocument(shapes: memos(["pear one"]))), more: [naming])
        w.commandF()
        w.window.spin { w.fieldHasKeyboard }
        w.window.type("pear")
        w.window.spin { w.find.total == 1 && w.find.isSettled && w.rows.count == 1 }
        let result = try require(w.find.results.first)
        expectEqual(w.find.rowName(of: result), "Basket")
        expectEqual(String(FindSnippet.named("Basket", of: result, in: w.find).characters), "Basket  pear one")
        expectEqual(String(FindSnippet.faint(of: result, in: w.find).characters), "pear one", "the snippet is a text of its own, which a long name never cuts away")
        expectEqual(w.find.rowLabel(of: 0), "Basket, pear one, memo, hit 1 of 1", "VoiceOver hears the name first too")
        w.find.query = "bask"
        w.window.spin { w.find.total == 1 && w.find.isSettled }
        expectEqual(w.find.rowName(of: try require(w.find.results.first)), nil, "the hit is in the name: the snippet shows it")
    },
])
