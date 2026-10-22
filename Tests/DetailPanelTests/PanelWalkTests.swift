import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TestKit

// The panel by keys (P3, P4, P5, P8, P9 of keyboard-navigation.md): Tab walks a panel's title, text
// box, code editor, list and checkbox in reading order and comes round inside the panel, the way back
// undoes each step, Escape leaves, and each stop has a role and a label.

/// A box kind with one of each control the walk visits.
struct Walker: BoxShapeProps {
    static let kind: ShapeKind = "walker"
    static let properties = Properties<Walker> {
        Property("frame", \.frame).required()
        Property("name", \.name)
        Property("notes", \.notes)
        Property("code", \.code)
        Property("allowed", \.allowed)
    }
    var frame: CGRect
    var name = ""
    var notes = ""
    var code = ""
    var allowed = false

    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

struct WalkerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Walker>, in context: RenderContext) {}
}

enum WalkerTab {}
extension WalkerTab: DetailTab { static var title: String { "Walker" } }
enum SecondWalkerTab {}
extension SecondWalkerTab: DetailTab { static var title: String { "Second" } }
enum ThirdWalkerTab {}
extension ThirdWalkerTab: DetailTab { static var title: String { "Third" } }

/// What activating a row of the walker's list did, and which rows the list highlighted.
@MainActor var walkerRowsActivated: [Int] = []
@MainActor var walkerHighlights: [Int?] = []

/// A head, which folds the three rows under it.
struct WalkerRows: View {
    @State private var folded = false

    var body: some View {
        let head = DetailRowItem(id: 100, kind: .head(isFolded: folded)) { folded.toggle() }
        let rows = folded ? [] : (0..<3).map { i in DetailRowItem(id: i, parent: 100) { walkerRowsActivated.append(i) } }
        DetailRowList([head] + rows, label: "Rows", onHighlight: { walkerHighlights.append($0) }) { item in
            if item.id == 100 {
                DetailGroupHeader("Group", count: 3, isCollapsed: folded, isRow: true) {}
                    .detailRowAccessibility(label: "Group", value: DetailGroupHeader.spoken(count: 3, isCollapsed: folded), activate: item.activate)
            } else {
                DetailShapeRow(symbol: "note", name: "Row \(item.id)")
                    .detailRowAccessibility(label: "Row \(item.id)", activate: item.activate)
            }
        }
    }
}

struct WalkersPlugin: CanvasPlugin {
    var id: PluginID { "walkers" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(WalkerDefinition()) { walker in
            walker.details(header: { $walker in RenamingHeader(text: $walker.name) }) {
                DetailSection("Notes", in: WalkerTab.self) { $walker in DetailTextArea($walker.notes, label: "Notes") }
                DetailSection("Code", in: WalkerTab.self) { $walker in DetailCodeEditor($walker.code, label: "Code") }
                DetailSection("Rows", in: WalkerTab.self) { _ in WalkerRows() }
                DetailSection("Allowed", in: WalkerTab.self) { $walker in DetailCheckbox("Allowed", isOn: $walker.allowed) }
                DetailSection("More", in: SecondWalkerTab.self) { $walker in DetailTextArea($walker.notes, label: "More notes") }
                DetailSection("Last", in: ThirdWalkerTab.self) { _ in Text("Nothing to type here") }
            }
        }
    }
}

/// A box kind whose one tab holds more text boxes than the panel is tall: the ones below the fold are
/// scrolled out of view, and Tab reaches them still.
struct Tall: BoxShapeProps {
    static let kind: ShapeKind = "tall"
    static let properties = Properties<Tall> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

struct TallDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tall>, in context: RenderContext) {}
}

/// How many boxes the tall kind has.
let tallBoxes = 24

struct TallPlugin: CanvasPlugin {
    var id: PluginID { "tall" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(TallDefinition()) { tall in
            for index in 0..<tallBoxes {
                tall.details { DetailSection("Box \(index)", in: WalkerTab.self) { _ in DetailTextArea(.constant(""), label: "Box \(index)") } }
            }
        }
    }
}

/// A panel and a canvas stand-in in one window, a walker selected, and a key walk over them.
@MainActor
final class WalkedPanel {
    let editor: CanvasEditor
    let panel: PanelWindow
    let walk: KeyWalk
    let id: ShapeID

