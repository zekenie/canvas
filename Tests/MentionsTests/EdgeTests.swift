import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology

// Mentions as Topology's edges: who mentions whom is Topology's index, of the whole file, which
// Mentions' source fills from mention text and MentionState reads.

private let frame = CGRect(x: 0, y: 0, width: 200, height: 200)

/// Asks Mentions which rows a commit affects as it hears it, and then what the jot mentions, from a
/// service made before Topology's, so it hears each commit before the index does.
@MainActor
private final class EarlyProbe {
    let jot: () -> ShapeID?
    var heard: [Set<ShapeID>] = []
    var mentions: [[ShapeID]] = []
    init(jot: @escaping () -> ShapeID?) { self.jot = jot }
}

extension EarlyProbe: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        heard.append(editor.mentions?.rowsAffected(by: changes) ?? [])
        if let jot = jot() { mentions.append(editor.mentions?.mentions(in: jot) ?? []) }
    }
}

@MainActor let edgeTests = Suite("Mention edges", [
    test("each mention is an edge of type mention, from the text's shape to what it names, in the slot of the property it's in, counted, in text order") {
        let h = try mentionHarness()
        let topology = try require(h.editor.topology)
        let groceries = h.editor.add(Plate(CGRect(x: 400, y: 0, width: 120, height: 80)), titled: "Groceries")
        let milk = h.add(Token(CGRect(x: 600, y: 0, width: 60, height: 60), caption: "Milk"))
        let gone = ShapeID()
        let jot = h.add(Jot(frame, text: mentioning([.mention(milk, label: "Milk"), .text(" "), .mention(groceries, label: "Groceries"),
                                                     .text(" "), .mention(milk, label: "Milk"), .text(" "), .mention(gone, label: "Gone")])))
        let mention = MentionEdge.id
        expectEqual(topology.edges(carriedBy: jot), [Edge(type: mention, source: jot, target: milk, carrier: jot, slot: "text", count: 2),
                                                     Edge(type: mention, source: jot, target: groceries, carrier: jot, slot: "text"),
                                                     Edge(type: mention, source: jot, target: gone, carrier: jot, slot: "text")])
        expectEqual(h.editor.mentionState.mentions(in: jot), [milk, groceries, gone], "each once, in text order")
        expectEqual(topology.end(gone), .missing, "a mention of a shape that isn't there is an edge still")
        expectEqual(topology.neighbors(of: milk, .incoming), [mention: [jot]])
        expect(topology.types.isDeclared(mention))
        expectEqual(topology.types.parent(of: mention), nil, "a root")
        expectEqual(topology.types.plugin(declaring: mention), .mentions)

        // A jot that mentions itself: one edge, there once.
        h.editor.setText(jot, mentioning([.mention(jot, label: "Me")]))
        expectEqual(topology.edges(of: jot), [Edge(type: mention, source: jot, target: jot, carrier: jot, slot: "text")])
        expectEqual(h.editor.mentionState.mentioners(of: jot), [jot])
        expectEqual(topology.edges(of: milk), [], "the text changed: its edges followed")
    },

    test("heard first by a service before Topology's, a commit brings the index up to date as that service asks (rowsAffected), and the index hears it once") {
        var jot: ShapeID?
        let probe = EarlyProbe { jot }
        let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), Contributor(id: "early") { $0.service { _ in probe } }, TopologyPlugin(),
                                           FixturesPlugin(), MentionFixturesPlugin(), AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(),
                                           SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin()]
        let h = try EditorHarness(plugins: plugins)
        let topology = try require(h.editor.topology)
        let groceries = h.editor.add(Plate(CGRect(x: 400, y: 0, width: 120, height: 80)), titled: "Groceries")
        let errands = h.editor.add(Plate(CGRect(x: 400, y: 200, width: 120, height: 80)), titled: "Errands")
        let added = h.add(Jot(frame, text: mentioning([.mention(groceries, label: "Groceries")])))
        jot = added
        #if DEBUG
        let read = topology.recordsRead
        #endif
        h.editor.setText(added, mentioning([.mention(errands, label: "Errands")]))
        expectEqual(probe.mentions.last, [errands], "the index was brought up to date before the probe read it")
        #if DEBUG
        expectEqual(topology.recordsRead, read + 1, "and heard the commit once")
        #endif
        h.editor.rename(errands, "Chores")
        expectEqual(probe.heard.last, [added], "a rename names the row of the jot that mentions it now")
        h.editor.rename(groceries, "Food")
        expectEqual(probe.heard.last, [], "nor that of a jot that no longer mentions it")
    },

    test("undo and redo put the edges back as they were: a mention's deletion, and its mentioner's") {
        let h = try mentionHarness()
        let topology = try require(h.editor.topology)
        let milk = h.add(Token(CGRect(x: 600, y: 0, width: 60, height: 60), caption: "Milk"))
        let jot = h.add(Jot(frame, text: mentioning([.mention(milk, label: "Milk")])))
        let edges = topology.edges(of: milk)
        expectEqual(edges.count, 1)
        h.editor.delete(milk)
        expectEqual(topology.edges(of: milk), edges, "deleting what's mentioned writes nothing: the edge stays")
        expectEqual(topology.end(milk), .missing)
        h.editor.delete(jot)
        expectEqual(topology.edges(of: milk), [])
        h.editor.undo()
        expectEqual(topology.edges(of: milk), edges)
        h.editor.undo()
        expectEqual(topology.end(milk), .live(.root))
        h.editor.redo()
        h.editor.redo()
        expectEqual(topology.edges(of: milk), [])
        expectEqual(h.editor.mentionState.mentioners(of: milk), [])
    },
])
