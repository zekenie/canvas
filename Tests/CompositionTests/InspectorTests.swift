import AppKit
import Arrows
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import DecisionModels
import DetailPanel
import Find
import Geometry
import LanguageModels
import Mentions
import Neighbors
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Titles
import Types
import Validation

/// The app's window (a `BoardWindow`), unshown: the canvas (through `CanvasRepresentable`), filling the window,
/// with the shipped detail panel in the inspector's sheet over its trailing edge, and the table of contents in
/// the sidebar's over its leading edge while `showsSidebar` (hidden by default), wired by a `CanvasFocus` as
/// the app wires them. The editor keeps real
/// time, so SwiftUI's updates and the panel's hand-back land while the main run loop runs
/// (`window.spin`, from CanvasTesting). The window is deferred, never given a place in the window
/// server, so each turn lays its views out without drawing their layers, which nothing here looks
/// at (`render()` draws the canvas itself).
@MainActor
final class InspectorWindow {
    let editor: CanvasEditor
    let window = BoardWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    let focus = CanvasFocus()
    let host: NSHostingView<InspectorHost>
    let canvas: CanvasView

    /// Shows or hides the inspector, as View › Hide Inspector does.
    var showsDetails = true {
        didSet { host.rootView = InspectorHost(editor: editor, focus: focus, showsDetails: showsDetails, showsSidebar: showsSidebar) }
    }
    let showsSidebar: Bool

    /// Over an empty board, or `file`.
    init(file: CanvasFile? = nil, showsSidebar: Bool = false, decisions: any DecisionModel = ScriptedDecisionModel()) throws {
        editor = try file.map { CanvasEditor(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel(), decisionModel: decisions), file: $0, scheduler: TaskScheduler()) }
            ?? ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: TaskScheduler(), model: ScriptedLanguageModel(), decisionModel: decisions)
        self.showsSidebar = showsSidebar
        host = NSHostingView(rootView: InspectorHost(editor: editor, focus: focus, showsDetails: true, showsSidebar: showsSidebar))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        window.editor = editor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        canvas = try require(focus.canvas, "the representable hands its canvas view to the focus")
        window.settle()
    }

    /// The panel's views of a class: those in the inspector, after the canvas.
    func panel<View: NSView>(_: View.Type) -> [View] { host.descendants(View.self).filter { $0.isInInspector } }
    /// The panel's editable text fields under its header, in view order.
    var fields: [NSTextField] { panel(NSTextField.self).filter { $0.isEditable && !$0.isInPanelHeader(of: host) } }
    /// The header's title field (Titles' `TitleHeader`), for a shape renamed there.
    var titleField: NSTextField? { panel(NSTextField.self).first { $0.isEditable && $0.isInPanelHeader(of: host) } }
    /// The panel's lists.
    var tables: [NSTableView] { panel(NSTableView.self) }
    /// The panel's buttons under its header (whose back button is there once a shape is selected).
    var buttons: [NSButton] { panel(NSButton.self).filter { !$0.isInPanelHeader(of: host) } }
    /// The header's back button.
    var backButton: NSButton? { panel(NSButton.self).first { $0.isInPanelHeader(of: host) } }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }

    /// The lines of the selected shape's Issues tab (Validation's), as the panel shows them.
    var issues: [String] {
        guard let id = editor.selection, let record = editor.document[id], let state = editor.detailPanel else { return [] }
        return state.layout(for: record).statuses(in: .of(IssuesTab.self)).map(\.text)
    }

    /// A press on the canvas, at a point of the canvas's view: AppKit gives the canvas the keyboard
    /// first, as `NSWindow.sendEvent` does (which doesn't reach views in an unshown window).
    func click(_ point: CGPoint) {
        window.makeFirstResponder(canvas)
        time += 0.1
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: inContent(point), time: time))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: inContent(point), time: time + 0.05))
        window.settle()
    }

    /// A point of the canvas's view in the window content's top-left coordinates, where
    /// `window.mouse` takes it: the canvas fills the window, under the sheets.
    func inContent(_ point: CGPoint) -> CGPoint {
        let inWindow = canvas.convert(point, to: nil)
        return CGPoint(x: inWindow.x, y: host.frame.height - inWindow.y)
    }

    /// The canvas as the window draws it.
    func render() -> NSBitmapImageRep { renderBitmap(editor, size: canvas.bounds.size) }

    /// The path's crumbs that are buttons, over the canvas ("…" isn't one).
    var crumbs: [NSButton] {
        let folds = pathFolds(under: host)
        return host.descendants(NSButton.self).filter { button in
            let frame = canvas.convert(button.bounds, from: button)
            return !folds.contains { $0 === button } && canvas.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                && !button.isOnSheet(.leading) && !button.isOnSheet(.trailing)
        }
    }
    /// The table of contents' list, while the sidebar shows it.
    var contents: NSTableView? { host.descendants(NSTableView.self).first { $0.isTableOfContents && !$0.isHiddenOrHasHiddenAncestor } }
    /// Its rows (its header is above them).
    var contentsRows: Int { contents?.numberOfRows ?? 0 }
    /// The buttons in its header, above its rows: up from the board, while it can go up.
    var contentsHeaderButtons: [NSButton] {
        guard let table = contents else { return [] }
        return host.descendants(NSButton.self).filter { $0.isOnSheet(.leading) && !$0.isDescendant(of: table) }
    }

    private var time: TimeInterval = 1
}

