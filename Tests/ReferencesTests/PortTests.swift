import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import DetailPanel
import Geometry
import Publishing
import References
import Selection
import TestKit
import Titles
import Topology

// Ports at a pill: its dots and what may end on it are those of what it stands for (boxes take beams,
// tiles take rails), on its own left and right; an arrow attached to it that what it stands for no
// longer takes stays as drawn, with a warning where a count would be and a line in the panel. Fixtures
// only: the shipped reference over CanvasTesting's boxes and tiles, and Connections' arrows.

enum Beam {}
extension Beam: Channel {
    static let id: ChannelID = "beam"
}

enum Rail {}
extension Rail: Channel {
    static let id: ChannelID = "rail"
}

/// Boxes take beams and tiles rails.
let channelsPlugin = Contributor(id: "pill-channels") { registrar in
    registrar.channel(Beam.self)
    registrar.channel(Rail.self)
    registrar.ports(Box.self, on: Beam.self)
    registrar.ports(Tile.self, on: Rail.self)
}

@MainActor private func portHarness() throws -> EditorHarness {
    try referenceHarness([ArrowsPlugin(), ArrowPortsPlugin(), channelsPlugin])
}

private let aMiddle = CGPoint(x: 175, y: 150)
private let aRight = CGPoint(x: boxFrame.maxX + 12, y: boxFrame.midY)

@MainActor private func frame(of id: ShapeID, in h: EditorHarness) throws -> CGRect {
    try require(h.editor.shapeContext.geometry(of: id)?.bounds)
}

extension EditorHarness {
    /// Drags from the box at `boxFrame`'s right dot to `point`, as a person does, and releases.
    func drawArrow(to point: CGPoint) {
        move(to: aMiddle)
        move(to: aRight)
        press()
        drag(to: point, speed: 3)
        release()
    }

    var arrows: [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

    /// Re-points the pill at `target`, as picking does.
    func repoint(_ pill: ShapeID, to target: ShapeID, label: String) {
        editor.transact { $0.update(pill, as: Reference.self) { ReferenceEdits.pick(&$0.props, ReferenceTarget(id: target, label: label)) } }
    }
}

/// How many pixels in `rect` are the warning's orange: red, some green, no blue.
@MainActor private func orange(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let p = pixel(rep, at: CGPoint(x: x, y: y))
            if p[0] > 200 && p[1] > 90 && p[1] < 190 && p[2] < 90 { count += 1 }
        }
    }
    return count
}

@MainActor private func glyphRect(_ pill: CGRect) -> CGRect {
    CGRect(x: pill.maxX - 25, y: pill.midY - 6, width: 11, height: 12)
}

