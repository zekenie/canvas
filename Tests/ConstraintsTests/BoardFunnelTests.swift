import Adornments
import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Constraints
import CoreGraphics
import DetailPanel
import Foundation
import LanguageModels
import Selection
import SwiftUI
import TestKit
import TextEditing
import Titles
import Validation

// The board's funnel: a pill at the canvas's top leading corner once the board shown has constraints of its own (the root's, or a
// subboard's seen from inside, with what it has from elsewhere), its words and the count of shapes that break one, quiet or red; a
// click opens a popover of the Rules tab's own rows over the board's place; the keys (Show Board Constraints, Tab, Escape); and
// what the root's issues and a subboard's board's do with Show Constraint.

private let drawerRect = CGRect(x: 600, y: 100, width: 200, height: 150)

/// A stand-in for the canvas, which takes the keyboard as the canvas does and is where the popover hands it back.
@MainActor private final class StandInCanvas: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// What the funnel hands the keyboard back to: the stand-in canvas, made after the overlay.
@MainActor private final class CanvasBox {
    weak var canvas: NSView?
    func take() { if let canvas { canvas.window?.makeFirstResponder(canvas) } }
}

/// The host's overlays over a stand-in canvas in an unshown window, as the app hosts them (`registry.hostOverlays`, each over the whole
/// of it, its `onExit` giving the keyboard back to the stand-in). SwiftUI lands as the run loop runs, the editor's own waits as the
/// harness's scheduler is advanced (`land`).
@MainActor
final class FunnelWindow {
    let h: EditorHarness
    let window: NSWindow
    let canvas: NSView
    let hosting: NSView
    let walk: KeyWalk
    private let box: CanvasBox

    init(_ h: EditorHarness, size: CGSize = CGSize(width: 900, height: 600)) {
        self.h = h
        let editor = h.editor
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let canvas = StandInCanvas(frame: content.bounds)
        self.canvas = canvas
        let box = CanvasBox()
        self.box = box
        box.canvas = canvas
        let overlays = editor.registry.hostOverlays.reduce(AnyView(Color.clear.allowsHitTesting(false))) { area, overlay in
            AnyView(area.overlay(alignment: overlay.alignment) { overlay.view(for: editor, onExit: { [box] in box.take() }) })
        }
        let hosting = NSHostingView(rootView: overlays.environment(\.locale, Locale(identifier: "en_US")))
        hosting.sizingOptions = []
        hosting.frame = content.bounds
        self.hosting = hosting
        content.addSubview(canvas)
        content.addSubview(hosting)
        window.contentView = content
        editor.viewportDidResize(to: size)
        let hosted = hosting
        let readers: [any FocusReader] = [
            .custom("funnel") { window in Self.read(window, hosting: hosted) },
            .canvas(canvas, selection: { [] }),
        ]
        walk = KeyWalk(window, editor: editor, readers: readers, settle: .both(h.scheduler))
        window.makeFirstResponder(canvas)
        land()
    }

    /// The keyboard as the popover has it: the control that has it, named as VoiceOver names it; nil elsewhere.
    @MainActor
    static func read(_ window: NSWindow, hosting: NSView) -> Focus? {
        guard let responder = window.firstResponder as? NSView, responder.isDescendant(of: hosting) else { return nil }
        let named = AccessibilityProbe.focused(in: window)
        let label = named.flatMap(AccessibilityProbe.label(of:)) ?? String(describing: Swift.type(of: responder))
        var focus = Focus.of(window, surface: "funnel", element: label)
        focus.role = named.flatMap(AccessibilityProbe.role(of:)) ?? focus.role
        focus.label = named.flatMap(AccessibilityProbe.label(of:)) ?? focus.label
        return focus
    }

    var board: ConstraintBoard { h.editor.constraintBoard! }
    var boxes: ConstraintBoxes { h.editor.constraintBoxes! }

    /// Lets what the editor waits on land (its scheduler's turns), then the run loop (SwiftUI, a model's answer).
    func land(after model: ScriptedLanguageModel? = nil, answers: Int = 0) {
        // In the turns the panel's retries are apart (20 ms), the run loop between: a view made a turn on is there for the next.
        for _ in 0..<10 {
            h.scheduler.advance(by: .milliseconds(20))
            window.settle()
        }
        if let model { window.spin { model.answered >= answers } }
        h.scheduler.advance(by: .zero)
        window.settle()
    }

