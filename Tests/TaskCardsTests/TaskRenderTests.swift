import AppKit
import Canvas
import CanvasTesting
import Checklists
import DetailPanel
import SwiftUI
import TaskCards
import TestKit

// Where things are on a card at `cardFrame` (40, 40, 240 × 200): a 5-point strip, then 12 points of
// padding all round, so the content runs from x 57 to 268 and y 52 to 228. Title lines are 17
// points, and the other lines 14.
let strip = CGPoint(x: 42, y: 120)
/// Just inside the status pill's right end, clear of its text.
let pillEnd = CGPoint(x: 265, y: 61)
/// The progress bar's middle row runs from x 57 to 268 at y 226.
func bar(_ fraction: CGFloat) -> CGPoint { CGPoint(x: 57 + 211 * fraction, y: 226) }

/// Bands of the card's content: the title and pill, the priority and schedule line, the notes and
/// checklist, the progress bar, and the strip.
enum Band {
    static let header = CGRect(x: 57, y: 52, width: 211, height: 17)
    static let meta = CGRect(x: 57, y: 75, width: 211, height: 14)
    static let body = CGRect(x: 57, y: 91, width: 211, height: 127)
    static let bar = CGRect(x: 57, y: 223, width: 211, height: 6)
    static let strip = CGRect(x: 40, y: 50, width: 5, height: 180)
}

@MainActor func expectColor(_ actual: [Int], _ expected: [Int], within tolerance: Int = 10, file: StaticString = #fileID, line: UInt = #line) {
    expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(actual) is not about \(expected)", file: file, line: line)
}

/// Whether any pixel in `rect` is about `color`.
@MainActor func contains(_ bitmap: NSBitmapImageRep, _ color: [Int], in rect: CGRect, within tolerance: Int = 10) -> Bool {
    stride(from: rect.minY, to: rect.maxY, by: 1).contains { y in
        stride(from: rect.minX, to: rect.maxX, by: 1).contains { x in
            zip(pixel(bitmap, at: CGPoint(x: x, y: y)), color).allSatisfy { abs($0 - $1) <= tolerance }
        }
    }
}

