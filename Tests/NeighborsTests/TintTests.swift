import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Neighbors
import TestKit

// A row's symbol in the panel's lists is in the tint the shape has (a plugin's `shapeTints`, here for
// a frozen shape: CanvasTesting's `Frozen` flag standing in for a color a shape holds), else its
// kind's; it is read as the row is drawn.

/// The tint a frozen shape has of its own, which the test can change.
@MainActor private final class OwnTint {
    var color: NSColor = .systemRed
}

@MainActor private func giving(_ tint: OwnTint) -> [any CanvasPlugin] {
    [FreezingPlugin(), Contributor(id: "own-tints") { r in
        r.shapeTints { record, _ in record[Frozen.self] == true ? tint.color : nil }
    }]
}

@MainActor let tintListTests = Suite("Neighbors: rows' tints", [
    test("a row's symbol is in its shape's own tint, else its kind's, and follows a commit and a change to what tints are") {
        let tint = OwnTint()
        let town = Town()
        let h = try listHarness(town.file(), more: giving(tint))
        h.watch(town.s)
        expectEqual(h.line(town.b, in: Lists.wiredTo)?.tint, nil, "a box has none")
        h.editor.freeze([town.b])
        h.settleList(after: 200)
        expectEqual(h.line(town.b, in: Lists.wiredTo)?.tint, tint.color, "its own")
        expectEqual(h.line(town.c, in: Lists.wiredFrom)?.tint, nil, "another shape's")
        let stamp = h.list.listing?.stamp
        tint.color = .systemPurple
        h.editor.shapeTintsDidChange()
        expect(h.list.listing?.stamp != stamp, "every row is drawn again")
        expectEqual(h.line(town.b, in: Lists.wiredTo)?.tint, .systemPurple, "what the color is changed")
        h.editor.freeze([town.b], false)
        h.settleList(after: 200)
        expectEqual(h.line(town.b, in: Lists.wiredTo)?.tint, nil, "taken away")
    },
])
