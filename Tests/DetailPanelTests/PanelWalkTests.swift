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

/// A box kind whose panel holds a list with a highlight and pages of its own (`PagedRows`).
struct Pager: BoxShapeProps {
    static let kind: ShapeKind = "pager"
    static let properties = Properties<Pager> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

struct PagerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pager>, in context: RenderContext) {}
}

/// What the pager's list is given and tells: the highlight it is handed, the heads folded, and the
/// page keys it was asked about.
@Observable @MainActor final class PagerModel {
    var highlight: Int?
    var folded: Set<Int> = []
    @ObservationIgnored var pageLog: [Bool] = []
    /// What Return, Space and a click ran, in order: a row's `activate`, and the click of row 11, which has one of its own.
    @ObservationIgnored var activated: [Int] = []
    @ObservationIgnored var clicked: [Int] = []
    /// The list's handle, as a caller that enters the list itself keeps one.
    @ObservationIgnored let handle = DetailListHandle()
    /// The most of the panel's height the list may take, if it says.
    var share: CGFloat?
    /// The pager's boards: a head and its rows, each; a row's board is its tens.
    static let heads = [100, 200]
    static let rows = [100: [0, 1, 2], 200: [10, 11, 12]]
    /// Rows under the first board after its three, to make the list taller than the panel (500...).
    var extra = 0
    /// How `pages` answers: the next and previous board, or nil for every press.
    @ObservationIgnored var pagesGiven = true
    /// Whether the list is given `pages` at all.
    @ObservationIgnored var givesPages = true

    /// The rows a board has, in order.
    func rows(of head: Int) -> [Int] { (Self.rows[head] ?? []) + (head == 100 ? Array(500..<(500 + extra)) : []) }

    /// Every line of the list, in order, for what is folded.
    var lines: [Int] { Self.heads.flatMap { head in folded.contains(head) ? [head] : [head] + rows(of: head) } }

    /// The head of the board a highlight is on.
    func head(of id: Int?) -> Int? { id.flatMap { Self.heads.contains($0) ? $0 : ($0 < 10 || $0 >= 500 ? 100 : 200) } }
}

/// Two boards, each a head and three rows; Page Down and Page Up go to the next and previous board's head.
struct PagedRows: View {
    let model: PagerModel

    var body: some View {
        var items: [DetailRowItem<Int>] = []
        for head in PagerModel.heads {
            let isFolded = model.folded.contains(head)
            items.append(DetailRowItem(id: head, kind: .head(isFolded: isFolded)) { [model] in
                if isFolded { model.folded.remove(head) } else { model.folded.insert(head) }
            })
            if !isFolded {
                items += model.rows(of: head).map { row in
                    var item = DetailRowItem(id: row, parent: head) { [model] in model.activated.append(row) }
                    if row == 11 { item.click = { [model] in model.clicked.append(row) } }
                    return item
                }
            }
        }
        let binding = Binding(get: { model.highlight }, set: { model.highlight = $0 })
        let pages: ((Bool) -> Int?)? = !model.givesPages ? nil : { [model] forward in
            model.pageLog.append(forward)
            guard model.pagesGiven else { return nil }
            guard let head = model.head(of: model.highlight), let at = PagerModel.heads.firstIndex(of: head) else { return nil }
            let to = at + (forward ? 1 : -1)
            return PagerModel.heads.indices.contains(to) ? PagerModel.heads[to] : nil
        }
        return DetailRowList(items, label: "Paged", handle: model.handle, highlight: binding, pages: pages, maxHeightShare: model.share) { item in
            Text(PagerModel.heads.contains(item.id) ? "Board \(item.id)" : "Row \(item.id)")
                .detailRowAccessibility(label: "\(item.id)", activate: item.activate)
        }
    }
}

struct PagersPlugin: CanvasPlugin {
    let model: PagerModel
    var id: PluginID { "pagers" }
    func register(into registrar: inout PluginRegistrar) {
        let model = model
        registrar.shape(PagerDefinition()) { pager in
            pager.details {
                DetailSection("Paged", in: WalkerTab.self) { _ in PagedRows(model: model) }
            }
        }
    }
}

/// A panel with the pager selected, and a walk over it.
@MainActor
final class PagedPanel {
    let editor: CanvasEditor
    let panel: PanelWindow
    let walk: KeyWalk
    let model = PagerModel()