/// The app's content view, less its toolbar: the canvas, with the path over it (its root crumb
/// named as the editor's told, `rootName`, which a board document's window does), the table of
/// contents in a sidebar, and the panel.
struct InspectorHost: View {
    let editor: CanvasEditor
    let focus: CanvasFocus
    let showsDetails: Bool
    var showsMinimap = false
    var showsSidebar = false
    var view: BoardViewState?

    var body: some View {
        CanvasRepresentable(editor: editor, focus: focus, showsMinimap: showsMinimap)
            .modifier(BoardChrome(editor: editor, showsSidebar: sidebarShown, showsInspector: shown, onExit: focus.take))
            .transaction { $0.disablesAnimations = true }
    }

    /// The board's view's, as the app binds it, where there is one (a board document's window), so
    /// what shows the inspector (Find's ⌘F) shows it; else as given.
    private var shown: Binding<Bool> {
        guard let view else { return .constant(showsDetails) }
        return Binding(get: { view.showsDetails }, set: { view.showsDetails = $0 })
    }

    /// The board's view's, as the app binds it, where there is one; else as given.
    private var sidebarShown: Binding<Bool> {
        guard let view else { return .constant(showsSidebar) }
        return Binding(get: { view.showsSidebar }, set: { view.showsSidebar = $0 })
    }
}

/// A note at (100, 100), 200 square.
func note(_ text: String = "") -> ShapeRecord<StickyNote> {
    ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: MentionText(plain: text)))
}

