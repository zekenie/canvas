import AppKit
import Arrows
import Boards
import Canvas
import CanvasTesting
import CanvasUI
import Checklists
import Composition
import DetailPanel
import Geometry
import LanguageModels
import Mentions
import Selection
import StickyNotes
import SwiftUI
import TableOfContents
import TaskCards
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

    /// The task tool's shortcut on the canvas, then a click: places a task there, selected.
    func placeTask(at point: CGPoint) throws -> ShapeRecord<TaskCard> {
        window.makeFirstResponder(canvas)
        window.press("t")
        click(point)
        window.spin { titleField?.placeholderString == "Untitled Task" }
        return try require(editor.selection.flatMap { editor.document[$0]?.typed(as: TaskCard.self) }, "T, then a click, places a task")
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

    /// The path's crumbs that are buttons, over the canvas.
    var crumbs: [NSButton] {
        host.descendants(NSButton.self).filter {
            let frame = canvas.convert($0.bounds, from: $0)
            return !($0 is NSPopUpButton) && canvas.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
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
                ShippedPlugins.detailPanel(editor: editor, onExit: focus.take)
            }
            .transaction { $0.disablesAnimations = true }
    }
}

/// A note at (100, 100), 200 square: its top-right corner, where the checklist chip goes, is at
/// (300, 100) in the window's canvas.
func note(_ text: String = "", checklist: [ChecklistItem] = []) -> ShapeRecord<StickyNote> {
    var shape = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: MentionText(plain: text)))
    shape[ChecklistProperty.self] = checklist
    return shape
}

/// Just inside the chip's right end.
let chipPoint = CGPoint(x: 303, y: 100)