/// Whether any pixel in `rect` is text-dark.
@MainActor func hasInk(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Bool {
    stride(from: rect.minY, to: rect.maxY, by: 1).contains { y in
        stride(from: rect.minX, to: rect.maxX, by: 1).contains { x in pixel(bitmap, at: CGPoint(x: x, y: y)).prefix(3).allSatisfy { $0 < 170 } }
    }
}

/// An editor showing one task, written to only through its panel bindings.
@MainActor final class Drawn {
    let editor: CanvasEditor
    let id: ShapeID
    let task: ShapeBinding<TaskCard>
    /// The checklist, as its Items section binds it.
    let checklist: Binding<[ChecklistItem]>

    init(_ shape: ShapeRecord<TaskCard> = fullTask()) throws {
        editor = try taskEditor()
        id = editor.add(shape)
        task = try require(editor.shapeBinding(id, as: TaskCard.self))
        checklist = try require(editor.propertyBinding(id, ChecklistProperty.self))[dynamicMember: \.self]
    }

    var bitmap: NSBitmapImageRep { renderBitmap(editor, size: CGSize(width: 320, height: 240)) }
}

@MainActor let taskRenderTests = Suite("Task card drawing", [
    test("a preset set through the binding recolors the strip, in one transaction") {
        let card = try Drawn()
        expectColor(pixel(card.bitmap, at: strip), [51, 122, 245])
        let revision = card.editor.revision
        card.task.displayColor.wrappedValue = TaskColor.presets[1].color.cgColor
        expectEqual(card.editor.revision, revision + 1)
        expectEqual(card.editor.task(card.id)?.color, .green)
        expectColor(pixel(card.bitmap, at: strip), [51, 179, 89])
    },
    test("the status pill's color follows the status") {
        let card = try Drawn()
        for (status, color) in [(TaskStatus.todo, [140, 140, 140]), (.doing, [51, 122, 245]), (.blocked, [230, 64, 61])] {
            card.task.status.wrappedValue = status
            expectColor(pixel(card.bitmap, at: pillEnd), color)
        }
    },
    test("a done card is dimmed, pill and all") {
        let card = try Drawn()
        card.task.status.wrappedValue = .done
        // The green pill and the blue strip, at 55% over the canvas.
        let pill = pixel(card.bitmap, at: pillEnd), stripColor = pixel(card.bitmap, at: strip)
        expect(pill[1] > pill[0] + 30 && pill[0] > 100, "\(pill)")
        expect(stripColor[2] > stripColor[0] + 50 && stripColor[0] > 110, "\(stripColor)")
    },
    test("the progress bar fills by the done fraction, and hides when switched off") {
        let card = try Drawn()          // 1 of 3 done
        expectColor(pixel(card.bitmap, at: bar(0.15)), [51, 122, 245])
        expectColor(pixel(card.bitmap, at: bar(0.6)), [230, 230, 230])
        card.checklist.wrappedValue = steps(done: 2)
        expectColor(pixel(card.bitmap, at: bar(0.6)), [51, 122, 245])
        expectColor(pixel(card.bitmap, at: bar(0.9)), [230, 230, 230])
        card.task.shows.progress.wrappedValue = false
        expectColor(pixel(card.bitmap, at: bar(0.15)), [255, 255, 255])
        card.task.shows.progress.wrappedValue = true
        card.checklist.wrappedValue = []
        expectColor(pixel(card.bitmap, at: bar(0.15)), [255, 255, 255])
    },
    test("every Task and Style field changes the drawing, where that field is drawn") {
        let cases: [(field: String, band: CGRect, write: @MainActor (Drawn) -> Void)] = [
            ("title", Band.header, { $0.task.title.wrappedValue = "Ship it" }),
            ("no title", Band.header, { $0.task.title.wrappedValue = "" }),
            ("status", Band.header, { $0.task.status.wrappedValue = .blocked }),
            ("priority", Band.meta, { $0.task.priority.wrappedValue = .high }),
            ("estimate", Band.meta, { $0.task.estimate.wrappedValue = 6 }),
            ("due date", Band.meta, { $0.task.dueDate.wrappedValue = day(10, 2) }),
            ("no due date", Band.meta, { $0.task.hasDue.wrappedValue = false }),
            ("notes", Band.body, { $0.task.notes.wrappedValue = "Just the card." }),
            ("a checked item", Band.body, { $0.checklist[1].isDone.wrappedValue = true }),
            ("an item's text", Band.body, { $0.checklist[2].text.wrappedValue = "celebrate" }),
            ("progress", Band.bar, { $0.checklist[1].isDone.wrappedValue = true }),
            ("shows notes", Band.body, { $0.task.shows.notes.wrappedValue = false }),
            ("shows checklist", Band.body, { $0.task.shows.checklist.wrappedValue = false }),
            ("shows progress", Band.bar, { $0.task.shows.progress.wrappedValue = false }),
            ("color", Band.strip, { $0.task.displayColor.wrappedValue = TaskColor.presets[4].color.cgColor }),
        ]
        for (field, band, write) in cases {
            let card = try Drawn()
            let before = card.bitmap, revision = card.editor.revision
            write(card)
            expectEqual(card.editor.revision, revision + 1, field)
            expect(changedPixels(before, card.bitmap, in: band) > 0, "\(field) left its part of the card as it was")
        }
    },
    test("notes get two lines, the second drawn, not cut to one with an ellipsis") {
        var task = fullTask()
        task.props.shows.checklist = false
        task.props.notes = "Keep the old tables read-only for a week after cut-over, in case we need to roll back."
        let long = try render(task)
        // The title and meta lines end at y 89; the notes start 6 points on, 14 points a line.
        let first = CGRect(x: 57, y: 97, width: 211, height: 10), second = first.offsetBy(dx: 0, dy: 14)
        expect(hasInk(long, in: first))
        expect(hasInk(long, in: second), "the notes' second line wasn't drawn")
        task.props.notes = "One line."
        expect(!hasInk(try render(task), in: second))
    },
    test("a full task at the default size shows its checklist's open items, not just the done ones") {
        let items = ["Draft the migration plan", "Review schema", "Write backfill script", "Dry run on staging", "Cut over"]
        let task = ShapeRecord(TaskCard(frame: CGRect(origin: cardFrame.origin, size: TaskCard.defaultSize), title: "Migrate billing to Postgres",
                                        notes: "Keep the old tables read-only for a week after cut-over, in case we need to roll back.",
                                        status: .doing, estimate: 12, due: day(10, 9)),
                               checklist: items.enumerated().map { ChecklistItem(text: $1, isDone: $0 < 2) })
        var renamed = task
        renamed[ChecklistProperty.self]?[2].text = "Write the backfill"     // the first open item, same count
        expect(changedPixels(try render(task), try render(renamed), in: Band.body) > 0, "the first open item's row wasn't drawn")
    },
    test("a small card drops the pill beside a narrow title, and draws below the title only what fits above the bar") {
        var task = fullTask()
        task.props.color = .purple
        let titleLine = CGRect(x: 57, y: 52, width: 61, height: 17)
        for height: CGFloat in [60, 51] {
            task.frame = CGRect(x: 40, y: 40, width: 90, height: height)
            let card = try render(task)
            expect(!contains(card, [51, 122, 245], in: task.frame), "the In Progress pill was drawn at \(height)")
            expect(hasInk(card, in: titleLine), "no title at \(height)")
            // Nothing but the title on its line (not the priority marks), and no text under it:
            // there's no room above the (purple) bar for the meta line or a checklist row.
            expect(!contains(card, [242, 140, 25], in: titleLine, within: 40))
            expect(!hasInk(card, in: CGRect(x: 57, y: titleLine.maxY + 1, width: 61, height: task.frame.maxY - titleLine.maxY - 1)),
                   "text under the title at \(height)")
        }
    },
    test("a card sized down to a sliver still draws, and the checklist chip stays off it") {
        var task = fullTask()
        let full = try render(task), bare = try render(ShapeRecord(TaskCard(frame: cardFrame, title: task.props.title)))
        // Checklists' chip would sit on the top-right corner: the card draws its own list instead.
        expectEqual(pixel(full, at: CGPoint(x: cardFrame.maxX + 3, y: cardFrame.minY)),
                    pixel(bare, at: CGPoint(x: cardFrame.maxX + 3, y: cardFrame.minY)))
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240), empty = renderBitmap(try taskEditor(), size: canvas.size)
        for size in [CGSize(width: 1, height: 1), CGSize(width: 12, height: 300), CGSize(width: 300, height: 10)] {
            task.frame.size = size
            expect(changedPixels(empty, try render(task), in: task.frame.intersection(canvas)) > 0, "nothing drawn at \(size)")
        }
    },
])
