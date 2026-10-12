import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit
import Topology

// An edge to a shape on another board goes through a stand-in: a shape of the run, beside the end that's
// on the board it draws on, standing for the other. These hold what `canvas draw` asks of stand-ins and
// does with them, over fixtures only: a relay (its record cites what it stands for, it says what it
// stands for, its width follows what it says; made by the kind's hook, and only for shapes that are
// open), tiles, and links as the edges.

/// Whether a relay may stand for a shape: metadata a test writes on a shape, as a person makes one public.
enum Open: ShapeMetaKey {
    static let owner: PluginID = "relays"
    static let name = "open"
    typealias Value = Bool
}

/// Whether a relay is pinned, which makes it read-only.
enum Sealed: ShapeMetaKey {
    static let owner: PluginID = "relays"
    static let name = "sealed"
    typealias Value = Bool
}

/// A box that stands for the shapes it cites, and says what it stands for: its width follows its words.
struct Relay: BoxShapeProps {
    static let kind: ShapeKind = "relay"
    static let properties = Properties<Relay> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
        Property("says", \.says)
    }
    var frame: CGRect
    var stands: [Citation]
    var says: String
    init(_ frame: CGRect, stands: [ShapeID] = [], says: String = "") {
        self.frame = frame
        self.stands = stands.map(Citation.init)
        self.says = says
    }
}

extension Relay {
    init() { self.init(.zero) }

    /// How wide a relay is that says this: 24 and 8 a letter.
    static func width(saying says: String) -> CGFloat { 24 + 8 * CGFloat(says.count) }
}

struct RelayDefinition {}

extension RelayDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Relay>, in context: RenderContext) {}
}

/// Written as a kind's setters would: its width fits what it says.
extension RelayDefinition: DerivedProps {
    func derive(_ props: inout Relay) { props.frame.size.width = Relay.width(saying: props.says) }
}

/// Relays: they stand for the shapes they cite, but only open ones, and are made to stand for one by
/// citing it and saying its name (what the hook is given). With `tool` false, no tool places one, so
/// none can be made. With `makes` false, the kind says nothing of how one is made.
@MainActor func relaysPlugin(tool: Bool = true, makes: Bool = true, needs: String? = "open") -> Contributor {
    Contributor(id: "relays") { registrar in
        registrar.shape(RelayDefinition()) { relay in
            let admitting: ForwardAdmission = { target, _ in target.meta[Open.self] == true }
            let stands: @MainActor (ShapeRecord<Relay>, Registry) -> Forwarding? = { shape, _ in
                shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape))
            }
            if makes {
                relay.standsIn(admitting: admitting, needs: needs, makes: { props, target, label in
                    props.stands = [Citation(target)]
                    props.says = label
                }, stands)
            } else {
                relay.standsIn(admitting: admitting, needs: needs, stands)
            }
            if tool { relay.tool(label: "Relay", systemImage: "arrow.right", placing: relay.placement(size: CGSize(width: 100, height: 40)) { Relay() }) }
        }
        registrar.readOnlyShapes { $0.meta[Sealed.self] == true }
    }
}

/// A harbor: on the root, tiles Hub, Dock (open) and Gate, and pockets P and Q; on P's board, tiles Deep
/// (open), Shut and Pier (open); on Q's, tile Reef (open). All in the editor's view, and room for a
/// relay right or left of Hub.
@MainActor struct Harbor {
    let p = ShapeID(), q = ShapeID(), hub = ShapeID(), dock = ShapeID(), gate = ShapeID(), deep = ShapeID(), shut = ShapeID(), pier = ShapeID(), reef = ShapeID()
    /// Whether Hub may be stood for.
    var openHub = false

    var file: CanvasFile {
        func tile(_ id: ShapeID, _ label: String, x: CGFloat, y: CGFloat = 150, open: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: y, width: 120, height: 80), label: label)))
            if open { record.meta[Open.self] = true }
            return record
        }
        func pocket(_ id: ShapeID, _ name: String, x: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: 400, width: 100, height: 100))))
            record[Nickname.self] = name
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [tile(hub, "Hub", x: 400, open: openHub), tile(dock, "Dock", x: 800, open: true),
                                                        tile(gate, "Gate", x: 800, y: 300), pocket(p, "P", x: 400), pocket(q, "Q", x: 600)]),
                          children: [p: CanvasDocument(shapes: [tile(deep, "Deep", x: 150, open: true), tile(shut, "Shut", x: 400, y: 300),
                                                                tile(pier, "Pier", x: 600, open: true)]),
                                     q: CanvasDocument(shapes: [tile(reef, "Reef", x: 150, open: true)])])
    }

    /// An editor on the harbor: names, links, relays (and Topology, whose point they stand in at) and pockets.
    func editor(log: EdgeLog = EdgeLog(), _ more: [any CanvasPlugin] = [], relays: Contributor = relaysPlugin()) throws -> CanvasEditor {
        let editor = try drawEditor([TopologyPlugin(), PocketsPlugin(), namedPockets, relays] + more, log: log)
        editor.replaceFile(with: file)
        return editor
    }
}

extension CanvasEditor {
    /// The relays on a board, in the stack's order.
    func relays(on board: BoardID = .root) -> [ShapeRecord<Relay>] { contents(of: board).shapes.compactMap { $0.typed(as: Relay.self) } }

    /// The links on a board, each as the ids it joins.
    func linkEnds(on board: BoardID = .root) -> [(from: ShapeID?, to: ShapeID?)] {
        contents(of: board).shapes.compactMap { $0.typed(as: Link.self) }.map { ($0.props.from, $0.props.to) }
    }

    /// The links on a board, by the titles of what they join: a relay by what it says, as `relay Deep`.
    func linkNames(on board: BoardID = .root) -> [String] {
        func name(_ id: ShapeID?) -> String {
            guard let record = id.flatMap({ file.record($0) }) else { return "?" }
            if let relay = record.typed(as: Relay.self) { return "relay \(relay.props.says)" }
            return record.typed(as: Tile.self)?.props.label ?? "?"
        }
        return linkEnds(on: board).map { "\(name($0.from)) -> \(name($0.to))" }
    }
}

