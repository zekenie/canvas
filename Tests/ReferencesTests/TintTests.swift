import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import QueryTranslation
import References
import SwiftUI
import TableOfContents
import TestKit

// The symbol of what a reference stands for, in the table of contents and in the panel's matches, in
// the color the shape has of its own (a plugin's `shapeTints`, here for a frozen shape: CanvasTesting's
// `Frozen` flag standing in for a color a shape holds), over its kind's (a box's orange). The pill's own symbol is
// the color book's (ColorTests).

/// The tint a frozen shape has of its own, which the test can change.
@MainActor private final class OwnTint {
    var color: NSColor = .systemRed
}

/// What gives a frozen shape that tint (`registrar.shapeTints`), and the flag.
@MainActor private func giving(_ tint: OwnTint) -> [any CanvasPlugin] {
    [FreezingPlugin(), Contributor(id: "own-tints") { r in
        r.shapeTints { record, _ in record[Frozen.self] == true ? tint.color : nil }
    }]
}

@MainActor let referenceTintTests = Suite("References' tints", [
    test("its row's symbol is in the tint of the shape it stands for, its own where it has one, and follows a change to it") {
        let tint = OwnTint()
        let h = try referenceHarness(giving(tint))
        let box = h.addBox("shapes")
        let reference = h.addReference(to: box, label: "shapes")
        @MainActor func color() throws -> Color? {
            let label = try require(h.editor.tableOfContents?.entries.first { $0.id == reference }?.label)
            return label.color
        }
        expectEqual(try color(), Color(nsColor: .systemOrange), "its kind's, as the original is mentioned")
        h.editor.freeze([box])
        expectEqual(try color(), Color(nsColor: .systemRed), "its own")
        tint.color = .systemPurple
        h.editor.shapeTintsDidChange()
        expectEqual(try color(), Color(nsColor: .systemPurple), "what the color is changed")
        h.editor.freeze([box], false)
        expectEqual(try color(), Color(nsColor: .systemOrange), "taken away")
    },
    test("the panel's matches have the symbol in each shape's tint") {
        let tint = OwnTint()
        let h = try referenceHarness(giving(tint))
        let first = h.addBox("B0"), second = h.addBox("B1", at: CGRect(x: 300, y: 100, width: 100, height: 100))
        let reference = h.addReference(query: "box", all: true)
        h.answer()
        let state = try require(h.editor.references)
        expectEqual(state.matchRows(of: reference).rows.map(\.tint), [.systemOrange, .systemOrange])
        h.editor.freeze([second])
        h.answer(after: 250)
        expectEqual(state.matchRows(of: reference).rows.map(\.id), [first, second])
        expectEqual(state.matchRows(of: reference).rows.map(\.tint), [.systemOrange, tint.color])
    },
])
