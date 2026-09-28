import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import LanguageModels
import Mentions
import Ports
import Schemas
import StickyNotes
import Subboards
import TestKit
import Topology

// Topology over the shipped plugins: arrows drawn on notes' and schemas' channels, a plain arrow,
// and mentions across a subboard, as one graph of the whole file.

private let noteLink = EdgeTypeID(rawValue: NoteLink.id.rawValue), schemaLink = EdgeTypeID(rawValue: SchemaLink.id.rawValue)

/// An arrow bound at both ends, imprecisely, at the centers, on `channel` (nil: as the arrow tool draws).
private func arrow(_ from: ShapeID, _ to: ShapeID, on channel: ChannelID?) -> AnyShapeRecord {
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    var record = ShapeRecord(Arrow(start: bound(from), end: bound(to)))
    record[ChannelProperty.self] = channel
    return AnyShapeRecord(record)
}

private func note(_ x: CGFloat, _ y: CGFloat, _ text: MentionText) -> ShapeRecord<StickyNote> {
    ShapeRecord(StickyNote(frame: CGRect(x: x, y: y, width: 200, height: 200), text: text))
}

@MainActor let topologyShippedTests = Suite("Topology, as shipped", [
    test("the edge types: arrow, with each channel under it, and mention") {
        let types = try ShippedPlugins.registry(model: ScriptedLanguageModel()).edgeTypes
        expectEqual(Set(types.declared), ["arrow", noteLink, schemaLink, "mention"])
        expectEqual(types.parent(of: noteLink), "arrow")
        expectEqual(types.parent(of: schemaLink), "arrow")
        expectEqual(types.parent(of: "arrow"), nil)
        expectEqual(types.parent(of: "mention"), nil)
    },

    test("arrows on notes' and schemas' channels, a plain arrow, and mentions across a subboard: one graph of the file, by type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let sub = ShapeRecord(Subboard(frame: CGRect(x: 0, y: 600, width: 240, height: 160)))
        let a = note(0, 0, MentionText([.text("In "), .mention(sub.id, label: "Sub")])), b = note(400, 0, "B")
        let deep = note(0, 0, MentionText([.text("See "), .mention(a.id, label: "A"), .text(" and "), .mention(a.id, label: "A")]))
        let card = ShapeRecord(SchemaCard(frame: CGRect(x: 0, y: 300, width: 240, height: 89)))
        let other = ShapeRecord(SchemaCard(frame: CGRect(x: 400, y: 300, width: 240, height: 89)))
        let linked = arrow(a.id, b.id, on: NoteLink.id), schemas = arrow(card.id, other.id, on: SchemaLink.id), plain = arrow(a.id, card.id, on: nil)
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(b), AnyShapeRecord(card), AnyShapeRecord(other),
                                                            AnyShapeRecord(sub), linked, schemas, plain]),
                              children: [sub.id: CanvasDocument(shapes: [AnyShapeRecord(deep)])])
        let h = try EditorHarness { scheduler in
            CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()), file: file, scheduler: scheduler)
        }
        let topology = try require(h.editor.topology)

        expectEqual(topology.neighbors(of: a.id), [noteLink: [b.id], "arrow": [card.id], "mention": [sub.id, deep.id]],
                    "what a note connects to, and how: its link, the plain arrow, what it mentions and what mentions it, from another board")
        expectEqual(topology.neighbors(of: a.id, .incoming), ["mention": [deep.id]])
        expectEqual(topology.edges(carriedBy: deep.id), [Edge(type: "mention", source: deep.id, target: a.id, carrier: deep.id, slot: "text", count: 2)])
        expectEqual(topology.edges(ofType: .within("arrow")).map(\.carrier), [linked.id, schemas.id, plain.id], "the family: every arrow")
        expectEqual(topology.edges(ofType: .only("arrow")).map(\.carrier), [plain.id], "the plain arrow alone")
        expectEqual(topology.edges(ofType: .only("mention")).map(\.carrier), [a.id, deep.id])
        expectEqual(topology.end(deep.id), .live(BoardID(owner: sub.id)))
        expectEqual(topology.parent(of: deep.id), sub.id)
        expect(topology.isInside(deep.id, sub.id))
        expectEqual(topology.children(of: sub.id), [deep.id])
        expectEqual(h.editor.mentions?.mentioners(of: a.id), [deep.id], "Mentions reads the same index: the subboard's note")

        // Deleting the subboard takes its note's mentions; undo brings them back.
        h.editor.transact { $0.delete([sub.id]) }
        expectEqual(topology.neighbors(of: a.id, .incoming), [:])
        expectEqual(topology.end(sub.id), .missing)
        h.editor.undo()
        expectEqual(topology.neighbors(of: a.id, .incoming), ["mention": [deep.id]])
        expectEqual(h.editor.mentions?.mentioners(of: a.id), [deep.id])
    },
])
