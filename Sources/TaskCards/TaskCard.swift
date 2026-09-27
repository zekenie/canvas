import Canvas
import Checklists
import CoreGraphics
import Foundation
import Titles

/// A task on the canvas: a title, a status, a schedule and a checklist, drawn as a card. It has no
/// editing view; the detail panel is its editor. Its title and checklist are the properties Titles
/// and Checklists add to it.
public struct TaskCard: BoxShapeProps {
    public static let kind: ShapeKind = "task-card"
    /// Append only. The count is the version boards record.
    public static let migrations = [
        // Checklists adds the checklist to every kind that opts in; the card no longer keeps one.
        PropsMigration.handOver("checklist", to: ChecklistProperty.self),
        // A blank title was an untitled task's; Titles keeps none for one.
        PropsMigration("a blank title is none") { props in
            if props["title"]?.stringValue?.allSatisfy(\.isWhitespace) == true { props["title"] = nil }
        },
        // Titles adds the title to every kind that opts in; the card no longer keeps one.
        PropsMigration.handOver("title", to: TitleProperty.self),
    ]
    public static let properties = Properties<TaskCard>(title: "Task card") {
        Property("frame", \.frame).required()
        Property("notes", \.notes)
        Property("status", \.status)
        Property("priority", \.priority)
        Property("estimate", \.estimate).minimum(0).description("Hours.")
        Property("due", \.due)
        Property("color", \.color)
        Property("shows", \.shows).description("What the card shows besides its title, status and schedule line.")
    }
    public static let defaultSize = CGSize(width: 240, height: 200)

    public var frame: CGRect
    public var notes: String
    public var status: TaskStatus
    public var priority: TaskPriority
    /// Hours.
    public var estimate: Double
    public var due: Date?
    public var color: TaskColor
    public var shows: TaskDisplay

    public init(frame: CGRect = .zero, notes: String = "", status: TaskStatus = .todo,
                priority: TaskPriority = .medium, estimate: Double = 0, due: Date? = nil, color: TaskColor = .blue,
                shows: TaskDisplay = TaskDisplay()) {
        self.frame = frame
        self.notes = notes
        self.status = status
        self.priority = priority
        self.estimate = estimate
        self.due = due
        self.color = color
        self.shows = shows
    }

    public init() { self.init(frame: .zero) }
}

// MARK: Derived

extension TaskCard {
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

extension ShapeRecord where Props == TaskCard {
    /// The card's title: Titles' property, which the card opts into; nil while it's untitled.
    public var title: String? { self[TitleProperty.self] }

    /// Whether it has no title, or a blank one: such a task is invalid, and is drawn and named
    /// "Untitled Task".
    public var isUntitled: Bool { title?.allSatisfy(\.isWhitespace) ?? true }

    /// The card's checklist: Checklists' property, which the card opts into.
    public var checklist: [ChecklistItem] { self[ChecklistProperty.self] ?? [] }

    /// The hours still to go: the estimate less the checked share of the checklist; none once done.
    public var remaining: Double { props.status == .done ? 0 : props.estimate * (1 - checklist.progress) }

    /// "In Progress · 2 of 5 · Due Sep 30": the status, then the checklist and due date if any.
    public var summary: String {
        var parts = [props.status.label]
        if !checklist.isEmpty { parts.append("\(checklist.doneCount) of \(checklist.count)") }
        if let due = props.due { parts.append("Due \(TaskCard.format(due))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Values

public enum TaskStatus: String, Codable, Sendable, CaseIterable, Identifiable, SchemaCases {
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
    public var schemaTitle: String { label }
}

public enum TaskPriority: String, Codable, Sendable, CaseIterable, Identifiable, SchemaCases {
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
    public var schemaTitle: String { rawValue.capitalized }
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
public struct TaskColor: SchemaDefined, Hashable {
    public static let properties = Properties<TaskColor>(title: "Color", description: "sRGB components, 0 to 1.") {
        Property("red", \.red).minimum(0).maximum(1)
        Property("green", \.green).minimum(0).maximum(1)
        Property("blue", \.blue).minimum(0).maximum(1)
    }
    private(set) var red: Double
    private(set) var green: Double
    private(set) var blue: Double

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

    public init() { self = .blue }

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
public struct TaskDisplay: SchemaDefined, Equatable {
    public static let properties = Properties<TaskDisplay> {
        Property("notes", \.notes)
        Property("checklist", \.checklist)
        Property("progress", \.progress)
    }
    public var notes: Bool
    public var checklist: Bool
    public var progress: Bool

    public init(notes: Bool = true, checklist: Bool = true, progress: Bool = true) {
        self.notes = notes
        self.checklist = checklist
        self.progress = progress
    }
    public init() { self.init(notes: true) }
}
