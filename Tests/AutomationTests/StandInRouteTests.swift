import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import DrawScript
import TestKit
import Topology

// The making half of `StandInRoute`: which kind stands for a shape, which pill an arrow reuses, and
// where a new one goes. The app's writer asks the route for the same pill in the same place a
// `canvas draw` run puts it, so these hold the route's landing against the rect a run gives the
// same pill, over the Shoal and its relays (DrawStandInTests).

/// A box that stands for a shape, or for one row of it (an endpoint): its record names the shape and, for a row, the row.
private struct Mark: BoxShapeProps {
    static let kind: ShapeKind = "mark"
    static let properties = Properties<Mark> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
        Property("row", \.row)
    }
    var frame: CGRect
    var stands: Citation?
    var row: PartID?
    init(_ frame: CGRect = .zero, stands: ShapeID? = nil, row: PartID? = nil) {
        self.frame = frame
        self.stands = stands.map(Citation.init)
        self.row = row
    }
    init() { self.init(.zero) }
}

private struct MarkDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Mark>, in context: RenderContext) {}
}

private let marksPlugin = Contributor(id: "marks") { registrar in
    registrar.shape(MarkDefinition()) { mark in
        mark.standsIn { shape, _ in
            guard let stands = shape.props.stands?.shape else { return nil }
            return shape.props.row.map { .row(stands, $0) } ?? .shapes([stands])
        }
    }
}

/// The route over an editor's registry.
@MainActor private func routeOf(_ editor: CanvasEditor) throws -> StandInRoute {
    try require(StandInRoute(editor.registry))
}

/// The id of the tile called `label` on the board.
@MainActor private func tileID(_ label: String, on board: BoardID = .root, in editor: CanvasEditor) throws -> ShapeID {
    try require(editor.contents(of: board).shapes.first { $0.typed(as: Tile.self)?.props.label == label }).id
}

/// Where the route lands a relay for `far` (called `label`) beside `near` on the root, for an edge
/// whose near end is `place`, on `side` if the edge names one.
@MainActor private func routed(_ label: String, beside near: String, _ place: EdgePlace, side: EdgeSide? = nil, avoiding: [CGRect] = [],
                               in editor: CanvasEditor, shoal: Shoal) throws -> CGRect {
    let route = try routeOf(editor)
    let far = try tileID(label, on: BoardID(owner: shoal.p), in: editor)
    let pill = try require(editor.registry.standIns.make(Relay.kind, standingFor: far, label: label))
    let size = try require(pill.box?.size)
    let reading = try require(editor.reading(of: .root))
    let spot = route.spot(beside: try tileID(near, in: editor), edgeIs: place, side: side, in: reading)
    let surroundings = try require(Surroundings(on: .root, moving: size, in: editor))
    return try require(route.landing(of: size, at: spot, in: surroundings, avoiding: avoiding)).rect
}

/// An editor on the shoal whose arrows have an identity key, `bond`: two ties of one pair are two edges.
@MainActor private func bondShoal() throws -> CanvasEditor {
    let editor = try makeEditor([namesPlugin(), tieEdgesPlugin(), TopologyPlugin(), PocketsPlugin(), namedPockets, relaysPlugin()])
    editor.replaceFile(with: Shoal().file)
    return editor
}