// The shipped panel beside the canvas, as the app places it.
@MainActor let inspectorTests = Suite("Inspector", [
    test("selecting a note shows its header, where it's named, and two tabs, Connections and Style") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        expect(w.titleField == nil)
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        expectEqual(w.editor.selection, shape.id)
        let state = try require(w.editor.detailPanel)
        expectEqual(state.layout(for: try require(w.editor.document[shape.id])).tabs.map(\.title), ["Connections", "Style"])
        expectEqual(w.fields.count, 0)
        expectEqual(w.tables.count, 0)
    },
    test("a note selected across the canvas's right edge keeps the part that showed in view as the inspector comes in over the canvas, which keeps its size") {
        let w = try InspectorWindow()
        let wide = w.canvas.bounds.width
        // Half of it past the canvas's edge.
        let frame = w.editor.camera.toWorld(CGRect(x: wide - 60, y: 250, width: 120, height: 120))
        let showed = frame.intersection(w.editor.camera.toWorld(w.editor.unobscuredViewport))
        expectEqual(showed.width, 60)
        let edge = w.editor.add(StickyNote(frame: frame, text: "Edge"))
        expect(w.titleField == nil, "nothing selected: no inspector")
        w.editor.selection = edge
        w.window.spin { w.titleField != nil && w.editor.coveredEdges.right > 0 }
        let slid = Date(timeIntervalSinceNow: 0.5)
        repeat { w.window.settle() } while Date() < slid
        expectEqual(w.canvas.bounds.width, wide, "the inspector covers the canvas: it takes none of its room")
        let shown = w.editor.camera.toView(showed)
        expect(w.editor.unobscuredViewport.maxX <= wide - w.editor.coveredEdges.right, "the clear part stops at the inspector")
        expect(w.editor.unobscuredViewport.contains(shown), "in view: \(shown) in \(w.editor.unobscuredViewport)")
    },
    test("typing into a panel field never switches tools") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        w.window.type("hnbfr")     // the Hand, Note, Subboard, Frame and Reference shortcuts, on the canvas
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], "hnbfr")
        expectEqual(w.editor.currentToolID, .select)
        expectEqual(w.editor.selection, shape.id)
    },
    test("Escape in the panel hands the keyboard to the canvas, and its next key picks a tool") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        expect(!w.canvasHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard)
        expectEqual(w.editor.selection, shape.id, "Escape in the panel isn't Escape on the canvas")
        w.window.type("b")
        expectEqual(w.editor.currentToolID, ToolID(placing: Subboard.kind))
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], nil)
    },
    test("hiding the inspector while a panel field has the keyboard hands it to the canvas, keeping what was typed") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        w.window.type("List")
        expect(!w.canvasHasKeyboard)
        w.showsDetails = false
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "not the window: \(String(describing: w.window.firstResponder))")
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], "List")
        w.window.type("b")
        expectEqual(w.editor.currentToolID, ToolID(placing: Subboard.kind))
    },
    test("a selection change that removes the focused field hands the keyboard to the canvas") {
        let w = try InspectorWindow()
        w.editor.transact { $0.insert(note("Buy milk")) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        w.editor.selection = nil
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "not the window: \(String(describing: w.window.firstResponder))")
    },
    test("an arrow shows its Arrow header and only its Connections and Style tabs") {
        let w = try InspectorWindow()
        let shape = note(), arrow = ShapeRecord(Arrow(start: .free(CGPoint(x: 400, y: 100)), end: .free(CGPoint(x: 600, y: 300))))
        w.editor.transact { $0.insert(shape); $0.insert(arrow) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        w.editor.selection = arrow.id
        w.window.spin { w.titleField == nil }
        let layout = try require(w.editor.detailPanel).layout(for: try require(w.editor.document[arrow.id]))
        expectEqual(layout.header, DetailHeader("Arrow", systemImage: "arrow.up.right"))
        expectEqual(layout.tabs.map(\.title), ["Connections", "Style"])
        expectEqual(w.fields.count, 0)
        expectEqual(w.tables.count, 0)
    },
    test("at its narrowest and its ideal width, a note's panel and each tab of a type note's and a subboard's fits the column, none pushing it wider") {
        // What widens a panel most: a note's long title, a type's schema whose one line runs far past
        // the column, a subboard's name.
        var titled = note("Buy milk and bread")
        titled[TitleProperty.self] = "Groceries for the week, and the party on Saturday"
        let schema = #"{"title": "Order", "type": "object", "properties": {"reference": {"type": "string", "description": "What the customer quotes when they call about this order, however long that takes"}}}"#
        let card = typeNote(schema, text: "An order", title: "Order", frame: CGRect(x: 400, y: 100, width: 200, height: 200))
        var sub = ShapeRecord(Subboard(frame: CGRect(x: 700, y: 100, width: 240, height: 160)))
        sub[TitleProperty.self] = "Payments"
        let panels: [(id: ShapeID, kind: ShapeKind, tabs: [any DetailTab.Type])] = [
            (titled.id, StickyNote.kind, []),
            (card.id, StickyNote.kind, [TypeSchemaTab.self]),
            (sub.id, Subboard.kind, [NeighborsTab.self, StyleTab.self]),
        ]
        @MainActor func choose<Tab: DetailTab>(_ tab: Tab.Type, for kind: ShapeKind, in editor: CanvasEditor) throws {
            try require(editor.detailPanel).choose(.of(tab), for: kind)
        }
        for width in [DetailStyle.minWidth, DetailStyle.idealWidth] {
            let editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: [AnyShapeRecord(titled), card, AnyShapeRecord(sub)]),
                                                   scheduler: TaskScheduler(), model: ScriptedLanguageModel())
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
            let hosting = NSHostingView(rootView: DetailPanelView(editor: editor))
            window.contentView = hosting
            for panel in panels {
                editor.selection = panel.id
                window.settle()
                // A panel without tabs is its header over no options: its title field, within the column.
                if panel.tabs.isEmpty {
                    let field = try require(hosting.descendants(NSTextField.self).first(where: \.isEditable), "\(panel.kind)'s header field")
                    let frame = field.convert(field.bounds, to: hosting)
                    expect(frame.minX >= 0 && frame.maxX <= width, "\(panel.kind)'s header at \(width): \(frame)")
                }
                for tab in panel.tabs {
                    try choose(tab, for: panel.kind, in: editor)
                    window.settle()
                    // The panel's own scroll view, the outermost.
                    let frame = try require(hosting.descendants(NSScrollView.self).first.map { $0.convert($0.bounds, to: hosting) })
                    expectEqual([hosting.bounds.width, frame.minX, frame.width], [width, 0, width], "\(panel.kind) \(tab.title) at \(width)")
                }
            }
        }
    },
    test("naming a note in its header puts a pill over it and names its row; Return hands the keyboard to the canvas") {
        let w = try InspectorWindow()
        let shape = note("Buy milk")
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        let untitled = w.render()
        let field = try require(w.titleField)
        expectEqual(field.placeholderString, "Note")
        w.window.focus(field)
        w.window.type("Groceries")      // r is the reference tool's shortcut, on the canvas
        w.window.settle()
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], "Groceries")
        expectEqual(w.editor.currentToolID, .select)
        // The pill, 9 to 27 points above the note's top-left corner at (100, 100).
        expect(changedPixels(untitled, w.render(), in: CGRect(x: 100, y: 75, width: 60, height: 12)) > 300, "the pill")
        w.window.pressReturn()
        w.window.spin { w.canvasHasKeyboard }
        w.editor.selection = nil
        expectEqual(w.editor.tableOfContents?.entries.map { $0.label?.text }, ["Groceries"])
    },
    test("a note whose title is too long has an Issues tab that says so, through ValidationDetailsPlugin, after its Connections and Style tabs; a note without issues has no such tab") {
        let w = try InspectorWindow()
        var long = note("Hi")
        long[TitleProperty.self] = String(repeating: "Groceries ", count: 9)
        let written = ShapeRecord(StickyNote(frame: CGRect(x: 400, y: 100, width: 200, height: 200), text: "Hi"))
        w.editor.transact { $0.insert(long); $0.insert(written) }
        w.click(CGPoint(x: 200, y: 200))
        expectEqual(w.editor.selection, long.id)
        let state = try require(w.editor.detailPanel)
        let record = try require(w.editor.document[long.id])
        expectEqual(state.layout(for: record).tabs.map(\.title), ["Connections", "Style", "Issues"])
        expectEqual(state.layout(for: record).statuses(in: .of(IssuesTab.self)),
                    [DetailStatus("Title is 90 characters long, and should be at most 80.", tone: .warning)])
        expectEqual(state.statuses(for: record), [], "nothing in the footer")
        w.click(CGPoint(x: 500, y: 200))
        expectEqual(w.editor.selection, written.id)
        expectEqual(state.layout(for: try require(w.editor.document[written.id])).tabs.map(\.title), ["Connections", "Style"])
        expectEqual(w.issues, [])
    },
    test("typing a subboard's name in the panel's header gives it a title's pill, and keeps Select") {
        let w = try InspectorWindow()
        w.window.makeFirstResponder(w.canvas)
        w.window.press("b")
        w.click(CGPoint(x: 300, y: 300))
        w.window.spin { w.titleField?.placeholderString == "Untitled Subboard" }
        let id = try require(w.editor.selection, "B, then a click, places a subboard")
        let frame = try require(w.editor.document[id]?.box)
        let untitled = w.render()
        w.window.focus(try require(w.titleField))
        w.window.type("base")     // b, a, s and e are tools' shortcuts, on the canvas
        expectEqual(w.editor.document[id]?[TitleProperty.self], "base")
        expectEqual(w.editor.currentToolID, .select)
        expectEqual(w.editor.selection, id)
        // Its title's pill, in the row 9 to 27 points above the card.
        let pill = CGRect(x: frame.minX, y: frame.minY - 28, width: 150, height: 20)
        expect(changedPixels(untitled, w.render(), in: pill) > 20, "the pill shows the new name")
    },
    test("inside a subboard, the sidebar lists its board under its name, with a way up") {
        let nest = NestedFile()
        let w = try InspectorWindow(file: nest.file, showsSidebar: true)
        w.window.spin { w.contentsRows == 3 }
        expectEqual(w.contentsHeaderButtons.count, 0, "nothing above the root")
        let contents = try require(w.editor.tableOfContents)
        expectEqual(contents.heading.title, "Board", "the root's, while no window has said what the file is called")
        w.editor.nameRoot("Roadmap")
        let root = contents.heading
        expectEqual(root.title, "Roadmap", "the file's name, as the window and the path's root crumb have it")
        expectEqual(root.up, nil)
        expect(w.editor.showBoard(nest.sBoard))
        w.window.spin { w.contentsHeaderButtons.count == 1 }
        let (first, second) = nest.notes(on: 2)
        expectEqual(w.editor.tableOfContents?.entries.map(\.id), [first, second, nest.t], "its notes (the arrow under the first) and the subboard in it")
        let heading = contents.heading
        expectEqual(heading.title, "Plans")
        expectEqual(heading.systemImage, "rectangle.stack")
        expectEqual(heading.up, .goUpBoard, "the board above, whatever is selected: ⌘↑ steps out of a group or a frame first")
        expectEqual(w.editor.registry.title(of: .goUpBoard), "Enclosing Board", "as the Go menu calls it")
        expectEqual(heading.upHelp, nil, "with no key, which is not always up a board")
        expect(w.editor.showBoard(nest.tBoard))
        expectEqual(contents.heading.title, "Untitled Subboard", "the placeholder, as the path has it")
        w.editor.goToEnclosingBoard()
        w.editor.selection = nil
        w.window.spin { w.contentsHeaderButtons.count == 1 }
        try require(w.contentsHeaderButtons.first).performClick(nil)
        w.window.spin { w.editor.board == .root }
        expectEqual(w.editor.selectedShapeIDs, [nest.s], "up, to the subboard")
    },
    test("what the panel shows and what heads its lists are plugins of their own, each after the plugins it joins; a list without them keeps the panel, the list and Find") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let all = ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let order = all.map(\.id)
        @MainActor func place(_ id: PluginID) throws -> Int { try require(order.firstIndex(of: id), "\(id) isn't shipped") }
        let faces: [(face: PluginID, after: [PluginID])] = [(.boardContents, [.boards, .tableOfContents]),
                                                           (.findPanel, [.findInBoards, .detailPanel]), (.boardHeadings, [.boards, .detailPanel]),
                                                           ("issue-walk-panel", [.findPanel, .detailPanel, "issue-walk"])]
        for (face, after) in faces {
            for owner in after { expect(try place(owner) < place(face), "\(face) comes after \(owner)") }
        }
        let without = try Registry(plugins: all.filter { plugin in !faces.contains { $0.face == plugin.id } })
        expect(!without.report.contains("detail takeover"), "the panel has no takeover")
        expect(without.hostSidebar != nil, "the list is still the window's sidebar")
        let editor = CanvasEditor(registry: without, file: CanvasFile(), scheduler: ManualScheduler())
        editor.nameRoot("Roadmap")
        expectEqual(editor.tableOfContents?.heading.title, "Board", "the list's own heading")
        expectEqual(editor.boardHeading(of: .root), BoardHeading("Board"), "and the panel's board headings, which Find's rows read")
        expectEqual(editor.name(of: .root), "Roadmap", "Boards names the root all the same")
    },
    test("inside a subboard, the way up is back once a click on empty canvas has let go of a note") {
        let nest = NestedFile()
        let w = try InspectorWindow(file: nest.file, showsSidebar: true)
        expect(w.editor.showBoard(nest.sBoard))
        w.editor.camera = Camera()
        w.window.spin { w.contentsHeaderButtons.count == 1 }
        w.click(CGPoint(x: 180, y: 180))
        expectEqual(w.editor.selection, nest.notes(on: 2).0)
        w.window.spin { w.titleField != nil }
        expectEqual(w.contentsRows, 3, "the list stays")
        // As AppKit delivers it: the heading draws while the press is under way, when there's no
        // going up.
        let empty = w.inContent(CGPoint(x: 400, y: 600))
        w.window.makeFirstResponder(w.canvas)
        w.canvas.mouseDown(with: w.window.mouse(.leftMouseDown, at: empty, time: 10))
        w.window.settle()
        expect(!w.editor.canPerform(.goUpBoard), "mid-press")
        w.canvas.mouseUp(with: w.window.mouse(.leftMouseUp, at: empty, time: 10.05))
        expect(w.editor.canPerform(.goUpBoard))
        w.window.spin { w.contentsHeaderButtons.count == 1 }
    },
])
