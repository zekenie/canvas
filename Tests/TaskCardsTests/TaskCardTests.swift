import AppKit
import Canvas
import CanvasTesting
import Checklists
import ContextMenus
import DetailPanel
import Foundation
import Keyboard
import Selection
import TableOfContents
import TaskCards
import TestKit
import Validation

@MainActor let taskCardTests = Suite("Task cards", [
    test("T and a press place a 240 × 200 task titled New Task, selected, in Select") {
        let h = try EditorHarness(plugins: taskPlugins())
        expect(h.key("t"))
        h.press(at: CGPoint(x: 300, y: 300)); h.release()
        let record = try require(h.editor.document.shapes.first)
        expectEqual(record.box, CGRect(x: 180, y: 200, width: 240, height: 200))
        expectEqual(record.typed(as: TaskCard.self)?.props.title, "New Task")
        expectEqual(h.editor.selection, record.id)
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("registers the kind and the Task tool; the panel is its editor, so it isn't Editable") {
        let registry = try Registry(plugins: taskPlugins())
        let tool = try require(registry.tools.first { $0.id == ToolID(placing: TaskCard.kind) })
        expectEqual([tool.label, tool.systemImage], ["Task", "checklist"])
        expectEqual(registry.shortcut(forTool: tool.id)?.chord, "t")
        expect(!(registry.definition(for: TaskCard.kind) is any Editable))
        expectEqual(registry.report.split(separator: "\n").first { $0.hasPrefix("task-cards") }.map(String.init), """
        task-cards         shape task-card · tool task-card · shortcut T → tool task-card · ValidationRules → task-card · ShapeDetails → task-card · \
        ShapeContextMenus → task-card · ContentsRows → task-card · ShapeChecklists → task-card · ShapeDetails → task-card · \
        ShapeContextMenus → task-card
        """)
    },
    test("needs validation, checklists, the panel, context menus and the table of contents installed") {
        let plugins = taskPlugins()
        for (point, owner) in [("ValidationRules", PluginID.validation), ("ShapeChecklists", .checklists), ("ShapeDetails", .detailPanel),
                              ("ShapeContextMenus", .contextMenus), ("ContentsRows", .tableOfContents)] {
            expectThrows(RegistryError.ownerNotInstalled(point: point, owner: owner, contributor: .taskCards)) {
                _ = try Registry(plugins: plugins.filter { $0.id != owner })
            }
        }
    },
    test("its context menu sets the status, checked, then the checklist's actions; several tasks' statuses show mixed") {
        let h = try EditorHarness { try taskEditor(scheduler: $0) }
        let task = h.add(fullTask())
        let menu = try require(h.secondaryClick(at: CGPoint(x: cardFrame.midX, y: cardFrame.midY)))
        expectEqual(menu.outline, ["Status ▸", "  To Do", "  ✓ In Progress", "  Blocked", "  Done", "—",
                                   "Check All", "Uncheck All", "Remove Checked"])
        try menu.choose("Status", "Done")
        expectEqual(h.editor.task(task)?.status, .done)
        var todo = fullTask()
        todo.frame = cardFrame.offsetBy(dx: 300, dy: 0)
        todo.status = .todo
        let other = h.add(todo)
        h.editor.selectedShapeIDs = [task, other]
        let both = try require(h.secondaryClick(at: CGPoint(x: cardFrame.midX, y: cardFrame.midY)))
        expectEqual(Array(both.outline.prefix(5)), ["Status ▸", "  – To Do", "  In Progress", "  Blocked", "  – Done"])
        try both.choose("Status", "Blocked")
        expectEqual([h.editor.task(task)?.status, h.editor.task(other)?.status], [.blocked, .blocked])
    },
    test("props round-trip through JSON: checklist, due date, color and what the card shows") {
        var task = fullTask()
        task.color = .purple
        task.shows = TaskDisplay(notes: false, checklist: true, progress: false)
        let decoded = try JSONDecoder().decode(TaskCard.self, from: JSONEncoder().encode(task))
        expectEqual(decoded, task)
        expectEqual(decoded.checklist.map(\.text), ["spec", "review", "ship"])
    },
    test("rules: no title is an error on title; done with open items warns on checklist; blocked without notes is info on notes") {
        let editor = try taskEditor()
        expectEqual(editor.issues(editor.add(fullTask())), [])
        expectEqual(editor.issues(editor.add(TaskCard(frame: cardFrame, title: " "))), [.error("A task needs a title.", field: "title")])
        var task = fullTask()
        task.status = .done
        expectEqual(editor.issues(editor.add(task)), [.warning("Done, with 2 unchecked items.", field: "checklist")])
        task.checklist = steps(done: 2)
        expectEqual(editor.issues(editor.add(task)), [.warning("Done, with 1 unchecked item.", field: "checklist")])
        task.checklist = steps(done: 3)
        expectEqual(editor.issues(editor.add(task)), [])
        task.status = .blocked
        expectEqual(editor.issues(editor.add(task)), [])
        task.notes = "\n"
        expectEqual(editor.issues(editor.add(task)), [.info("Blocked: say why in the notes.", field: "notes")])
    },
    test("hasDue on gives a date a week from today and keeps one already set; off clears it") {
        var task = TaskCard(frame: cardFrame)
        task.hasDue = true
        let today = Calendar.current.startOfDay(for: .now)
        expectEqual(task.due, Calendar.current.date(byAdding: .day, value: 7, to: today))
        expectEqual(task.dueDate, task.due)
        task.due = day(9, 30)
        task.hasDue = true
        expectEqual(task.due, day(9, 30))
        task.hasDue = false
        expectEqual(task.due, nil)
        task.dueDate = day(10, 2)
        expectEqual(task.due, day(10, 2))
    },
    test("remaining is the estimate less the checked share, none once done; the summary reads status, count, due") {
        var task = fullTask()
        expectClose(task.remaining, 4 * 2 / 3)
        expectEqual(task.summary, "In Progress · 1 of 3 · Due \(day(9, 30).formatted(.dateTime.month(.abbreviated).day()))")
        task.status = .done
        expectEqual(task.remaining, 0)
        task = TaskCard(frame: cardFrame, title: "New Task", estimate: 2.5)
        expectEqual(task.remaining, 2.5)
        expectEqual(task.summary, "To Do")
    },
    test("the panel: Task, Checklist, Style, Arrange, from three plugins") {
        let editor = try taskEditor()
        expectEqual(try editor.layout(editor.add(TaskCard(frame: cardFrame, title: "New Task"))).outline, [
            "Task: main, Notes, Schedule", "Checklist: Items", "Style: Color, On the Card", "Arrange: Size, Position",
        ])
    },
    test("Progress shows once the checklist has items") {
        let editor = try taskEditor()
        expectEqual(try editor.layout(editor.add(fullTask())).outline[1], "Checklist: Items, Progress")
    },
    test("the header: the title, or Untitled Task, over the summary, with the tool's symbol") {
        let editor = try taskEditor()
        let header = try editor.layout(editor.add(fullTask())).header
        expectEqual(header, DetailHeader("Write the spec", subtitle: fullTask().summary, systemImage: "checklist"))
        expectEqual(try editor.layout(editor.add(TaskCard(frame: cardFrame))).header,
                    DetailHeader("Untitled Task", subtitle: "To Do", systemImage: "checklist"))
    },
    test("its row in the table of contents: the title or Untitled Task, the status as a symbol, the checklist's tally") {
        let editor = try taskEditor()
        editor.add(fullTask())
        editor.add(TaskCard(frame: cardFrame, status: .done))
        let labels = try require(editor.tableOfContents).entries.map(\.label)
        expectEqual(labels.map { $0?.text }, ["Write the spec", "Untitled Task"])
        expectEqual(labels.map { $0?.isPlaceholder }, [false, true])
        expectEqual(labels.map { $0?.systemImage }, ["circle.lefthalf.filled", "checkmark.circle.fill"])
        expectEqual(labels.map { $0?.badge }, ["1/3", nil])
    },
])
