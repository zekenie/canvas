import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SwiftUI
import TableOfContents
import TestKit

// An arrow's row in the table of contents has no color unless the arrow has one of its own.

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

@MainActor let arrowTintTests = Suite("Arrows' tints", [
    test("its row's symbol is no color, or the color it has of its own, and follows a change to it") {
        let tint = OwnTint()
        let h = try EditorHarness(plugins: arrowsPlugins(more: [FreezingPlugin(), giving(tint)]))
        let id = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200))))
        @MainActor func color() throws -> Color? {
            let label = try require(h.editor.tableOfContents?.entries.first { $0.id == id }?.label)
            return label.color
        }
        expectEqual(try color(), nil)
        h.editor.freeze([id])
        expectEqual(try color(), Color(nsColor: .systemRed), "its own")
        tint.color = .systemPurple
        h.editor.shapeTintsDidChange()
        expectEqual(try color(), Color(nsColor: .systemPurple), "what the color is changed")
        h.editor.freeze([id], false)
        expectEqual(try color(), nil, "taken away")
    },
])
