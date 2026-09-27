import AppKit
import Canvas
import CanvasTesting
import Checklists
import DetailPanel
import Selection
import TaskCards
import TestKit
import Validation

/// Every plugin a task card needs (it contributes to validation, checklists and the panel), and
/// the selection, to select one.
@MainActor func taskPlugins() -> [any CanvasPlugin] {
    [SelectionPlugin(), TaskCardsPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin()]
}

@MainActor func taskEditor(scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: taskPlugins()), scheduler: scheduler)
}

let cardFrame = CGRect(x: 40, y: 40, width: 240, height: 200)

/// Noon on a day of 2026, in the current calendar.
func day(_ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
}

/// "spec", "review", "ship"; the first `done` of them checked.
func steps(done: Int = 0) -> [ChecklistItem] {
    ["spec", "review", "ship"].enumerated().map { ChecklistItem(text: $1, isDone: $0 < done) }
}

/// A task with every field set, so each one has something on the card to change.
func fullTask() -> TaskCard {
    TaskCard(frame: cardFrame, title: "Write the spec", notes: "Cover the panel and the card.", status: .doing, priority: .medium,
             estimate: 4, due: day(9, 30), checklist: steps(done: 1))
}

extension CanvasEditor {
    func task(_ id: ShapeID) -> TaskCard? { document[id]?.typed(as: TaskCard.self)?.props }

    func layout(_ id: ShapeID) throws -> DetailLayout {
        try require(detailPanel).layout(for: try require(document[id]))
    }

    func issues(_ id: ShapeID) -> [ValidationIssue] { validation?.result(for: id)?.issues ?? [] }
}

extension DetailLayout {
    /// "Tab: section, section" per tab, which reads well in a failure.
    var outline: [String] {
        tabs.map { tab in "\(tab.title): " + sections(in: tab).map(\.section).joined(separator: ", ") }
    }
}

/// The canvas with one task on it, nothing selected.
@MainActor func render(_ task: TaskCard, scale: CGFloat = 1) throws -> NSBitmapImageRep {
    let editor = try taskEditor()
    editor.add(task)
    return renderBitmap(editor, size: CGSize(width: 320, height: 240), scale: scale)
}
