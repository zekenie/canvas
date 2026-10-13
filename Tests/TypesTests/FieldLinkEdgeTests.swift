import Canvas
import CanvasTesting
import Foundation
import Mentions
import TestKit
import Topology
import Types

// A pointer as Topology's edge: `field-link`, a child of `mention`, from the note that holds it to the
// note it names, in the slot of the field's top-level key.

private let ann = FieldFixtures.annLeeID, bo = FieldFixtures.boParkID

@MainActor private func setValues(_ editor: CanvasEditor, _ id: ShapeID, _ values: FieldValues) {
    editor.transact("Set Values") { $0.update(id) { $0[FieldValuesProperty.self] = values } }
}

@MainActor private func linkEdges(_ editor: CanvasEditor, from id: ShapeID) throws -> [Edge] {
    try require(editor.topology).edges(carriedBy: id).filter { $0.type == FieldLinkEdge.id }
}

@MainActor let fieldLinkEdgeTests = Suite("The field-link edge", [
    test("one edge for each token, from the note to its target, in the slot of the top-level key; repeats counted, two fields two edges, a group's pointer in the group's slot") {
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        setValues(editor, order, FieldValues(["customer": link(to: ann, "Ann Lee"),
                                              "guests": .array([link(to: bo, "Bo Park"), link(to: bo, "Bo Park")]),
                                              "host": ["who": link(to: ann, "Ann Lee")],
                                              "giftNote": "no token here"]))
        let edges = try linkEdges(editor, from: order)
        expectEqual(edges.count, 3)
        let expected: [(ShapeID, String, Int)] = [(ann, "customer", 1), (bo, "guests", 2), (ann, "host", 1)]
        for (target, slot, count) in expected {
            expect(edges.contains(Edge(type: FieldLinkEdge.id, source: order, target: target, carrier: order, slot: slot, count: count)), "\(slot): \(edges)")
        }
        // The edges are in a fixed order, whatever the values' dictionary does.
        expectEqual(edges.map(\.slot), ["customer", "guests", "host"])
        expectEqual(try require(editor.topology).edges(of: ann, .incoming, types: .only(FieldLinkEdge.id)).map(\.source), [order, order])
    },

    test("edges follow commits, and undo and redo put them back") {
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        expectEqual(try linkEdges(editor, from: order), [])
        setValues(editor, order, FieldValues(["customer": link(to: ann, "Ann Lee")]))
        expectEqual(try linkEdges(editor, from: order).map(\.target), [ann])
        setValues(editor, order, FieldValues(["customer": link(to: bo, "Bo Park")]))
        expectEqual(try linkEdges(editor, from: order).map(\.target), [bo])
        editor.undo()
        expectEqual(try linkEdges(editor, from: order).map(\.target), [ann])
        editor.redo()
        expectEqual(try linkEdges(editor, from: order).map(\.target), [bo])
        editor.transact("Delete") { $0.delete([bo]) }
        expectEqual(try linkEdges(editor, from: order).map(\.target), [bo], "the edge stays, its end gone")
        expectEqual(try require(editor.topology).end(bo), .missing)
    },

    test("a move reads no record") {
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        setValues(editor, order, FieldValues(["customer": link(to: ann, "Ann Lee")]))
        let topology = try require(editor.topology)
        let reads = topology.recordsRead
        editor.transact("Move") { $0.translate([order, ann], by: CGPoint(x: 30, y: 20)) }
        expectEqual(topology.recordsRead, reads)
        expectEqual(try linkEdges(editor, from: order).map(\.target), [ann])
    },

    test("a field called stands-for makes no edge: Topology's slot is its own (pinned: the loss is known)") {
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        setValues(editor, order, FieldValues(["stands-for": link(to: ann, "Ann Lee"), "customer": link(to: bo, "Bo Park")]))
        expectEqual(try linkEdges(editor, from: order).map(\.slot), ["customer"])
    },

    test("the edge type is a child of mention: the mention tree has it, only mention does not; Mentions' own readers leave it out") {
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        setValues(editor, order, FieldValues(["customer": link(to: ann, "Ann Lee")]))
        let topology = try require(editor.topology)
        expectEqual(topology.types.parent(of: FieldLinkEdge.id), MentionEdge.id)
        expectEqual(topology.types.plugin(declaring: FieldLinkEdge.id), .types)
        expectEqual(topology.types.summary(of: FieldLinkEdge.id), "a field's link to a note, from the note that holds it to the note it names")
        expectEqual(topology.edges(of: ann, .incoming, types: .within(MentionEdge.id)).map(\.source), [order])
        expectEqual(topology.edges(of: ann, .incoming, types: .only(MentionEdge.id)), [])
        let mentions = try require(editor.mentions)
        expectEqual(mentions.mentioners(of: ann), [], "no pointing note is a mentioner: a pointer is no text")
        expect(!mentions.isMentioned(ann), "a pointer isn't a mention")
        expectEqual(mentions.mentions(in: order), [])
    },
])
