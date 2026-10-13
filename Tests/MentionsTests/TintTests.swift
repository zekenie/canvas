import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import TestKit

// A mention's tint when its shape has a color of its own (a plugin's `shapeTints`, here for a frozen
// shape: CanvasTesting's `Frozen` flag standing in for a color a shape holds): the pill's symbol on a
// neutral surface, the `@` picker's rows.

private let frame = CGRect(x: 0, y: 0, width: 100, height: 80)

/// The tint a frozen shape has of its own, which the test can change.
@MainActor private final class OwnTint {
    var color: NSColor = .systemRed
}

@MainActor private func ownTints(_ tint: OwnTint) -> [any CanvasPlugin] {
    [FreezingPlugin(), Contributor(id: "own-tints") { r in
        r.shapeTints { record, _ in record[Frozen.self] == true ? tint.color : nil }
    }]
}

@MainActor let mentionTintTests = Suite("Mentions' tints", [
    test("a mention's tint is the shape's own where a plugin gives one, over what the kind says for the shape and over its kind's") {
        typealias IndexCard = CanvasTesting.Card
        let own = OwnTint()
        let h = try mentionHarness([CardsPlugin { card, _ in card.tint(.systemTeal) },
                                    Contributor(id: "card-mentions") {
                                        $0.mentionable(IndexCard.self, untitled: { _ in "A card" }, tint: { $0.props.text == "blue" ? .systemBlue : nil })
                                    }] + ownTints(own))
        let plain = h.add(IndexCard(frame)), blue = h.add(IndexCard(frame, text: "blue")), plate = h.editor.add(Plate(frame), titled: "P")
        @MainActor func tint(_ id: ShapeID) throws -> NSColor? {
            let record = try require(h.record(id))
            let appearance = try require(h.editor.mentionAppearance(of: record))
            return appearance.tint
        }
        expectEqual(try tint(plain), .systemTeal, "its kind's")
        expectEqual(try tint(plate), nil, "a kind with none")
        h.editor.freeze([plain, blue, plate])
        expectEqual(try tint(plain), own.color, "its own, over its kind's")
        expectEqual(try tint(blue), own.color, "its own, over what the kind says of the shape")
        h.editor.freeze([blue], false)
        expectEqual(try tint(blue), .systemBlue, "what the kind says of the shape")
        expectEqual(try tint(plate), own.color, "a kind with no tint of its own gets one")
        expectEqual(h.record(plain).flatMap(h.editor.registry.mentionAppearance(of:))?.tint, .systemTeal, "the registry's has no editor to ask")
    },

    test("what a mention shows follows the shape's tint: a commit to it, and a change to what tints are, tell its observers") {
        let own = OwnTint()
        let h = try mentionHarness(ownTints(own))
        let state = h.editor.mentionState
        let plate = h.editor.add(Plate(frame), titled: "P")
        var heard: [Set<ShapeID>] = []
        let observation = state.observe([plate]) { heard.append($0) }
        expectEqual(state.resolve(plate).appearance?.tint, nil)
        h.editor.freeze([plate])
        expectEqual(state.resolve(plate).appearance?.tint, own.color)
        expectEqual(heard, [[plate]], "the commit that gave it a tint")
        own.color = .systemPurple
        h.editor.shapeTintsDidChange()
        expectEqual(state.resolve(plate).appearance?.tint, .systemPurple, "what the tint is, with no commit")
        expectEqual(heard.count, 2)
        h.editor.shapeTintsDidChange()
        expectEqual(heard.count, 2, "nothing changed, no call")
        h.editor.freeze([plate], false)
        expectEqual(state.resolve(plate).appearance?.tint, nil)
        observation.cancel()
    },

    test("the picker's rows have the tint now: a commit changes it, and so does a change to what tints are") {
        let own = OwnTint()
        let h = try mentionHarness(ownTints(own))
        let state = h.editor.mentionState
        let plate = h.editor.add(Plate(frame), titled: "Planet")
        @MainActor func rowTint() throws -> NSColor? {
            let matches = state.candidates(matching: "planet", in: AnyMentionable.self, for: nil).matches
            let row = try require(matches.first(where: { $0.id == plate }))
            return row.appearance.tint
        }
        expectEqual(try rowTint(), nil)
        h.editor.freeze([plate])
        expectEqual(try rowTint(), own.color, "a commit to the shape")
        own.color = .systemPurple
        h.editor.shapeTintsDidChange()
        expectEqual(try rowTint(), .systemPurple, "no commit: the entries are read again at the next query")
    },
])