// The shipped panel beside the canvas, as the app places it.
@MainActor let inspectorTests = Suite("Inspector", [
    test("selecting a note shows its Checklist tab first, then Arrange") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        expectEqual(w.tables.count, 0)
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { !w.tables.isEmpty }
        expectEqual(w.editor.selection, shape.id)
        let state = try require(w.editor.detailPanel)
        expectEqual(state.layout(for: try require(w.editor.document[shape.id])).tabs.map(\.title), ["Checklist", "Arrange"])
        expectEqual(w.tables.map(\.numberOfRows), [0], "the Checklist tab's Items, empty")
        expectEqual(w.fields.map(\.stringValue), [])
        state.choose(.of(ArrangeTab.self), for: StickyNote.kind)
        w.window.spin { !w.fields.isEmpty }
        expectEqual(w.tables.count, 0)
        expectEqual(w.fields.map(\.stringValue), ["200 pt", "200 pt", "100 pt", "100 pt"])
    },
    test("adding checklist items through the panel draws the chip on the note") {
        let w = try InspectorWindow()
        let shape = note("Shopping")
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        let bare = w.render()
        expect(pixel(bare, at: chipPoint)[0..<3].allSatisfy { $0 > 200 }, "no chip for an empty checklist: \(pixel(bare, at: chipPoint))")

        // The list's + and − buttons; − is off with no row selected.
        let buttons = w.buttons
        expectEqual(buttons.map(\.isEnabled), [true, false])
        try require(buttons.first).performClick(nil)
        w.window.spin { w.fields.contains { $0.placeholderString == "Item" } }
        w.window.focus(try require(w.fields.first { $0.placeholderString == "Item" }))
        w.window.type("milk")
        expectEqual(w.editor.document[shape.id]?[ChecklistProperty.self]?.map(\.text), ["milk"])
        expectEqual(w.editor.document[shape.id]?.typed(as: StickyNote.self)?.props.text, "Shopping")

        let color = pixel(w.render(), at: chipPoint)
        expect(color[0..<3].allSatisfy { $0 < 100 }, "a dark chip for one open item: \(color)")
    },
    test("typing into a panel field never switches tools") {
        let w = try InspectorWindow()
        let shape = note(checklist: [ChecklistItem(text: "eggs")])
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.focus(try require(w.fields.first { $0.stringValue == "eggs" }))
        w.window.type("anev")     // the arrow, note, ellipse and select shortcuts, on the canvas
        expectEqual(w.editor.document[shape.id]?[ChecklistProperty.self]?.map(\.text), ["anev"])
        expectEqual(w.editor.currentToolID, .select)
        expectEqual(w.editor.selection, shape.id)
    },
    test("Escape in the panel hands the keyboard to the canvas, and its next key picks the arrow tool") {
        let w = try InspectorWindow()
        let shape = note(checklist: [ChecklistItem(text: "eggs")])
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.focus(try require(w.fields.first { $0.stringValue == "eggs" }))
        expect(!w.canvasHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard)
        expectEqual(w.editor.selection, shape.id, "Escape in the panel isn't Escape on the canvas")
        w.window.type("a")
        expectEqual(w.editor.currentToolID, .arrow)
        expectEqual(w.editor.document[shape.id]?[ChecklistProperty.self]?.map(\.text), ["eggs"])
    },
    test("hiding the inspector while a panel field has the keyboard hands it to the canvas, keeping the draft") {
        let w = try InspectorWindow()
        let task = try w.placeTask(at: CGPoint(x: 300, y: 300))
        let field = try require(w.fields.first { $0.stringValue.hasSuffix(" h") }, "the Estimate field")
        w.window.focus(field)
        w.window.type("7")
        expect(!w.canvasHasKeyboard)
        w.showsDetails = false
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "not the window: \(String(describing: w.window.firstResponder))")
        expectEqual(w.editor.document[task.id]?.typed(as: TaskCard.self)?.props.estimate, 7)
        w.window.type("a")
        expectEqual(w.editor.currentToolID, .arrow)
    },
    test("a selection change that removes the focused field hands the keyboard to the canvas") {
        let w = try InspectorWindow()
        _ = try w.placeTask(at: CGPoint(x: 300, y: 300))
        w.window.focus(try require(w.titleField))
        w.editor.selection = nil
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "not the window: \(String(describing: w.window.firstResponder))")
    },
    test("a checklist shows every item, up to eight, each row 22 points tall") {
        let w = try InspectorWindow()
        let shape = note(checklist: ["a", "b", "c", "d", "e"].map { ChecklistItem(text: $0) })
        w.editor.transact { $0.insert(shape) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { !w.tables.isEmpty }
        let table = try require(w.tables.first)
        expectEqual(table.numberOfRows, 5)
        expectEqual(table.rect(ofRow: 0).height, 22)
        let visible = try require(table.enclosingScrollView).documentVisibleRect
        expect(visible.height >= table.rect(ofRow: 4).maxY, "row 5 ends at \(table.rect(ofRow: 4).maxY), below \(visible.height)")
    },
    test("an arrow shows its Arrow header and no options") {
        let w = try InspectorWindow()
        let shape = note(), arrow = ShapeRecord(Arrow(start: .free(CGPoint(x: 400, y: 100)), end: .free(CGPoint(x: 600, y: 300))))
        w.editor.transact { $0.insert(shape); $0.insert(arrow) }
        w.click(CGPoint(x: 200, y: 200))
        w.window.spin { !w.tables.isEmpty }
        expectEqual(w.tables.count, 1)
        w.editor.selection = arrow.id
        w.window.spin { w.tables.isEmpty }
        let layout = try require(w.editor.detailPanel).layout(for: try require(w.editor.document[arrow.id]))
        expectEqual(layout.header, DetailHeader("Arrow", systemImage: "arrow.up.right"))
        expectEqual(layout.tabs, [])
        expectEqual(w.fields.count, 0)
        expectEqual(w.tables.count, 0)
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
        w.window.type("Groceries")      // e is the eraser's shortcut, on the canvas
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
    test("an empty note's Issues tab says so, through the validation-details bridge; a written note has no such tab") {
        let w = try InspectorWindow()
        let empty = note(), written = ShapeRecord(StickyNote(frame: CGRect(x: 400, y: 100, width: 200, height: 200), text: "Hi"))
        w.editor.transact { $0.insert(empty); $0.insert(written) }
        w.click(CGPoint(x: 200, y: 200))
        expectEqual(w.editor.selection, empty.id)
        let state = try require(w.editor.detailPanel)
        let record = try require(w.editor.document[empty.id])
        expectEqual(state.layout(for: record).tabs.map(\.title), ["Checklist", "Arrange", "Issues"])
        expectEqual(state.layout(for: record).statuses(in: .of(IssuesTab.self)), [DetailStatus("This note is empty.", tone: .warning)])
        expectEqual(state.statuses(for: record), [], "nothing in the footer")
        w.click(CGPoint(x: 500, y: 200))
        expectEqual(w.editor.selection, written.id)
        expectEqual(state.layout(for: try require(w.editor.document[written.id])).tabs.map(\.title), ["Checklist", "Arrange"])
        expectEqual(w.issues, [])
    },
    test("T places a task, which the panel shows with its tabs: Task, Checklist, Style, Arrange") {
        let w = try InspectorWindow()
        let task = try w.placeTask(at: CGPoint(x: 300, y: 300))
        expectEqual(task.title, "New Task")
        expectEqual(w.editor.currentToolID, .select)
        let layout = try require(w.editor.detailPanel).layout(for: AnyShapeRecord(task))
        expectEqual(layout.headerText, "New Task")
        expectEqual(layout.tabs.map(\.title), ["Task", "Checklist", "Style", "Arrange"])
        expectEqual(w.titleField?.stringValue, "New Task", "the header renames it")
        expectEqual(w.fields.map(\.stringValue), ["0 h"], "the Task tab is showing: its Estimate")
        expectEqual(w.issues, [])
    },
    test("typing a task's title in the panel's header redraws the card, clears its error, and keeps Select") {
        let w = try InspectorWindow()
        let task = try w.placeTask(at: CGPoint(x: 300, y: 300))
        w.window.focus(try require(w.titleField))
        w.window.pressDelete()
        expectEqual(w.editor.document[task.id]?[TitleProperty.self], nil, "cleared, it's untitled, not titled \"\"")
        expectEqual(w.issues, ["A task needs a title."])
        let untitled = w.render()

        w.window.type("tea")     // t is the task tool's shortcut, on the canvas
        expectEqual(w.editor.document[task.id]?[TitleProperty.self], "tea")
        expectEqual(w.issues, [])
        expectEqual(w.editor.currentToolID, .select)
        expectEqual(w.editor.selection, task.id)
        // The title's line, left of the status pill.
        let title = CGRect(x: task.frame.minX + 17, y: task.frame.minY + 12, width: 130, height: 16)
        expect(changedPixels(untitled, w.render(), in: title) > 20, "the card draws the new title")
    },
    test("a task's checklist, edited in its Checklist tab, draws on the card and gets no chip") {
        let w = try InspectorWindow()
        let task = try w.placeTask(at: CGPoint(x: 300, y: 300))
        try require(w.editor.detailPanel).choose(.of(ChecklistTab.self), for: TaskCard.kind)
        w.window.spin { !w.tables.isEmpty }
        let corner = CGPoint(x: task.frame.maxX + 3, y: task.frame.minY)
        let before = w.render()
        expect(pixel(before, at: corner)[0..<3].allSatisfy { $0 > 200 }, "nothing at the corner yet: \(pixel(before, at: corner))")

        let buttons = w.buttons
        expectEqual(buttons.map(\.isEnabled), [true, false], "the list's + and −")
        try require(buttons.first).performClick(nil)
        w.window.spin { w.fields.contains { $0.placeholderString == "Item" } }
        w.window.focus(try require(w.fields.first { $0.placeholderString == "Item" }))
        w.window.type("milk")
        expectEqual(w.editor.document[task.id]?[ChecklistProperty.self]?.map(\.text), ["milk"])

        let after = w.render()
        // Below the title and the meta line, above the progress bar.
        let rows = CGRect(x: task.frame.minX + 17, y: task.frame.minY + 50, width: 200, height: 80)
        expect(changedPixels(before, after, in: rows) > 20, "the card draws the item")
        expect(pixel(after, at: corner)[0..<3].allSatisfy { $0 > 200 }, "no chip: the card opted in with badge: false: \(pixel(after, at: corner))")
    },
    test("a number being typed in the panel lands on its shape, on its board, before a crumb shows another") {
        let nest = NestedFile()
        let w = try InspectorWindow(file: nest.file)
        expect(w.editor.showBoard(nest.sBoard))
        w.editor.camera = Camera()
        let task = try w.placeTask(at: CGPoint(x: 500, y: 330))
        w.window.focus(try require(w.fields.first { $0.stringValue.hasSuffix(" h") }, "the Estimate field"))
        w.window.type("7")
        expectEqual(w.editor.document[task.id]?.typed(as: TaskCard.self)?.props.estimate, 0, "a draft, while it's typed")
        w.window.spin { w.crumbs.count == 1 }
        try require(w.crumbs.first).performClick(nil)
        w.window.settle()
        expectEqual(w.editor.board, .root)
        expectEqual(w.editor.contents(of: nest.sBoard)[task.id]?.typed(as: TaskCard.self)?.props.estimate, 7)
        w.window.spin { w.canvasHasKeyboard }
    },
    test("inside a subboard, with nothing selected, the overview lists its board under its name, with a way up") {
        let nest = NestedFile()
        let w = try InspectorWindow(file: nest.file)
        w.window.spin { w.contentsRows == 3 }
        expectEqual(w.contentsHeaderButtons.count, 0, "nothing above the root")
        expect(ShippedPlugins.contentsHeading(for: w.editor) == nil, "the root's is the list's own, \"Board\"")
        expect(w.editor.showBoard(nest.sBoard))
        w.window.spin { w.contentsHeaderButtons.count == 1 }
        let (first, second) = nest.notes(on: 2)
        expectEqual(w.editor.tableOfContents?.entries.map(\.id), [first, second, nest.t], "its notes (the arrow under the first) and the subboard in it")
        let heading = try require(ShippedPlugins.contentsHeading(for: w.editor))
        expectEqual(heading.title, "Plans")
        expectEqual(heading.systemImage, "rectangle.stack")
        expectEqual(heading.up, .enclosingBoard)
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