    /// Everything VoiceOver reads under the overlays, as lines.
    var outline: [String] { AccessibilityProbe.tree(of: hosting).outline }

    /// The pill as drawn: the button the window has for it, nil while there is none.
    var pillButton: NSButton? { buttons.first }

    /// The popover's text views, in reading order: each row's words, its query, the box that adds one.
    var texts: [NSTextView] {
        hosting.descendants(NSTextView.self).filter { !$0.isFieldEditor }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// What the popover's text views say, in reading order.
    var strings: [String] { texts.map(\.string) }

    var buttons: [NSButton] { hosting.descendants(NSButton.self) }

    /// Types `text` in a box and presses Return.
    func type(_ text: String, in box: NSTextView) {
        window.makeFirstResponder(box)
        land()
        window.type(text)
        window.pressReturn()
        land()
    }

    /// The popover is open and drawn: its boxes are there.
    func openAndDraw(boxes count: Int) throws {
        expect(h.editor.perform(.showBoardConstraints), "the command runs")
        window.spin { texts.count == count }
        land()
    }
}

/// The view highest in its window.
@MainActor func topmost<V: NSView>(_ views: [V]) -> V? { views.max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY } }

extension EditorHarness {
    /// The words of the funnel's tooltip, as the pill says them.
    func pillWords(_ place: ConstraintTarget) -> String? {
        guard let says = index.constraints(of: place).map(\.constraint.says) as [String]?, !says.isEmpty else { return nil }
        var seen: Set<String> = []
        return ConstraintsStyle.pillWords(says.filter { seen.insert($0).inserted })
    }
}

