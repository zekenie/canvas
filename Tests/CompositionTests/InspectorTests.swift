import AppKit
import Arrows
import Canvas
import CanvasTesting
import CanvasUI
import Checklists
import Composition
import DetailPanel
import Selection
import StickyNotes
import SwiftUI
import TaskCards
import TestKit

/// The app's window, unshown: the canvas (through `CanvasRepresentable`) with the shipped detail
/// panel in an `.inspector`, wired by a `CanvasFocus` as the app wires them. The editor keeps real
/// time, so SwiftUI's updates and the panel's hand-back land while the main run loop runs
/// (`window.spin`, from CanvasTesting).
@MainActor
final class InspectorWindow {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: TaskScheduler())
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    let focus = CanvasFocus()
    let host: NSHostingView<InspectorHost>
    let canvas: CanvasView

    /// Shows or hides the inspector, as View › Hide Inspector does.
    var showsDetails = true {
        didSet { host.rootView = InspectorHost(editor: editor, focus: focus, showsDetails: showsDetails) }
    }

    init() throws {
        host = NSHostingView(rootView: InspectorHost(editor: editor, focus: focus, showsDetails: true))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        canvas = try require(focus.canvas, "the representable hands its canvas view to the focus")
        window.settle()
    }

    /// The panel's editable text fields, in view order.
    var fields: [NSTextField] { host.descendants(NSTextField.self).filter(\.isEditable) }
    var tables: [NSTableView] { host.descendants(NSTableView.self) }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }

    /// The selected shape's footer lines, as the panel shows them.
    var footer: [String] {
        guard let id = editor.selection, let record = editor.document[id], let state = editor.detailPanel else { return [] }
        return state.statuses(for: record).map(\.text)
    }

    /// The task tool's shortcut on the canvas, then a click: places a task there, selected.
    func placeTask(at point: CGPoint) throws -> ShapeRecord<TaskCard> {
        window.makeFirstResponder(canvas)
        window.press("t")
        click(point)
        window.spin { fields.contains { $0.placeholderString == "Title" } }
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

    private var time: TimeInterval = 1
}

/// The app's content view, less its toolbar.
struct InspectorHost: View {
    let editor: CanvasEditor
    let focus: CanvasFocus
    let showsDetails: Bool

    var body: some View {
        CanvasRepresentable(editor: editor, focus: focus)
            .inspector(isPresented: .constant(showsDetails)) {
                ShippedPlugins.detailPanel(editor: editor, onExit: focus.take)
            }
            .transaction { $0.disablesAnimations = true }
    }
}

/// A note at (100, 100), 200 square: its top-right corner, where the checklist chip goes, is at
/// (300, 100) in the window's canvas.
func note(_ text: String = "", checklist: [ChecklistItem] = []) -> ShapeRecord<StickyNote> {
    ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: text, checklist: checklist))
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
        let buttons = w.host.descendants(NSButton.self)
        expectEqual(buttons.map(\.isEnabled), [true, false])
        try require(buttons.first).performClick(nil)
        w.window.spin { w.fields.contains { $0.placeholderString == "Item" } }
        w.window.focus(try require(w.fields.first { $0.placeholderString == "Item" }))
        w.window.type("milk")
        expectEqual(w.editor.document[shape.id]?.typed(as: StickyNote.self)?.props.checklist.map(\.text), ["milk"])
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
        expectEqual(w.editor.document[shape.id]?.typed(as: StickyNote.self)?.props.checklist.map(\.text), ["anev"])
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
        expectEqual(w.editor.document[shape.id]?.typed(as: StickyNote.self)?.props.checklist.map(\.text), ["eggs"])
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
        w.window.focus(try require(w.fields.first { $0.placeholderString == "Title" }))
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
    test("an empty note's footer says so, through the validation-details bridge") {
        let w = try InspectorWindow()
        let empty = note(), written = ShapeRecord(StickyNote(frame: CGRect(x: 400, y: 100, width: 200, height: 200), text: "Hi"))
        w.editor.transact { $0.insert(empty); $0.insert(written) }
        w.click(CGPoint(x: 200, y: 200))
        expectEqual(w.editor.selection, empty.id)
        let record = try require(w.editor.document[empty.id])
        expectEqual(try require(w.editor.detailPanel).statuses(for: record), [DetailStatus("This note is empty.", tone: .warning)])
        w.click(CGPoint(x: 500, y: 200))
        expectEqual(w.editor.selection, written.id)
        expectEqual(w.footer, [])
    },
    test("T places a task, which the panel shows with its tabs: Task, Checklist, Style, Arrange") {
        let w = try InspectorWindow()
        let task = try w.placeTask(at: CGPoint(x: 300, y: 300))
        expectEqual(task.props.title, "New Task")
        expectEqual(w.editor.currentToolID, .select)
        let layout = try require(w.editor.detailPanel).layout(for: AnyShapeRecord(task))
        expectEqual(layout.header.title, "New Task")
        expectEqual(layout.tabs.map(\.title), ["Task", "Checklist", "Style", "Arrange"])
        expectEqual(w.fields.first { $0.placeholderString == "Title" }?.stringValue, "New Task", "the Task tab is showing")
        expectEqual(w.footer, [])
    },
    test("typing a task's title in the panel redraws the card, clears the footer's error, and keeps Select") {
        let w = try InspectorWindow()
        let task = try w.placeTask(at: CGPoint(x: 300, y: 300))
        w.window.focus(try require(w.fields.first { $0.placeholderString == "Title" }))
        w.window.pressDelete()
        expectEqual(w.editor.document[task.id]?.typed(as: TaskCard.self)?.props.title, "")
        expectEqual(w.footer, ["A task needs a title."])
        let untitled = w.render()

        w.window.type("tea")     // t is the task tool's shortcut, on the canvas
        expectEqual(w.editor.document[task.id]?.typed(as: TaskCard.self)?.props.title, "tea")
        expectEqual(w.footer, [])
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

        let buttons = w.host.descendants(NSButton.self)
        expectEqual(buttons.map(\.isEnabled), [true, false], "the list's + and −")
        try require(buttons.first).performClick(nil)
        w.window.spin { w.fields.contains { $0.placeholderString == "Item" } }
        w.window.focus(try require(w.fields.first { $0.placeholderString == "Item" }))
        w.window.type("milk")
        expectEqual(w.editor.document[task.id]?.typed(as: TaskCard.self)?.props.checklist.map(\.text), ["milk"])

        let after = w.render()
        // Below the title and the meta line, above the progress bar.
        let rows = CGRect(x: task.frame.minX + 17, y: task.frame.minY + 50, width: 200, height: 80)
        expect(changedPixels(before, after, in: rows) > 20, "the card draws the item")
        expect(pixel(after, at: corner)[0..<3].allSatisfy { $0 > 200 }, "no chip: the card opted in with badge: false: \(pixel(after, at: corner))")
    },
])
