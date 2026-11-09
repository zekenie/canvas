@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Draw
import Keyboard
import Selection
import TestKit
import Topology

// A shape's arrows as its parts (principle 1, 3, 4, 5): from the middle of three shapes in a row, ⌥Tab
// walks the connections bound to it, Return selects one, Escape comes back to the shape.

/// Tiles say their labels to VoiceOver, as a shipped kind says its title.
private let tileVoices = Contributor(id: "tile-voices") { registrar in
    registrar.forEveryShape { every in
        every.accessibility { record, _ in AccessibleTraits(name: record.typed(as: Tile.self)?.props.label) }
    }
}

/// Tiles A, B, C in a row, a connection from B to C and one from A to B.
@MainActor private func row() throws -> (h: EditorHarness, a: ShapeID, b: ShapeID, c: ShapeID, out: ShapeID, into: ShapeID) {
    let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), DrawPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(),
                                       LinksPlugin(), PortsPlugin(), channelsPlugin(), linkConnector(), fixtureNames, PortEdgesPlugin(), tileVoices]
    let h = try EditorHarness(plugins: plugins)
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    let a = h.add(Tile(CGRect(x: 0, y: 100, width: 100, height: 60), label: "A"))
    let b = h.add(Tile(CGRect(x: 300, y: 100, width: 100, height: 60), label: "B"))
    let c = h.add(Tile(CGRect(x: 600, y: 100, width: 100, height: 60), label: "C"))
    let out = h.add(Link(from: b, to: c))
    let into = h.add(Link(from: a, to: b))
    return (h, a, b, c, out, into)
}

@MainActor let connectionPartsTests = Suite("A shape's arrows as parts", [
    test("⌥Tab from the middle shape walks its arrows, each titled by the shape at its other end, by where they leave it") {
        let (h, a, b, c, out, into) = try row()
        _ = (a, c)
        expectEqual(h.editor.shapeParts(of: a).map(\.title), ["Arrow to B"])
        expectEqual(h.editor.shapeParts(of: b).map(\.id), [AnyHashable(into), AnyHashable(out)], "left to right, where they leave B")
        expectEqual(h.editor.shapeParts(of: b).map(\.title), ["Arrow from A", "Arrow to C"])
        expect(h.editor.shapeParts(of: b).allSatisfy { $0.role == .connection })
        h.editor.selection = b
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Arrow from A")
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Arrow to C")
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Arrow from A", "round")
        expect(!h.editor.selectedShapeIDs.contains(out), "an arrow is never a Tab stop")
    },
    test("an arrow with the focus is lit whole, outlined as a selected arrow is, besides its ring; Escape lets it go") {
        let (h, _, b, _, out, into) = try row()
        h.editor.selection = b
        expectEqual(h.editor.outlines.shapes, [b])
        h.key(Chord.optionTab)
        expectEqual(h.editor.outlines.shapes, [b, into], "the arrow from A, whole, in the selection's color")
        h.key(Chord.optionTab)
        expectEqual(h.editor.outlines.shapes, [b, out], "the next one lit instead")
        h.key(Chord.escape)
        expectEqual(h.editor.outlines.shapes, [b])
    },
    test("Return selects the arrow; Escape comes back to the shape, still selected") {
        let (h, _, b, _, out, _) = try row()
        h.editor.selection = b
        h.key(Chord.optionTab)
        h.key(Chord.optionTab)
        expect(h.key(Chord.return))
        expectEqual(h.editor.selectedShapeIDs, [out])
        h.editor.selection = b
        h.key(Chord.optionTab)
        h.key(Chord.optionTab)
        expect(h.key(Chord.escape))
        expect(!h.editor.hasFocusedPart)
        expectEqual(h.editor.selectedShapeIDs, [b])
    },
    test("⌥⇧Tab is the exact inverse of ⌥Tab, at every part") {
        let (h, _, b, _, _, _) = try row()
        h.editor.selection = b
        var forward: [String] = []
        for _ in 0..<2 {
            h.key(Chord.optionTab)
            forward.append(h.editor.focusedPart?.title ?? "")
        }
        var back: [String] = []
        for _ in 0..<2 {
            h.key(Chord.optionBackTab)
            back.append(h.editor.focusedPart?.title ?? "")
        }
        expectEqual(back, [forward[0], forward[1]], "back round to where it began")
        h.key(Chord.optionTab)
        let at = h.editor.focusedPart?.id
        h.key(Chord.optionTab)
        h.key(Chord.optionBackTab)
        expectEqual(h.editor.focusedPart?.id, at)
    },
])