@MainActor let portTests = Suite("Ports at a pill", [
    test("an arrow drawn from a box's port ends on a pill standing for a box, and not on one standing for a tile") {
        let h = try portHarness()
        let a = h.addBox("A")
        let order = h.addBox("Order", at: CGRect(x: 100, y: 500, width: 150, height: 100))
        let tile = h.addTile("Tile", at: CGRect(x: 700, y: 500, width: 120, height: 80))
        let forBox = h.addReference(to: order, label: "Order", at: CGPoint(x: 400, y: 300))
        let forTile = h.addReference(to: tile, label: "Tile", at: CGPoint(x: 400, y: 400))
        h.drawArrow(to: try frame(of: forTile, in: h).center)
        expect(h.arrows.isEmpty, "a tile doesn't take beams")
        h.drawArrow(to: try frame(of: forBox, in: h).center)
        let arrow = try require(h.arrows.first)
        expectEqual(h.arrows.count, 1)
        expectEqual(arrow.props.start.binding?.shapeID, a)
        expectEqual(arrow.props.end.binding?.shapeID, forBox)
        expectEqual(arrow[ChannelProperty.self], Beam.id)
        let resolved = try require(h.editor.topology?.edges(of: order, .incoming, types: .within(ArrowEdge.id)).first)
        expectEqual(resolved.source, a, "into the pill, it reads as into the box")
        expectEqual(resolved.literalTarget, forBox)
    },
    test("a pill standing for nothing has no dots and nothing ends on it: empty, missing, private") {
        let h = try portHarness()
        h.addBox("A")
        let order = h.addBox("Order", public: false, at: CGRect(x: 100, y: 500, width: 150, height: 100))
        let empty = h.addEmptyReference(at: CGPoint(x: 400, y: 300))
        let missing = h.addReference(to: ShapeID(), label: "Old", at: CGPoint(x: 400, y: 400))
        let hidden = h.addReference(to: order, label: "Order", at: CGPoint(x: 400, y: 500))
        for pill in [empty, missing, hidden] {
            let rect = try frame(of: pill, in: h)
            h.move(to: rect.center)
            h.move(to: CGPoint(x: rect.maxX + 12, y: rect.midY))
            expectEqual(h.editor.hoveredButton, nil, "no dot at \(rect.midY)")
            h.drawArrow(to: rect.center)
            expect(h.arrows.isEmpty, "nothing ends at \(rect.midY)")
        }
    },
    test("a pill's dots are its own left and right, and begin arrows on what it stands for: they follow being re-pointed") {
        let h = try portHarness()
        let order = h.addBox("Order", at: CGRect(x: 100, y: 500, width: 150, height: 100))
        let tile = h.addTile("Tile", at: CGRect(x: 100, y: 650, width: 120, height: 80))
        let pill = h.addReference(to: order, label: "Order", at: CGPoint(x: 400, y: 300))
        let box = h.addBox("B", at: CGRect(x: 700, y: 280, width: 150, height: 100))
        let tile2 = h.addTile("Tile 2", at: CGRect(x: 700, y: 480, width: 120, height: 80))
        @MainActor func rightDot() throws -> CGPoint { let rect = try frame(of: pill, in: h); return CGPoint(x: rect.maxX + 12, y: rect.midY) }
        var rect = try frame(of: pill, in: h)
        h.move(to: rect.center)
        h.move(to: CGPoint(x: rect.midX, y: rect.minY - 12))
        expectEqual(h.editor.hoveredButton, nil, "none above")
        h.move(to: rect.center)
        h.move(to: CGPoint(x: rect.minX - 12, y: rect.midY))
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: pill, side: .left)))
        // Beams, for it stands for a box: they end on a box, not on a tile.
        h.move(to: rect.center)
        h.move(to: try rightDot())
        h.press()
        h.drag(to: try frame(of: tile2, in: h).center, speed: 3)
        h.release()
        expect(h.arrows.isEmpty, "a tile doesn't take beams")
        h.move(to: rect.center)
        h.move(to: try rightDot())
        h.press()
        h.drag(to: CGPoint(x: 775, y: 330), speed: 3)
        h.release()
        let beam = try require(h.arrows.first)
        expectEqual(beam.props.start.binding?.shapeID, pill)
        expectEqual(beam.props.end.binding?.shapeID, box)
        expectEqual(beam[ChannelProperty.self], Beam.id)
        h.editor.transact { $0.delete([beam.id]) }
        // Re-pointed at a tile, it has rails.
        h.repoint(pill, to: tile, label: "Tile")
        rect = try frame(of: pill, in: h)
        h.move(to: rect.center)
        h.move(to: try rightDot())
        h.press()
        h.drag(to: CGPoint(x: 775, y: 330), speed: 3)
        h.release()
        expect(h.arrows.isEmpty, "a box doesn't take rails")
        h.move(to: rect.center)
        h.move(to: try rightDot())
        h.press()
        h.drag(to: try frame(of: tile2, in: h).center, speed: 3)
        h.release()
        let rail = try require(h.arrows.first)
        expectEqual(rail.props.start.binding?.shapeID, pill)
        expectEqual(rail.props.end.binding?.shapeID, tile2)
        expectEqual(rail[ChannelProperty.self], Rail.id)
    },
    test("an arrow's end re-aimed onto a pill binds only to one standing for what takes its channel: not an empty, missing, private or non-taking pill") {
        let h = try portHarness()
        let a = h.addBox("A")
        let b = h.addBox("B", at: CGRect(x: 700, y: 100, width: 150, height: 100))
        let order = h.addBox("Order", at: CGRect(x: 100, y: 650, width: 150, height: 100))
        let secret = h.addBox("Secret", public: false, at: CGRect(x: 300, y: 650, width: 150, height: 100))
        let tile = h.addTile("Tile", at: CGRect(x: 500, y: 650, width: 120, height: 80))
        let pills: [(String, ShapeID, Bool)] = [
            ("taking", h.addReference(to: order, label: "Order", at: CGPoint(x: 400, y: 300)), true),
            ("empty", h.addEmptyReference(at: CGPoint(x: 400, y: 360)), false),
            ("missing", h.addReference(to: ShapeID(), label: "Old", at: CGPoint(x: 400, y: 420)), false),
            ("private", h.addReference(to: secret, label: "Secret", at: CGPoint(x: 400, y: 480)), false),
            ("non-taking", h.addReference(to: tile, label: "Tile", at: CGPoint(x: 400, y: 540)), false),
        ]
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        for (what, pill, takes) in pills {
            var record = ShapeRecord(Arrow(start: bound(a), end: bound(b)))
            record[ChannelProperty.self] = Beam.id
            h.editor.transact { $0.insert(record) }
            h.editor.selection = record.id
            let rect = try frame(of: pill, in: h)
            h.move(to: CGPoint(x: 775, y: 150))
            h.press()
            h.drag(to: rect.center, speed: 3)
            expectEqual(h.editor.hintedShapeID, takes ? pill : nil, what)
            h.release()
            let end = h.editor.document[record.id]?.typed(as: Arrow.self)?.props.end
            expectEqual(end?.binding?.shapeID, takes ? pill : nil, what)
            if !takes { expectEqual(end, .free(rect.center), what) }
            h.editor.transact { $0.delete([record.id]) }
        }
    },
    test("an arrow the pill stands for no longer takes stays as drawn, with a warning glyph and a line in the panel; re-pointed back, it clears") {
        let h = try portHarness()
        let a = h.addBox("A")
        _ = a
        let order = h.addBox("Order", at: CGRect(x: 100, y: 500, width: 150, height: 100))
        let tile = h.addTile("Order", at: CGRect(x: 700, y: 500, width: 120, height: 80))
        let pill = h.addReference(to: order, label: "Order", at: CGPoint(x: 400, y: 300))
        let rect = try frame(of: pill, in: h)
        let before = render(h.editor, size: CGSize(width: 1000, height: 800))
        expectEqual(orange(before, in: glyphRect(rect)), 0)
        h.drawArrow(to: rect.center)
        let arrow = try require(h.arrows.first?.id)
        let state = try require(h.editor.references)
        expectEqual(state.channelMismatch(of: pill), nil)
        let record = try require(h.editor.document[pill])
        expectEqual(try require(h.editor.detailPanel).statuses(for: record), [])
        // Re-pointed at a tile (called "Order" too): it doesn't take beams.
        h.repoint(pill, to: tile, label: "Order")
        expectEqual(state.channelMismatch(of: pill), ChannelMismatch(channel: Beam.id, target: tile))
        expectEqual(state.mismatchLine(of: pill), "“Order” doesn’t take beams.")
        let after = render(h.editor, size: CGSize(width: 1000, height: 800))
        expect(orange(after, in: glyphRect(try frame(of: pill, in: h))) > 8, "the warning triangle trails the pill")
        expectEqual(try require(h.editor.detailPanel).statuses(for: try require(h.editor.document[pill])),
                    [DetailStatus("“Order” doesn’t take beams.", tone: .warning)])
        expectEqual(h.editor.document[arrow]?.typed(as: Arrow.self)?.props.end.binding?.shapeID, pill, "the arrow isn't let go")
        expectEqual(h.editor.document[arrow]?[ChannelProperty.self], Beam.id, "and keeps its channel")
        // And back.
        h.repoint(pill, to: order, label: "Order")
        expectEqual(state.channelMismatch(of: pill), nil)
        expectEqual(orange(render(h.editor, size: CGSize(width: 1000, height: 800)), in: glyphRect(try frame(of: pill, in: h))), 0)
        h.editor.undo()
        expect(state.channelMismatch(of: pill) != nil, "undo brings it back")
        // The arrow deleted: nothing is attached.
        h.editor.transact { $0.delete([arrow]) }
        expectEqual(state.channelMismatch(of: pill), nil)
        expectEqual(try require(h.editor.detailPanel).statuses(for: try require(h.editor.document[pill])), [])
    },
    test("an arrow that starts at the pill is judged as a source; one on no channel, or a pill standing for nothing, never warns") {
        let h = try portHarness()
        let order = h.addBox("Order", at: CGRect(x: 100, y: 500, width: 150, height: 100))
        let tile = h.addTile("Tile", at: CGRect(x: 700, y: 500, width: 120, height: 80))
        let pill = h.addReference(to: order, label: "Order", at: CGPoint(x: 400, y: 300))
        let state = try require(h.editor.references)
        let rect = try frame(of: pill, in: h)
        let other = h.addBox("Other", at: CGRect(x: 800, y: 100, width: 100, height: 100))
        h.move(to: rect.center)
        h.move(to: CGPoint(x: rect.maxX + 12, y: rect.midY))
        h.press()
        h.drag(to: CGPoint(x: 850, y: 150), speed: 3)
        h.release()
        let outgoing = try require(h.arrows.first)
        expectEqual(outgoing.props.start.binding?.shapeID, pill)
        expectEqual(outgoing.props.end.binding?.shapeID, other)
        expectEqual(state.channelMismatch(of: pill), nil)
        h.repoint(pill, to: tile, label: "Tile")
        expectEqual(state.channelMismatch(of: pill), ChannelMismatch(channel: Beam.id, target: tile))
        expectEqual(state.mismatchLine(of: pill), "“Tile” doesn’t take beams.")
        // Standing for nothing says so already.
        h.editor.transact { $0.delete([tile]) }
        expectEqual(state.channelMismatch(of: pill), nil)
        // An arrow on no channel has none to mismatch.
        h.editor.transact { $0.delete([outgoing.id]) }
        let plain = h.editor.add(Arrow(start: .bound(ArrowBinding(shapeID: other, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                       end: .bound(ArrowBinding(shapeID: pill, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))))
        _ = plain
        h.repoint(pill, to: tile, label: "Tile")
        expectEqual(state.channelMismatch(of: pill), nil)
    },
])
