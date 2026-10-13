import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Subboards
import SwiftUI
import TableOfContents
import TestKit

// A subboard's row in the table of contents is in the color the subboard has of its own, its indigo otherwise.

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

@MainActor let subboardTintTests = Suite("Subboards' tints", [
    test("its row's symbol is its indigo, or the color it has of its own, and follows a change to it") {
        let tint = OwnTint()
        let nest = Nest()
        let h = try EditorHarness(plugins: subboardPlugins() + [FreezingPlugin(), giving(tint)], file: nest.file())
        let id = nest.s
        let indigo = Color(nsColor: try require(h.editor.registry.label(of: Subboard.kind).tint))
        @MainActor func color() throws -> Color? {
            let label = try require(h.editor.tableOfContents?.entries.first { $0.id == id }?.label)
            return label.color
        }
        expectEqual(try color(), indigo)
        h.editor.freeze([id])
        expectEqual(try color(), Color(nsColor: .systemRed), "its own")
        tint.color = .systemPurple
        h.editor.shapeTintsDidChange()
        expectEqual(try color(), Color(nsColor: .systemPurple), "what the color is changed")
        h.editor.freeze([id], false)
        expectEqual(try color(), indigo, "taken away")
    },
])
