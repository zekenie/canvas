import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import DetailPanel
import LanguageModels
import Palette
import QueryLanguage
import QueryTranslation
import Selection
import SwiftUI
import TestKit
import Titles
import Validation

// The Rules tab's constraints: a container's sections (what it has from elsewhere under its source's pill, read-only; its
// own, a row each, and the box that adds one; the shapes inside that break one), a holder's (its rows, what it inherits,
// the box that adds one), the words typed in a row turned into a query by a scripted model, the query edited in place, the
// reach, ×, and the whole by keys in an unshown window.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)

/// The panel alone in an unshown window, over a harness's editor: SwiftUI lands as the run loop runs, the editor's own waits as
/// the harness's scheduler is advanced.
@MainActor
final class ConstraintsPanelWindow {
    let h: EditorHarness
    let window: NSWindow
    let hosting: NSView

    init(_ h: EditorHarness) {
        self.h = h
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: DetailPanelView(editor: h.editor, onExit: {}).environment(\.locale, Locale(identifier: "en_US")))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        window.contentView = hosting
        window.settle()
    }

    /// Shows a shape's panel on its Rules tab.
    func show(_ id: ShapeID) throws {
        let record = try require(h.editor.document[id])
        h.editor.detailPanel?.choose(.of(RulesTab.self), for: record.kind)
        h.editor.selectedShapeIDs = [id]
        window.settle()
        h.scheduler.advance(by: .milliseconds(100))
        window.settle()
    }

    /// The panel's text views below its header, in reading order: each row's words, its query, the box that adds one.
    var boxes: [NSTextView] { hosting.descendants(NSTextView.self).filter { !$0.isFieldEditor && $0.convert($0.bounds, to: hosting).maxY > 44 } }
    /// The panel's buttons below its header, in reading order.
    var buttons: [NSButton] {
        var placed: [(button: NSButton, frame: CGRect)] = []
        for button in hosting.descendants(NSButton.self) {
            let frame = button.convert(button.bounds, to: nil)
            if frame.maxY < window.contentLayoutRect.maxY - 44 { placed.append((button, frame)) }
        }
        placed.sort { a, b in abs(a.frame.maxY - b.frame.maxY) > 4 ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX }
        return placed.map(\.button)
    }

    /// Types `text` in a box and presses Return.
    func type(_ text: String, in box: NSTextView) {
        window.makeFirstResponder(box)
        window.settle()
        window.type(text)
        window.pressReturn()
        window.settle()
    }

    /// Lets what the editor waits on land: its scheduler's turns, then the run loop (a model's answer).
    func land(after model: ScriptedLanguageModel? = nil, answers: Int = 0) {
        h.scheduler.advance(by: .zero)
        if let model { window.spin { model.answered >= answers } }
        window.settle()
        h.scheduler.advance(by: .zero)
        window.settle()
    }
}

extension EditorHarness {
    /// A container's constraints as its list holds them.
    func list(of id: ShapeID) -> [Constraint] { writer.constraints(of: .shape(id)) ?? [] }
}

@MainActor let panelTests = Suite("Constraints: the Rules tab", [
    test("a container gets a Rules tab once a constraint applies, with its section, and Not accepted while some shape breaks one") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect)
        let panel = try require(h.editor.detailPanel)
        expect(try !panel.layout(for: require(h.editor.document[pen])).tabs.contains(.of(RulesTab.self)), "none: no Rules tab")
        h.writer.add(onlyTiles, to: .shape(pen))
        var layout = try panel.layout(for: require(h.editor.document[pen]))
        expect(layout.tabs.contains(.of(RulesTab.self)))
        expectEqual(layout.sections(in: .of(RulesTab.self)).map(\.section), ["constraints"])
        h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        layout = try panel.layout(for: require(h.editor.document[pen]))
        expectEqual(layout.sections(in: .of(RulesTab.self)).map(\.section), ["constraints", "not-accepted"])
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        expectEqual(try panel.layout(for: require(h.editor.document[drawer])).sections(in: .of(RulesTab.self)).map(\.section), ["constraints"], "a pocket's too")
    },
    test("a holder has its section with the holder's registration, and a shape of its kind that holds no list has none") {
        let h = try constraintHarness()
        let named = AnyShapeRecord(ShapeRecord(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint")))
        let unnamed = AnyShapeRecord(ShapeRecord(Charter(CGRect(x: 600, y: 450, width: 100, height: 80))))
        h.editor.transact { transaction in
            transaction.insert(named)
            transaction.insert(unnamed)
        }
        let panel = try require(h.editor.detailPanel)
        expectEqual(try panel.layout(for: require(h.editor.document[named.id])).sections(in: .of(RulesTab.self)).map(\.section), ["holder-constraints"])
        expect(try !panel.layout(for: require(h.editor.document[unnamed.id])).tabs.contains(.of(RulesTab.self)), "no name: no list")
        expectEqual(h.editor.constraintHeading(of: named.id), "Inside each sprint")
    },
])

