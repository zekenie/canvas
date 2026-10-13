import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// The tint of a shape's symbol where it is listed (`registrar.shapeTints`, `editor.tint(of:)`), with
// CanvasTesting's `Frozen` flag standing in for a color a shape holds of its own.

/// Counts what services heard of the tints changing.
@MainActor
private final class TintListener {
    var heard = 0
}

extension TintListener: EditorService {
    func shapeTintsDidChange(in editor: CanvasEditor) { heard += 1 }
}

@MainActor let tintTests = Suite("Shape tints", [
    test("a shape's tint is the first a plugin gives it, else its kind's; none for a kind with neither") {
        let h = try EditorHarness(plugins: [
            FixturesPlugin(), FreezingPlugin(),
            CardsPlugin { card, _ in card.tint(.systemTeal) },
            Contributor(id: "declines") { $0.shapeTints { _, _ in nil } },
            Contributor(id: "first") { $0.shapeTints { record, _ in record[Frozen.self] == true ? .systemRed : nil } },
            Contributor(id: "second") { $0.shapeTints { _, _ in .systemBlue } },
        ])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([card])
        let frozen = try require(h.editor.document[card])
        expectEqual(h.editor.tint(of: frozen), .systemRed, "the first plugin that answers, over the kind's and the later plugin's")
        expectEqual(h.editor.ownTint(of: frozen), .systemRed)
        h.editor.freeze([card], false)
        let thawed = try require(h.editor.document[card])
        expectEqual(h.editor.tint(of: thawed), .systemBlue, "the next plugin that answers")
        expectEqual(h.editor.tint(of: try require(h.editor.document[box])), .systemBlue, "any shape")
        expect(h.editor.registry.report.contains("shape tints"), h.editor.registry.report)
    },
    test("with no plugin answering, a shape has its kind's tint, and a kind with none has none") {
        let h = try EditorHarness(plugins: [
            FixturesPlugin(), FreezingPlugin(),
            CardsPlugin { card, _ in card.tint(.systemTeal) },
            Contributor(id: "frozen") { $0.shapeTints { record, _ in record[Frozen.self] == true ? .systemRed : nil } },
        ])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let record = try require(h.editor.document[card])
        expectEqual(h.editor.tint(of: record), .systemTeal, "its kind's")
        expectEqual(h.editor.ownTint(of: record), nil, "no plugin gave it one")
        expectEqual(h.editor.tint(of: try require(h.editor.document[box])), nil, "a kind with neither")
        expectEqual(h.editor.tint(of: try require(record.typed(as: Card.self))), .systemTeal, "a typed record too")
    },
    test("no plugin's rule, no tint but the kind's") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin { card, _ in card.tint(.systemTeal) }])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expectEqual(h.editor.tint(of: try require(h.editor.document[card])), .systemTeal)
    },
    test("every service hears the tints changed when a plugin says so") {
        let listener = TintListener()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "listens") { $0.service { _ in listener } }])
        expectEqual(listener.heard, 0)
        h.editor.shapeTintsDidChange()
        expectEqual(listener.heard, 1)
    },
])
