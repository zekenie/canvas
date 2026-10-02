import AppKit
import Arrows
import Boards
import Canvas
import CanvasTesting
import CanvasUI
import Composition
import DetailPanel
import Geometry
import LanguageModels
import Mentions
import Schemas
import Selection
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Titles
import ValidationDetails

/// The app's window (a `BoardWindow`), unshown: the canvas (through `CanvasRepresentable`) with the shipped detail
/// panel in an `.inspector`, wired by a `CanvasFocus` as the app wires them. The editor keeps real
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
        didSet { host.rootView = InspectorHost(editor: editor, focus: focus, showsDetails: showsDetails) }
    }

    /// Over an empty board, or `file`.
    init(file: CanvasFile? = nil) throws {
        editor = try file.map { CanvasEditor(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel()), file: $0, scheduler: TaskScheduler()) }
            ?? ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: TaskScheduler(), model: ScriptedLanguageModel())
        host = NSHostingView(rootView: InspectorHost(editor: editor, focus: focus, showsDetails: true))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        window.editor = editor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        canvas = try require(focus.canvas, "the representable hands its canvas view to the focus")
        window.settle()
    }

    /// The panel's editable text fields under its header, in view order.
    var fields: [NSTextField] { host.descendants(NSTextField.self).filter { $0.isEditable && !$0.isInPanelHeader(of: host) } }
    /// The header's title field (Titles' `TitleHeader`), for a shape renamed there.
    var titleField: NSTextField? { host.descendants(NSTextField.self).first { $0.isEditable && $0.isInPanelHeader(of: host) } }
    /// The panel's lists, less the table of contents.
    var tables: [NSTableView] { host.descendants(NSTableView.self).filter { !$0.isTableOfContents } }
    /// The panel's buttons under its header (whose back button is there once a shape is selected).
    var buttons: [NSButton] { host.descendants(NSButton.self).filter { !$0.isInPanelHeader(of: host) } }
    /// The header's back button.
    var backButton: NSButton? { host.descendants(NSButton.self).first { $0.isInPanelHeader(of: host) } }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }

    /// The lines of the selected shape's Issues tab (ValidationDetails'), as the panel shows them.
    var issues: [String] {
        guard let id = editor.selection, let record = editor.document[id], let state = editor.detailPanel else { return [] }
        return state.layout(for: record).statuses(in: .of(IssuesTab.self)).map(\.text)
    }

    /// A press on the canvas, at a view point: AppKit gives the canvas the keyboard first, as
    /// `NSWindow.sendEvent` does (which doesn't reach views in an unshown window).
    func click(_ point: CGPoint) {
        window.makeFirstResponder(canvas)
        time += 0.1
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: point, time: time))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: point, time: time + 0.05))
        window.settle()
    }

    /// The canvas as the window draws it.
    func render() -> NSBitmapImageRep { renderBitmap(editor, size: canvas.bounds.size) }

    /// The path's crumbs that are buttons, over the canvas ("…" isn't one).
    var crumbs: [NSButton] {
        let folds = pathFolds(under: host)
        return host.descendants(NSButton.self).filter { button in
            let frame = canvas.convert(button.bounds, from: button)
            return !folds.contains { $0 === button } && canvas.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }
    /// The table of contents' list, while the panel shows it.
    var contents: NSTableView? { host.descendants(NSTableView.self).first { $0.isTableOfContents } }
    /// Its rows, less its header.
    var contentsRows: Int { max(0, (contents?.numberOfRows ?? 0) - 1) }
    /// The buttons in its header: up from the board, while it can go up.
    var contentsHeaderButtons: [NSButton] {
        guard let table = contents, table.numberOfRows > 0 else { return [] }
        let header = table.rect(ofRow: 0)
        return table.descendants(NSButton.self).filter { header.contains($0.convert($0.bounds, to: table)) }
    }

    private var time: TimeInterval = 1
}

/// The app's content view, less its toolbar: the canvas, with the path over it (its root crumb
/// named by `view`'s file name), and the panel.
struct InspectorHost: View {
    let editor: CanvasEditor
    let focus: CanvasFocus
    let showsDetails: Bool
    var showsMinimap = false
    var view: BoardViewState?