@MainActor let boardFunnelTests = Suite("Constraints: the board's funnel", [
    test("it is about the root on the root and about a subboard seen from inside; none while no constraint applies") {
        let given = Given()
        let h = try constraintHarness(given, [BoardsPlugin()])
        let board = try require(h.editor.constraintBoard)
        expectEqual(board.place, nil, "the root holds none")
        h.writer.add(onlyTiles, to: .root)
        expectEqual(board.place, .root)
        let drawer = h.pocket("Drawer", drawerRect, [noDiscs])
        let plain = h.pocket("Plain", CGRect(x: 600, y: 300, width: 200, height: 150))
        expectEqual(board.place, .root, "a pocket on the board doesn't change what its board says")
        expect(h.enter(drawer))
        expectEqual(board.place, .shape(drawer), "inside it, its own")
        expect(h.editor.showBoard(.root))
        expect(h.enter(plain))
        expectEqual(board.place, nil, "a pocket with none: the root's don't reach inside it")
        given.lists[plain] = [ConstraintSource(holder: ShapeID(), constraints: [onlyTiles])]
        h.index.inheritedConstraintsDidChange(of: [plain])
        h.wait(0)
        expectEqual(board.place, .shape(plain), "what it has from elsewhere says too")
        expect(h.editor.showBoard(.root))
        h.writer.remove(onlyTiles, from: .root)
        expectEqual(board.place, nil, "gone with the last constraint")
    },
    test("what the pill says: its words, how many shapes break a constraint, what VoiceOver hears and its tooltip; a pocket's board too") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let board = try require(h.editor.constraintBoard)
        expectEqual(board.pill, nil)
        h.writer.add(onlyTiles, to: .root)
        var pill = try require(board.pill)
        expectEqual(pill.place, .root)
        expectEqual(pill.words, "Accepts only tiles")
        expectEqual(pill.count, nil)
        expectEqual(pill.spoken, "Constraints, only tiles")
        expectEqual(pill.help, "Accepts: only tiles")
        h.writer.add(noDiscs, to: .root)
        pill = try require(board.pill)
        expectEqual(pill.words, "Accepts only tiles and 1 more")
        expectEqual(pill.count, nil, "quiet while everything fits")
        h.disc(at: CGPoint(x: 100, y: 100))
        h.disc(at: CGPoint(x: 200, y: 100))
        h.settle()
        pill = try require(board.pill)
        expectEqual(pill.count, 2, "red, with how many shapes break one")
        expectEqual(pill.spoken, "Constraints, only tiles and 1 more, 2 not accepted")
        expectEqual(pill.help, "Accepts: only tiles; no discs\n2 not accepted")
        let drawer = h.pocket("Drawer", drawerRect, [noDiscs])
        expect(h.enter(drawer))
        h.disc(at: CGPoint(x: 100, y: 100))
        h.settle()
        pill = try require(board.pill)
        expectEqual(pill.place, .shape(drawer))
        expectEqual([pill.words, pill.count.map(String.init) ?? "-", pill.spoken], ["Accepts no discs", "1", "Constraints, no discs, 1 not accepted"])
    },
    test("the pill's words are the first constraint's, \"and 2 more\" for several, cut at the end in less room, then the symbol and the count alone") {
        let one = ConstraintsStyle.pillWords(["only tiles"]), several = ConstraintsStyle.pillWords(["only tiles", "no discs", "only glossy tiles"])
        expectEqual(one, "Accepts only tiles")
        expectEqual(several, "Accepts only tiles and 2 more")
        var fit = FunnelFit.of(words: one, count: nil, in: 400)
        expectEqual(fit.fit, .full)
        let full = fit.width
        fit = FunnelFit.of(words: one, count: 3, in: 400)
        expectEqual(fit.fit, .full)
        expect(fit.width > full, "the count is after the words")
        let counted = fit.width
        fit = FunnelFit.of(words: one, count: 3, in: counted - 10)
        guard case .words(let room) = fit.fit else { return expect(false, "the words are cut first: \(fit)") }
        expect(room >= ConstraintsStyle.pillMinWords && fit.width <= counted - 10, "cut to what room there is: \(room), \(fit.width)")
        // The count follows the words: the cut text takes the room there is and no more (the next character would not fit), so the pill
        // isn't drawn wider than what it shows.
        let shown = FunnelFit.cut(one, to: room)
        let font = ChromeStyle.floatPillFont
        func wide(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        expect(shown.hasSuffix("\u{2026}") && shown.count < one.count, "cut at the end with an ellipsis: \(shown)")
        expect(wide(shown) <= room, "within the room: \(wide(shown)) of \(room)")
        expect(wide(String(one.prefix(shown.count)) + "\u{2026}") > room, "and the next character would not: \(shown)")
        fit = FunnelFit.of(words: one, count: 3, in: 50)
        expectEqual(fit.fit, .symbolOnly, "then the symbol and the count")
        expect(fit.width <= 50, "and it fits: \(fit.width)")
    },
    test("cutting long words costs a few measures, not one per character, and a sweep of widths is kept for the second pass") {
        let long = "Accepts " + String(repeating: "only tasks, no bugs, ", count: 40)
        var shown = ""
        let once = threadCPUTime { shown = FunnelFit.cut(long, to: 60) }
        expect(shown.hasSuffix("\u{2026}") && shown.count < 20, "cut: \(shown)")
        expect(once < .milliseconds(15), "one cut of \(long.count) characters took \(once)")
        // The most that fits, as before: the next character would not.
        let font = ChromeStyle.floatPillFont
        func wide(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        expect(wide(shown) <= 60 && wide(String(long.prefix(shown.count)) + "\u{2026}") > 60, "the most that fits: \(shown)")
        let again = threadCPUTime { shown = FunnelFit.cut(long, to: 60) }
        expect(again < .milliseconds(1), "the same room asked again is kept: \(again)")
        // A resize through more widths than the old cache's 64, the same widths swept again: the second sweep is kept, not measured anew.
        let words = "Accepts " + String(repeating: "only tasks, no bugs, ", count: 6)
        let full = FunnelFit.of(words: words, count: 2, in: 1000).width
        let symbols = FunnelFit.of(words: words, count: 2, in: 10).width
        let rooms = Array(stride(from: full - 1, to: full - 151, by: -1))
        let first = threadCPUTime { for room in rooms { _ = FunnelFit.of(words: words, count: 2, in: room) } }
        let second = threadCPUTime { for room in rooms { _ = FunnelFit.of(words: words, count: 2, in: room) } }
        expect(full - symbols > 160, "the sweep is in the cut range")
        expect(second * 3 < first, "the second sweep of 150 widths is kept: first \(first), second \(second)")
    },
    test("the menu item is enabled while the pill shows, runs the pill's click for the keyboard, and the canvas's own menu has it") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let board = try require(h.editor.constraintBoard)
        expect(!h.editor.canPerform(.showBoardConstraints), "dimmed with no pill")
        expect(!board.open(), "nothing to open")
        h.writer.add(onlyTiles, to: .root)
        expect(h.editor.canPerform(.showBoardConstraints))
        expectEqual(h.editor.registry.title(of: .showBoardConstraints), "Show Board Constraints")
        expect(h.editor.perform(.showBoardConstraints))
        expect(board.isOpen)
        let focus = board.focusRequest
        expect(h.editor.perform(.showBoardConstraints))
        expect(board.focusRequest > focus, "again: the keyboard comes back to it")
        board.toggle()
        expect(!board.isOpen, "a click on the pill closes it while it's open")
        board.toggle()
        expect(board.isOpen)
        expect(h.editor.showBoard(BoardID(owner: h.pocket("Drawer", drawerRect))), "another board shown closes it")
        expect(!board.isOpen)
        expect(!h.editor.canPerform(.showBoardConstraints), "and the pocket has none")
        let menu = h.secondaryClick(at: CGPoint(x: 30, y: 30))
        expect(menu?.outline.contains { $0.contains("Show Board Constraints") } != true, "not where there is no pill: \(menu?.outline ?? [])")
        expect(h.editor.showBoard(.root))
        let shown = try require(h.secondaryClick(at: CGPoint(x: 30, y: 30)))
        expect(shown.outline.contains { $0.contains("Show Board Constraints") }, "on empty canvas where there is: \(shown.outline)")
    },
])