@MainActor let panelWindowTests = Suite("Constraints: the Rules tab, in a window", [
    test("a container's tab: its own row (words, query) then the box that adds one") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 5 }
        expectEqual(panel.boxes.map(\.string), ["only tiles", "tile", "no discs", ":not(disc)", ""])
        expect(!panel.buttons.isEmpty)
    },
    test("words typed in the box that adds one and Return: the model is asked once (in the place's name), and the constraint lands as one step, Add Constraint") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        panel.type("only tiles", in: panel.boxes[2])
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: pen), [noDiscs, Constraint(says: "only tiles", query: "tile")])
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(model.requests.count, 1)
        expect(model.lastRequest?.system?.hasSuffix("which shapes Pen accepts.") == true, "the accepts context, by the place's name")
        h.editor.undo()
        expectEqual(h.list(of: pen), [noDiscs])
    },
    test("words that already read as a query skip the model") {
        let model = ScriptedLanguageModel()
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        panel.type("tile", in: panel.boxes[2])
        panel.land()
        expectEqual(h.list(of: pen), [noDiscs, Constraint(says: "tile", query: "tile")])
        expectEqual(model.requests.count, 0)
    },
    test("a row's words edited ask for a new query and replace the constraint, its reach kept, one step, Change Constraint") {
        let model = ScriptedLanguageModel(answers: ["tile[finish=\"glossy\"]"])
        let h = try constraintHarness(model: model)
        let reaching = Constraint(says: "only tiles", query: "tile", reach: .descendants)
        let pen = h.corral("Pen", penRect, [reaching])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.boxes[0].selectAll(nil)
        panel.window.type("only glossy tiles")
        panel.window.pressReturn()
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: pen), [Constraint(says: "only glossy tiles", query: "tile[finish=\"glossy\"]", reach: .descendants)])
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
    },
    test("a row emptied goes, one step, Remove Constraint; × does the same") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 5 }
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.boxes[0].selectAll(nil)
        panel.boxes[0].deleteBackward(nil)
        panel.window.pressReturn()
        panel.land()
        expectEqual(h.list(of: pen), [noDiscs])
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraint")
        panel.window.spin { panel.boxes.count == 3 }
        let remove = try require(panel.buttons.first { !($0 is NSPopUpButton) })
        remove.performClick(nil)
        expectEqual(h.list(of: pen), [])
    },
    test("the query under a row is edited in place: written as the keyboard leaves if the engine reads it, else its refusal shows and nothing is written") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 3 }
        let query = panel.boxes[1]
        panel.window.makeFirstResponder(query)
        query.selectAll(nil)
        panel.window.type("tile[finish=\"glossy\"]")
        panel.window.makeFirstResponder(panel.boxes[2])
        panel.window.settle()
        expectEqual(h.list(of: pen), [Constraint(says: "only tiles", query: "tile[finish=\"glossy\"]")])
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
        let before = h.editor.revision
        panel.window.makeFirstResponder(panel.boxes[1])
        panel.boxes[1].selectAll(nil)
        panel.window.type(":scope")
        panel.window.makeFirstResponder(panel.boxes[2])
        panel.window.settle()
        expectEqual(h.editor.revision, before, "a query with `:scope` is refused: it is no stored query")
        expectEqual(h.list(of: pen).first?.query, "tile[finish=\"glossy\"]")
    },
    test("while the model is asked the row says so, and the words stay; a failure says why in the words every host says and Retry asks again, landing as the step") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue(LanguageModelError.notSignedIn)
        model.queue("tile")
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        let boxes = try require(h.editor.constraintBoxes)
        let adding = ConstraintBox(holder: pen, constraint: nil)
        panel.window.spin { panel.boxes.count == 3 }
        panel.type("only tiles", in: panel.boxes[2])
        panel.land()
        expectEqual(boxes.status(of: adding), .interpreting, "the call is out")
        expectEqual(boxes.text(of: adding), "only tiles")
        model.release()
        panel.land(after: model, answers: 1)
        expectEqual(boxes.status(of: adding), .failed(.notSignedIn))
        expectEqual(InterpretationStatus.notSignedIn.words, "Not signed in")
        expectEqual(boxes.text(of: adding), "only tiles", "kept")
        expectEqual(h.list(of: pen), [noDiscs], "nothing written")
        boxes.retry(adding)
        panel.land()
        model.release()
        panel.land(after: model, answers: 2)
        expectEqual(h.list(of: pen), [noDiscs, Constraint(says: "only tiles", query: "tile")])
        expectEqual(boxes.status(of: adding), .none)
        expectEqual(boxes.text(of: adding), "")
    },
    test("words naming a title no shape has fail as that, by name, and stay in the box with Retry") {
        let model = ScriptedLanguageModel()
        model.queue(#""Ghost""#)
        model.queue(#""Ghost""#)
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        let boxes = try require(h.editor.constraintBoxes)
        let adding = ConstraintBox(holder: pen, constraint: nil)
        panel.window.spin { panel.boxes.count == 3 }
        panel.type("only ghosts", in: panel.boxes[2])
        panel.land()
        panel.land(after: model, answers: 2)
        expectEqual(boxes.status(of: adding), .failed(.unknownTitle("Ghost")))
        expectEqual(InterpretationStatus.unknownTitle("Ghost").words, "No shape is called Ghost")
        expectEqual(boxes.text(of: adding), "only ghosts", "kept")
        expectEqual(h.list(of: pen), [noDiscs], "nothing written")
    },
    test("a list from elsewhere is read-only under its source's pill, which goes to the holder; the container's own rows follow") {
        let given = Given()
        let h = try constraintHarness(given)
        let charter = h.add(Charter(CGRect(x: 900, y: 0, width: 200, height: 100), name: "Sprint"))
        let pen = h.corral("Pen", penRect, [onlyTiles])
        given.lists[pen] = [ConstraintSource(holder: charter, swatch: Swatch(RGB(hex: 0x4465E9)), constraints: [noDiscs])]
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.settle()
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 4 }
        expectEqual(panel.boxes.map(\.string), [":not(disc)", "only tiles", "tile", ""], "the given list first, then Own")
        expectEqual(panel.boxes.map(\.isEditable), [false, true, true, true], "what is given is read-only")
        h.editor.selectedShapeIDs = [pen]
        let pill = try require(panel.buttons.first)
        pill.performClick(nil)
        h.scheduler.advance(by: .zero)
        expectEqual(h.editor.selectedShapeIDs, [charter], "the pill goes to the holder")
    },
    test("Not accepted: a row for each shape inside that breaks one, by name, the pointer or the keyboard on a row lights it, Return goes to it") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [Constraint(says: "only discs", query: "disc")])
        let beta = h.tile("Beta", at: CGPoint(x: 150, y: 250), in: pen), alpha = h.tile("Alpha", at: CGPoint(x: 300, y: 150), in: pen)
        h.disc(at: CGPoint(x: 400, y: 330), in: pen)
        h.settle()
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { !panel.hosting.descendants(NSTableView.self).isEmpty }
        let table = try require(panel.hosting.descendants(NSTableView.self).first)
        expectEqual(table.numberOfRows, 2, "the disc fits")
        let walk = KeyWalk(panel.window, editor: h.editor, menu: nil, readers: [], settle: .both(h.scheduler))
        panel.window.makeFirstResponder(table)
        panel.window.settle()
        expectEqual(h.editor.hovered, alpha, "the first row, by name, lit")
        walk.press(.down)
        expectEqual(h.editor.hovered, beta)
        walk.press(.return)
        h.scheduler.advance(by: .zero)
        expectEqual(h.editor.selectedShapeIDs, [beta], "Return goes to the shape")
    },
    test("a holder's tab: its rows and the box that adds one, written through the holder, one step") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let h = try constraintHarness(model: model)
        let named = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(named)
        panel.window.spin { panel.boxes.count == 1 }
        panel.type("only tiles", in: panel.boxes[0])
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: named), [Constraint(says: "only tiles", query: "tile")])
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expect(model.lastRequest?.system?.hasSuffix("which shapes each sprint accepts.") == true, "a holder is named as its section says it")
        panel.window.spin { panel.boxes.count == 3 }
        expectEqual(panel.boxes.map(\.string), ["only tiles", "tile", ""])
    },
    test("by keys: Tab walks each row's words, its remove button, its query and its reach, then the box that adds one, Shift-Tab back") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 5 }
        let walk = KeyWalk(panel.window, editor: h.editor, menu: nil, readers: [], settle: .both(h.scheduler))
        walk.standardControls = ["window/Remove only tiles", "window/Reach of only tiles", "window/Remove no discs", "window/Reach of no discs"]
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.window.settle()
        h.scheduler.advance(by: .milliseconds(100))
        expectEqual(walk.focus.id, "window/Constraint 1")
        walk.expectCycle(inOrder: ["window/Constraint 1", "window/Remove only tiles", "window/Query of only tiles", "window/Reach of only tiles",
                                   "window/Constraint 2", "window/Remove no discs", "window/Query of no discs", "window/Reach of no discs",
                                   "window/add constraint"], wraps: .closed)
        walk.expectShows([walk.focus])
    },
    test("words that have no query and nobody is asking about offer Interpret, which asks the model and lands as Change Constraint; not for a read-only list or with nothing to ask with") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let h = try constraintHarness(model: model)
        let words = Constraint(says: "only tiles")
        let pen = h.corral("Pen", penRect, [words]), frozen = h.corral("Frozen", CGRect(x: 600, y: 100, width: 150, height: 150), [words])
        let boxes = try require(h.editor.constraintBoxes)
        let box = ConstraintBox(holder: pen, constraint: words)
        expect(boxes.offersInterpret(box))
        expect(!boxes.offersInterpret(ConstraintBox(holder: pen, constraint: noDiscs)), "a query it has")
        h.editor.freeze([frozen])
        expect(!boxes.offersInterpret(ConstraintBox(holder: frozen, constraint: words)), "read-only")
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 2 }
        expectEqual(panel.boxes.map(\.string), ["only tiles", ""], "no query to show")
        boxes.interpret(box)
        expectEqual(boxes.status(of: box), .interpreting)
        expect(!boxes.offersInterpret(box), "being asked")
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: pen), [Constraint(says: "only tiles", query: "tile")])
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
        expectEqual(boxes.status(of: box), .none)
    },
    test("the reach is a pop-up: Directly inside, Anywhere inside, written as Change Constraint") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { !panel.hosting.descendants(NSPopUpButton.self).isEmpty }
        let pop = try require(panel.hosting.descendants(NSPopUpButton.self).first)
        expectEqual(pop.itemTitles, ["Directly inside", "Anywhere inside"])
        expectEqual(pop.titleOfSelectedItem, "Directly inside")
        pop.menu?.performActionForItem(at: 1)
        panel.land()
        expectEqual(h.list(of: pen).first?.reach, .descendants)
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
    },
])
