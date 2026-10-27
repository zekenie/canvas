import Canvas
import CoreGraphics
import Foundation
import SlashCommands
import Titles

// `/bulk-create A, B, C`: notes titled A, B and C made at once, put down where the next click is. Typed in
// the command bar with nothing selected (a command about its target as a whole, `SelectionSlashCommand`),
// it hands them to the core to place later (`editor.placeLater`), which draws them faint on the pointer
// until a click or Return puts them down, in one step, all selected.

/// What `/bulk-create` does.
@MainActor
enum BulkCreate {
    static let name = "bulk-create"

    /// The command: offered with nothing selected (the bar's every shape, on an empty board too), on a
    /// board that can change; it takes one title or more, between commas.
    static var command: SelectionSlashCommand {
        .atOnce(name, argument: BulkCreateStyle.argument, when: { target, editor in offers(target, in: editor) },
                accepts: { titles(in: $0) != nil }) { _, arguments, editor in start(arguments, in: editor) }
    }

    /// Nothing selected, and the board shown can change.
    static func offers(_ target: SlashTarget, in editor: CanvasEditor) -> Bool {
        guard case .everything = target else { return false }
        return !editor.isBoardReadOnly
    }

    /// The titles typed: what's between the commas, each trimmed, the empty ones left out; nil for none,
    /// and for a line that names a shape (a pill), which no title is.
    static func titles(in arguments: SlashArguments) -> [String]? {
        guard arguments.shapes.isEmpty else { return nil }
        let titles = arguments.text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return titles.isEmpty ? nil : titles
    }

    /// A note a title, the size a new note is, waiting to be placed: in a column from the pointer, the
    /// first note's middle on it, or in a row while ⌥ is held. VoiceOver hears how many wait.
    static func start(_ arguments: SlashArguments, in editor: CanvasEditor) {
        guard let titles = titles(in: arguments), let placement = editor.registry.placement(for: StickyNote.kind) else { return }
        let records = titles.map { placement.setting(TitleProperty.self, to: $0).shape(at: .zero) }
        let size = placement.size, count = records.count
        let pending = PendingPlacement(records, stepName: BulkCreateStyle.step(count)) { modifiers in
            corners(of: count, size: size, inRow: modifiers.contains(.option))
        }
        guard editor.placeLater(pending) else { return }
        editor.announce(BulkCreateStyle.waiting(count))
    }

    /// Where each of `count` notes of `size` goes, its top-left corner from where they're put down: the
    /// first's middle there, the rest below it, or to its right in a row, `BulkCreateStyle.gap` apart.
    static func corners(of count: Int, size: CGSize, inRow: Bool) -> [CGPoint] {
        (0..<count).map { index in
            let step = CGFloat(index)
            return CGPoint(x: -size.width / 2 + (inRow ? step * (size.width + BulkCreateStyle.gap) : 0),
                           y: -size.height / 2 + (inRow ? 0 : step * (size.height + BulkCreateStyle.gap)))
        }
    }
}

/// `/bulk-create`'s words and spacing.
@MainActor
enum BulkCreateStyle {
    /// The hint beside its name in the list: the form it takes.
    static let argument = "A, B, C"
    /// Between two notes, world units: the gap a note added beside another gets (`canvas draw`'s
    /// normal), room for each note's title pill above it once zoomed out, which 40 wouldn't leave.
    static let gap: CGFloat = 80
    /// What ⌥ held does while they wait (a click, or ⌥↩), for the Keyboard Shortcuts window.
    static let inRow = "Place Notes in a Row"

    /// The step putting them down makes.
    static func step(_ count: Int) -> String { count == 1 ? "Add Note" : "Add Notes" }

    /// What VoiceOver hears as they wait: "3 notes to place".
    static func waiting(_ count: Int) -> String { count == 1 ? "1 note to place" : "\(count) notes to place" }
}
