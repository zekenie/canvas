import AppKit
import Canvas
import CanvasTesting
import Checklists
import DetailPanel
import Selection
import SwiftUI
import TaskCards
import TestKit
import Validation

/// The panel alone in an unshown window. The editor keeps real time, so SwiftUI's updates land
/// while the main run loop runs (`window.spin`, from CanvasTesting). Controls are found by their
/// public AppKit superclass.
@MainActor
final class TaskPanelWindow {
    let editor: CanvasEditor
    let id: ShapeID
    let window: NSWindow
    let hosting: NSHostingView<DetailPanelView>

    init(_ task: TaskCard, width: CGFloat = DetailStyle.idealWidth) throws {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        editor = try taskEditor(scheduler: TaskScheduler())
        id = editor.add(task)
        editor.selection = id
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor))
        window.contentView = hosting
        window.spin { !fields.isEmpty }
    }

    func show<Tab: DetailTab>(_ tab: Tab.Type) throws {
        try require(editor.detailPanel).choose(.of(tab), for: TaskCard.kind)
        window.settle()
    }

    var fields: [String] { hosting.descendants(NSTextField.self).filter(\.isEditable).map(\.stringValue) }
    var tables: [NSTableView] { hosting.descendants(NSTableView.self) }
    /// The checkboxes' states (SwiftUI's toggles are untitled buttons), under the header, whose back
    /// button is in its top 44 points (`DetailStyle.headerHeight`).
    var checkboxes: [NSControl.StateValue] {
        hosting.descendants(NSButton.self).filter { !($0 is NSPopUpButton) && $0.convert($0.bounds, to: hosting).maxY > 44 }.map(\.state)
    }
    /// The panel's own scroll view, the outermost.
    var scrollFrame: CGRect? { hosting.descendants(NSScrollView.self).first.map { $0.convert($0.bounds, to: hosting) } }
    var status: NSPopUpButton? { hosting.descendants(NSPopUpButton.self).first }
    var priority: NSSegmentedControl? { hosting.descendants(NSSegmentedControl.self).first }
    var due: NSDatePicker? { hosting.descendants(NSDatePicker.self).first }
    var colorWells: Int { hosting.descendants(NSColorWell.self).count }

    /// Gives the Title field the keyboard, with its text selected, and types.
    func typeTitle(_ text: String) throws {
        window.focus(try require(hosting.descendants(NSTextField.self).first { $0.placeholderString == "Title" }))
        window.type(text)
        window.settle()
    }

    /// As choosing from the pop-up does.
    func choose(status title: String) throws {
        let menu = try require(status?.menu)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
        window.settle()
    }

    /// As a click on a segment does.
    func choose(priority segment: Int) throws {
        let control = try require(priority)
        control.selectedSegment = segment
        control.sendAction(control.action, to: control.target)
        window.settle()
    }

    var task: TaskCard? { editor.task(id) }
}

@MainActor let taskPanelWindowTests = Suite("Task panel in a window", [
    test("every tab builds: Task's fields, Checklist's rows, Style's checkboxes and well, Arrange's four pt fields") {
        let panel = try TaskPanelWindow(TaskCard(frame: cardFrame, title: "New Task", checklist: steps(done: 1)))
        expectEqual(panel.fields, ["New Task", "0 h"])
        expectEqual(panel.status?.titleOfSelectedItem, "To Do")
        expectEqual(panel.priority?.selectedSegment, 1)
        expect(panel.due == nil)

        try panel.show(ChecklistTab.self)
        expectEqual(panel.tables.map(\.numberOfRows), [3])

        try panel.show(StyleTab.self)
        expectEqual(panel.checkboxes, [.on, .on, .on])
        expectEqual(panel.colorWells, 1)

        try panel.show(ArrangeTab.self)
        expectEqual(panel.fields, ["240 pt", "200 pt", "40 pt", "40 pt"])
    },
    test("the Status pop-up and Priority segments write the task, each in one transaction") {
        let panel = try TaskPanelWindow(fullTask())
        expectEqual(panel.status?.itemTitles, ["To Do", "In Progress", "Blocked", "Done"])
        // Each status has its pill's dot, in color, with room after it before the title.
        expect(panel.status?.itemArray.allSatisfy { $0.image.map { !$0.isTemplate && $0.size.width > $0.size.height } ?? false } ?? false)
        var revision = panel.editor.revision
        try panel.choose(status: "Blocked")
        expectEqual(panel.task?.status, .blocked)
        expectEqual(panel.editor.revision, revision + 1)
        revision = panel.editor.revision
        try panel.choose(priority: 2)
        expectEqual(panel.task?.priority, .high)
        expectEqual(panel.editor.revision, revision + 1)
    },
    test("typing a title retitles the task and clears its error, and never switches tools") {
        let panel = try TaskPanelWindow(TaskCard(frame: cardFrame))
        expectEqual(panel.editor.validation?.result(for: panel.id)?.isValid, false)
        try panel.typeTitle("Plant tomatoes")     // T, the task tool's shortcut, on the canvas
        expectEqual(panel.task?.title, "Plant tomatoes")
        expect(panel.editor.validation?.result(for: panel.id) == nil)
        expectEqual(panel.editor.currentToolID, .select)
    },
    test("Due's checkbox shows whether there's a date; the picker, there only then, shows and sets it") {
        let panel = try TaskPanelWindow(fullTask())
        let picker = try require(panel.due)
        expectEqual(picker.dateValue, day(9, 30))
        picker.dateValue = day(12, 24)
        picker.sendAction(picker.action, to: picker.target)
        panel.window.settle()
        expectEqual(panel.task?.due, day(12, 24))

        // The Task tab's one checkbox is Due's. (SwiftUI's checkboxes track the mouse themselves,
        // and an unshown window gets no clicks, so this writes what a click does.)
        expectEqual(panel.checkboxes, [.on])
        let hasDue = try require(panel.editor.shapeBinding(panel.id, as: TaskCard.self)).hasDue
        hasDue.wrappedValue = false
        panel.window.spin { panel.due == nil }
        expectEqual(panel.checkboxes, [.off])
        expect(panel.due == nil, "no date to show, and none invented")
        hasDue.wrappedValue = true
        panel.window.spin { panel.due != nil }
        expectEqual(panel.checkboxes, [.on])
        expectEqual(panel.due?.dateValue, panel.task?.due)
    },
    test("at its narrowest and its ideal width, every tab fits the panel, none pushing it wider") {
        for width in [DetailStyle.minWidth, DetailStyle.idealWidth] {
            let panel = try TaskPanelWindow(fullTask(), width: width)
            for tab: any DetailTab.Type in [TaskTab.self, ChecklistTab.self, StyleTab.self, ArrangeTab.self] {
                try panel.show(tab)
                let frame = try require(panel.scrollFrame)
                expectEqual([panel.hosting.bounds.width, frame.minX, frame.width], [width, 0, width], "\(tab.title) at \(width)")
            }
        }
    },
    test("the Style checkboxes show what the card shows") {
        var task = fullTask()
        task.shows.checklist = false
        let panel = try TaskPanelWindow(task)
        try panel.show(StyleTab.self)
        expectEqual(panel.checkboxes, [.on, .off, .on])
    },
])
