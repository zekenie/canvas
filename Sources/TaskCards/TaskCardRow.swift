import Canvas
import Checklists
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == TaskCardDefinition {
    /// The task's row in the table of contents: its title (or "Untitled Task"), its status as a
    /// symbol in the status pill's color, and its checklist's tally.
    mutating func taskRow() {
        contentsRow { task in
            ContentsLabel(task.title ?? "", placeholder: "Untitled Task", systemImage: task.props.status.symbol,
                          color: Color(nsColor: TaskStyle.statusColor(task.props.status)), badge: task.checklist.tally)
        }
    }
}

extension TaskStatus {
    /// Circles, as Reminders draws tasks: empty, half full, with a warning, checked.
    public var symbol: String {
        switch self {
        case .todo: "circle"
        case .doing: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}