    var body: some View {
        CanvasRepresentable(editor: editor, focus: focus, showsMinimap: showsMinimap)
            .overlay(alignment: .top) { ShippedPlugins.boardPath(editor: editor, rootName: view?.fileName ?? "") }
            .inspector(isPresented: .constant(showsDetails)) {
                ShippedPlugins.detailPanel(editor: editor, onExit: focus.take, rootName: view?.fileName ?? "")
            }
            .transaction { $0.disablesAnimations = true }
    }
}

/// A note at (100, 100), 200 square.
func note(_ text: String = "") -> ShapeRecord<StickyNote> {
    ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: MentionText(plain: text)))
}

// The shipped panel beside the canvas, as the app places it.
@MainActor let inspectorTests = Suite("Inspector", [
    test("selecting a note shows its header, where it's named, and no tabs") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        expect(w.titleField == nil)
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        expectEqual(w.editor.selection, shape.id)
        let state = try require(w.editor.detailPanel)
        expectEqual(state.layout(for: try require(w.editor.document[shape.id])).tabs, [])
        expectEqual(w.fields.count, 0)
        expectEqual(w.tables.count, 0)
    },
    test("typing into a panel field never switches tools") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        w.window.type("hnbfs")     // the Hand, Note, Subboard, Frame and Schema shortcuts, on the canvas
        expectEqual(w.editor.document[shape.id]?[TitleProperty.self], "hnbfs")
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
    test("an arrow shows its Arrow header and no options") {
        let w = try InspectorWindow()
        let shape = note(), arrow = ShapeRecord(Arrow(start: .free(CGPoint(x: 400, y: 100)), end: .free(CGPoint(x: 600, y: 300))))
        w.editor.transact { $0.insert(shape); $0.insert(arrow) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { w.titleField != nil }
        w.editor.selection = arrow.id
        w.window.spin { w.titleField == nil }
        let layout = try require(w.editor.detailPanel).layout(for: try require(w.editor.document[arrow.id]))
        expectEqual(layout.header, DetailHeader("Arrow", systemImage: "arrow.up.right"))
        expectEqual(layout.tabs, [])
        expectEqual(w.fields.count, 0)
        expectEqual(w.tables.count, 0)
    },
    test("at its narrowest and its ideal width, a note's panel and each tab of a schema card's and a subboard's fits the column, none pushing it wider") {
        // What widens a panel most: a note's long title, a schema whose one line runs far past the
        // column, a subboard's name.
        var titled = note("Buy milk and bread")
        titled[TitleProperty.self] = "Groceries for the week, and the party on Saturday"
        let schema = #"{"title": "Order", "type": "object", "properties": {"reference": {"type": "string", "description": "What the customer quotes when they call about this order, however long that takes"}}}"#
        let card = ShapeRecord(SchemaCard(frame: CGRect(x: 400, y: 100, width: 240, height: 67), schema: SchemaText(schema)))
        var sub = ShapeRecord(Subboard(frame: CGRect(x: 700, y: 100, width: 240, height: 160)))
        sub[TitleProperty.self] = "Payments"
        let panels: [(id: ShapeID, kind: ShapeKind, tabs: [any DetailTab.Type])] = [
            (titled.id, StickyNote.kind, []),
            (card.id, SchemaCard.kind, [SchemaTab.self]),
            (sub.id, Subboard.kind, [BoardTab.self]),
        ]
        @MainActor func choose<Tab: DetailTab>(_ tab: Tab.Type, for kind: ShapeKind, in editor: CanvasEditor) throws {
            try require(editor.detailPanel).choose(.of(tab), for: kind)
        }
        for width in [DetailStyle.minWidth, DetailStyle.idealWidth] {
            let editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: [AnyShapeRecord(titled), AnyShapeRecord(card), AnyShapeRecord(sub)]),
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
        w.window.type("Groceries")      // s is the schema tool's shortcut, on the canvas
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
    test("a note whose title is too long has an Issues tab that says so, through the validation-details bridge; a note without issues has no such tab") {
        let w = try InspectorWindow()
        var long = note("Hi")
        long[TitleProperty.self] = String(repeating: "Groceries ", count: 9)
        let written = ShapeRecord(StickyNote(frame: CGRect(x: 400, y: 100, width: 200, height: 200), text: "Hi"))
        w.editor.transact { $0.insert(long); $0.insert(written) }
        w.click(CGPoint(x: 200, y: 200))
        expectEqual(w.editor.selection, long.id)
        let state = try require(w.editor.detailPanel)
        let record = try require(w.editor.document[long.id])
        expectEqual(state.layout(for: record).tabs.map(\.title), ["Issues"])
        expectEqual(state.layout(for: record).statuses(in: .of(IssuesTab.self)),
                    [DetailStatus("Title is 90 characters long, and should be at most 80.", tone: .warning)])
        expectEqual(state.statuses(for: record), [], "nothing in the footer")
        w.click(CGPoint(x: 500, y: 200))
        expectEqual(w.editor.selection, written.id)
        expectEqual(state.layout(for: try require(w.editor.document[written.id])).tabs, [])
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
    test("inside a subboard, with nothing selected, the overview lists its board under its name, with a way up") {
        let nest = NestedFile()
        let w = try InspectorWindow(file: nest.file)
        w.window.spin { w.contentsRows == 3 }
        expectEqual(w.contentsHeaderButtons.count, 0, "nothing above the root")
        expect(ShippedPlugins.contentsHeading(for: w.editor) == nil, "the root's is the list's own, \"Board\", with no name for it")
        let root = try require(ShippedPlugins.contentsHeading(for: w.editor, rootName: "Roadmap"))
        expectEqual(root.title, "Roadmap", "the file's name, as the window and the path's root crumb have it")
        expectEqual(root.up, nil)
        expect(w.editor.showBoard(nest.sBoard))
        w.window.spin { w.contentsHeaderButtons.count == 1 }
        let (first, second) = nest.notes(on: 2)
        expectEqual(w.editor.tableOfContents?.entries.map(\.id), [first, second, nest.t], "its notes (the arrow under the first) and the subboard in it")
        let heading = try require(ShippedPlugins.contentsHeading(for: w.editor))
        expectEqual(heading.title, "Plans")
        expectEqual(heading.systemImage, "rectangle.stack")
        expectEqual(heading.up, .enclosingBoard)
        expectEqual(heading.upTitle, "Enclosing Board", "as the Go menu calls it")
        expectEqual(heading.upHelp, "Enclosing Board (⌘↑)", "with its key, as Back's tooltip has its")
        expect(w.editor.showBoard(nest.tBoard))
        expectEqual(ShippedPlugins.contentsHeading(for: w.editor)?.title, "Untitled Subboard", "the placeholder, as the path has it")
        w.editor.goToEnclosingBoard()
        w.editor.selection = nil
        w.window.spin { w.contentsHeaderButtons.count == 1 }
        try require(w.contentsHeaderButtons.first).performClick(nil)
        w.window.spin { w.editor.board == .root }
        expectEqual(w.editor.selectedShapeIDs, [nest.s], "up, to the subboard")
    },
    test("inside a subboard, the way up is back once a click on empty canvas has let go of a note") {
        let nest = NestedFile()
        let w = try InspectorWindow(file: nest.file)
        expect(w.editor.showBoard(nest.sBoard))
        w.editor.camera = Camera()
        w.window.spin { w.contentsHeaderButtons.count == 1 }
        w.click(CGPoint(x: 180, y: 180))
        expectEqual(w.editor.selection, nest.notes(on: 2).0)
        w.window.spin { w.contents == nil }
        // As AppKit delivers it: the list comes back, and its heading draws, while the press is
        // under way, when there's no going up.
        let empty = CGPoint(x: 600, y: 600)
        w.window.makeFirstResponder(w.canvas)
        w.canvas.mouseDown(with: w.window.mouse(.leftMouseDown, at: empty, time: 10))
        w.window.spin { w.contentsRows == 3 }
        expect(!w.editor.canPerform(.enclosingBoard), "mid-press")
        w.canvas.mouseUp(with: w.window.mouse(.leftMouseUp, at: empty, time: 10.05))
        expect(w.editor.canPerform(.enclosingBoard))
        w.window.spin { w.contentsHeaderButtons.count == 1 }
    },
])
