import AppKit
import Canvas
import CanvasTesting
import Checklists
import ContextMenus
import DetailPanel
import Foundation
import Keyboard
import Ports
import Selection
import TableOfContents
import TaskCards
import TestKit
import Titles
import Validation

@MainActor let taskCardTests = Suite("Task cards", [
    test("T and a press place a 240 × 200 task titled New Task, selected, in Select") {
        let h = try EditorHarness(plugins: taskPlugins())
        expect(h.key("t"))
        h.press(at: CGPoint(x: 300, y: 300)); h.release()
        let record = try require(h.editor.document.shapes.first)
        expectEqual(record.box, CGRect(x: 180, y: 200, width: 240, height: 200))
        expectEqual(record[TitleProperty.self], "New Task")
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
        task-cards         shape task-card v3 · tool task-card · shortcut T → tool task-card · ValidationRules → task-card · ShapeDetails → task-card · \
        ShapeContextMenus → task-card · ContentsRows → task-card · property checklist → task-card · ShapeChecklists → task-card · \
        ShapeDetails → task-card · ShapeContextMenus → task-card · property title → task-card · ShapeTitles → task-card · ContentsTitles → task-card · \
        ports task-link → task-card · channel task-link
        """)
    },
    test("needs validation, checklists, the panel, context menus, the table of contents and ports installed") {
        let plugins = taskPlugins()
        for (point, owner) in [("ValidationRules", PluginID.validation), ("ShapeChecklists", .checklists), ("ShapeDetails", .detailPanel),
                              ("ShapeContextMenus", .contextMenus), ("ContentsRows", .tableOfContents), ("ShapePorts", .ports)] {
            expectThrows(RegistryError.ownerNotInstalled(point: point, owner: owner, contributor: .taskCards)) {
                _ = try Registry(plugins: plugins.filter { $0.id != owner })
            }
        }
    },
    test("its context menu sets the status, checked, then the checklist's actions; several tasks' statuses show mixed") {
        let h = try EditorHarness { try taskEditor(scheduler: $0) }
        let task = h.editor.add(fullTask())
        let menu = try require(h.secondaryClick(at: CGPoint(x: cardFrame.midX, y: cardFrame.midY)))
        expectEqual(menu.outline, ["Status ▸", "  To Do", "  ✓ In Progress", "  Blocked", "  Done", "—",
                                   "Check All", "Uncheck All", "Remove Checked"])
        try menu.choose("Status", "Done")
        expectEqual(h.editor.task(task)?.status, .done)
        var todo = fullTask()
        todo.frame = cardFrame.offsetBy(dx: 300, dy: 0)
        todo.props.status = .todo
        let other = h.editor.add(todo)
        h.editor.selectedShapeIDs = [task, other]
        let both = try require(h.secondaryClick(at: CGPoint(x: cardFrame.midX, y: cardFrame.midY)))
        expectEqual(Array(both.outline.prefix(5)), ["Status ▸", "  – To Do", "  In Progress", "  Blocked", "  – Done"])
        try both.choose("Status", "Blocked")
        expectEqual([h.editor.task(task)?.status, h.editor.task(other)?.status], [.blocked, .blocked])
    },
    test("props round-trip through JSON: due date, color and what the card shows; the checklist, beside them in a board") {
        var task = fullTask()
        task.props.color = .purple
        task.props.shows = TaskDisplay(notes: false, checklist: true, progress: false)
        let decoded = try JSONDecoder().decode(TaskCard.self, from: JSONEncoder().encode(task.props))
        expectEqual(decoded, task.props)
        let editor = try taskEditor()
        let id = editor.add(task)
        let codec = BoardCodec(registry: editor.registry)
        let board = try codec.decode(codec.encode(editor.document)).document
        expectEqual(board[id], editor.document[id])
        expectEqual(board[id]?[ChecklistProperty.self]?.map(\.text), ["spec", "review", "ship"])
    },
    test("rules: no title is an error on title; done with open items warns on checklist, and blocked without notes on notes") {
        let editor = try taskEditor()
        expectEqual(editor.issues(editor.add(fullTask())), [])
        expectEqual(editor.issues(editor.add(ShapeRecord(TaskCard(frame: cardFrame), title: " "))), [.error("A task needs a title.", field: "title")])
        var task = fullTask()
        task.props.status = .done
        expectEqual(editor.issues(editor.add(task)), [.warning("Done, with 2 unchecked items.", field: "checklist")])
        task[ChecklistProperty.self] = steps(done: 2)
        expectEqual(editor.issues(editor.add(task)), [.warning("Done, with 1 unchecked item.", field: "checklist")])
        task[ChecklistProperty.self] = steps(done: 3)
        expectEqual(editor.issues(editor.add(task)), [])
        task.props.status = .blocked
        expectEqual(editor.issues(editor.add(task)), [])
        task.props.notes = "\n"
        expectEqual(editor.issues(editor.add(task)), [.warning("Blocked: say why in the notes.", field: "notes")])
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
        task.props.status = .done
        expectEqual(task.remaining, 0)
        task = ShapeRecord(TaskCard(frame: cardFrame, estimate: 2.5), title: "New Task")
        expectEqual(task.remaining, 2.5)
        expectEqual(task.summary, "To Do")
    },
    test("the panel: Task, Checklist, Style, Arrange, from three plugins") {
        let editor = try taskEditor()
        expectEqual(try editor.layout(editor.add(ShapeRecord(TaskCard(frame: cardFrame), title: "New Task"))).outline, [
            "Task: main, Notes, Schedule", "Checklist: Items", "Style: Color, On the Card", "Arrange: Size, Position",
        ])
    },
    test("Progress shows once the checklist has items") {
        let editor = try taskEditor()
        expectEqual(try editor.layout(editor.add(fullTask())).outline[1], "Checklist: Items, Progress")
    },
    test("the header renames the task: its title, or Untitled Task while it has none, over the summary, with the tool's symbol") {
        let editor = try taskEditor()
        let header = try require(try editor.layout(editor.add(fullTask())).header(as: TitleHeader.self))
        expectEqual(header.title, "Write the spec")
        expectEqual(header.placeholder, "Untitled Task")
        expectEqual(header.subtitle, fullTask().summary)
        expectEqual(header.systemImage, nil, "the Task tool's")
        let untitled = try require(try editor.layout(editor.add(TaskCard(frame: cardFrame))).header(as: TitleHeader.self))
        expectEqual(untitled.title, "")
        expectEqual(untitled.subtitle, "To Do")
    },
    test("a task's title is its title, which the card draws: no pill above it") {
        let editor = try taskEditor()
        let id = editor.add(TaskCard(frame: cardFrame.offsetBy(dx: 0, dy: 40)))
        expectEqual(editor.registry.title(of: try require(editor.document[id])), nil, "untitled")
        editor.transact { $0.update(id) { $0[TitleProperty.self] = "Write the spec" } }
        expectEqual(editor.registry.title(of: try require(editor.document[id])), "Write the spec")
        // Renamed, it's valid either way: validation's outline doesn't change.
        let before = renderBitmap(editor, size: CGSize(width: 320, height: 300))
        editor.transact { $0.update(id) { $0[TitleProperty.self] = "Plant tomatoes, in rows along the fence" } }
        expectEqual(changedPixels(before, renderBitmap(editor, size: CGSize(width: 320, height: 300)), in: CGRect(x: 0, y: 0, width: 320, height: 78)), 0)
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