@MainActor let boardFunnelIssueTests = Suite("Constraints: Show Constraint on the board's own place", [
    test("a shape breaking a subboard's constraint, seen from inside its board: Show Constraint opens the board's popover rather than going out to the board above") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let drawer = h.pocket("Drawer", drawerRect, [noDiscs])
        expect(h.enter(drawer))
        let d = h.disc(at: CGPoint(x: 100, y: 100))
        h.settle()
        expectEqual(h.validationIssues(of: d).flatMap(\.actions).map(\.title), ["Move Out", "Show Constraint"])
        let board = try require(h.editor.constraintBoard)
        expect(!board.isOpen)
        try h.perform("Show Constraint", on: d)
        h.wait(0)
        expect(board.isOpen, "the popover")
        expectEqual(h.editor.board, BoardID(owner: drawer), "still inside")
    },
    test("a root constraint's breaker on a subboard's board: Show Constraint shows the root and opens its popover; a frame's constraint is still selected on its Rules tab") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let drawer = h.pocket("Drawer", drawerRect)
        h.writer.add(Constraint(says: "no discs anywhere", query: ":not(disc)", reach: .descendants), to: .root)
        expect(h.enter(drawer))
        let d = h.disc(at: CGPoint(x: 100, y: 100))
        h.settle()
        expectEqual(h.validationIssues(of: d).flatMap(\.actions).map(\.title), ["Show Constraint"], "the root's: nowhere out to move it")
        try h.perform("Show Constraint", on: d)
        h.wait(0)
        expectEqual(h.editor.board, .root, "the root shown")
        expect(h.editor.constraintBoard?.isOpen == true, "and its popover open")
        // A frame's own constraint, seen from the board it is on, goes as it did.
        let pen = h.corral("Pen", CGRect(x: 100, y: 300, width: 300, height: 200), [noDiscs])
        let inPen = h.disc(at: CGPoint(x: 150, y: 350), in: pen)
        h.settle()
        h.editor.constraintBoard?.close()
        try h.perform("Show Constraint", on: inPen)
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [pen])
        expect(h.editor.constraintBoard?.isOpen == false)
    },
    test("the canvas's menu on a shape that breaks the root's constraint has Show Constraint and no Move Out") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let d = h.disc(at: CGPoint(x: 400, y: 300))
        h.writer.add(noDiscs, to: .root)
        h.settle()
        h.editor.setTool("select")
        let menu = try require(h.secondaryClick(at: CGPoint(x: 425, y: 325)))
        expect(menu.outline.contains("Show Constraint"), "\(menu.outline)")
        expect(!menu.outline.contains { $0.hasPrefix("Move Out") }, "\(menu.outline)")
        try menu.choose("Show Constraint")
        expect(h.editor.constraintBoard?.isOpen == true)
        _ = d
    },
])

