import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SwiftUI
import Mentions
import StickyNotes
import TableOfContents
import TestKit
import Titles

// A note's row in the table of contents is in the color the note has of its own, its yellow otherwise.

/// The tint a frozen shape has of its own, standing in for a color a shape holds (CanvasTesting's
/// `Frozen` flag), which the test can change.
@MainActor private final class OwnTint {
    var color: NSColor = .systemRed
}

/// What gives a frozen shape that tint (`registrar.shapeTints`).
private func giving(_ tint: OwnTint) -> Contributor {
    Contributor(id: "own-tints") { r in
        r.shapeTints { record, _ in record[Frozen.self] == true ? tint.color : nil }
    }
}

@MainActor let noteTintTests = Suite("Sticky notes' tints", [
    test("its row's symbol is yellow, or the color the note has of its own, and follows a change to it") {
        let tint = OwnTint()
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins + [FreezingPlugin(), giving(tint)]), scheduler: ManualScheduler())
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Shopping"))
        editor.transact { $0.insert(note) }
        @MainActor func color() throws -> Color? {
            let label = try require(editor.tableOfContents?.entries.first { $0.id == note.id }?.label)
            return label.color
        }
        expectEqual(try color(), Color(nsColor: .systemYellow))
        editor.freeze([note.id])
        expectEqual(try color(), Color(nsColor: .systemRed), "its own")
        tint.color = .systemPurple
        editor.shapeTintsDidChange()
        expectEqual(try color(), Color(nsColor: .systemPurple), "what the color is changed")
        editor.freeze([note.id], false)
        expectEqual(try color(), Color(nsColor: .systemYellow), "taken away")
    },
])
