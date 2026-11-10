@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// The core's part basics over CanvasTesting's rosters: a part's id written as a UUID string and kept by a copy, a part
// addressed with its shape, a kind's parts read from its record (`PartedShape`, through the registry) and where each is
// kept in its geometry (`ShapeGeometry.parts`), a folded part where the last shown one is; a part lit as the hint's, and a
// part's name read with its shape's.

private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

@MainActor let partTests = Suite("Parts", [
    test("a part's id is written as its UUID string, read back as it was, and schema'd as the core's part-id") {
        let id = PartID(uuid(7))
        let data = try JSONEncoder().encode(id)
        expectEqual(String(decoding: data, as: UTF8.self), "\"00000000-0000-0000-0000-000000000007\"")
        expectEqual(try JSONDecoder().decode(PartID.self, from: data), id)
        expectEqual(id.rawValue, uuid(7))
        expectEqual(id.description, uuid(7).uuidString)
        var definitions = SchemaDefinitions()
        expectEqual(PartID.schema(in: &definitions), ["$ref": "#/$defs/core.part-id"])
    },
    test("an address is a shape and maybe a part; the shape alone is its whole") {
        let shape = ShapeID(uuid(1)), part = PartID(uuid(2))
        expectEqual(PartAddress(shape).part, nil)
        expect(PartAddress(shape) != PartAddress(shape, part: part))
        expectEqual(PartAddress(shape, part: part).description, "\(uuid(1).uuidString)/\(uuid(2).uuidString)")
        let read = try JSONDecoder().decode(PartAddress.self, from: try JSONEncoder().encode(PartAddress(shape, part: part)))
        expectEqual(read, PartAddress(shape, part: part))
    },
    test("a parted kind says its parts from its record, through the registry; another kind has none") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), RostersPlugin()])
        let alice = RosterRow(id: PartID(uuid(11)), name: "alice"), bob = RosterRow(id: PartID(uuid(12)), name: "bob")
        let roster = h.editor.add(Roster(CGRect(x: 0, y: 0, width: 100, height: 60), rows: [alice, bob]))
        let box = h.editor.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        let registry = h.editor.registry
        expectEqual(registry.partedKinds, [Roster.kind])
        expectEqual(try require(h.editor.document[roster]).kind, Roster.kind)
        expectEqual(registry.parts(of: try require(h.editor.document[roster])),
                    [PartName(id: alice.id, name: "alice", kindWord: "Member", lead: .symbol("crown")),
                     PartName(id: bob.id, name: "bob", kindWord: "Member")])
        expectEqual(registry.parts(of: try require(h.editor.document[box])), nil, "a box has no parts")
    },
    test("where each part is kept in its geometry, worked out again as the shape moves or a row folds away; a folded part is where the last shown one is") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), RostersPlugin()])
        let rows = (1...3).map { RosterRow(id: PartID(uuid($0)), name: "r\($0)") }
        let roster = h.editor.add(Roster(CGRect(x: 0, y: 0, width: 100, height: 70), rows: rows))
        let parts = try require(h.editor.shapeContext.geometry(of: roster)?.parts)
        expectEqual(parts.map(\.id), rows.map(\.id))
        expectEqual(parts.frame(rows[1].id), PartFrame(id: rows[1].id, rect: CGRect(x: 0, y: 30, width: 100, height: 20)))
        expectEqual(parts.frame(PartID(uuid(99))), nil, "a part the geometry doesn't list is gone")
        expectEqual(parts.frame(nearestY: 33)?.id, rows[1].id)
        expectEqual(parts.frame(nearestY: -40)?.id, rows[0].id, "above the shape: the first")
        h.editor.transact("Move") { $0.update(roster, as: Roster.self) { $0.props.frame.origin = CGPoint(x: 50, y: 100) } }
        expectEqual(h.editor.shapeContext.geometry(of: roster)?.parts.frame(rows[0].id)?.rect, CGRect(x: 50, y: 110, width: 100, height: 20))
        h.editor.transact("Fold") { $0.update(roster, as: Roster.self) { $0.props.folded = 2 } }
        let folded = try require(h.editor.shapeContext.geometry(of: roster)?.parts)
        expectEqual(folded.map(\.isShown), [true, false, false])
        expectEqual(folded.frame(rows[2].id)?.rect, folded.frame(rows[0].id)?.rect, "folded away: shown where the last row shown is")
        expectEqual(folded.frame(nearestY: 170)?.id, rows[0].id, "a part folded away is never the nearest")
    },
    test("a part of the hinted shape is lit, drawn where its row is and nowhere else, and goes when the hint does") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), RostersPlugin()])
        let rows = (1...3).map { RosterRow(id: PartID(uuid($0)), name: "r\($0)") }
        let roster = h.editor.add(Roster(CGRect(x: 100, y: 100, width: 200, height: 70), rows: rows))
        let size = CGSize(width: 400, height: 300)
        h.editor.hintedPart = rows[1].id
        expectEqual(h.editor.hintedPart, nil, "no part without a hinted shape")
        h.editor.hintedShapeID = roster
        let hinted = renderBitmap(h.editor, size: size)
        h.editor.hintedPart = rows[1].id
        expectEqual(h.editor.hintedPart, rows[1].id)
        let lit = renderBitmap(h.editor, size: size)
        expect(changedPixels(hinted, lit, in: CGRect(x: 110, y: 131, width: 180, height: 18)) > 0, "the row is lit")
        expectEqual(changedPixels(hinted, lit, in: CGRect(x: 110, y: 111, width: 180, height: 16)), 0, "the row above isn't")
        expectEqual(changedPixels(hinted, lit, in: CGRect(x: 110, y: 153, width: 180, height: 14)), 0, "nor the one below")
        h.editor.hintedShapeID = nil
        expectEqual(h.editor.hintedPart, nil, "the hint's part goes with the hint")
        h.editor.hintedShapeID = roster
        expectEqual(h.editor.hintedPart, nil, "and doesn't come back with it")
    },
    test("a part's name is read with its shape's; the shape alone is its own; a part it doesn't have is none") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), RostersPlugin()])
        let row = RosterRow(id: PartID(uuid(3)), name: "carol")
        let roster = h.editor.add(Roster(CGRect(x: 0, y: 0, width: 100, height: 40), rows: [row]))
        expectEqual(h.editor.accessibleName(of: PartAddress(roster, part: row.id)), "carol in roster")
        expectEqual(h.editor.accessibleName(of: PartAddress(roster)), "roster")
        expectEqual(h.editor.accessibleName(of: PartAddress(roster, part: PartID(uuid(4)))), nil)
        expectEqual(h.editor.accessibleName(of: PartAddress(ShapeID())), nil)
        expectEqual(h.editor.registry.removing([row.id], from: try require(h.editor.document[roster])), nil,
                    "a kind that doesn't take its parts out by id: nothing")
    },
    test("a shape's parts' ids are in its props as coded, which is what a copy is made of (the copy itself, with the clipboard, is CompositionTests' engineering suite)") {
        let row = RosterRow(id: PartID(uuid(5)), name: "only")
        let record = AnyShapeRecord(ShapeRecord(Roster(CGRect(x: 0, y: 0, width: 50, height: 30), rows: [row])))
        let data = try JSONEncoder().encode(try require(record.typed(as: Roster.self)?.props))
        expectEqual(try JSONDecoder().decode(Roster.self, from: data).rows, [row])
    },
])