@MainActor let standInRouteTests = Suite("stand-in route: making", [
    test("a landing is the rect a canvas draw run gives the same pill: the first beside a start, and beside an end") {
        let shoal = Shoal(), editor = try shoal.editor()
        let right = try routed("Deep", beside: "Hub", .from, in: editor, shoal: shoal)
        let left = try routed("Pier", beside: "Hub", .to, in: editor, shoal: shoal)
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Pier" -> "Hub"
            """, on: editor)
        let frames = editor.relayFrames()
        expectEqual(right, frames["Deep"], "right of a start")
        expectEqual(left, frames["Pier"], "left of an end")
        expectEqual(right, CGRect(x: 600, y: 170, width: 56, height: 40), "a gap away, centered on Hub")
    },
    test("the next in its column is the rect a run gives it, 16 past the last and lined up with it, on each side") {
        let shoal = Shoal(), editor = try shoal.editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            edge "Lagoon" -> "Hub"
            """, on: editor)
        // Right of Hub: below Pier's, left edges in line; on its left: below Lagoon's, right edges in line.
        let right = try routed("Reef", beside: "Hub", .from, in: editor, shoal: shoal)
        let left = try routed("Kelp", beside: "Hub", .to, in: editor, shoal: shoal)
        _ = try drawn("""
            edge "Hub" -> "Reef"
            edge "Kelp" -> "Hub"
            """, on: editor)
        let frames = editor.relayFrames()
        expectEqual(right, frames["Reef"], "next in the column on the right")
        expectEqual(left, frames["Kelp"], "next in the column on the left")
        expectEqual(right.minX, frames["Deep"]?.minX, "lined up with the column")
        expectEqual(right.minY, (frames["Pier"]?.maxY ?? 0) + 16, "16 past its end")
    },
    test("a named side: below, above, left and right of the shape, joined to the column there") {
        let shoal = Shoal(), editor = try shoal.editor()
        for (side, word) in [(EdgeSide.bottom, "bottom"), (.top, "top"), (.left, "left"), (.right, "right")] {
            let first = try routed("Deep", beside: "Hub", .from, side: side, in: editor, shoal: shoal)
            _ = try drawn(#"edge "Hub" -> "Deep" from: \#(word)"#, on: editor)
            expectEqual(first, editor.relayFrames()["Deep"], "the first \(word)")
            let next = try routed("Pier", beside: "Hub", .from, side: side, in: editor, shoal: shoal)
            _ = try drawn(#"edge "Hub" -> "Pier" from: \#(word)"#, on: editor)
            expectEqual(next, editor.relayFrames()["Pier"], "the next \(word)")
            editor.undo()
            editor.undo()
        }
    },
    test("pushed clear of what is in the way, as a run pushes it") {
        let shoal = Shoal(), editor = try shoal.editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            """, on: editor)
        tile("W", CGRect(x: 590, y: 260, width: 80, height: 20), in: editor)
        let rect = try routed("Reef", beside: "Hub", .from, in: editor, shoal: shoal)
        _ = try drawn(#"edge "Hub" -> "Reef""#, on: editor)
        expectEqual(rect, editor.relayFrames()["Reef"])
        expectEqual(rect, CGRect(x: 600, y: 344, width: 56, height: 40), "down past W, still in line")
    },
    test("a shape the caller moves leaves its column behind, and a pill it moves is no end of the column") {
        let shoal = Shoal(), editor = try shoal.editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            """, on: editor)
        let route = try routeOf(editor)
        let reading = try require(editor.reading(of: .root))
        let hub = try tileID("Hub", in: editor)
        let joined = route.spot(beside: hub, edgeIs: .from, side: nil, in: reading)
        expect(joined.after != nil, "the column is there")
        expectEqual(joined.step, 16)
        expectEqual(joined.level, .left)
        let moved = route.spot(beside: hub, edgeIs: .from, side: nil, in: reading, staying: { $0 != hub })
        expectEqual(moved, StandInSpot(near: hub, direction: .right, after: nil, step: 80, level: nil), "beside the shape, a gap away")
        let end = try require(joined.after)
        expectEqual(route.spot(beside: hub, edgeIs: .from, side: nil, in: reading, staying: { $0 != end }).after, nil, "nor past one that moves")
        // Pills a run deletes are not in the column.
        let relays = editor.relays().map(\.id)
        expectEqual(route.spot(beside: hub, edgeIs: .from, side: nil, in: reading, excluding: Set(relays)).after, nil)
        expectEqual(route.spot(beside: hub, edgeIs: .to, side: nil, in: reading), StandInSpot(near: hub, direction: .left, after: nil, step: 80, level: nil))
    },
    test("avoiding: a box planned and not yet put down is in the way, as a shape of the board is") {
        let shoal = Shoal(), editor = try shoal.editor()
        let planned = CGRect(x: 590, y: 160, width: 60, height: 60)
        let avoided = try routed("Deep", beside: "Hub", .from, avoiding: [planned], in: editor, shoal: shoal)
        let clear = try routed("Deep", beside: "Hub", .from, in: editor, shoal: shoal)
        expect(avoided != clear, "moved")
        expect(!avoided.intersects(planned), "clear of it: \(avoided)")
        tile("Planned", planned, in: editor)
        expectEqual(try routed("Deep", beside: "Hub", .from, in: editor, shoal: shoal), avoided, "as a shape there pushes it")
        // Beside a box not on the board: where a shape of that size there would land one.
        let surroundings = try require(Surroundings(on: .root, moving: CGSize(width: 56, height: 40), in: editor))
        let box = CGRect(x: 100, y: 300, width: 120, height: 80)
        let beside = try require(surroundings.near(box))
        expectEqual(beside.rect, CGRect(x: 300, y: 320, width: 56, height: 40), "a gap right of it, centered")
        let around = try require(surroundings.near(box, avoiding: [CGRect(x: 280, y: 300, width: 100, height: 80)]))
        expect(around.rect != beside.rect && !around.rect.intersects(CGRect(x: 280, y: 300, width: 100, height: 80)), "\(around.rect)")
        expectEqual(beside.board, .root)
    },
    test("kind(for:fulfilling:): the first kind that admits the shape; with fulfilling, the first that can be made to") {
        let shoal = Shoal()
        let editor = try shoal.editor(relays: relaysPlugin(fulfils: true))
        let route = try routeOf(editor)
        let open = try require(editor.file.record(try tileID("Deep", on: BoardID(owner: shoal.p), in: editor)))
        let closed = try require(editor.file.record(try tileID("Hub", in: editor)))
        expectEqual(route.kind(for: open, fulfilling: false)?.kind, Relay.kind)
        expectEqual(route.kind(for: open, fulfilling: false)?.fulfils, false)
        expectEqual(route.kind(for: open, fulfilling: true)?.fulfils, false, "admitted already: nothing to do")
        expect(route.kind(for: closed, fulfilling: false) == nil, "a script never changes the shape")
        expectEqual(route.kind(for: closed, fulfilling: true)?.kind, Relay.kind)
        expectEqual(route.kind(for: closed, fulfilling: true)?.fulfils, true)
        expectEqual(closed.meta[Open.self], nil, "asking changes nothing")
        // A kind that says nothing of how a shape is made one it may stand for takes only open shapes.
        let plain = try routeOf(try shoal.editor())
        expect(plain.kind(for: closed, fulfilling: true) == nil)
        expectEqual(plain.kind(for: open, fulfilling: true)?.fulfils, false)
    },
    test("existing: none for never; any pill of the kind for the shape beside the shape for any; the one a host's arrow runs into for host") {
        let shoal = Shoal(), editor = try shoal.editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Rock" -> "Deep"
            """, on: editor)
        let route = try routeOf(editor)
        let document = editor.document
        let hub = try tileID("Hub", in: editor), rock = try tileID("Rock", in: editor)
        let deep = try tileID("Deep", on: BoardID(owner: shoal.p), in: editor), pier = try tileID("Pier", on: BoardID(owner: shoal.p), in: editor)
        let relays = editor.relays().sorted { $0.frame.minY < $1.frame.minY }.map(\.id)
        expectEqual(relays.count, 2)
        let byHub = try require(route.pills(in: document)[deep]?.first)
        expect(relays.contains(byHub))
        expect(route.existing(for: deep, kind: Relay.kind, sharing: .never, near: hub, in: document) == nil)
        expectEqual(route.existing(for: deep, kind: Relay.kind, sharing: .any, near: hub, in: document), byHub, "the first in document order")
        let hubs = route.existing(for: deep, kind: Relay.kind, sharing: .host(hub), near: hub, in: document)
        let rocks = route.existing(for: deep, kind: Relay.kind, sharing: .host(rock), near: rock, in: document)
        expect(hubs != nil && rocks != nil && hubs != rocks, "each host's own")
        expectEqual(hubs, byHub)
        expect(route.existing(for: pier, kind: Relay.kind, sharing: .host(hub), near: hub, in: document) == nil, "none stands for Pier")
        expect(route.existing(for: deep, kind: Tile.kind, sharing: .any, near: hub, in: document) == nil, "of another kind")
        tile("Dock", CGRect(x: 100, y: 300, width: 120, height: 80), in: editor)
        expect(route.existing(for: deep, kind: Relay.kind, sharing: .host(try tileID("Dock", in: editor)), near: hub, in: editor.document) == nil, "Dock has no arrow")
        expect(route.existing(for: deep, kind: Relay.kind, sharing: .host(hub), near: hub, in: document, excluding: [try require(hubs)]) == nil, "not one being deleted")
        // The same asked of an index made once.
        let index = route.index(of: document)
        expectEqual(route.existing(for: deep, kind: Relay.kind, sharing: .host(rock), near: rock, in: document, index: index), rocks)
    },
    test("existing matches on the shape and its row: a pill for a whole shape is never a row's, and a row's is never the shape's, for any and for host") {
        let shoal = Shoal(), editor = try shoal.editor([marksPlugin])
        let route = try routeOf(editor)
        let hub = try tileID("Hub", in: editor), deep = try tileID("Deep", on: BoardID(owner: shoal.p), in: editor)
        let row = PartID(), other = PartID()
        let whole = ShapeID(), forRow = ShapeID()
        editor.transact("Pills") { tx in
            tx.insert(AnyShapeRecord(ShapeRecord(id: whole, Mark(CGRect(x: 600, y: 100, width: 60, height: 30), stands: deep))))
            tx.insert(AnyShapeRecord(ShapeRecord(id: forRow, Mark(CGRect(x: 600, y: 200, width: 60, height: 30), stands: deep, row: row))))
        }
        editor.addLink(hub, whole)
        editor.addLink(hub, forRow)
        let document = editor.document
        expectEqual(route.existing(for: deep, kind: Mark.kind, sharing: .any, near: hub, in: document), whole, "no row asked: the shape's own pill")
        expectEqual(route.existing(for: deep, row: row, kind: Mark.kind, sharing: .any, near: hub, in: document), forRow, "the row asked: its pill")
        expect(route.existing(for: deep, row: other, kind: Mark.kind, sharing: .any, near: hub, in: document) == nil, "another row has none")
        expectEqual(route.existing(for: deep, kind: Mark.kind, sharing: .host(hub), near: hub, in: document), whole)
        expectEqual(route.existing(for: deep, row: row, kind: Mark.kind, sharing: .host(hub), near: hub, in: document), forRow)
        expect(route.existing(for: deep, row: other, kind: Mark.kind, sharing: .host(hub), near: hub, in: document) == nil)
        expectEqual(route.row(of: forRow, in: document), row)
        expectEqual(route.row(of: whole, in: document), nil)
        let withoutWhole = route.existing(for: deep, kind: Mark.kind, sharing: .any, near: hub, in: document, excluding: [whole])
        expect(withoutWhole == nil, "the row's pill is not the shape's, even with the shape's gone")
    },
    test("a second typed edge from a shape to the same far shape goes into the pill the first one does: two arrows into one pill") {
        let editor = try bondShoal()
        let first = try drawn(#"edge "Hub" -> "Deep" bond: "x""#, on: editor)
        expectEqual(rows(first).map { $0["did"] }, ["created", "connected"], "the first makes the pill")
        let relay = try require(editor.relays().first)
        let second = try drawn(#"edge "Hub" -> "Deep" bond: "y""#, on: editor)
        expectEqual(rows(second).map { $0["did"] }, ["connected"], "no pill of its own")
        expectEqual(rows(second).last?["via"], "relay")
        expectEqual(rows(second).last?["shared"], true, "it says the pill was there")
        expectEqual(editor.relays().map(\.id), [relay.id], "one pill")
        expectEqual(editor.linkEnds().count, 2)
        expectEqual(Set(editor.linkEnds().compactMap { $0.to }), [relay.id], "both arrows run into it")
        let made = editor.file, revision = editor.revision
        // A run again finds both.
        let again = try drawn("""
            edge "Hub" -> "Deep" bond: "x"
            edge "Hub" -> "Deep" bond: "y"
            """, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(editor.file, made)
        expectEqual(editor.revision, revision)
    },
    test("two typed edges of one pair in one script share the pill the first makes, and so does the other way round; a third far shape and another near shape get their own") {
        let editor = try bondShoal()
        let result = try drawn("""
            edge "Hub" -> "Deep" bond: "x"
            edge "Hub" -> "Deep" bond: "y"
            edge "Hub" -> "Pier" bond: "x"
            edge "Rock" -> "Deep" bond: "x"
            """, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected", "connected", "created", "connected", "created", "connected"])
        expectEqual(editor.relays().count, 3, "Hub's for Deep, Hub's for Pier, Rock's for Deep")
        expectEqual(editor.linkEnds().count, 4)
        let hubDeep = editor.linkNames().filter { $0 == "Hub -> relay Deep" }
        expectEqual(hubDeep.count, 2)
        // The far shape the start: Hub's arrows out of a pill for Deep and into one for Deep are the
        // same pill, a column's.
        let before = editor.relays().count
        _ = try drawn(#"edge "Deep" -> "Hub" bond: "z""#, on: editor)
        expectEqual(editor.relays().count, before, "Hub already has an arrow to a pill for Deep")
        expectEqual(editor.linkEnds().count, 5)
    },
    test("a statement that writes no identity key reaches none of it: an edge through a pill makes a pill of its own as it did") {
        let editor = try bondShoal()
        _ = try drawn(#"edge "Hub" -> "Deep" bond: "x""#, on: editor)
        // share: names which arrows; without it and without a bond, another statement over the pair
        // is the edge already drawn.
        let again = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
        expectEqual(editor.relays().count, 1)
        // A different near shape without a bond: its own pill, as before.
        let rock = try drawn(#"edge "Rock" -> "Deep""#, on: editor)
        expectEqual(rows(rock).map { $0["did"] }, ["created", "connected"])
        expectEqual(editor.relays().count, 2)
    },
    test("emptied: deleting a pill's only arrow empties it, and an arrow that stays holds it") {
        let shoal = Shoal(), editor = try shoal.editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let relay = try require(editor.relays().first)
        let arrow = try require(editor.document.shapes.first { $0.kind == Link.kind })
        let route = try routeOf(editor)
        expectEqual(route.emptied(by: [arrow.id], in: editor.document), [relay.id], "deleting its only arrow empties the pill")
        expectEqual(route.emptied(by: [], in: editor.document), [], "an arrow that stays holds it")
        expectEqual(route.emptied(by: [ShapeID()], in: editor.document), [], "and so does a delete of something else")
    },
])
