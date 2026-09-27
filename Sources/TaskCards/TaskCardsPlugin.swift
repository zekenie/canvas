import Canvas
import Checklists
import Keyboard
import Titles
import Validation

extension PluginID {
    public static let taskCards: PluginID = "task-cards"
}

/// Task cards: the Task tool (T), validation rules, a detail panel that is the card's only editor,
/// a Status submenu in its context menu, and a row in the table of contents. The card draws its
/// own title and checklist, so it opts into Titles without the pill and Checklists without the chip.
public struct TaskCardsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .taskCards }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(TaskCardDefinition()) { task in
            let place = task.placement(size: TaskStyle.size) { TaskCard(title: "New Task") }
            task.tool(label: "Task", systemImage: "checklist", shortcut: "t", placing: place)
            task.validate { shape, _ in shape.props.issues }
            task.taskPanel()
            task.taskMenu()
            task.taskRow()
            task.checklist(\.checklist, badge: false)
            task.title(pill: false) { $0.props.title }
        }
    }
}

extension TaskCard {
    /// The task's rules. Only the props: no clock (validation caches by revision, so a rule like
    /// "overdue" would go stale) and no other shape.
    var issues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if isUntitled { issues.append(.error("A task needs a title.", field: "title")) }
        let open = checklist.count - checklist.doneCount
        if status == .done, open > 0 {
            issues.append(.warning("Done, with \(open) unchecked \(open == 1 ? "item" : "items").", field: "checklist"))
        }
        if status == .blocked, notes.allSatisfy(\.isWhitespace) {
            issues.append(.info("Blocked: say why in the notes.", field: "notes"))
        }
        return issues
    }
}
