import Canvas
import Checklists
import Keyboard
import Mentions
import Ports
import Titles
import Validation

extension PluginID {
    public static let taskCards: PluginID = "task-cards"
}

/// Task cards: the Task tool (T), validation rules, a detail panel that is the card's only editor,
/// a Status submenu in its context menu, a row in the table of contents, and ports, whose arrows
/// link a task to a task (`TaskLink`). A task can be mentioned, by its title and with its status's
/// symbol ("Untitled Task" while it has none). The card draws its own title and checklist, so it
/// opts into Titles without the pill and Checklists without the chip.
public struct TaskCardsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .taskCards }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(TaskCardDefinition()) { task in
            let place = task.placement(size: TaskStyle.size) { TaskCard() }.setting(TitleProperty.self, to: "New Task")
            task.tool(label: "Task", systemImage: "checklist", shortcut: "t", placing: place)
            task.validate { shape, _ in shape.issues }
            task.taskPanel()
            task.taskMenu()
            task.taskRow()
            task.checklist(badge: false)
            task.title(pill: false)
            task.taskLinks()
            task.mentionable(symbol: { $0.props.status.symbol })   // mentioned by its title, with its status
        }
        registrar.channel(TaskLink.self)
    }
}

extension ShapeRecord where Props == TaskCard {
    /// The task's rules. Only the shape: no clock (validation caches by revision, so a rule like
    /// "overdue" would go stale) and no other shape.
    var issues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if isUntitled { issues.append(.error("A task needs a title.", field: "title")) }
        let open = checklist.count - checklist.doneCount
        if props.status == .done, open > 0 {
            issues.append(.warning("Done, with \(open) unchecked \(open == 1 ? "item" : "items").", field: "checklist"))
        }
        if props.status == .blocked, props.notes.allSatisfy(\.isWhitespace) {
            issues.append(.warning("Blocked: say why in the notes.", field: "notes"))
        }
        return issues
    }
}