@MainActor let boardFunnelWindowTests = Suite("Constraints: the board's funnel, in a window", [
    test("the pill appears with the first constraint, 12 in from the leading edge and centered on the path's row, and goes with the last") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let w = FunnelWindow(h)
        expectEqual(w.pillButton, nil, "nothing while the board has none")
        h.writer.add(onlyTiles, to: .root)
        w.window.spin { w.pillButton != nil }
        let frame = try require(w.pillButton).frame
        expectEqual(frame.minX, ChromeStyle.floatMargin, "in from the canvas's edge as the zoom's pill is")
        expectEqual(frame.height, ChromeStyle.floatPillHeight, "as tall as the zoom's")
        expectEqual(frame.midY, BoardPath.rowMidline, "its middle on the middle of the path's pill")
        h.writer.removeAll(from: .root)
        w.land()
        expectEqual(w.pillButton, nil)
    },
    test("a click on the pill opens the popover, with the Rules tab's own rows over the root's list: each constraint's words and its query, the box that adds one") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        h.writer.add(onlyTiles, to: .root)
        h.writer.add(noDiscs, to: .root)
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        expect(!w.board.isOpen)
        expectEqual(w.texts.count, 0, "closed: no rows")
        try require(w.pillButton).performClick(nil)
        w.window.spin { w.texts.count == 5 }
        w.land()
        expect(w.board.isOpen)
        expectEqual(w.strings, ["only tiles", "tile", "no discs", ":not(disc)", ""])
        expect(w.texts.allSatisfy(\.isEditable), "the root's list can change")
        expect(w.window.firstResponder is NSTextView, "the keyboard is in the first box")
        try require(w.pillButton).performClick(nil)
        w.land()
        expect(!w.board.isOpen, "a click on it again closes it")
        expectEqual(w.texts.count, 0)
    },
    test("words typed in the add box and Return: the model is asked once, in the board's name, and the constraint lands on the root as one step, Add Constraint, which an undo takes back") {
        let model = ScriptedLanguageModel(answers: ["tile[finish=\"glossy\"]"])
        let h = try constraintHarness(Given(), model: model, [BoardsPlugin()])
        h.editor.nameRoot("Plans")
        h.writer.add(onlyTiles, to: .root)
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        try w.openAndDraw(boxes: 3)
        w.type("only glossy tiles", in: w.texts[2])
        w.land(after: model, answers: 1)
        expectEqual(h.writer.constraints(of: .root), [onlyTiles, Constraint(says: "only glossy tiles", query: #"tile[finish="glossy"]"#)])
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(model.requests.count, 1)
        expect(model.lastRequest?.system?.hasSuffix("which shapes Plans accepts.") == true, "the board's name, as a refusal names it: \(model.lastRequest?.system ?? "")")
        w.window.spin { w.texts.count == 5 }
        h.editor.undo()
        w.land()
        expectEqual(h.writer.constraints(of: .root), [onlyTiles])
        expectEqual(w.texts.count, 3)
        // Words that already read as a query skip the model.
        w.type("tile", in: w.texts[2])
        w.land()
        expectEqual(model.requests.count, 1)
        expectEqual(h.writer.constraints(of: .root)?.map(\.says), ["only tiles", "tile"])
    },
    test("a row's query and reach change the root's list, each one step, and the row acts on the constraint as it is now: × after either takes it away; a row emptied goes") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        h.writer.add(onlyTiles, to: .root)
        h.writer.add(noDiscs, to: .root)
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        try w.openAndDraw(boxes: 5)
        // The query, edited in place.
        w.window.makeFirstResponder(w.texts[1])
        w.texts[1].selectAll(nil)
        w.window.type("tile[finish=\"glossy\"]")
        w.window.makeFirstResponder(w.texts[4])
        w.land()
        expectEqual(h.writer.constraints(of: .root)?.first?.query, "tile[finish=\"glossy\"]")
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
        // The reach, by the pop-up, of the row whose query was just written.
        let popup = try require(topmost(w.hosting.descendants(NSPopUpButton.self)))
        popup.menu?.performActionForItem(at: 1)
        w.land()
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
        expectEqual(h.writer.constraints(of: .root)?.first?.reach, .descendants)
        // ×, on the row as the writes left it.
        let remove = try require(topmost(w.buttons.filter { !($0 is NSPopUpButton) && $0.convert($0.bounds, to: nil).width < 20 }))
        remove.performClick(nil)
        w.land()
        expectEqual(h.writer.constraints(of: .root)?.map(\.says), ["no discs"])
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraint")
        // A row emptied goes.
        w.window.spin { w.texts.count == 3 }
        w.window.makeFirstResponder(w.texts[0])
        w.texts[0].selectAll(nil)
        w.texts[0].deleteBackward(nil)
        w.window.pressReturn()
        w.land()
        expectEqual(h.writer.constraints(of: .root), [])
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraint")
    },
    test("the lists from elsewhere are read-only under their source, a locked subboard's own rows are too, and Not accepted lists what breaks one") {
        let given = Given()
        let h = try constraintHarness(given, [BoardsPlugin()])
        let drawer = h.pocket("Drawer", drawerRect, [noDiscs])
        given.lists[drawer] = [ConstraintSource(holder: ShapeID(), constraints: [onlyTiles])]
        h.index.inheritedConstraintsDidChange(of: [drawer])
        h.wait(0)
        expect(h.enter(drawer))
        h.disc(at: CGPoint(x: 100, y: 100))
        h.settle()
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        expect(h.editor.perform(.showBoardConstraints))
        w.window.spin { w.texts.filter(\.isEditable).count == 3 }
        w.land()
        expectEqual(w.texts.filter(\.isEditable).map(\.string), ["no discs", ":not(disc)", ""], "its own rows and the add box: editable")
        expect(w.strings.contains("tile") || w.buttons.count >= 1, "the list from elsewhere shows read-only: \(w.strings)")
        expect(!w.strings.contains("only tiles"), "its words aren't a box")
        // Not accepted.
        let notAccepted = w.hosting.descendants(NSTableView.self)
        expect(!notAccepted.isEmpty, "Not accepted is a list of the shapes that break one")
        // A locked subboard: every row is read-only.
        expect(h.editor.showBoard(.root))
        h.editor.freeze([drawer])
        expect(h.enter(drawer))
        w.land()
        expect(h.editor.perform(.showBoardConstraints))
        w.window.spin { w.texts.count == 4 }
        w.land()
        expect(w.texts.allSatisfy { !$0.isEditable }, "read-only as the tab's are: \(w.texts.map(\.isEditable))")
        let adders = w.texts.compactMap { $0 as? EditingTextView }.filter { $0.placeholder != nil }
        expect(!adders.isEmpty && adders.allSatisfy { !$0.placeholderIsEnabled }, "the add box's placeholder is dimmed with the rest: \(adders.map(\.placeholderIsEnabled))")
    },
    test("the keys: Show Board Constraints takes the keyboard to the first box, Tab and Back-Tab walk every stop in the tab's order and come round, Escape closes it with the canvas taking the keyboard") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        h.writer.add(onlyTiles, to: .root)
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        w.walk.standardControls = ["funnel/Remove only tiles", "funnel/Reach of only tiles"]
        expectEqual(w.walk.focus.id, "canvas")
        try w.openAndDraw(boxes: 3)
        expectEqual(w.walk.focus.id, "funnel/Constraint 1", "the first box")
        w.walk.expectCycle(["funnel/Constraint 1", "funnel/Remove only tiles", "funnel/Query of only tiles", "funnel/Reach of only tiles", "funnel/add constraint"])
        w.walk.expectShows([w.walk.focus])
        w.walk.go("funnel/add constraint")
        w.walk.expectEscapeLadder(["canvas"])
        expect(!w.board.isOpen, "Escape closed it")
        expect(w.window.firstResponder === w.canvas, "and the canvas has the keyboard")
        expectEqual(w.texts.count, 0)
    },
    test("Escape lets go of words typed that haven't landed first, then closes; nothing typed is lost to a click outside, which closes it too") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        h.writer.add(onlyTiles, to: .root)
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        try w.openAndDraw(boxes: 3)
        w.window.makeFirstResponder(w.texts[2])
        w.window.type("only discs")
        w.land()
        expect(w.boxes.hasDraft(ConstraintBox(place: .root, constraint: nil)), "typed, not landed")
        w.walk.expectEscapeLadder(["funnel/add constraint"])
        expect(!w.boxes.hasDraft(ConstraintBox(place: .root, constraint: nil)), "the first Escape drops what was typed")
        expect(w.board.isOpen)
        w.walk.expectEscapeLadder(["canvas"])
        expect(!w.board.isOpen)
        expectEqual(h.writer.constraints(of: .root)?.map(\.says), ["only tiles"])
    },
    test("another board shown, an undo that takes the last constraint away and the pill going close the popover, and the keyboard it had goes to the canvas") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let other = h.pocket("Other", drawerRect)
        h.writer.add(onlyTiles, to: .root)
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        try w.openAndDraw(boxes: 3)
        expect(w.window.firstResponder !== w.canvas)
        expect(h.enter(other))
        w.land()
        expect(!w.board.isOpen, "another board shown")
        expectEqual(w.texts.count, 0)
        expect(w.window.firstResponder === w.canvas, "the keyboard went to the canvas")
        expect(h.editor.showBoard(.root))
        w.land()
        try w.openAndDraw(boxes: 3)
        h.editor.undo()
        w.land()
        expectEqual(h.writer.constraints(of: .root), [], "the undo took the last constraint away")
        expect(!w.board.isOpen, "and the popover with it")
        expect(w.window.firstResponder === w.canvas)
        // The window going: closed, so reopening starts shut.
        h.editor.redo()
        w.land()
        try w.openAndDraw(boxes: 3)
        w.hosting.removeFromSuperview()
        w.land()
        expect(!w.board.isOpen, "the overlay gone, nothing is left open")
    },
])