    init(extraRows: Int = 0, band: BandModel? = nil, givesPages: Bool = true) throws {
        model.extra = extraRows
        model.givesPages = givesPages
        let editor = try gadgetEditor([PagersPlugin(model: model)] + (band.map { [BandPlugin(model: $0)] } ?? []), scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        panel.window.isReleasedWhenClosed = false
        editor.selection = editor.add(Pager(gadgetFrame))
        panel.window.spin { !panel.tables.isEmpty }
        self.editor = editor
        self.panel = panel
        walk = KeyWalk(panel.window, editor: editor, menu: nil, readers: [.canvas(panel.canvas, selection: { [] })])
        panel.window.settle()
    }

    /// The keyboard goes to the list, as a Tab to it does.
    func enter() {
        panel.window.makeFirstResponder(panel.tables.first)
        panel.window.settle()
    }

    /// How far the list's table is scrolled.
    var scrolled: CGFloat { panel.tables.first?.enclosingScrollView?.contentView.bounds.origin.y ?? 0 }

    /// Whether the table has scrolled to the line for `id`: its rect meets the clip (SwiftUI's scroll to a row ends a few
    /// points short of it, so it need not be whole).
    func shows(_ id: Int) -> Bool {
        guard let table = panel.tables.first, let row = model.lines.firstIndex(of: id) else { return false }
        return table.visibleRect.intersects(table.rect(ofRow: row))
    }

    /// The row the table has selected, as the model's id.
    var selected: Int? {
        guard let table = panel.tables.first, table.selectedRow >= 0 else { return nil }
        let ids = model.lines
        return ids.indices.contains(table.selectedRow) ? ids[table.selectedRow] : nil
    }
}

/// A panel and a canvas stand-in in one window, a walker selected, and a key walk over them.
@MainActor
final class WalkedPanel {
    let editor: CanvasEditor
    let panel: PanelWindow
    let walk: KeyWalk
    let id: ShapeID