    init() throws {
        let editor = try gadgetEditor([WalkersPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        panel.window.isReleasedWhenClosed = false
        let id = editor.add(Walker(gadgetFrame))
        editor.selection = id
        panel.window.spin { panel.headerField != nil && panel.textViews.count >= 2 && !panel.tables.isEmpty }
        let canvas = panel.canvas
        self.editor = editor
        self.panel = panel
        self.id = id
        walk = KeyWalk(panel.window, editor: editor, menu: nil,
                       readers: [.canvas(canvas, selection: { editor.selectedShapeIDs.map { _ in "walker" } })])
        walk.standardControls = ["Allowed"]
        panel.window.makeFirstResponder(panel.headerField)
        panel.window.settle()
    }
}

@MainActor let panelWalkTests = Suite("Panel by keys", [
    test("Tab walks the title, the text box, the code editor, the list and the checkbox in order and comes round inside the panel; Shift-Tab undoes it") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        let start = w.walk.focus
        expectEqual(start.id, "window/Name")
        w.walk.expectCycle(inOrder: ["window/Name", "window/Notes", "window/Code", "window/Rows"], wraps: .closed)
        expectEqual(w.walk.focus.id, start.id, "round to the title, never out to the canvas: \(w.walk.traceText)")
    },
    test("Tab reaches the boxes scrolled out of the panel's view, and the ring comes round only after the last") {
        let editor = try gadgetEditor([TallPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        panel.window.isReleasedWhenClosed = false
        defer { panel.window.close() }
        editor.selection = editor.add(Tall(gadgetFrame))
        panel.window.spin { panel.textViews.count >= 2 }
        let walk = KeyWalk(panel.window, editor: editor, menu: nil, readers: [.canvas(panel.canvas, selection: { [] })])
        panel.window.settle()
        panel.window.makeFirstResponder(panel.textViews.first)
        panel.window.settle()
        let last = "window/Box \(tallBoxes - 1)"
        walk.go(last)
        expectEqual(walk.focus.id, last)
        expectEqual(walk.press(.tab).id, "window/Box 0", "round to the first, after the last of them all: \(walk.traceText)")
        expectEqual(walk.press(.backTab).id, last, "and back")
    },
    test("each stop of the panel shows and is named") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        var stops = [w.walk.focus]
        for _ in 0..<6 {
            let next = w.walk.press(.tab)
            if next.id == stops[0].id { break }
            stops.append(next)
        }
        w.walk.expectShows(stops)
    },
    test("Escape in the panel leaves it for the canvas, and the text typed stays") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        w.walk.go("window/Notes")
        w.panel.window.type("typed")
        w.walk.press(.escape)
        expect(w.panel.canvasHasKeyboard, w.walk.traceText)
        expectEqual(w.editor.props(w.id, as: Walker.self)?.notes, "typed")
    },
    test("Command-Return in a box with nothing to commit leaves the panel too") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        w.walk.go("window/Notes")
        w.panel.window.type("done")
        w.walk.press(.commandReturn)
        expect(w.panel.canvasHasKeyboard, w.walk.traceText)
        expectEqual(w.editor.props(w.id, as: Walker.self)?.notes, "done")
    },
    test("Next and Previous Inspector Tab wrap round the tabs, and the keyboard goes to the new tab's first control") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        let state = try require(w.editor.detailPanel)
        @MainActor func tab() throws -> DetailTabID? { state.currentTab(in: try w.editor.layout(w.id), for: Walker.kind) }
        w.panel.window.makeFirstResponder(w.panel.canvas)
        let next = Chord("]", [.command, .option]), previous = Chord("[", [.command, .option])
        expectEqual(try tab(), .of(WalkerTab.self))
        w.walk.press(next)
        w.panel.window.spin { w.walk.focus.id == "window/More notes" }
        expectEqual(try tab(), .of(SecondWalkerTab.self))
        expectEqual(w.walk.focus.id, "window/More notes", "the new tab's first control, not the canvas: \(w.walk.traceText)")
        // From the text, which has the keyboard now, the menu bar's items answer (the window's menu is the app's).
        w.editor.perform(.nextInspectorTab)
        expectEqual(try tab(), .of(ThirdWalkerTab.self))
        w.editor.perform(.nextInspectorTab)
        expectEqual(try tab(), .of(FrameTab.self))
        w.panel.window.spin { w.walk.focus.id == "window/Width" }
        expectEqual(w.walk.focus.id, "window/Width", "the Frame tab's first field")
        w.editor.perform(.nextInspectorTab)
        expectEqual(try tab(), .of(WalkerTab.self), "round to the first")
        w.panel.window.spin { w.walk.focus.id == "window/Notes" }
        expectEqual(w.walk.focus.id, "window/Notes", "under the strip, not the title above it")
        w.panel.window.makeFirstResponder(w.panel.canvas)
        w.walk.press(previous)
        expectEqual(try tab(), .of(FrameTab.self), "and back round")
        expectEqual(state.canStepTab, true)
        w.editor.selection = nil
        expectEqual(state.canStepTab, false)
        expect(!state.stepTab(by: 1), "with nothing selected there are no tabs to step")
    },
    test("a list is one Tab stop: Down and Up, Home and End move its highlight, and it lights what the row stands for only while the keyboard is in it") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        walkerHighlights = []
        w.walk.go("window/Rows")
        w.panel.window.spin { walkerHighlights.last == 100 }
        expectEqual(walkerHighlights.last ?? nil, 100, "entering the list highlights its first row: \(walkerHighlights)")
        for expected in [0, 1, 2, 2] {
            w.walk.press(.down)
            w.panel.window.spin { walkerHighlights.last == expected }
            expectEqual(walkerHighlights.last ?? nil, expected, "Down: \(walkerHighlights)")
            expectEqual(w.walk.focus.id, "window/Rows", "still the one stop")
        }
        w.walk.press(.up)
        w.panel.window.spin { walkerHighlights.last == 1 }
        expectEqual(walkerHighlights.last ?? nil, 1)
        w.walk.press(Chord(Key.home))
        w.panel.window.spin { walkerHighlights.last == 100 }
        expectEqual(walkerHighlights.last ?? nil, 100, "Home")
        w.walk.press(Chord(Key.end))
        w.panel.window.spin { walkerHighlights.last == 2 }
        expectEqual(walkerHighlights.last ?? nil, 2, "End")
        w.walk.press(.tab)
        w.panel.window.spin { walkerHighlights.last == .some(nil) }
        expect(walkerHighlights.last == .some(nil), "Tab leaves the list and lets go of the highlight: \(walkerHighlights)")
    },
    test("Return and Space run a row with Caps Lock on too") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        walkerHighlights = []
        walkerRowsActivated = []
        w.walk.go("window/Rows")
        w.walk.press(Chord.down.capsLock)
        w.panel.window.spin { walkerHighlights.last == 0 }
        w.walk.press(Chord.return.capsLock)
        w.walk.press(Chord.space.capsLock)
        expectEqual(walkerRowsActivated, [0, 0])
    },
    test("Return and Space on a row run it; Left and Right fold the head, and Left on a row goes up to its head") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        walkerHighlights = []
        walkerRowsActivated = []
        w.walk.go("window/Rows")
        w.walk.press(.down)
        w.panel.window.spin { walkerHighlights.last == 0 }
        w.walk.press(.return)
        w.walk.press(.space)
        expectEqual(walkerRowsActivated, [0, 0])
        w.walk.press(.left)
        w.panel.window.spin { walkerHighlights.last == 100 }
        expectEqual(walkerHighlights.last ?? nil, 100, "Left on a row: its head")
        w.walk.press(.left)
        w.panel.window.spin { w.panel.tables.first.map { $0.numberOfRows == 1 } == true }
        expectEqual(w.panel.tables.first?.numberOfRows, 1, "Left on a head folds it")
        w.walk.press(.right)
        w.panel.window.spin { w.panel.tables.first.map { $0.numberOfRows == 4 } == true }
        expectEqual(w.panel.tables.first?.numberOfRows, 4, "Right on a folded head unfolds it")
        w.walk.press(.return)
        w.panel.window.spin { w.panel.tables.first.map { $0.numberOfRows == 1 } == true }
        expectEqual(w.panel.tables.first?.numberOfRows, 1, "Return on a head folds it too")
        expectEqual(walkerRowsActivated, [0, 0])
    },
])
