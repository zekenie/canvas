@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Publishing
import References
import TestKit
import Topology

// A direct reference stands for the shape it names, in Topology (`standsIn`, admitted while the shape
// is public): a link into the pill is a link into the shape for everything that reads the graph,
// and holds the shape public while it stands for it. Fixtures only: boxes, and links whose wire is
// an edge.

/// A box B ("stickies") linked into a reference to a public box A ("shapes").
@MainActor private struct Wired {
    let h: EditorHarness
    let a: ShapeID, b: ShapeID, reference: ShapeID, link: ShapeID

    init(_ more: [any CanvasPlugin] = []) throws {
        h = try referenceHarness(more)
        a = h.addBox("shapes")
        b = h.addBox("stickies", at: CGRect(x: 100, y: 400, width: 150, height: 100))
        reference = h.addReference(to: a, label: "shapes")
        link = h.connect(b, reference)
    }
}

@MainActor let forwardingTests = Suite("What a direct reference stands for, in the graph", [
    test("a link into the pill reads as a link into the shape it names; as drawn, it's still into the pill") {
        let w = try Wired()
        expectEqual(w.h.editor.wired(from: w.b), [w.a], "resolved, what every reader sees")
        expectEqual(w.h.editor.wired(from: w.b, view: .literal), [w.reference], "literal, as it's drawn")
        expectEqual(w.h.editor.wired(from: w.b, view: .recorded), [w.a], "recorded: a direct reference's record names its shape")
        let topology = try require(w.h.editor.topology)
        expectEqual(topology.forwards(of: w.reference), [w.a])
        expectEqual(topology.standIns(for: w.a), [w.reference])
        expectEqual(topology.forwarding(of: w.reference), .record([w.a]))
        let wire = try require(topology.edges(of: w.a, .incoming, types: .only(WireEdge.id)).first)
        expectEqual(wire.literalTarget, w.reference, "it was forwarded through the pill")
        expectEqual(wire.carrier, w.link)
        expectEqual(topology.edges(of: w.reference, .outgoing, types: .only(StandingEdge.id)).map(\.target), [w.a],
                    "and the pill stands for the shape: a stands-for edge")
    },
    test("what it stands for goes with what the shape is: made private, the link falls back to the pill in that commit, and public again heals it") {
        let w = try Wired()
        w.h.editor.transact { $0.update(w.a) { $0[PublicProperty.self] = nil } }
        expectEqual(w.h.editor.wired(from: w.b), [w.reference], "a private shape isn't stood for")
        expectEqual(w.h.editor.topology?.forwards(of: w.reference), [])
        w.h.editor.makePublic([w.a])
        expectEqual(w.h.editor.wired(from: w.b), [w.a])
        w.h.editor.undo()
        expectEqual(w.h.editor.wired(from: w.b), [w.reference], "and an undo of that is private again")
    },
    test("a deleted shape leaves the link at the pill, an undo brings it back to the shape, and a deleted pill lets the link go") {
        let w = try Wired()
        w.h.editor.transact { $0.delete([w.a]) }
        expectEqual(w.h.editor.wired(from: w.b), [w.reference], "nothing dangles")
        expect(w.h.reference(w.reference)?.target?.id == w.a, "the reference still names it")
        w.h.editor.undo()
        expectEqual(w.h.editor.wired(from: w.b), [w.a])
        w.h.editor.transact { $0.delete([w.reference]) }
        expectEqual(w.h.editor.wired(from: w.b), [], "a link bound to what's gone joins nothing")
    },
    test("re-pointing the pill moves the link to the new shape in the same commit, and an undo moves it back") {
        let w = try Wired()
        let tile = w.h.addTile("Pricing")
        w.h.editor.transact { $0.update(w.reference, as: Reference.self) { ReferenceEdits.pick(&$0.props, ReferenceTarget(id: tile, label: "Pricing")) } }
        expectEqual(w.h.editor.wired(from: w.b), [tile])
        expectEqual(w.h.editor.topology?.standIns(for: w.a), [])
        w.h.editor.undo()
        expectEqual(w.h.editor.wired(from: w.b), [w.a])
    },
    test("a shape on a board the app can't show, a shape of another file's, and nothing at all: the pill stands for nothing and the link stays") {
        let nowhere = ShapeID()
        let hidden = ShapeRecord(Box(boxFrame))
        let file = CanvasFile(root: CanvasDocument(), children: [nowhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])])
        let h = try referenceHarness(file: file)
        let b = h.addBox("stickies", at: CGRect(x: 100, y: 400, width: 150, height: 100))
        for target in [hidden.id, ShapeID()] {
            let reference = h.addReference(to: target, label: "gone")
            h.connect(b, reference)
            expectEqual(h.editor.topology?.forwarding(of: reference), .record([]))
            expect(h.editor.wired(from: b).contains(reference), "the link stays at the pill")
        }
        let empty = h.addEmptyReference(at: CGPoint(x: 600, y: 300))
        expectEqual(h.editor.topology?.forwarding(of: empty), ForwardingState.none, "an empty pill stands for nothing at all")
    },
    test("a dynamic reference is asked for: pending until an answer comes, which no one gives yet; words stand for nothing") {
        let w = try Wired()
        let words = w.h.addReference(words: "blocked work", at: CGPoint(x: 600, y: 300))
        let query = w.h.addReference(words: "blocked work", query: "box", at: CGPoint(x: 600, y: 400))
        expectEqual(w.h.editor.topology?.forwarding(of: words), ForwardingState.none)
        expectEqual(w.h.editor.topology?.forwarding(of: query), ForwardingState.pending)
        w.h.connect(w.b, query)
        expect(w.h.editor.wired(from: w.b).contains(query), "an arrow into a pill nothing has answered for stays at the pill")
    },
    test("a pill is never stood for, and never stands for another pill: one hop") {
        let w = try Wired()
        let second = w.h.addReference(to: w.reference, label: "a pill", at: CGPoint(x: 600, y: 300))
        expectEqual(w.h.editor.topology?.forwards(of: second), [], "a stand-in is never stood for")
        expectEqual(w.h.editor.wired(from: w.b), [w.a])
    },
    test("what stands for the shape holds it public: making it private is refused, and nothing is written") {
        let w = try Wired()
        let publishing = try require(w.h.editor.publishing)
        expect(publishing.isHeld(w.a))
        expectEqual(w.h.editor.makePrivate([w.a]), [w.a], "refused while a pill stands for it")
        expect(w.h.editor.document[w.a]?[PublicProperty.self] == true, "nothing was written")
        expectEqual(publishing.standIns(for: w.a), [w.reference])
        let words = w.h.addReference(words: "stuff", at: CGPoint(x: 600, y: 300))
        // Words stand for nothing, so they hold nothing (a dynamic pill holds the shape once it is answered for).
        expectEqual(publishing.standIns(for: w.a), [w.reference])
        expectEqual(w.h.editor.topology?.forwards(of: words), [])
    },
    test("what a pill calls what it stands for is the label it keeps, which outlives the shape, or a dynamic pill's words; an empty one calls it nothing") {
        let w = try Wired()
        let standIns = w.h.editor.registry.standIns
        let words = w.h.addReference(words: "stuff", query: "note", at: CGPoint(x: 600, y: 300))
        let empty = w.h.addEmptyReference(at: CGPoint(x: 600, y: 400))
        expectEqual(standIns.calls(try require(w.h.editor.document[w.reference])), "shapes")
        expectEqual(standIns.calls(try require(w.h.editor.document[words])), "stuff")
        expectEqual(standIns.calls(try require(w.h.editor.document[empty])), nil)
        expectEqual(standIns.calls(try require(w.h.editor.document[w.a])), nil, "a box doesn't stand in")
        w.h.editor.transact { $0.delete([w.a]) }
        expectEqual(standIns.calls(try require(w.h.editor.document[w.reference])), "shapes", "the note is gone, its name is kept")
    },
    test("a private shape is fulfilled for a pill by being made public, on the record alone: the document is the caller's to write") {
        let w = try Wired()
        let tile = w.h.addTile("Pricing")
        w.h.editor.transact { $0.update(tile) { $0[PublicProperty.self] = nil } }
        let standIns = w.h.editor.registry.standIns
        var record = try require(w.h.editor.document[tile])
        expect(!standIns.admits(Reference.kind, record))
        expect(standIns.fulfil(Reference.kind, &record))
        expectEqual(record[PublicProperty.self], true)
        expect(standIns.admits(Reference.kind, record))
        expectEqual(w.h.editor.document[tile]?[PublicProperty.self], nil, "not written")
        var pill = try require(w.h.editor.document[w.reference])
        expect(!standIns.fulfil(Reference.kind, &pill), "a pill is never stood for, nor public")
    },
])
