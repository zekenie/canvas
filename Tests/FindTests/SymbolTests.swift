import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Find
import Observation
import TestKit

// A row's symbol in the panel: its kind's, in the tint the shape has. A plugin's `shapeTints` gives
// the tint here, for a frozen shape (CanvasTesting's `Frozen` flag standing in for a color a shape
// holds of its own).

/// The tint a frozen shape has of its own, which the test can change.
@MainActor private final class OwnTint {
    var color: NSColor = .systemRed
}

@MainActor private func ownTints(_ tint: OwnTint) -> [any CanvasPlugin] {
    [FreezingPlugin(), Contributor(id: "own-tints") { r in
        r.shapeTints { record, _ in record[Frozen.self] == true ? tint.color : nil }
    }, CardsPlugin { card, _ in card.tint(.systemTeal) }]
}

/// How many times a view's observation fired.
private final class Counter: @unchecked Sendable {
    var count = 0
}

@MainActor let symbolTests = Suite("Find's rows' symbols", [
    test("a row's symbol is in the tint its shape has, its kind's when it has none of its own") {
        let own = OwnTint()
        let memo = ShapeID(), card = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: memo, Memo(CGRect(x: 100, y: 100, width: 160, height: 40), "note one"))),
            AnyShapeRecord(ShapeRecord(id: card, Card(CGRect(x: 400, y: 100, width: 160, height: 60), text: "note two"))),
        ]))
        let h = try findHarness(file, more: ownTints(own))
        let find = try search("note", in: h)
        expectEqual(find.symbol(of: memo).tint, nil, "a memo's kind declares none")
        expectEqual(find.symbol(of: card).tint, .systemTeal, "a card's kind's")
        h.editor.freeze([memo, card])
        expectEqual(find.symbol(of: memo).tint, own.color, "its own")
        expectEqual(find.symbol(of: card).tint, own.color, "its own, over its kind's")
        h.editor.freeze([card], false)
        expectEqual(find.symbol(of: card).tint, .systemTeal, "taken away")
    },
    test("a commit to a row's shape, and a change to the file's colors, tell a row to be drawn again; a commit to another shape doesn't") {
        let own = OwnTint()
        let memo = ShapeID(), other = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: memo, Memo(CGRect(x: 100, y: 100, width: 160, height: 40), "note one"))),
            AnyShapeRecord(ShapeRecord(id: other, Memo(CGRect(x: 400, y: 100, width: 160, height: 40), "other"))),
        ]))
        let h = try findHarness(file, more: ownTints(own))
        let find = try search("note", in: h)
        let redrawn = Counter()
        @MainActor func watch() {
            withObservationTracking { _ = find.symbol(of: memo) } onChange: { redrawn.count += 1 }
        }
        watch()
        h.editor.freeze([other])
        expectEqual(redrawn.count, 0, "a shape that isn't a result")
        h.editor.freeze([memo])
        expectEqual(redrawn.count, 1, "the result's own commit")
        watch()
        own.color = .systemPurple
        h.editor.shapeTintsDidChange()
        expectEqual(redrawn.count, 2, "the file's colors")
        expectEqual(find.symbol(of: memo).tint, .systemPurple)
    },
])