@MainActor let drawStandInTests = Suite("draw: an edge to a shape on another board goes through a stand-in", [
    test("an edge to a shape on another board is drawn into a relay for it beside the start: a shape of the run, before the arrow, with the arrow's row saying via, and no warning") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        let result = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let relay = try require(editor.relays().first)
        expectEqual(editor.relays().count, 1)
        expectEqual(relay.props.stands.map(\.shape), [h.deep], "it stands for Deep, on P's board")
        expectEqual(relay.props.says, "Deep", "the name it's given is Deep's title as draw folds it")
        expectEqual(relay.frame.width, Relay.width(saying: "Deep"), "put in step, as the kind's setters would")
        let hub = try require(editor.file.record(h.hub)?.box)
        expectEqual(relay.frame.minX, hub.maxX + 80, "right of Hub, a gap away")
        expectEqual(relay.frame.midY, hub.midY, "and level with it, as any shape placed right of one is")
        expectEqual(editor.linkEnds().count, 1)
        expectEqual(editor.linkEnds().first?.from, h.hub)
        expectEqual(editor.linkEnds().first?.to, relay.id, "the arrow runs into the relay, not to Deep")
        expectEqual(editor.linkNames(), ["Hub -> relay Deep"])
        // The relay is a row of its own, on the edge's line, before the edge's.
        let changes = rows(result)
        expectEqual(changes.map { $0["did"] }, ["created", "connected"])
        expectEqual(changes.map { $0["line"] }, [1, 1])
        expectEqual(changes[0]["kind"], "relay")
        expectEqual(changes[0]["title"], nil, "a relay has no title")
        expect(changes[0]["at"] != nil, "it says where it landed")
        expectEqual(changes[1], ["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"])
        expectEqual(messages(result), [], "the row says it went through a relay")
        expectEqual(result["on"]?["board"], "root", "it drew where Hub is")
        expectEqual(editor.board, .root)
        // The edge maker was asked of the relay as one that stands for a tile, on the relay's own sides.
        let request = try require(log.requests.last)
        expectEqual(request.from, h.hub)
        expectEqual(request.to, relay.id)
        expectEqual(request.fromStandsFor, [])
        expectEqual(request.toStandsFor, [Tile.kind])
        expectEqual(request.fromName, #""Hub""#)
        expectEqual(request.toName, #""Deep""#)
    },
    test("the far end may be the start: the relay is left of the end that stays, and the arrow runs out of it; <-> is the same") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        let result = try drawn(#"edge "Deep" -> "Hub""#, on: editor)
        let relay = try require(editor.relays().first)
        let hub = try require(editor.file.record(h.hub)?.box)
        expectEqual(relay.frame.maxX, hub.minX - 80, "left of Hub")
        expectEqual(editor.linkNames(), ["relay Deep -> Hub"])
        expectEqual(editor.linkEnds().first?.from, relay.id)
        expectEqual(rows(result).last, ["line": 1, "did": "connected", "kind": "link", "from": "Deep", "to": "Hub", "via": "relay"])
        expectEqual(messages(result), [])
        expectEqual(log.requests.last?.fromStandsFor, [Tile.kind])
        expectEqual(log.requests.last?.toStandsFor, [])

        let both = try drawn(#"edge "Hub" <-> "Reef""#, on: editor)
        expectEqual(editor.relays().count, 2)
        expectEqual(log.requests.last?.bothHeads, true)
        expectEqual(editor.linkNames().last, "Hub -> relay Reef")
        expectEqual(rows(both).last?["via"], "relay")
    },
    test("a side the edge names for the end on the board says which side of it the relay goes: below it for from: bottom; one for the end that's stood for is the edge maker's") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        _ = try drawn(#"edge "Hub" -> "Deep" from: bottom to: left"#, on: editor)
        let relay = try require(editor.relays().first), hub = try require(editor.file.record(h.hub)?.box)
        expectEqual(relay.frame.minY, hub.maxY + 80, "below Hub")
        expectEqual(relay.frame.midX, hub.midX)
        expectEqual(log.requests.last?.fromSide, .bottom)
        expectEqual(log.requests.last?.toSide, .left, "the relay's own side: the edge maker decides what it has")
        _ = try drawn(#"edge "Deep" -> "Hub" to: top"#, on: editor)
        expectEqual(editor.relays().count, 2)
        let second = try require(editor.relays().last)
        expectEqual(second.frame.maxY, hub.minY - 80, "above Hub: its end's side is where the relay goes")
    },
    test("the relay is placed as a new shape is: kept clear of what's there, and the warning says which side to name") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        // A tile where the relay would go, right of Hub.
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 600, y: 140, width: 60, height: 100), label: "Buoy")))) }
        let result = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let relay = try require(editor.relays().first)
        expect(relay.frame.minX >= 660, "pushed right past Buoy: \(relay.frame)")
        expectEqual(rows(result).first?["pushedPast"], ["Buoy"])
        expect(messages(result).contains(#"the relay to "Deep" was pushed right past "Buoy" to keep clear of it, so it no longer sits against "Hub" — name another side for it with from: or to:"#),
               "\(messages(result))")
        // On another side it's clear.
        editor.undo()
        let clear = try drawn(#"edge "Hub" -> "Deep" from: bottom"#, on: editor)
        expectEqual(rows(clear).first?["pushedPast"], nil)
    },
    test("an edge between two shapes on the board stays straight: no relay, whatever the kinds can do") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        let result = try drawn(#"edge "Hub" -> "Dock""#, on: editor)
        expectEqual(rows(result), [["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": "Dock"]])
        expectEqual(editor.relays().count, 0)
        expectEqual(editor.linkNames(), ["Hub -> Dock"])
        expectEqual(messages(result), [])
        expectEqual(log.requests.last?.toStandsFor, [])
    },
    test("which board the run draws on: hard claims first; an end that can't be stood for claims hard, and one that can claims softly") {
        // Hub can be stood for: the run goes where `in "P"` says, and a relay for Hub goes beside Deep.
        var open = Harbor()
        open.openHub = true
        let editor = try open.editor()
        let result = try drawn("""
            tile "Extra" in "P"
            edge "Hub" -> "Deep"
            """, on: editor)
        expectEqual(result["on"]?["board"], .string(open.p.description))
        let relay = try require(editor.relays(on: BoardID(owner: open.p)).first)
        expectEqual(relay.props.stands.map(\.shape), [open.hub], "a relay for Hub, on P's board")
        expectEqual(editor.relays().count, 0)
        let deep = try require(editor.file.record(open.deep)?.box)
        expectEqual(relay.frame.maxX, deep.minX - 80, "left of Deep: Deep is where the arrow ends")
        expectEqual(editor.linkNames(on: BoardID(owner: open.p)), ["relay Hub -> Deep"])
        expectEqual(rows(result).last?["via"], "relay")
        expectEqual(messages(result), [])

        // Hub can't be: it claims the root, which `in "P"` doesn't, and nothing can be said of two.
        let closed = try Harbor().editor()
        let two = try refused("""
            tile "Extra" in "P"
            edge "Hub" -> "Deep"
            """, on: closed)
        expectEqual(two.reason, "several_boards")
        expectEqual(two.message, #"this script draws on "P"'s board (in "P", line 1) and on the root board ("Hub")"#)
        expectEqual(two.hint, #"an arrow can't leave its board: it goes into a relay standing for the shape on the other board, and only an open shape can be stood for; ask the user to make "Hub" open, or split the script into a run for each board"#)
        expectEqual(two.data?["line"], 2)
        expectEqual(closed.relays(on: BoardID(owner: open.p)).count, 0, "nothing drawn")
    },
    test("with no hard claim the run draws on the board of the first such edge's start; each such edge needs one end on it") {
        var open = Harbor()
        open.openHub = true
        let editor = try open.editor()
        // Both ends can be stood for, so neither claims: the start's board.
        let first = try drawn(#"edge "Deep" -> "Hub""#, on: editor)
        expectEqual(first["on"]?["board"], .string(open.p.description), "Deep's board")
        expectEqual(editor.relays(on: BoardID(owner: open.p)).first?.props.stands.map(\.shape), [open.hub])
        let other = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        expectEqual(other["on"]?["board"], "root", "Hub's")
        // A second edge between other boards: neither end is on the first's board.
        let two = try refused("""
            edge "Hub" -> "Deep" tone: warm
            edge "Reef" -> "Pier"
            """, on: editor)
        expectEqual(two.reason, "several_boards")
        expectEqual(two.message, #"this script draws on the root board ("Hub", line 1) and on "Q"'s board ("Reef")"#)
        expectEqual(two.data?["line"], 2)
    },
    test("an end that can't be stood for, with the other that can: the run draws on the one that can't be") {
        let h = Harbor()
        let editor = try h.editor()
        // Hub can't be: the run is the root's, and Deep is stood for there, whichever way it runs.
        _ = try drawn(#"edge "Deep" -> "Hub""#, on: editor)
        expectEqual(editor.relays().first?.props.stands.map(\.shape), [h.deep])
        _ = try drawn(#"edge "Hub" -> "Pier""#, on: editor)
        expectEqual(editor.relays().count, 2)
        expectEqual(editor.relays(on: BoardID(owner: h.p)).count, 0)
    },
    test("neither end can be stood for: several_boards, saying which could be asked to be, and when no kind makes stand-ins, as it always was") {
        let h = Harbor()
        let editor = try h.editor()
        let both = try refused(#"edge "Hub" -> "Shut""#, on: editor)
        expectEqual(both.reason, "several_boards")
        expectEqual(both.message, #"this script draws on the root board ("Hub", line 1) and on "P"'s board ("Shut")"#)
        expectEqual(both.hint, #"an arrow can't leave its board: it goes into a relay standing for the shape on the other board, and only an open shape can be stood for; ask the user to make "Hub" or "Shut" open, or split the script into a run for each board"#)
        // Dock can be stood for and Shut can't, so the run is on Shut's board: a relay for Dock, beside it.
        let toShut = try drawn(#"edge "Dock" -> "Shut""#, on: editor)
        expectEqual(toShut["on"]?["board"], .string(h.p.description))
        expectEqual(editor.relays(on: BoardID(owner: h.p)).first?.props.stands.map(\.shape), [h.dock])
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["relay Dock -> Shut"])
        editor.undo()
        expect(!editor.canUndo)

        // Nothing makes stand-ins: the hint is the old one.
        let plain = try h.editor(relays: relaysPlugin(tool: false))
        let none = try refused(#"edge "Dock" -> "Deep""#, on: plain)
        expectEqual(none.reason, "several_boards")
        expectEqual(none.hint, "a run draws on one board: split the script into a run for each")
        let unmade = try h.editor(relays: relaysPlugin(makes: false))
        expectEqual(try refused(#"edge "Dock" -> "Deep""#, on: unmade).reason, "several_boards", "a kind that stands in and can't be made isn't one")
        expectEqual(unmade.relays().count, 0)
    },
    test("both ends off the board the run draws on is several_boards, naming the one it can't reach") {
        var open = Harbor()
        open.openHub = true
        let editor = try open.editor()
        let result = try refused("""
            tile "Extra" in "Q"
            edge "Hub" -> "Deep"
            """, on: editor)
        expectEqual(result.reason, "several_boards")
        expectEqual(result.message, #"this script draws on "Q"'s board (in "Q", line 1) and on the root board ("Hub")"#)
        expectEqual(result.data?["line"], 2)
    },
    test("an end the script draws has no board of its own to put a relay on: the edge claims the other end's board, as it always did") {
        var open = Harbor()
        open.openHub = true
        let editor = try open.editor()
        // Skiff lands wherever the run draws: on P's board, where Deep is, joined straight.
        let result = try drawn("""
            tile "Skiff"
            edge "Skiff" -> "Deep"
            """, on: editor)
        expectEqual(result["on"]?["board"], .string(open.p.description))
        expectEqual(editor.relays(on: BoardID(owner: open.p)).count, 0)
        expectEqual(editor.linkNames(on: BoardID(owner: open.p)), ["Skiff -> Deep"])
        // A shape drawn in an earlier run is on its board, and the edge between boards goes through a relay.
        _ = try drawn(#"tile "Barge" below "Hub""#, on: editor)
        let later = try drawn(#"edge "Barge" -> "Deep""#, on: editor)
        expectEqual(later["on"]?["board"], "root")
        expectEqual(editor.linkNames(), ["Barge -> relay Deep"])
    },
    test("the end on the board may be a shape the script restates and moves: the relay is beside it where it lands") {
        let h = Harbor()
        let editor = try h.editor()
        let result = try drawn("""
            tile "Hub" below "Gate"
            edge "Hub" -> "Deep"
            """, on: editor)
        let hub = try require(editor.file.record(h.hub)?.box), gate = try require(editor.file.record(h.gate)?.box)
        expect(hub.minY >= gate.maxY, "Hub moved below Gate: \(hub)")
        let relay = try require(editor.relays().first)
        expectEqual(relay.frame.minX, hub.maxX + 80, "right of Hub where it is now")
        expectEqual(relay.frame.midY, hub.midY)
        expectEqual(rows(result).map { $0["did"] }, ["moved", "created", "connected"])
        expectEqual(editor.linkNames(), ["Hub -> relay Deep"])
    },
    test("an edge each way in one run makes a relay each, on either side of the shape; the same far shape for two near ones is two relays") {
        var open = Harbor()
        open.openHub = true
        let h = open
        let editor = try h.editor()
        let result = try drawn("""
            edge "Hub" -> "Deep"
            edge "Deep" -> "Hub"
            """, on: editor)
        expectEqual(result["on"]?["board"], "root", "the first's start is on the root, and Deep can be stood for: the second needs one end there, and has Hub")
        expectEqual(editor.relays().count, 2)
        expectEqual(editor.linkNames(), ["Hub -> relay Deep", "relay Deep -> Hub"])
        let hub = try require(editor.file.record(h.hub)?.box)
        let frames = editor.relays().map(\.frame)
        expect(frames.contains { $0.minX > hub.maxX } && frames.contains { $0.maxX < hub.minX }, "one on each side: \(frames)")
    },
    test("a far end that's in the file twice is ambiguous; one on a board the script deletes is unknown") {
        let h = Harbor()
        let editor = try h.editor()
        editor.transact(on: BoardID(owner: h.q), "Twin") { transaction in
            var twin = AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 400, y: 150, width: 120, height: 80), label: "Deep")))
            twin.meta[Open.self] = true
            transaction.insert(twin)
        }
        let result = try refused(#"edge "Hub" -> "Deep""#, on: editor)
        expectEqual(result.reason, "ambiguous_title")
        expectEqual(result.message, #""Deep" is on 2 boards: "P"'s board and "Q"'s board"#)
        // A pocket deleted takes its board, and what's on it can't be reached.
        let gone = try refused("""
            delete "P"
            edge "Hub" -> "Pier"
            """, on: editor)
        expectEqual(gone.reason, "unknown_title")
        expectEqual(gone.message, #"there's no shape called "Pier""#)
    },
])

@MainActor let drawViaTests = Suite("draw: via names the kind a stand-in is made as", [
    test("via puts a stand-in for the end beside the start, even where both are on the board: the arrow runs into it, and the row says so") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        let result = try drawn(#"edge "Hub" -> "Dock" via: relay"#, on: editor)
        let relay = try require(editor.relays().first)
        expectEqual(relay.props.stands.map(\.shape), [h.dock])
        expectEqual(relay.props.says, "Dock")
        expectEqual(editor.linkNames(), ["Hub -> relay Dock"], "not straight to Dock")
        let hub = try require(editor.file.record(h.hub)?.box)
        expectEqual(relay.frame.minX, hub.maxX + 80)
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected"])
        expectEqual(rows(result).last?["via"], "relay")
        expectEqual(messages(result), [])
        expectEqual(log.requests.last?.toStandsFor, [Tile.kind])
        // <-> works the same.
        _ = try drawn(#"edge "Hub" <-> "Pocket" via: relay"#.replacingOccurrences(of: "Pocket", with: "Dock"), on: try Harbor().editor(log: log))
        expectEqual(log.requests.last?.bothHeads, true)
    },
    test("via with the end elsewhere is the same as without; from the other side it stands for the end, not the start") {
        let h = Harbor()
        let editor = try h.editor()
        let result = try drawn(#"edge "Hub" -> "Deep" via: relay"#, on: editor)
        expectEqual(editor.linkNames(), ["Hub -> relay Deep"])
        expectEqual(messages(result), [])
        // `<-` is the same edge written the other way: the stand-in is for its end, Hub.
        var open = Harbor()
        open.openHub = true
        let other = try open.editor()
        _ = try drawn(#"edge "Hub" <- "Deep" via: relay"#, on: other)
        expectEqual(other.relays(on: BoardID(owner: open.p)).first?.props.stands.map(\.shape), [open.hub], "the end of Deep -> Hub is Hub")
        expectEqual(other.linkNames(on: BoardID(owner: open.p)), ["Deep -> relay Hub"])
    },
    test("via takes a kind that stands in and can be made to: anything else is invalid_value naming them, with the one it's like") {
        let editor = try Harbor().editor()
        let tile = try refused(#"edge "Hub" -> "Dock" via: tile"#, on: editor)
        expectEqual(tile.reason, "invalid_value")
        expectEqual(tile.message, #"edge "Hub" -> "Dock": via: tile isn't a kind of shape that stands for others"#)
        expectEqual(tile.hint, "via: takes relay")
        let typo = try refused(#"edge "Hub" -> "Dock" via: rely"#, on: editor)
        expectEqual(typo.hint, "did you mean relay? via: takes relay")
        expectEqual(typo.data?["statement"], #"edge "Hub" -> "Dock" via: rely"#)
        let none = try refused(#"edge "Hub" -> "Dock" via: relay"#, on: try Harbor().editor(relays: relaysPlugin(tool: false)))
        expectEqual(none.reason, "invalid_value")
        expectEqual(none.hint, "no kind here is put beside a shape it stands for: leave via: out")
        let unmade = try refused(#"edge "Hub" -> "Dock" via: relay"#, on: try Harbor().editor(relays: relaysPlugin(makes: false)))
        expectEqual(unmade.reason, "invalid_value")
        expectEqual(editor.relays().count, 0)
        expect(!editor.canUndo)
    },
    test("via names a stand-in for a shape it can't stand for: invalid_value, saying what it needs and who to ask") {
        let editor = try Harbor().editor()
        let gate = try refused(#"edge "Hub" -> "Gate" via: relay"#, on: editor)
        expectEqual(gate.reason, "invalid_value")
        expectEqual(gate.message, #"edge "Hub" -> "Gate": via: relay can't stand for "Gate": only an open shape can be stood for"#)
        expectEqual(gate.hint, #"ask the user to make "Gate" open, or leave via: out"#)
        // On another board too, which then claims its own: a board the run can't draw on and stand for it there.
        let far = try refused(#"edge "Hub" -> "Shut" via: relay"#, on: editor)
        expectEqual(far.reason, "several_boards")
        expectEqual(far.message, #"this script draws on the root board ("Hub", line 1) and on "P"'s board ("Shut")"#)
        expectEqual(far.hint, #"an arrow can't leave its board: it goes into a relay standing for the shape on the other board, and only an open shape can be stood for; ask the user to make "Shut" open, or split the script into a run for each board"#,
                    "Hub isn't the one to make open: via stands for the end")
        let saying = try Harbor().editor(relays: relaysPlugin(needs: nil))
        expectEqual(try refused(#"edge "Hub" -> "Gate" via: relay"#, on: saying).message, #"edge "Hub" -> "Gate": via: relay can't stand for "Gate""#)
        expectEqual(try refused(#"edge "Hub" -> "Gate" via: relay"#, on: saying).hint, "leave via: out")
    },
    test("via with the start elsewhere draws on the start's board: the stand-in for the end is beside it there") {
        let h = Harbor()
        let editor = try h.editor()
        let result = try drawn(#"edge "Deep" -> "Dock" via: relay"#, on: editor)
        expectEqual(result["on"]?["board"], .string(h.p.description))
        let relay = try require(editor.relays(on: BoardID(owner: h.p)).first)
        expectEqual(relay.props.stands.map(\.shape), [h.dock])
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["Deep -> relay Dock"])
        expectEqual(editor.relays().count, 0)
        // The end can't be stood for, and is on another board: the root and P's board both claim.
        let shut = try refused(#"edge "Shut" -> "Gate" via: relay"#, on: editor)
        expectEqual(shut.reason, "several_boards")
        expect(shut.hint?.contains(#"ask the user to make "Gate" open"#) == true, "\(shut.hint ?? "")")
    },
    test("via is the language's key: an edge maker can't declare an attribute named it") {
        let broken = Contributor(id: "via-edges") { registrar in
            registrar.drawEdges(kind: { _ in Link.kind }, attributes: ["via"], sides: { _, _ in [:] }, ends: { _, _ in nil },
                                make: { _, _, _ throws(DrawError) in throw DrawError("no", reason: "cannot_connect") })
        }
        expectThrows(RegistryError.invalid(point: "DrawEdges", reason: "attribute via: the language keeps via: for itself")) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), FixturesPlugin(), LinksPlugin(), broken])
        }
    },
])

extension CanvasEditor {
    /// A relay for `target` on `board`, put there as a person would: called `says`, at `at`.
    @discardableResult
    func addRelay(for target: ShapeID, says: String, on board: BoardID = .root, at origin: CGPoint = CGPoint(x: 200, y: 450)) -> ShapeID {
        let relay = ShapeRecord(Relay(CGRect(origin: origin, size: CGSize(width: Relay.width(saying: says), height: 40)), stands: [target], says: says))
        let id = relay.id
        transact(on: board, "Add Relay") { $0.insert(AnyShapeRecord(relay)) }
        return id
    }

    /// A link between two shapes, as a drag would make one; with no end shape, one with that end free.
    @discardableResult
    func addLink(_ from: ShapeID, _ to: ShapeID?, on board: BoardID = .root) -> ShapeID {
        let link = AnyShapeRecord(ShapeRecord(Link(from: from, to: to)))
        transact(on: board, "Add Link") { $0.insert(link) }
        return link.id
    }
}

@MainActor let drawStandInMatchTests = Suite("draw: an edge through a stand-in is the edge", [
    test("a run again draws neither a second arrow nor a second relay: unchanged, via and all; a change to the arrow is reconnected") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let made = editor.file, revision = editor.revision
        let link = try require(editor.document.shapes.first { $0.kind == Link.kind })
        let again = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(again), [["line": 1, "did": "unchanged", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"]])
        expectEqual(messages(again), [], "the relay is there: nothing to say")
        expectEqual(editor.file, made)
        expectEqual(editor.revision, revision)

        let relay = try require(editor.relays().first)
        let warmer = try drawn(#"edge "Hub" -> "Deep" tone: warm"#, on: editor)
        expectEqual(rows(warmer), [["line": 1, "did": "reconnected", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay", "tone": "warm"]])
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.linkEnds().count, 1)
        expectEqual(log.existing.last, link.id, "the arrow that was there is changed")
        expectEqual(log.requests.last?.from, h.hub)
        expectEqual(log.requests.last?.to, relay.id, "asked of the arrow's own ends: the relay, which stands for a tile")
        expectEqual(log.requests.last?.toStandsFor, [Tile.kind])
        // <-> finds it drawn the other way: Deep as the start is Hub's end.
        let both = try drawn(#"edge "Deep" <-> "Hub" tone: warm"#, on: editor)
        expectEqual(rows(both).map { $0["did"] }, ["reconnected"])
        expectEqual(rows(both).last?["via"], "relay")
        expectEqual(editor.relays().count, 1)
        expectEqual(log.requests.last?.from, h.hub, "asked the way it's drawn")
        expectEqual(log.requests.last?.to, relay.id)
        expectEqual(log.requests.last?.bothHeads, true)
    },
    test("on one board too: an arrow into a relay for B, or out of one for A, is the edge A -> B, and no straight one is drawn") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        let forDock = editor.addRelay(for: h.dock, says: "Dock")
        editor.addLink(h.hub, forDock)
        let result = try drawn(#"edge "Hub" -> "Dock""#, on: editor)
        expectEqual(rows(result), [["line": 1, "did": "unchanged", "kind": "link", "from": "Hub", "to": "Dock", "via": "relay"]])
        expectEqual(editor.linkNames(), ["Hub -> relay Dock"])
        // A relay for the start.
        let forGate = editor.addRelay(for: h.gate, says: "Gate", at: CGPoint(x: 200, y: 520))
        editor.addLink(forGate, h.dock)
        expectEqual(rows(try drawn(#"edge "Gate" -> "Dock""#, on: editor)).map { $0["did"] }, ["unchanged"])
        expectEqual(editor.linkEnds().count, 2)
        // The edge the other way round isn't drawn: it makes one.
        expectEqual(rows(try drawn(#"edge "Dock" -> "Gate""#, on: editor)).map { $0["did"] }, ["connected"])
        expectEqual(editor.linkNames(), ["Hub -> relay Dock", "relay Gate -> Dock", "Dock -> Gate"])
    },
    test("a relay that may stand for several shapes never is the edge, nor one standing for another shape, or for none") {
        let h = Harbor()
        let editor = try h.editor()
        let query = AnyShapeRecord(ShapeRecord(Relay(CGRect(x: 200, y: 450, width: 80, height: 40), stands: [h.dock, h.gate], says: "Docks")))
        editor.transact { $0.insert(query) }
        editor.addLink(h.hub, query.id)
        let none = editor.addRelay(for: h.gate, says: "Gate", at: CGPoint(x: 200, y: 520))
        editor.addLink(h.hub, none)
        let result = try drawn(#"edge "Hub" -> "Dock""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["connected"], "drawn straight: neither arrow is to exactly Dock")
        expectEqual(editor.linkEnds().count, 3)
        expectEqual(editor.relays().count, 2, "and no relay is made")
    },
    test("via with only a straight arrow drawn is refused, saying how to redraw it; redrawn through a relay, a run again finds it") {
        let h = Harbor()
        let editor = try h.editor()
        _ = try drawn(#"edge "Hub" -> "Dock""#, on: editor)
        let straight = try refused(#"edge "Hub" -> "Dock" via: relay"#, on: editor)
        expectEqual(straight.reason, "invalid_value")
        expectEqual(straight.message, #"the edge "Hub" -> "Dock" is drawn straight to "Dock""#)
        expectEqual(straight.hint, #"write delete edge "Hub" -> "Dock" above this line to draw it through a relay"#)
        expectEqual(straight.data?["line"], 1)
        expectEqual(editor.relays().count, 0)
        // Saying so draws it through one, and a run again finds that.
        let redrawn = try drawn("""
            delete edge "Hub" -> "Dock"
            edge "Hub" -> "Dock" via: relay
            """, on: editor)
        expectEqual(rows(redrawn).map { $0["did"] }, ["deleted", "created", "connected"])
        expectEqual(editor.linkNames(), ["Hub -> relay Dock"])
        expectEqual(rows(try drawn(#"edge "Hub" -> "Dock" via: relay"#, on: editor)).map { $0["did"] }, ["unchanged"])
        expectEqual(editor.relays().count, 1)
    },
    test("via where the arrow is drawn through a relay for the start, not the end, is refused too") {
        let h = Harbor()
        let editor = try h.editor()
        let forHub = editor.addRelay(for: h.hub, says: "Hub")
        editor.addLink(forHub, h.dock)
        let start = try refused(#"edge "Hub" -> "Dock" via: relay"#, on: editor)
        expectEqual(start.reason, "invalid_value")
        expectEqual(start.message, #"the edge "Hub" -> "Dock" is drawn through a relay to "Hub""#)
        expectEqual(start.hint, #"write delete edge "Hub" -> "Dock" above this line to draw it through a relay"#)
        expectEqual(rows(try drawn(#"edge "Hub" -> "Dock""#, on: editor)).map { $0["did"] }, ["unchanged"], "without via, it's the edge as it's drawn")
    },
    test("two arrows that are the edge are ambiguous_edge, as two straight ones are") {
        let h = Harbor()
        let editor = try h.editor()
        let first = editor.addRelay(for: h.dock, says: "Dock")
        let second = editor.addRelay(for: h.dock, says: "Dock", at: CGPoint(x: 200, y: 520))
        editor.addLink(h.hub, first)
        editor.addLink(h.hub, second)
        let result = try refused(#"edge "Hub" -> "Dock""#, on: editor)
        expectEqual(result.reason, "ambiguous_edge")
        expectEqual(result.message, #""Hub" -> "Dock" is drawn 2 times"#)
        expectEqual(result.hint, #"write delete edge "Hub" -> "Dock" above this line to replace them"#)
    },
])

@MainActor let drawStandInDeleteTests = Suite("draw: delete edge and delete through a stand-in", [
    test("delete edge takes the arrow and the relay it leaves with none, each a row; undone, both are back") {
        let h = Harbor()
        let editor = try h.editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let made = editor.file
        let result = try drawn(#"delete edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(result), [["line": 1, "did": "deleted", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"],
                                   ["line": 1, "did": "deleted", "kind": "relay"]])
        expectEqual(editor.relays().count, 0)
        expectEqual(editor.linkEnds().count, 0)
        expect(editor.file.record(h.hub) != nil && editor.file.record(h.deep) != nil, "the shapes stay")
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.file, made)
        // A dry run says the same and changes nothing.
        let dry = try drawn(#"delete edge "Hub" -> "Deep""#, on: editor, ["--dry-run"])
        expectEqual(rows(dry), rows(result))
        expectEqual(dry["dryRun"], true)
        expectEqual(editor.file, made)
    },
    test("an arrow out of a relay for the start is the edge too; delete edge with <-> takes either way round") {
        let h = Harbor()
        let editor = try h.editor()
        _ = try drawn(#"edge "Deep" -> "Hub""#, on: editor)
        expectEqual(editor.linkNames(), ["relay Deep -> Hub"])
        let result = try drawn(#"delete edge "Deep" <-> "Hub""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["deleted", "deleted"])
        expectEqual(editor.relays().count, 0)
        expectEqual(editor.linkEnds().count, 0)
    },
    test("a relay with another arrow on it stays; it goes with the last, whichever statement takes it") {
        let h = Harbor()
        let editor = try h.editor()
        let relay = editor.addRelay(for: h.deep, says: "Deep")
        editor.addLink(h.hub, relay)
        editor.addLink(h.dock, relay)
        let one = try drawn(#"delete edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(one).map { $0["kind"] }, ["link"], "the relay isn't deleted: Dock's arrow is on it")
        expectEqual(editor.linkNames(), ["Dock -> relay Deep"])
        expectEqual(editor.relays().count, 1)
        editor.undo()
        let both = try drawn("""
            delete edge "Hub" -> "Deep"
            delete edge "Dock" -> "Deep"
            """, on: editor)
        expectEqual(rows(both).map { $0["kind"] }, ["link", "link", "relay"])
        expectEqual(rows(both).map { $0["line"] }, [1, 2, 2], "the relay goes on the line that leaves it empty")
        expectEqual(editor.relays().count, 0)
        // An arrow with one end free is still an arrow on the relay.
        editor.undo()
        editor.addLink(relay, nil)
        let loose = try drawn(#"delete edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(loose).map { $0["kind"] }, ["link"])
        expectEqual(editor.relays().count, 1)
    },
    test("delete \"X\" takes X's arrows and each relay they leave with no arrow, either way round, each a row after theirs; a dry run says the same, and one undo brings them back") {
        let h = Harbor()
        let editor = try h.editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Pier" -> "Hub"
            """, on: editor)
        expectEqual(editor.linkNames(), ["Hub -> relay Deep", "relay Pier -> Hub"])
        let made = editor.file
        let dry = try drawn(#"delete "Hub""#, on: editor, ["--dry-run"])
        expectEqual(editor.file, made)
        let result = try drawn(#"delete "Hub""#, on: editor)
        // Each arrow's row names what the relay stood for, as delete edge's does.
        expectEqual(rows(result), [["line": 1, "did": "deleted", "kind": "tile", "title": "Hub"],
                                   ["line": 1, "did": "deleted", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"],
                                   ["line": 1, "did": "deleted", "kind": "link", "from": "Pier", "to": "Hub", "via": "relay"],
                                   ["line": 1, "did": "deleted", "kind": "relay"],
                                   ["line": 1, "did": "deleted", "kind": "relay"]])
        expectEqual(messages(result), [])
        expectEqual(rows(dry), rows(result))
        expectEqual(editor.relays().count, 0)
        expectEqual(editor.linkEnds().count, 0)
        expect(editor.file.record(h.deep) != nil && editor.file.record(h.pier) != nil, "the shapes they stood for stay")
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.file, made, "one step: Hub, its arrows and the relays")
    },
    test("a shape deleted and drawn again with its edge in one script has one relay: the old one goes, a new one is made") {
        let h = Harbor()
        let editor = try h.editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let result = try drawn("""
            delete "Hub"
            tile "Hub" below "Gate"
            edge "Hub" -> "Deep"
            """, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["deleted", "deleted", "deleted", "created", "created", "connected"])
        expectEqual(rows(result).map { $0["kind"] }, ["tile", "link", "relay", "tile", "relay", "link"])
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.linkNames(), ["Hub -> relay Deep"])
    },
    test("a relay with an arrow from elsewhere stays; it goes with the last, whichever statement takes it; an arrow with a free end holds it") {
        let h = Harbor()
        let editor = try h.editor()
        let relay = editor.addRelay(for: h.deep, says: "Deep")
        editor.addLink(h.hub, relay)
        editor.addLink(h.dock, relay)
        let one = try drawn(#"delete "Hub""#, on: editor)
        expectEqual(rows(one).map { $0["kind"] }, ["tile", "link"], "the relay isn't deleted: Dock's arrow is on it")
        expectEqual(editor.linkNames(), ["Dock -> relay Deep"])
        editor.undo()
        let both = try drawn("""
            delete "Hub"
            delete "Dock"
            """, on: editor)
        expectEqual(rows(both).map { $0["kind"] }, ["tile", "link", "tile", "link", "relay"])
        expectEqual(rows(both).map { $0["line"] }, [1, 1, 2, 2, 2], "the relay goes on the line that leaves it empty")
        expectEqual(editor.relays().count, 0)
        editor.undo()
        let mixed = try drawn("""
            delete edge "Dock" -> "Deep"
            delete "Hub"
            """, on: editor)
        expectEqual(rows(mixed).map { $0["kind"] }, ["link", "tile", "link", "relay"])
        expectEqual(rows(mixed).map { $0["line"] }, [1, 2, 2, 2])
        expectEqual(editor.relays().count, 0)
        // An arrow with one end free is still an arrow on the relay.
        editor.undo()
        editor.addLink(relay, nil)
        let loose = try drawn("""
            delete "Hub"
            delete "Dock"
            """, on: editor)
        expectEqual(rows(loose).map { $0["kind"] }, ["tile", "link", "tile", "link"])
        expectEqual(editor.relays().count, 1)
    },
    test("a relay that may stand for several shapes stays, as delete edge never takes one; a locked relay delete \"X\" would empty is read_only, and nothing goes") {
        let h = Harbor()
        let editor = try h.editor()
        let several = AnyShapeRecord(ShapeRecord(Relay(CGRect(x: 200, y: 450, width: 80, height: 40), stands: [h.dock, h.gate], says: "Docks")))
        editor.transact { $0.insert(several) }
        editor.addLink(h.hub, several.id)
        expectEqual(rows(try drawn(#"delete "Hub""#, on: editor)).map { $0["kind"] }, ["tile", "link"])
        expectEqual(editor.relays().count, 1)
        editor.undo()

        let relay = editor.addRelay(for: h.deep, says: "Deep", at: CGPoint(x: 200, y: 520))
        editor.addLink(h.hub, relay)
        editor.transact { $0.update(relay) { $0.meta[Sealed.self] = true } }
        let before = editor.file, step = editor.undoHistory.undoName
        let locked = try refused(#"delete "Hub""#, on: editor)
        expectEqual(locked.reason, "read_only")
        expectEqual(locked.message, #"the relay that delete "Hub" leaves with no arrow is read-only (locked, say), so it can't be deleted"#)
        expectEqual(locked.hint, "leave it out of the script, or ask the user to unlock it")
        expectEqual(locked.data?["line"], 1)
        expectEqual(editor.file, before, "nothing deleted")
        expectEqual(editor.undoHistory.undoName, step)
    },
    test("nothing drawn from one to the other is nothing_to_delete, the shapes on another board included; a locked relay can't go") {
        let h = Harbor()
        let editor = try h.editor()
        expectEqual(try refused(#"delete edge "Hub" -> "Deep""#, on: editor).reason, "nothing_to_delete")
        let relay = editor.addRelay(for: h.deep, says: "Deep")
        editor.addLink(h.hub, relay)
        expectEqual(try refused(#"delete edge "Deep" -> "Hub""#, on: editor).reason, "nothing_to_delete", "it runs the other way")
        editor.transact { $0.update(relay) { $0.meta[Sealed.self] = true } }
        let locked = try refused(#"delete edge "Hub" -> "Deep""#, on: editor)
        expectEqual(locked.reason, "read_only")
        expectEqual(locked.message, #"the relay that delete edge "Hub" -> "Deep" leaves with no arrow is read-only (locked, say), so it can't be deleted"#)
        expectEqual(editor.linkEnds().count, 1)
        // Both ends off the board the script draws on.
        let off = try refused("""
            tile "Extra" in "Q"
            delete edge "Hub" -> "Deep"
            """, on: editor)
        expectEqual(off.reason, "several_boards")
    },
])

@MainActor let drawStandInRunTests = Suite("draw: a run with a stand-in", [
    test("one undo takes back the relay and the arrow together, and one redo brings them; a dry run says the same and changes nothing") {
        let h = Harbor()
        let editor = try h.editor()
        let before = editor.file
        let dry = try drawn(#"edge "Hub" -> "Deep""#, on: editor, ["--dry-run"])
        expectEqual(dry["dryRun"], true)
        expectEqual(rows(dry).map { $0["did"] }, ["created", "connected"])
        expectEqual(rows(dry).last?["via"], "relay")
        expectEqual(editor.file, before)
        expect(!editor.canUndo)
        let real = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(real).map { $0["did"] }, ["created", "connected"])
        expectEqual(messages(real), messages(dry))
        expectEqual(editor.undoHistory.undoName, "Draw")
        let made = editor.file
        editor.undo()
        expectEqual(editor.file, before)
        expect(!editor.canUndo, "one step")
        editor.redo()
        expectEqual(editor.file, made)
    },
    test("it's an agent's change, in one commit, and the board the relay is made on stays where the window is") {
        let h = Harbor(), agents = AgentLog()
        let editor = try h.editor([Contributor(id: "agents") { $0.service { _ in agents } }])
        let opened = agents.commits.count
        _ = try drawn(#"edge "Deep" -> "Dock""#, on: editor)
        expectEqual(Array(agents.commits.dropFirst(opened)), [true], "the relay and the arrow are one commit")
        expectEqual(editor.board, .root, "the run drew on Deep's board, and the window stayed")
        expectEqual(editor.relays(on: BoardID(owner: h.p)).count, 1)
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.board, BoardID(owner: h.p), "undoing it shows its board")
        expectEqual(editor.relays(on: BoardID(owner: h.p)).count, 0)
    },
    test("several edges in one run: each makes its own relay, beside its own start, one step") {
        let h = Harbor()
        let editor = try h.editor()
        let result = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep"
            edge "Hub" -> "Pier"
            """, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected", "created", "connected", "created", "connected"].map { Optional($0) }.compactMap { $0 })
        expectEqual(rows(result).map { $0["line"] }, [1, 1, 2, 2, 3, 3])
        expectEqual(editor.relays().count, 3, "a relay for each edge, though two stand for Deep")
        expectEqual(editor.linkNames(), ["Hub -> relay Deep", "Dock -> relay Deep", "Hub -> relay Pier"])
        // None of them on another: they're kept clear of one another.
        let frames = editor.relays().map(\.frame)
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { expect(!a.intersects(b), "\(a) meets \(b)") } }
    },
    test("an edge's other attributes are the arrow's, and the stand-in's own side is the edge maker's") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        let result = try drawn(#"edge "Hub" -> "Deep" tone: warm caption: "calls""#, on: editor)
        expectEqual(rows(result).last, ["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay", "tone": "warm"])
        let link = try require(editor.document.shapes.first { $0.kind == Link.kind })
        expectEqual(link[Caption.self], "calls")
        expectEqual(log.requests.last?.attributes, ["tone": "warm"])
    },
])

/// A harbor with Hub open as well: a relay can stand for either end of an edge between boards.
private func openHarbor() -> Harbor {
    var harbor = Harbor()
    harbor.openHub = true
    return harbor
}

@MainActor let drawStandInPlaceTests = Suite("draw: an edge drawn through a stand-in is found where the stand-in is", [
    test("a run again that would draw on the start's board draws on the board the relay is on, and is unchanged: no second relay, no second arrow") {
        let h = openHarbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        // Restating Deep puts the run on P's board, where the relay for Hub goes, beside Deep.
        let first = try drawn("""
            tile "Deep"
            edge "Hub" -> "Deep"
            """, on: editor)
        expectEqual(first["on"]?["board"], .string(h.p.description))
        expectEqual(rows(first).map { $0["did"] }, ["unchanged", "created", "connected"])
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["relay Hub -> Deep"])
        let made = editor.file, revision = editor.revision
        // Alone, both ends can be stood for, so nothing says which board: the start's, Hub's, where
        // another relay would be drawn. The arrow is found where it is.
        let again = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        expectEqual(again["on"]?["board"], .string(h.p.description), "where the relay is")
        expectEqual(rows(again), [["line": 1, "did": "unchanged", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"]])
        expectEqual(messages(again), [])
        expectEqual(editor.file, made)
        expectEqual(editor.revision, revision)
        let boards: [BoardID] = [.root, BoardID(owner: h.p), BoardID(owner: h.q)]
        expectEqual(boards.reduce(0) { $0 + editor.relays(on: $1).count }, 1, "one relay in the file")
        expectEqual(boards.reduce(0) { $0 + editor.linkEnds(on: $1).count }, 1, "and one arrow")
        // `via: relay` asks for a relay for the end, beside the start. The arrow goes through one for
        // the start, so it's refused where the relay is, as it is on one board, and none is drawn.
        let via = try refused(#"edge "Hub" -> "Deep" via: relay"#, on: editor)
        expectEqual(via.reason, "invalid_value")
        expectEqual(via.message, #"the edge "Hub" -> "Deep" is drawn through a relay to "Hub""#)
        expectEqual(via.hint, #"write delete edge "Hub" -> "Deep" above this line to draw it through a relay"#)
        expectEqual(editor.file, made)
    },
    test("the same for an edge the other way round: the relay for the start is on the end's board, and a run again goes there") {
        let h = openHarbor()
        let editor = try h.editor()
        let first = try drawn("""
            tile "Hub"
            edge "Deep" -> "Hub"
            """, on: editor)
        expectEqual(first["on"]?["board"], "root")
        expectEqual(editor.linkNames(), ["relay Deep -> Hub"])
        let made = editor.file
        let again = try drawn(#"edge "Deep" -> "Hub""#, on: editor)
        expectEqual(again["on"]?["board"], "root", "Hub's board, not the start's")
        expectEqual(rows(again), [["line": 1, "did": "unchanged", "kind": "link", "from": "Deep", "to": "Hub", "via": "relay"]])
        expectEqual(editor.file, made)
        expectEqual(editor.relays(on: BoardID(owner: h.p)).count, 0)
        // Either way round for <->: drawn one way, found with either start.
        let both = try h.editor()
        _ = try drawn("tile \"Deep\"\nedge \"Hub\" <-> \"Deep\"", on: both)
        let bothMade = both.file
        for script in [#"edge "Hub" <-> "Deep""#, #"edge "Deep" <-> "Hub""#] {
            let result = try drawn(script, on: both)
            expectEqual(rows(result).map { $0["did"] }, ["unchanged"], script)
            expectEqual(result["on"]?["board"], .string(h.p.description), script)
        }
        expectEqual(both.file, bothMade)
    },
    test("delete edge goes to the board the relay is on too: it takes the arrow and the relay, and undone, both are back") {
        let h = openHarbor()
        let editor = try h.editor()
        _ = try drawn("tile \"Deep\"\nedge \"Hub\" -> \"Deep\"", on: editor)
        let made = editor.file
        // Alone it would be Hub's board, where nothing is drawn from Hub to Deep.
        let result = try drawn(#"delete edge "Hub" -> "Deep""#, on: editor)
        expectEqual(result["on"]?["board"], .string(h.p.description))
        expectEqual(rows(result), [["line": 1, "did": "deleted", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"],
                                   ["line": 1, "did": "deleted", "kind": "relay"]])
        expectEqual(editor.relays(on: BoardID(owner: h.p)).count, 0)
        expectEqual(editor.linkEnds(on: BoardID(owner: h.p)).count, 0)
        editor.undo()
        expectEqual(editor.file, made)
        // The edge the other way round isn't drawn: Deep to Hub is nothing_to_delete, drawing nothing.
        expectEqual(try refused(#"delete edge "Deep" -> "Hub""#, on: editor).reason, "nothing_to_delete")
        expectEqual(editor.file, made)
    },
    test("an edge drawn through a relay claims that board hard: a statement that claims another is several_boards, never a second relay") {
        let h = openHarbor()
        let editor = try h.editor()
        _ = try drawn("tile \"Deep\"\nedge \"Hub\" -> \"Deep\"", on: editor)
        let made = editor.file
        let result = try refused("""
            tile "Extra" in "Q"
            edge "Hub" -> "Deep"
            """, on: editor)
        expectEqual(result.reason, "several_boards")
        expectEqual(result.message, #"this script draws on "Q"'s board (in "Q", line 1) and on "P"'s board ("Deep")"#, "the shape the relay is beside, on its board")
        expectEqual(result.data?["line"], 2)
        expectEqual(editor.file, made)
    },
    test("an edge that isn't drawn yet claims as it did, and one that is drawn the other way round isn't the edge") {
        let h = openHarbor()
        let editor = try h.editor()
        _ = try drawn("tile \"Deep\"\nedge \"Hub\" -> \"Deep\"", on: editor)
        // Deep to Hub is another edge: nothing's drawn, so it's Deep's board, as the start's.
        let other = try drawn(#"edge "Deep" -> "Hub""#, on: editor)
        expectEqual(other["on"]?["board"], .string(h.p.description))
        expectEqual(rows(other).map { $0["did"] }, ["created", "connected"])
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["relay Hub -> Deep", "Deep -> relay Hub"])
    },
    test("only an edge between two boards looks at a board's arrows, each board once a run") {
        let h = openHarbor()
        let editor = try h.editor()
        @MainActor func reads(_ script: String) throws -> Int {
            let before = DrawPlugin.boardConnectionsRead
            _ = try drawn(script, on: editor)
            return DrawPlugin.boardConnectionsRead - before
        }
        expectEqual(try reads("tile \"Dock\"\ntile \"Gate\" below \"Dock\""), 0, "no edge")
        expectEqual(try reads(#"edge "Hub" -> "Dock""#), 0, "an edge on one board")
        expectEqual(try reads("tile \"Skiff\"\nedge \"Skiff\" -> \"Hub\""), 0, "an edge to a shape the script draws")
        // Three edges between the root and P's or Q's board: three boards, whatever the edges.
        expectEqual(try reads("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Pier"
            edge "Hub" -> "Reef"
            """), 3)
        expectEqual(editor.relays().count, 3)
    },
])

@MainActor let drawStandInClosedTests = Suite("draw: an edge drawn through a stand-in for a shape that can't be stood for any more", [
    test("a run again is unchanged, with via too, and a script that restates the end that stays too: what it stands for is no concern") {
        let h = Harbor()
        let editor = try h.editor()
        // Hub can't be stood for, and Deep can: the run is on Hub's board.
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        editor.transact(on: BoardID(owner: h.p), "Close") { $0.update(h.deep) { $0.meta[Open.self] = nil } }
        let made = editor.file
        for script in [#"edge "Hub" -> "Deep""#, #"edge "Hub" -> "Deep" via: relay"#] {
            let result = try drawn(script, on: editor)
            expectEqual(result["on"]?["board"], "root", script)
            expectEqual(rows(result), [["line": 1, "did": "unchanged", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"]], script)
            expectEqual(editor.file, made, script)
        }
        let restated = try drawn("tile \"Hub\"\nedge \"Hub\" -> \"Deep\"", on: editor)
        expectEqual(rows(restated).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(editor.file, made)
        // A change to the arrow still goes through.
        let warmer = try drawn(#"edge "Hub" -> "Deep" tone: warm"#, on: editor)
        expectEqual(rows(warmer).map { $0["did"] }, ["reconnected"])
        expectEqual(editor.relays().count, 1)
        // And an edge to it that isn't drawn yet is refused, as it always was: Gate can't be stood for either.
        let none = try refused(#"edge "Gate" -> "Deep""#, on: editor)
        expectEqual(none.reason, "several_boards")
    },
    test("delete edge takes the arrow and the relay for a start that's closed since: the relay stands for it still") {
        let h = openHarbor()
        let editor = try h.editor()
        _ = try drawn("tile \"Deep\"\nedge \"Hub\" -> \"Deep\"", on: editor)
        // Hub is closed now, and the relay for it, with its arrow, is the edge still.
        editor.transact { $0.update(h.hub) { $0.meta[Open.self] = nil } }
        let result = try drawn(#"delete edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["deleted", "deleted"])
        expectEqual(result["on"]?["board"], .string(h.p.description))
        expectEqual(editor.relays(on: BoardID(owner: h.p)).count, 0)
        expectEqual(editor.linkEnds(on: BoardID(owner: h.p)).count, 0)
    },
])

@MainActor let drawStandInDrawnEndTests = Suite("draw: an edge to a shape the script draws", [
    test("the script's shape is on the board the run draws on: a relay for the shape elsewhere goes beside it, where in names") {
        let h = Harbor(), log = EdgeLog()
        let editor = try h.editor(log: log)
        // Dock is open, on the root; Skiff goes on P's board.
        let result = try drawn("""
            tile "Skiff" in "P"
            edge "Skiff" -> "Dock"
            """, on: editor)
        expectEqual(result["on"]?["board"], .string(h.p.description))
        let relay = try require(editor.relays(on: BoardID(owner: h.p)).first)
        expectEqual(relay.props.stands.map(\.shape), [h.dock])
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["Skiff -> relay Dock"])
        expectEqual(editor.relays().count, 0)
        expectEqual(rows(result).map { $0["did"] }, ["created", "created", "connected"])
        expectEqual(rows(result).last?["via"], "relay")
        expectEqual(messages(result), [])
        let skiff = try require(editor.contents(of: BoardID(owner: h.p)).shapes.first { $0.typed(as: Tile.self)?.props.label == "Skiff" })
        expectEqual(relay.frame.minX, try require(skiff.box).maxX + 80, "right of Skiff, which is the start")
        // The far shape may be the start: the relay is left of Skiff, and the arrow runs out of it.
        let reverse = try drawn("""
            tile "Barge" in "P"
            edge "Dock" -> "Barge"
            """, on: editor)
        expectEqual(reverse["on"]?["board"], .string(h.p.description))
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["Skiff -> relay Dock", "relay Dock -> Barge"])
        expectEqual(rows(reverse).last?["via"], "relay")
        expectEqual(messages(reverse), [])
    },
    test("placed against a shape on another board, the script's shape is on that board, and via: puts the relay beside it the same") {
        let h = Harbor()
        let editor = try h.editor()
        let result = try drawn("""
            tile "Skiff" above "Deep"
            edge "Skiff" -> "Dock" via: relay
            """, on: editor)
        expectEqual(result["on"]?["board"], .string(h.p.description))
        expectEqual(editor.relays(on: BoardID(owner: h.p)).first?.props.stands.map(\.shape), [h.dock])
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["Skiff -> relay Dock"])
        expectEqual(messages(result), [])
    },
    test("with nothing else to say, the run draws on the board of the end the file has, and the edge is straight there, as it always was") {
        let h = Harbor()
        let editor = try h.editor()
        // Deep can be stood for, Shut can't: either way the run is on P's board, and the new shape joins them straight.
        for (new, end) in [("Skiff", "Deep"), ("Barge", "Shut")] {
            let result = try drawn("tile \"\(new)\"\nedge \"\(new)\" -> \"\(end)\"", on: editor)
            expectEqual(result["on"]?["board"], .string(h.p.description), end)
            expectEqual(editor.relays(on: BoardID(owner: h.p)).count, 0, end)
        }
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)), ["Skiff -> Deep", "Barge -> Shut"])
        // The first of such edges decides, when no statement claims a board: a later one's end is reached through a relay.
        let two = try drawn("""
            tile "Raft"
            edge "Raft" -> "Pier"
            edge "Raft" -> "Reef"
            """, on: editor)
        expectEqual(two["on"]?["board"], .string(h.p.description), "Pier's board, the first edge's")
        expectEqual(editor.relays(on: BoardID(owner: h.p)).first?.props.stands.map(\.shape), [h.reef])
        expectEqual(editor.linkNames(on: BoardID(owner: h.p)).suffix(2), ["Raft -> Pier", "Raft -> relay Reef"])
    },
    test("a shape that can't be stood for claims its board hard, as an end of an edge between boards does, and the hint asks for it to be opened") {
        let h = Harbor()
        let editor = try h.editor()
        let made = editor.file
        let result = try refused("""
            tile "Skiff" in "P"
            edge "Skiff" -> "Gate"
            """, on: editor)
        expectEqual(result.reason, "several_boards")
        expectEqual(result.message, #"this script draws on "P"'s board (in "P", line 1) and on the root board ("Gate")"#)
        expectEqual(result.hint, #"an arrow can't leave its board: it goes into a relay standing for the shape on the other board, and only an open shape can be stood for; ask the user to make "Gate" open, or split the script into a run for each board"#)
        expectEqual(result.data?["line"], 2)
        // With nothing that stands in, the hint is the old one.
        let plain = try h.editor(relays: relaysPlugin(tool: false))
        let none = try refused("tile \"Skiff\" in \"P\"\nedge \"Skiff\" -> \"Dock\"", on: plain)
        expectEqual(none.hint, "a run draws on one board: split the script into a run for each")
        expectEqual(editor.file, made)
    },
])

@MainActor let drawStandInLockedTests = Suite("draw: a stand-in that would land in a read-only container", [
    test("the hint names the sides, since a stand-in has no placement a script can change; the side it names puts it clear") {
        let h = Harbor(), refusals = RefusalLog()
        let editor = try h.editor([pens, FreezingPlugin(log: refusals)])
        // A locked pen over where the relay for Deep would go, right of Hub, with a buoy in it.
        let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 580, y: 100, width: 200, height: 200), label: "Pen")))
        editor.transact { $0.insert(pen) }
        tile("Buoy", CGRect(x: 600, y: 120, width: 60, height: 40), in: editor)
        editor.freeze([pen.id])
        let before = editor.file, step = editor.undoHistory.undoName
        let result = try refused(#"edge "Hub" -> "Deep""#, on: editor)
        expectEqual(result.reason, "read_only")
        expectEqual(result.message, #"the relay to "Deep" would go in "Pen", which is read-only (locked, say)"#)
        expectEqual(result.hint, #"name another side for it with from: or to: to put it clear of "Pen", or ask the user to unlock it"#)
        expectEqual(editor.file, before, "nothing committed")
        expectEqual(editor.undoHistory.undoName, step)
        // Below Hub it's clear of the pen.
        let below = try drawn(#"edge "Hub" -> "Deep" from: bottom"#, on: editor)
        expectEqual(rows(below).map { $0["did"] }, ["created", "connected"])
        expectEqual(editor.relays().count, 1)
        // A shape with placements of its own keeps the hint that names them.
        let shape = try refused(#"tile "Y" inside "Pen" bottom-right"#, on: editor)
        expectEqual(shape.hint, #"place it clear of "Pen", or ask the user to unlock it"#)
    },
])

/// A shoal: Hub alone near the root's top, Rock below-left of it, and pocket P far below, whose board
/// holds open tiles Deep, Pier, Reef, Kelp and Lagoon (each relay to one 56 wide, Lagoon's 72).
@MainActor struct Shoal {
    let p = ShapeID(), hub = ShapeID()

    var file: CanvasFile {
        let center = AnyShapeRecord(ShapeRecord(id: hub, Tile(CGRect(x: 400, y: 150, width: 120, height: 80), label: "Hub")))
        let rock = AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 100, y: 600, width: 120, height: 80), label: "Rock")))
        var pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 400, y: 800, width: 100, height: 100))))
        pocket[Nickname.self] = "P"
        let far = ["Deep", "Pier", "Reef", "Kelp", "Lagoon"].enumerated().map { index, label in
            var record = AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 150 + 200 * CGFloat(index), y: 150, width: 120, height: 80), label: label)))
            record.meta[Open.self] = true
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [center, rock, pocket]), children: [p: CanvasDocument(shapes: far)])
    }

    func editor(_ more: [any CanvasPlugin] = []) throws -> CanvasEditor {
        let editor = try drawEditor([TopologyPlugin(), PocketsPlugin(), namedPockets, relaysPlugin()] + more)
        editor.replaceFile(with: file)
        return editor
    }
}

extension CanvasEditor {
    /// Each relay on the root by what it says, with its frame.
    func relayFrames() -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: relays().map { ($0.props.says, $0.frame) })
    }
}

@MainActor let drawStandInColumnTests = Suite("draw: the stand-ins beside a shape are a column", [
    test("those beside one shape on one side are a list of their own, 16 apart, lined up as one") {
        let editor = try Shoal().editor()
        let result = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            edge "Hub" -> "Reef"
            """, on: editor)
        let frames = editor.relayFrames()
        expectEqual(frames["Deep"], CGRect(x: 600, y: 114, width: 56, height: 40), "centered on Hub as one column")
        expectEqual(frames["Pier"], CGRect(x: 600, y: 170, width: 56, height: 40))
        expectEqual(frames["Reef"], CGRect(x: 600, y: 226, width: 56, height: 40))
        expectEqual(rows(result).compactMap { $0["pushedPast"] }, [])
    },
    test("a shape the script places beside it as they are is no member: it's where it says, and they give way past it as one, each said") {
        let editor = try Shoal().editor()
        let result = try drawn("""
            tile "H" right of "Hub"
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            """, on: editor)
        expectEqual(shape("H", in: editor)?.box, CGRect(x: 600, y: 150, width: 120, height: 80), "centered on Hub, as right of says")
        let frames = editor.relayFrames()
        expectEqual(frames["Deep"], CGRect(x: 760, y: 142, width: 56, height: 40), "past H, still a column centered on Hub")
        expectEqual(frames["Pier"], CGRect(x: 760, y: 198, width: 56, height: 40))
        expectEqual(rows(result).map { $0["pushedPast"] }, [nil, ["H"], nil, nil, nil])
        expectEqual(messages(result), [
            #"the relay to "Deep" was pushed right past "H" to keep clear of it, so it no longer sits against "Hub" — name another side for it with from: or to:"#,
            #"the relay to "Pier" moved right along with the relay to "Deep", which was pushed past "H" to keep clear of it, so the relay to "Pier" no longer sits against "Hub" — name another side for the relay to "Deep" with from: or to:"#,
        ])
    },
    test("a column meeting a wall moves as one: the one that met it is pushed, the rest go along") {
        let editor = try Shoal().editor()
        tile("W", CGRect(x: 620, y: 175, width: 60, height: 20), in: editor)
        let result = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            edge "Hub" -> "Reef"
            """, on: editor)
        let frames = editor.relayFrames()
        expectEqual(frames.values.map(\.minX), [720, 720, 720], "only Pier's met W, and all three went past it")
        expectEqual(frames["Pier"]?.minY, 170, "down the page, where they were")
        expectEqual(rows(result).compactMap { $0["pushedPast"] }, [["W"]])
        expectEqual(messages(result), [
            #"the relay to "Deep" moved right along with the relay to "Pier", which was pushed past "W" to keep clear of it, so the relay to "Deep" no longer sits against "Hub" — name another side for the relay to "Pier" with from: or to:"#,
            #"the relay to "Pier" was pushed right past "W" to keep clear of it, so it no longer sits against "Hub" — name another side for it with from: or to:"#,
            #"the relay to "Reef" moved right along with the relay to "Pier", which was pushed past "W" to keep clear of it, so the relay to "Reef" no longer sits against "Hub" — name another side for the relay to "Pier" with from: or to:"#,
        ])
    },
    test("a later run's stand-ins join the column there: 16 past its end, lined up with it, as one list") {
        let editor = try Shoal().editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            """, on: editor)
        expectEqual(editor.relayFrames()["Pier"], CGRect(x: 600, y: 198, width: 56, height: 40))
        let later = try drawn("""
            edge "Hub" -> "Lagoon"
            edge "Hub" -> "Reef"
            """, on: editor)
        let frames = editor.relayFrames()
        expectEqual(frames["Lagoon"], CGRect(x: 600, y: 254, width: 72, height: 40), "below Pier's, left edges in line")
        expectEqual(frames["Reef"], CGRect(x: 600, y: 310, width: 56, height: 40))
        expectEqual(frames["Deep"]?.minY, 142, "the column already there stays")
        expectEqual(rows(later).compactMap { $0["pushedPast"] }, [])
        expectEqual(messages(later), [])
    },
    test("on the left their right edges are in line, below and above their middles, and above it grows up") {
        let editor = try Shoal().editor()
        _ = try drawn(#"edge "Deep" -> "Hub""#, on: editor)
        _ = try drawn(#"edge "Lagoon" -> "Hub""#, on: editor)
        var frames = editor.relayFrames()
        expectEqual(frames["Deep"], CGRect(x: 264, y: 170, width: 56, height: 40), "left of Hub")
        expectEqual(frames["Lagoon"], CGRect(x: 248, y: 226, width: 72, height: 40), "below it, right edges in line")
        _ = try drawn(#"edge "Hub" -> "Pier" from: bottom"#, on: editor)
        _ = try drawn(#"edge "Hub" -> "Kelp" from: bottom"#, on: editor)
        frames = editor.relayFrames()
        expectEqual(frames["Pier"], CGRect(x: 432, y: 310, width: 56, height: 40), "below Hub")
        expectEqual(frames["Kelp"], CGRect(x: 432, y: 366, width: 56, height: 40), "below that, middles in line")
        _ = try drawn(#"edge "Hub" -> "Reef" from: top"#, on: editor)
        let reef = try require(editor.relayFrames()["Reef"])
        expectEqual(reef, CGRect(x: 432, y: 30, width: 56, height: 40), "above Hub")
    },
    test("a column's end in the way of what's there: pushed past it, the push naming the stand-in it no longer sits against") {
        let editor = try Shoal().editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            """, on: editor)
        tile("W", CGRect(x: 590, y: 260, width: 80, height: 20), in: editor)
        let result = try drawn(#"edge "Hub" -> "Reef""#, on: editor)
        expectEqual(editor.relayFrames()["Reef"], CGRect(x: 600, y: 344, width: 56, height: 40), "down past W, still in line")
        expectEqual(messages(result).last,
                    #"the relay to "Reef" was pushed down past "W" to keep clear of it, so it no longer sits against the relay to "Pier" — name another side for it with from: or to:"#)
    },
    test("a stand-in dragged off elsewhere is no column: one across from the shape's middle is, past one dragged nearer") {
        let editor = try Shoal().editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let deep = try require(editor.relays().first)
        editor.transact { $0.update(deep.id) { $0.box?.origin = CGPoint(x: 900, y: 700) } }
        _ = try drawn(#"edge "Hub" -> "Pier""#, on: editor)
        expectEqual(editor.relayFrames()["Pier"], CGRect(x: 600, y: 170, width: 56, height: 40), "centered on Hub, as with no column")
        // Deep's, dragged right of Hub but nearer than Pier's column and below Hub, is passed over for it.
        editor.transact { $0.update(deep.id) { $0.box?.origin = CGPoint(x: 560, y: 400) } }
        _ = try drawn(#"edge "Hub" -> "Reef""#, on: editor)
        expectEqual(editor.relayFrames()["Reef"], CGRect(x: 600, y: 226, width: 56, height: 40), "below Pier's")
    },
    test("a column a frame the run moves carries off is left behind too: the new stand-in goes beside the shape") {
        let editor = try Shoal().editor([pens])
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Hub" -> "Pier"
            """, on: editor)
        let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 580, y: 120, width: 120, height: 140), label: "Pen")))
        editor.transact { $0.insert(pen) }
        editor.transact { $0.setContainer(editor.relays().map(\.id), to: pen.id) }
        let result = try drawn("""
            pen "Pen" below "Rock"
            edge "Hub" -> "Reef"
            """, on: editor)
        expectEqual(rows(result).compactMap { $0["did"]?.stringValue }, ["moved", "created", "connected"])
        let reef = try require(editor.relayFrames()["Reef"])
        expect(reef.minY != 254, "not joined below Pier's, which moved with the pen: \(reef)")
        expectEqual(reef.midY, 190, "centered on Hub")
    },
    test("a shape the run moves leaves its column behind: its new stand-ins go beside it where it lands") {
        let editor = try Shoal().editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        _ = try drawn("""
            tile "Hub" right of "Rock"
            edge "Hub" -> "Pier"
            """, on: editor)
        let hub = try require(shape("Hub", in: editor)?.box)
        expectEqual(hub, CGRect(x: 300, y: 600, width: 120, height: 80))
        expectEqual(editor.relayFrames()["Pier"], CGRect(x: 500, y: 620, width: 56, height: 40), "right of Hub where it is now, centered")
        expectEqual(editor.relayFrames()["Deep"], CGRect(x: 600, y: 170, width: 56, height: 40), "the old column stays where it was")
    },
])
