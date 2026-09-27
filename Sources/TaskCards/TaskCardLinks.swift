import AppKit
import Canvas
import Ports

/// What a task card's ports draw: a link from a task to a task, the only connection a task takes. It
/// says nothing more yet; a channel is where a connection's meaning would go (one task blocking
/// another, say).
public enum TaskLink {}

extension TaskLink: Channel {
    public static let id: ChannelID = "task-link"
    public static var color: NSColor { .systemPurple }
}

extension ShapeRegistrar where Definition == TaskCardDefinition {
    /// Ports on all four sides: the card draws its title inside, so nothing sits above it.
    mutating func taskLinks() {
        ports(TaskLink.self)
    }
}
