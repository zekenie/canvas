import Canvas
import Checklists
import CoreGraphics
import Foundation

/// A task on the canvas: a title, a status, a schedule and a checklist, drawn as a card. It has no
/// editing view; the detail panel is its editor.
public struct TaskCard: BoxShapeProps {
    public static let kind: ShapeKind = "task-card"
    public static let defaultSize = CGSize(width: 240, height: 200)

    public var frame: CGRect
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public var priority: TaskPriority
    /// Hours.
    public var estimate: Double
    public var due: Date?
    public var color: TaskColor
    /// Checklists' items: the card opts into that horizontal, and draws them itself.
    public var checklist: [ChecklistItem]
    public var shows: TaskDisplay

    public init(frame: CGRect = .zero, title: String = "", notes: String = "", status: TaskStatus = .todo,
                priority: TaskPriority = .medium, estimate: Double = 0, due: Date? = nil, color: TaskColor = .blue,
                checklist: [ChecklistItem] = [], shows: TaskDisplay = TaskDisplay()) {
        self.frame = frame
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.estimate = estimate
        self.due = due
        self.color = color
        self.checklist = checklist
        self.shows = shows
    }
}

// MARK: Derived

extension TaskCard {
    /// Whether the title is blank: such a task is invalid, and is drawn and named "Untitled Task".
    public var isUntitled: Bool { title.allSatisfy(\.isWhitespace) }

    /// The hours still to go: the estimate less the checked share of the checklist; none once done.
    public var remaining: Double { status == .done ? 0 : estimate * (1 - checklist.progress) }

    /// "In Progress · 2 of 5 · Due Sep 30": the status, then the checklist and due date if any.
    public var summary: String {
        var parts = [status.label]
        if !checklist.isEmpty { parts.append("\(checklist.doneCount) of \(checklist.count)") }
        if let due { parts.append("Due \(TaskCard.format(due))") }
        return parts.joined(separator: " · ")
    }

    /// "Sep 30", in the user's locale.
    static func format(_ due: Date) -> String { due.formatted(.dateTime.month(.abbreviated).day()) }

    // Settable views of the props, so the panel's controls bind to them directly.

    /// Whether there is a due date. Turning it on sets one a week from today; off clears it.
    public var hasDue: Bool {
        get { due != nil }
        set { due = newValue ? due ?? TaskCard.weekFromToday() : nil }
    }

    /// `due`, for a date picker: a week from today while there is none.
    public var dueDate: Date {
        get { due ?? TaskCard.weekFromToday() }
        set { due = newValue }
    }

    /// `color` as a CGColor, for swatches and the color well.
    public var displayColor: CGColor {
        get { color.cgColor }
        set { color = TaskColor(newValue) }
    }

    private static func weekFromToday() -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return calendar.date(byAdding: .day, value: 7, to: today) ?? today
    }
}

// MARK: Values

public enum TaskStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case todo, doing, blocked, done
    public var id: Self { self }
    public var label: String {
        switch self {
        case .todo: "To Do"
        case .doing: "In Progress"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }
}

public enum TaskPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case low, medium, high
    public var id: Self { self }
    /// Short enough for a segmented control.
    public var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Med"
        case .high: "High"
        }
    }
    /// What the card shows: "!", "!!" or "!!!".
    public var marks: String {
        switch self {
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }
}

/// A card's color, in sRGB.
public struct TaskColor: Codable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Any color, through sRGB.
    public init(_ color: CGColor) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) }
        let c = srgb?.components ?? [0, 0, 0]
        self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
    }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    public static let blue = TaskColor(red: 0.20, green: 0.48, blue: 0.96)
    public static let green = TaskColor(red: 0.20, green: 0.70, blue: 0.35)
    public static let yellow = TaskColor(red: 0.96, green: 0.74, blue: 0.10)
    public static let orange = TaskColor(red: 0.97, green: 0.52, blue: 0.16)
    public static let red = TaskColor(red: 0.90, green: 0.25, blue: 0.24)
    public static let purple = TaskColor(red: 0.62, green: 0.36, blue: 0.87)
    /// The Style tab's swatches, named for VoiceOver.
    public static let presets: [(name: String, color: TaskColor)] = [
        ("Blue", .blue), ("Green", .green), ("Yellow", .yellow), ("Orange", .orange), ("Red", .red), ("Purple", .purple),
    ]
}

/// What the card shows besides its title, status and schedule line.
public struct TaskDisplay: Codable, Equatable, Sendable {
    public var notes: Bool
    public var checklist: Bool
    public var progress: Bool

    public init(notes: Bool = true, checklist: Bool = true, progress: Bool = true) {
        self.notes = notes
        self.checklist = checklist
        self.progress = progress
    }
}