    /// `band`: a band over the panel (TakeoverTests' `BandPlugin`), active or not.
    init(band: BandModel? = nil, otherBand: BandModel? = nil) throws {
        let editor = try gadgetEditor([WalkersPlugin()] + (band.map { [BandPlugin(model: $0)] } ?? [])
                                      + (otherBand.map { [BandPlugin(model: $0, name: "Other")] } ?? []), scheduler: TaskScheduler())
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
        walk.standardControls = ["Allowed", "Done"]
        panel.window.makeFirstResponder(panel.headerField)
        panel.window.settle()
    }
}

/// A menu item's target that counts its runs.
@MainActor final class MenuCounter: NSObject {
    var count = 0
    @objc func run(_ sender: Any?) { count += 1 }
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
    test("⌘↓, ⌘↑, ⌥Tab and ⌥⇧Tab do nothing in a list that has the keyboard, and ⌘↑ with the keyboard elsewhere still reaches the menu") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        walkerHighlights = []
        w.walk.go("window/Rows")
        w.panel.window.spin { walkerHighlights.last == 100 }
        w.walk.press(.down)
        w.panel.window.spin { walkerHighlights.last == 0 }
        let table = w.panel.tables.first
        let up = Chord(Key.up, .command)
        let menu = NSMenu()
        let target = MenuCounter()
        let item = NSMenuItem(title: "Out", action: #selector(MenuCounter.run(_:)), keyEquivalent: "\u{F700}")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)
        let driver = KeyDriver(w.panel.window, menu: menu)
        for chord in [Chord(Key.down, .command), up, Chord.optionTab, Chord.optionBackTab] {
            let delivery = driver.send(chord)
            driver.release(chord)
            w.panel.window.settle()
            expect(w.panel.window.firstResponder === table, "\(chord): the list keeps the keyboard")
            expectEqual(walkerHighlights.last ?? nil, 0, "\(chord): the highlight stays")
            expect(delivery.menuItem == nil, "\(chord): the menu is not reached")
        }
        expectEqual(target.count, 0, "the list took ⌘↑ from the menu")
        w.panel.window.makeFirstResponder(w.panel.canvas)
        w.panel.window.settle()
        let delivery = driver.send(up)
        driver.release(up)
        expect(delivery.menuItem === item, "with the keyboard off the list ⌘↑ reaches the menu")
        expectEqual(target.count, 1)
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
    test("a band is the first stop of the panel's ring and the last stop's Tab comes round to it, ⇧Tab from it to the last; as the band goes the ring closes on the title again") {
        let band = BandModel()
        band.active = true
        let w = try WalkedPanel(band: band)
        defer { w.panel.window.close() }
        w.panel.window.spin { w.panel.fields.contains { $0.placeholderString == "Band" } }
        w.walk.go("window/Band")
        w.walk.expectCycle(inOrder: ["window/Band", "window/Name", "window/Notes", "window/Code", "window/Rows"], wraps: .closed)
        w.walk.go("window/Band")
        let last = w.walk.press(.backTab).id
        expect(last == "window/Rows" || last == "window/Allowed", "⇧Tab from the band goes round to the panel's last stop: \(last)")
        expectEqual(w.walk.press(.tab).id, "window/Band", "and Tab from the last comes round to the band: \(w.walk.traceText)")
        expectEqual(w.walk.press(.tab).id, w.walk.keyboardNavigation ? "window/Done" : "window/Name", "the band's own stops before the panel's")
        w.walk.go("window/Band")
        w.walk.expectShows([w.walk.focus])
        w.walk.go("window/Name")
        band.active = false
        w.panel.window.spin { !w.panel.fields.contains { $0.placeholderString == "Band" } }
        let wrapped = w.walk.press(.backTab).id
        expect(wrapped == "window/Rows" || wrapped == "window/Allowed", "the ring is closed on the title now: ⇧Tab from it goes to the last: \(wrapped)")
        expectEqual(w.walk.press(.tab).id, "window/Name")
    },
    test("Escape in a list under a band gives the band the keyboard and ⌘. cancels it: a table's Escape and ⌘. both come as cancelOperation:, told apart") {
        let band = BandModel()
        band.active = true
        let w = try WalkedPanel(band: band)
        defer { w.panel.window.close() }
        w.panel.window.spin { w.panel.fields.contains { $0.placeholderString == "Band" } }
        w.walk.go("window/Rows")
        w.walk.press(.escape)
        w.panel.window.spin { w.walk.focus.id == "window/Band" }
        expectEqual(w.walk.focus.id, "window/Band", "the band has the keyboard: \(w.walk.traceText)")
        expectEqual(band.log, [])
        w.walk.press(.escape)
        w.panel.window.spin { w.panel.canvasHasKeyboard }
        expect(w.panel.canvasHasKeyboard, "from the band, the canvas: \(w.walk.traceText)")
        expectEqual(band.log, [])
        w.panel.window.makeFirstResponder(w.panel.tables.first)
        w.panel.window.settle()
        w.walk.press(.commandPeriod)
        w.panel.window.spin { w.panel.canvasHasKeyboard }
        expectEqual(band.log, ["cancel"], "⌘. in the list ends the band")
        expect(w.panel.canvasHasKeyboard)
    },
    test("with Keyboard navigation off the band's button is no stop, the field still is, and Escape from the panel still finds the band's field") {
        let band = BandModel()
        band.active = true
        let w = try WalkedPanel(band: band)
        defer { w.panel.window.close() }
        w.panel.window.spin { w.panel.fields.contains { $0.placeholderString == "Band" } }
        w.walk.go("window/Band")
        if !w.walk.keyboardNavigation {
            expect(!w.walk.press(.tab).id.hasSuffix("Done"), "a standard control is out of the ring: \(w.walk.traceText)")
            expect(w.walk.skipped.isEmpty || w.walk.skipped.allSatisfy { ["Allowed", "Done"].contains($0) })
        }
        w.walk.go("window/Name")
        w.walk.press(.escape)
        w.panel.window.spin { w.walk.focus.id == "window/Band" }
        expectEqual(w.walk.focus.id, "window/Band")
    },
    test("a list given its highlight reads it and writes the row a key lands on, never nil as the keyboard leaves or its row folds away") {
        let w = try PagedPanel()
        defer { w.panel.window.close() }
        w.model.highlight = 11
        w.panel.window.spin { w.selected == 11 }
        expectEqual(w.selected, 11, "the table shows the caller's highlight")
        w.model.highlight = nil
        w.enter()
        w.panel.window.spin { w.model.highlight == 100 }
        expectEqual(w.model.highlight, 100, "entering the list with none highlights the first row")
        w.walk.press(.down)
        w.panel.window.spin { w.model.highlight == 0 }
        expectEqual(w.model.highlight, 0)
        w.walk.press(.tab)
        w.panel.window.settle()
        expectEqual(w.model.highlight, 0, "the keyboard left, the highlight stays")
        w.model.highlight = 12
        w.panel.window.spin { w.selected == 12 }
        expectEqual(w.selected, 12, "written from outside while the list has no keyboard")
        w.model.folded.insert(200)
        w.panel.window.settle()
        expectEqual(w.model.highlight, 12, "its row folded away, the highlight is the caller's still")
        w.model.folded = []
        w.panel.window.spin { w.selected == 12 }
        expectEqual(w.selected, 12, "and shows again when the row does")
    },
    test("Page Up and Page Down go where a list's pages say, once a press, nowhere on nil, and the arrows still walk the rows") {
        let w = try PagedPanel()
        defer { w.panel.window.close() }
        w.enter()
        w.panel.window.spin { w.model.highlight == 100 }
        w.walk.press(Chord(Key.pageDown))
        w.panel.window.spin { w.model.highlight == 200 }
        expectEqual(w.model.highlight, 200, "Page Down: the next board's head")
        expectEqual(w.model.pageLog, [true], "asked once")
        w.walk.press(Chord(Key.pageDown))
        w.panel.window.settle()
        expectEqual(w.model.highlight, 200, "no board after the last: it stays")
        expectEqual(w.model.pageLog, [true, true])
        w.walk.press(Chord(Key.pageUp))
        w.panel.window.spin { w.model.highlight == 100 }
        expectEqual(w.model.highlight, 100, "Page Up")
        expectEqual(w.model.pageLog, [true, true, false])
        w.walk.press(.down)
        w.panel.window.spin { w.model.highlight == 0 }
        w.walk.press(.down)
        w.panel.window.spin { w.model.highlight == 1 }
        w.walk.press(Chord(Key.pageDown))
        w.panel.window.spin { w.model.highlight == 200 }
        expectEqual(w.model.highlight, 200, "from a row, the next board")
        expect(w.panel.window.firstResponder === w.panel.tables.first, "still the one stop")
    },
    test("a list with no pages of its own leaves Page Up and Page Down to the table") {
        let w = try WalkedPanel()
        defer { w.panel.window.close() }
        walkerHighlights = []
        w.walk.go("window/Rows")
        w.panel.window.spin { walkerHighlights.last == 100 }
        w.walk.press(Chord(Key.pageDown))
        w.panel.window.settle()
        expectEqual(walkerHighlights.last ?? nil, 100, "the table's paging scrolls, and moves no highlight: \(walkerHighlights)")
        expectEqual(w.walk.focus.id, "window/Rows")
    },
    test("the ring closes again as a band arrives, and as one band replaces another") {
        let band = BandModel(), other = BandModel()
        let w = try WalkedPanel(band: band, otherBand: other)
        defer { w.panel.window.close() }
        let nav = w.walk.keyboardNavigation
        @MainActor func pastRetry() {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            w.panel.window.settle()
        }
        w.walk.go("window/Name")
        let before = w.walk.press(.backTab).id
        expect(before == "window/Rows" || before == "window/Allowed", "no band: ⇧Tab from the title goes round to the last stop: \(before)")
        w.walk.go("window/Name")
        band.active = true
        w.panel.window.spin { w.panel.fields.contains { $0.placeholderString == "Band" } }
        pastRetry()
        expectEqual(w.walk.focus.id, "window/Name", "the keyboard didn't move: \(w.walk.traceText)")
        expectEqual(w.walk.press(.backTab).id, nav ? "window/Done" : "window/Band", "the band joined the ring first, with no key moving the keyboard: \(w.walk.traceText)")
        w.walk.go("window/Name")
        band.active = false
        other.active = true
        w.panel.window.spin { w.panel.fields.contains { $0.placeholderString == "Other" } && !w.panel.fields.contains { $0.placeholderString == "Band" } }
        pastRetry()
        expectEqual(w.walk.focus.id, "window/Name")
        expectEqual(w.walk.press(.backTab).id, nav ? "window/Done" : "window/Other", "and the second band's controls replaced the first's: \(w.walk.traceText)")
    },
    test("a band that is one button: Escape from the panel gives it the button with Keyboard navigation on, and with it off goes straight to the canvas") {
        let nav = NSApplication.shared.isFullKeyboardAccessEnabled
        let band = BandModel()
        let editor = try gadgetEditor([BandPlugin(model: band, buttonOnly: true)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        panel.window.isReleasedWhenClosed = false
        defer { panel.window.close() }
        editor.selection = editor.add(Gadget(gadgetFrame))
        band.active = true
        // The band's button, by its place: the topmost of the panel's buttons, the band being above everything (the header's
        // back button too, when there is one). SwiftUI draws its label, so the AppKit button has no title.
        @MainActor func done() -> NSButton? {
            panel.hosting.descendants(NSButton.self).filter { !($0 is NSPopUpButton) }
                .min { $0.convert($0.bounds, to: panel.hosting).minY < $1.convert($1.bounds, to: panel.hosting).minY }
        }
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Name" } && done() != nil }
        let state = try require(editor.detailPanel)
        panel.window.focus(try panel.field("Name"))
        expectEqual(state.focusBand(), nav, "the button takes the keyboard only with Keyboard navigation on")
        if nav { expect(state.keyboardPlace == .band && panel.window.firstResponder === done(), "the button has it") }
        panel.window.focus(try panel.field("Name"))
        panel.window.pressEscape()
        if nav {
            panel.window.spin { state.keyboardPlace == .band }
            expect(state.keyboardPlace == .band, "Escape: the band's button")
            expectEqual(panel.exits, 0)
            panel.window.pressEscape()
            panel.window.spin { panel.exits == 1 }
        } else {
            panel.window.spin { panel.canvasHasKeyboard }
        }
        expectEqual(panel.exits, 1)
        expect(panel.canvasHasKeyboard, "and then the canvas")
    },
    test("a band is the panel's, not a scrolled table's whose middle sweeps through its strip") {
        let band = BandModel()
        band.active = true
        let w = try PagedPanel(extraRows: 120, band: band)
        defer { w.panel.window.close() }
        w.panel.window.spin { w.panel.fields.contains { $0.placeholderString == "Band" } }
        let state = try require(w.editor.detailPanel)
        let table = try require(w.panel.tables.first)
        let scroll = try require(table.enclosingScrollView)
        let strip = try require(w.panel.fields.first { $0.placeholderString == "Band" }).convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: nil).midY
        w.panel.window.makeFirstResponder(table)
        w.panel.window.settle()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let middle = table.convert(table.bounds, to: nil).midY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: strip - middle))
        scroll.reflectScrolledClipView(scroll.contentView)
        let swept = table.convert(table.bounds, to: nil).midY
        expect(abs(swept - strip) < 3, "the table's own middle is in the band's strip now: \(swept) against \(strip)")
        expect(state.keyboardPlace == .content, "the list has the keyboard, not the band: \(String(describing: state.keyboardPlace))")
        expect(state.focusBand(), "the band takes it")
        expect(w.panel.window.firstResponder !== table, "the band's control, not the table")
        expect(state.keyboardPlace == .band)
    },
    test("a click runs the line's own click when it has one, else its activate; Return and Space always activate") {
        let w = try PagedPanel()
        defer { w.panel.window.close() }
        @MainActor func buttons() -> [NSButton] {
            let table = w.panel.tables.first
            return (table?.descendants(NSButton.self) ?? []).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        }
        expectEqual(buttons().count, 8, "a button a line")
        buttons()[6].performClick(nil)
        w.panel.window.spin { w.model.highlight == 11 }
        expectEqual(w.model.highlight, 11, "a click highlights the line")
        expectEqual(w.model.clicked, [11], "row 11 has a click of its own")
        expectEqual(w.model.activated, [], "and activate is not run")
        buttons()[7].performClick(nil)
        w.panel.window.spin { w.model.highlight == 12 }
        expectEqual(w.model.activated, [12], "a row with none activates on a click")
        w.enter()
        w.walk.press(.up)
        w.panel.window.spin { w.model.highlight == 11 }
        w.walk.press(.return)
        w.panel.window.spin { w.model.activated.count == 2 }
        expectEqual(w.model.activated, [12, 11], "Return on row 11 activates it, whatever its click does")
        expectEqual(w.model.clicked, [11])
    },
    test("a list given a share of the panel's height is no taller than that share, and one without it keeps the panel less 96 points") {
        let w = try PagedPanel(extraRows: 120)
        defer { w.panel.window.close() }
        let table = try require(w.panel.tables.first)
        let scroll = try require(table.enclosingScrollView)
        w.panel.window.settle()
        let whole = scroll.frame.height
        w.model.share = 0.3
        w.panel.window.spin { scroll.frame.height < whole - 10 }
        let share = scroll.frame.height
        expect(share < whole - 10, "a share of 0.3 is shorter than the panel less 96: \(share) against \(whole)")
        expect(abs(share - 0.3 * (whole + 96)) < 6, "and is that share of the panel's height: \(share) of \(whole + 96)")
        w.model.share = nil
        w.panel.window.spin { abs(scroll.frame.height - whole) < 1 }
        expect(abs(scroll.frame.height - whole) < 1, "unset, the panel less 96 again")
    },
    test("a highlight on a row that appears as its head unfolds brings it into view") {
        let w = try PagedPanel(extraRows: 60)
        defer { w.panel.window.close() }
        w.model.folded = [100]
        w.panel.window.settle()
        w.model.highlight = 530
        w.panel.window.settle()
        w.model.folded = []
        w.panel.window.spin { w.shows(530) }
        expect(w.shows(530), "the row is scrolled to as it appears: \(w.scrolled)")
    },
    test("entering a list through its handle scrolls its table to the highlight, as a list that opens far down needs") {
        let w = try PagedPanel(extraRows: 60)
        defer { w.panel.window.close() }
        w.model.highlight = 530
        w.panel.window.spin { w.shows(530) }
        expect(w.shows(530), "written from outside, the row is in view")
        let scroll = try require(w.panel.tables.first?.enclosingScrollView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        w.panel.window.settle()
        expect(!w.shows(530), "scrolled away to the top")
        expect(w.model.handle.enter(), "the keyboard goes in")
        w.panel.window.spin { w.shows(530) }
        expect(w.shows(530), "and the table is at the highlight: \(w.scrolled)")
        expectEqual(w.model.highlight, 530, "which stays")
    },
    test("a highlight written from outside brings its row into view, with the keyboard in the list or not") {
        let w = try PagedPanel(extraRows: 60)
        defer { w.panel.window.close() }
        expect(!w.shows(530), "a row well down starts below the fold")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        w.panel.window.settle()
        w.model.highlight = 530
        w.panel.window.spin { w.shows(530) }
        expect(w.shows(530), "written while the keyboard is elsewhere: \(w.scrolled)")
        w.enter()
        w.panel.window.settle()
        expectEqual(w.model.highlight, 530, "entering keeps a highlight that is on a row")
        w.model.highlight = 0
        w.panel.window.spin { w.shows(0) }
        expect(w.shows(0), "written with the keyboard in the list: \(w.scrolled)")
    },
    test("entering a list whose highlight is on a row that is not in it highlights its first row; the arrows and the fold keys write the caller's highlight") {
        let w = try PagedPanel()
        defer { w.panel.window.close() }
        w.model.folded = [200]
        w.model.highlight = 11
        w.panel.window.settle()
        w.enter()
        w.panel.window.spin { w.model.highlight == 100 }
        expectEqual(w.model.highlight, 100, "11 is folded away: the first row, as entering a list with none")
        w.walk.press(.down)
        w.panel.window.spin { w.model.highlight == 0 }
        w.walk.press(.left)
        w.panel.window.spin { w.model.highlight == 100 }
        expectEqual(w.model.highlight, 100, "Left on a row: its head")
        expect(!w.model.folded.contains(100))
        w.walk.press(.left)
        w.panel.window.spin { w.model.folded.contains(100) }
        expect(w.model.folded.contains(100), "Left on a head folds it")
        expectEqual(w.model.highlight, 100)
        w.walk.press(.right)
        w.panel.window.spin { !w.model.folded.contains(100) }
        expect(!w.model.folded.contains(100), "Right unfolds it")
        expectEqual(w.model.highlight, 100)
        w.walk.press(.down)
        w.panel.window.spin { w.model.highlight == 0 }
        expectEqual(w.model.highlight, 0, "and the arrows go on from there")
    },
    test("pages that answer nil take the key and the table does not scroll; with no pages at all the table does") {
        let given = try PagedPanel(extraRows: 120)
        defer { given.panel.window.close() }
        given.model.pagesGiven = false
        given.enter()
        given.panel.window.spin { given.model.highlight == 100 }
        given.walk.press(Chord(Key.pageDown))
        given.panel.window.settle()
        expectEqual(given.model.pageLog, [true], "asked")
        expectEqual(given.scrolled, 0, "the key was the list's, and nil moved nothing")
        expectEqual(given.model.highlight, 100)
        let none = try PagedPanel(extraRows: 120, givesPages: false)
        defer { none.panel.window.close() }
        none.enter()
        none.panel.window.spin { none.model.highlight == 100 }
        none.walk.press(Chord(Key.pageDown))
        none.panel.window.spin { none.scrolled > 0 }
        expect(none.scrolled > 0, "the table took the key and scrolled a screenful")
        expectEqual(none.model.pageLog, [], "and nothing was asked")
    },
])