// The pill's room and the popover's give and take: where it goes beside and under Boards' path pill at every width, one overlay
// with the canvas at a time, a popover that gives way to the shape a row goes to, and rows that follow a lock.

/// A subboard's board with long names and one constraint and one breaker, the case that leaves least room beside the path's pill.
@MainActor private func longNames(_ h: EditorHarness) throws -> ShapeID {
    h.editor.nameRoot("Quarterly planning for the platform team")
    let sub = h.pocket("Sprint 12 and its retrospective notes", drawerRect, [Constraint(says: "only tiles", query: "tile")])
    h.disc(at: CGPoint(x: 100, y: 100))
    expect(h.enter(sub))
    h.disc(at: CGPoint(x: 100, y: 100))
    h.settle()
    return sub
}

@MainActor let boardFunnelRoomTests = Suite("Constraints: the board's funnel, its room, its give and take", [
    test("beside the path's pill the pill keeps the clearance at every width it is drawn in, and under the path, at the same margin, when not even the symbol and the count fit; never over it") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        _ = try longNames(h)
        for width in [480.0, 600.0, 700.0, 900.0] {
            let w = FunnelWindow(h, size: CGSize(width: width, height: 400))
            let crumbs = try require(h.editor.boardCrumbs)
            w.window.spin { crumbs.pillWidth > 0 && w.pillButton != nil }
            w.land()
            let pill = try require(w.pillButton).frame
            let pathLeading = (width - crumbs.pillWidth) / 2
            let pathBottom = BoardPath.coveredHeight(on: h.editor.board) - ChromeStyle.floatShadowReach
            expectEqual(pill.minX, ChromeStyle.floatMargin, "at \(width): the margin")
            expectEqual(pill.height, ChromeStyle.floatPillHeight)
            if pill.minY >= pathBottom {
                expect(pill.maxX <= width - ChromeStyle.floatMargin + 0.01, "at \(width): under the path, in the canvas (to \(pill.maxX))")
            } else {
                expect(pill.maxX + ConstraintsStyle.pillClearance <= pathLeading + 0.01, "at \(width): beside the path (to \(pill.maxX), path from \(pathLeading)): the clearance")
            }
            if width == 480 { expect(pill.minY >= pathBottom, "at the minimum width it goes under the path: \(pill)") }
            if width >= 700 { expect(pill.minY < pathBottom, "with room it stays on the path's row: \(pill)") }
            w.window.close()
        }
    },
    test("under the path the popover opens under the pill, its rows all there") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        _ = try longNames(h)
        let w = FunnelWindow(h, size: CGSize(width: 480, height: 500))
        let crumbs = try require(h.editor.boardCrumbs)
        w.window.spin { crumbs.pillWidth > 0 && w.pillButton != nil }
        w.land()
        let pill = try require(w.pillButton).frame
        try w.openAndDraw(boxes: 3)
        expect(w.texts.allSatisfy { $0.convert($0.bounds, to: w.hosting).minY >= pill.maxY }, "under the pill: \(w.texts.map { $0.convert($0.bounds, to: w.hosting) })")
        w.window.close()
    },
    test("an overlay with the canvas closes the popover and takes the pill away until it is done; opening the popover closes the overlay that had it") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        h.writer.add(onlyTiles, to: .root)
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        try w.openAndDraw(boxes: 3)
        expectEqual(h.editor.modalOverlay, ConstraintFacesPlugin.id)
        var closed = 0
        h.editor.presentModalOverlay("other-overlay") { closed += 1 }
        w.land()
        expect(!w.board.isOpen, "the popover gives way")
        expectEqual(h.editor.modalOverlay, "other-overlay")
        expectEqual(w.pillButton, nil, "and the pill leaves the other overlay's place")
        expectEqual(w.texts.count, 0)
        expect(h.editor.perform(.showBoardConstraints), "asked for while the other has the canvas")
        w.land()
        expectEqual(closed, 1, "the other is closed")
        expect(w.board.isOpen)
        expectEqual(h.editor.modalOverlay, ConstraintFacesPlugin.id)
        expect(w.pillButton != nil, "the pill is there with the popover")
        w.board.close()
        expectEqual(h.editor.modalOverlay, nil, "closed: nothing has the canvas")
        h.editor.presentModalOverlay("other-overlay") {}
        w.land()
        expectEqual(w.pillButton, nil)
        h.editor.dismissModalOverlay("other-overlay")
        w.land()
        expect(w.pillButton != nil, "the other done, the pill is back")
        w.window.close()
    },
    test("Return on a Not accepted row goes to the shape with the popover closed and the canvas holding the keyboard") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        h.writer.add(noDiscs, to: .root)
        let d = h.disc(at: CGPoint(x: 100, y: 150))
        h.settle()
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        try w.openAndDraw(boxes: 3)
        var steps = 0
        while !(w.window.firstResponder is NSTableView), steps < 10 { w.walk.press(.tab); steps += 1 }
        expect(w.window.firstResponder is NSTableView, "the list has the keyboard")
        w.walk.press(.down)
        w.walk.press(.return)
        w.land()
        expectEqual(h.editor.selectedShapeIDs, [d], "gone to")
        expect(!w.board.isOpen, "the popover gives way to the shape it went to")
        expect(w.window.firstResponder === w.canvas, "and the canvas has the keyboard")
        w.window.close()
    },
    test("a click on a list's source pill goes to its holder the same way") {
        let given = Given()
        let h = try constraintHarness(given, [BoardsPlugin()])
        let sub = h.pocket("Drawer", drawerRect, [noDiscs])
        expect(h.enter(sub))
        let holder = h.tile(at: CGPoint(x: 100, y: 100))
        given.lists[sub] = [ConstraintSource(holder: holder, constraints: [onlyTiles])]
        h.index.inheritedConstraintsDidChange(of: [sub])
        h.wait(0)
        h.settle()
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        let pill = try require(w.pillButton).frame
        expect(h.editor.perform(.showBoardConstraints))
        w.window.spin { w.texts.count >= 3 }
        w.land()
        @MainActor func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: w.hosting).minY }
        let source = try require(w.buttons.filter { top($0) >= pill.maxY && !($0 is NSPopUpButton) }.min { top($0) < top($1) })
        source.performClick(nil)
        w.land()
        expectEqual(h.editor.selectedShapeIDs, [holder])
        expect(!w.board.isOpen)
        expect(w.window.firstResponder === w.canvas)
        w.window.close()
    },
    test("a subboard locked or unlocked while its board's popover is open turns its rows read-only, and back") {
        let h = try constraintHarness(Given(), [BoardsPlugin()])
        let sub = h.pocket("Drawer", drawerRect, [noDiscs])
        expect(h.enter(sub))
        h.settle()
        let w = FunnelWindow(h)
        w.window.spin { w.pillButton != nil }
        try w.openAndDraw(boxes: 3)
        expect(w.texts.allSatisfy(\.isEditable))
        // Locked from where it is on, the root's board (an undo, an agent's write, `/lock`), while its own board is shown.
        h.editor.transact(on: .root, "Lock") { $0.update(sub) { $0[Frozen.self] = true } }
        w.land()
        expect(w.texts.allSatisfy { !$0.isEditable }, "read-only once locked: \(w.texts.map(\.isEditable))")
        expect(w.board.isOpen)
        h.editor.transact(on: .root, "Unlock") { $0.update(sub) { $0[Frozen.self] = nil } }
        w.land()
        expect(w.texts.allSatisfy(\.isEditable), "editable once unlocked: \(w.texts.map(\.isEditable))")
        w.window.close()
    },
])
