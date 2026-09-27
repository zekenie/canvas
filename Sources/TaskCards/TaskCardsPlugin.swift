import Canvas
import Checklists
import Validation

extension PluginID {
    public static let taskCards: PluginID = "task-cards"
}

/// Task cards: the Task tool (T), validation rules, a detail panel that is the card's only editor,
/// and a Status submenu in its context menu. The card draws its own checklist, so it opts into
/// Checklists without the chip.
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
            task.checklist(\.checklist, badge: false)
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
