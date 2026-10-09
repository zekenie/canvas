@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// `share:` on an edge through a stand-in: the arrow runs to a stand-in for the same end that is already
// beside the start's container, rather than to one of its own. `share: true` takes one for the end that
// the board has or an earlier edge of the run made; `share: "A"` takes the one A's own arrow goes into,
// and is refused when A has none, never a stand-in made silently. Over fixtures only, on the Harbor and
// pens the stand-in tests use: relays are the stand-ins, tiles the shapes, links the edges.

extension CanvasEditor {
    /// The relay a tile's link runs to (the first), by the tile's label.
    func relay(of label: String) -> ShapeID? {
        guard let tile = document.shapes.first(where: { $0.typed(as: Tile.self)?.props.label == label }) else { return nil }
        return linkEnds().first { $0.from == tile.id }?.to
    }
}

/// The Harbor with a pen on the root holding tiles A, B, C and D (a column, each with room right of it
/// for a relay), and a tile Out beside the pen.
@MainActor private func penned() throws -> (editor: CanvasEditor, pen: ShapeID) {
    let editor = try Harbor().editor([pens])
    let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 0, y: 600, width: 1000, height: 800), label: "Pen")))
    editor.transact { $0.insert(pen) }
    var held: [ShapeID] = []
    for (index, label) in ["A", "B", "C", "D"].enumerated() {
        held.append(tile(label, CGRect(x: 40, y: 640 + 180 * CGFloat(index), width: 120, height: 80), in: editor).id)
    }
    editor.transact { $0.setContainer(held, to: pen.id) }
    tile("Out", CGRect(x: 1200, y: 640, width: 120, height: 80), in: editor)
    return (editor, pen.id)
}

@MainActor let drawShareTests = Suite("draw: share: an edge through a stand-in takes one that is there", [
    test("share: true: the second and third arrows run to the first's relay, and their rows say shared") {
        let h = Harbor()
        let editor = try h.editor()
        let result = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            edge "Gate" -> "Deep" share: true
            """, on: editor)
        expectEqual(editor.relays().count, 1, "one relay for Deep")
        expectEqual(editor.linkNames(), ["Hub -> relay Deep", "Dock -> relay Deep", "Gate -> relay Deep"])
        let relay = try require(editor.relays().first)
        expectEqual(editor.linkEnds().map(\.to), [relay.id, relay.id, relay.id])
        let hub = try require(editor.file.record(h.hub)?.box)
        expect(relay.frame.minX > hub.maxX, "beside the first shape, the one that made it")
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected", "connected", "connected"])
        expectEqual(rows(result).map { $0["line"] }, [1, 1, 2, 3])
        expectEqual(rows(result)[1], ["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"], "the first made it: nothing shared")
        expectEqual(rows(result)[2], ["line": 2, "did": "connected", "kind": "link", "from": "Dock", "to": "Deep", "via": "relay", "shared": true])
        expectEqual(rows(result)[3], ["line": 3, "did": "connected", "kind": "link", "from": "Gate", "to": "Deep", "via": "relay", "shared": true])
        expectEqual(messages(result), [])
    },
    test("without share: each edge makes its own relay, as it always did") {
        let editor = try Harbor().editor()
        let result = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep"
            """, on: editor)
        expectEqual(editor.relays().count, 2)
        expectEqual(rows(result).compactMap { $0["shared"] }, [])
    },
    test("share: true with no relay for the end yet makes one, as without, and says nothing is shared") {
        let editor = try Harbor().editor()
        let result = try drawn(#"edge "Hub" -> "Deep" share: true"#, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected"])
        expectEqual(rows(result).compactMap { $0["shared"] }, [])
    },
    test("a later run's share: true joins the relay the board has, wherever it is on the board's container") {
        let editor = try Harbor().editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let relay = try require(editor.relays().first)
        let later = try drawn(#"edge "Dock" -> "Deep" share: true"#, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.relay(of: "Dock"), relay.id)
        expectEqual(rows(later), [["line": 1, "did": "connected", "kind": "link", "from": "Dock", "to": "Deep", "via": "relay", "shared": true]])
        // A relay for another end isn't one for Deep.
        let other = try drawn(#"edge "Gate" -> "Pier" share: true"#, on: editor)
        expectEqual(editor.relays().count, 2)
        expectEqual(rows(other).map { $0["did"] }, ["created", "connected"])
        // One a person put there counts as one the board has.
        let h = Harbor()
        let editor2 = try h.editor()
        let placed = editor2.addRelay(for: h.deep, says: "Deep")
        editor2.addLink(h.hub, placed)
        let joined = try drawn(#"edge "Dock" -> "Deep" share: true"#, on: editor2)
        expectEqual(editor2.relays().count, 1)
        expectEqual(editor2.relay(of: "Dock"), placed)
        expectEqual(rows(joined).count, 1)
    },
    test("share: \"A\" takes the relay A's own arrow goes into: in the same run, or one the board has") {
        let editor = try Harbor().editor()
        let one = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: "Hub"
            """, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.relay(of: "Dock"), editor.relay(of: "Hub"))
        expectEqual(rows(one).last, ["line": 2, "did": "connected", "kind": "link", "from": "Dock", "to": "Deep", "via": "relay", "shared": true, "sharedWith": "Hub"])
        let later = try drawn(#"edge "Gate" -> "Deep" share: "Hub""#, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.relay(of: "Gate"), editor.relay(of: "Hub"))
        expectEqual(rows(later), [["line": 1, "did": "connected", "kind": "link", "from": "Gate", "to": "Deep", "via": "relay", "shared": true, "sharedWith": "Hub"]])
        // The host may itself have shared.
        let chained = try drawn("""
            edge "Hub" -> "Pier"
            edge "Dock" -> "Pier" share: true
            edge "Gate" -> "Pier" share: "Dock"
            """, on: try Harbor().editor())
        expectEqual(rows(chained).last?["sharedWith"], "Dock")
    },
    test("share: \"A\" with the host's own edge below it is refused, as is a host with no relay for the end") {
        let editor = try Harbor().editor()
        let before = editor.file, step = editor.undoHistory.undoName
        let below = try refused("""
            edge "Dock" -> "Deep" share: "Hub"
            edge "Hub" -> "Deep"
            """, on: editor)
        expectEqual(below.reason, "invalid_value")
        expectEqual(below.message, #"edge "Dock" -> "Deep": share: "Hub" has no relay to "Deep" beside it"#)
        expectEqual(below.hint, #"draw an edge between "Hub" and "Deep" above this line, in this run or an earlier one; or write share: true, or leave share: out"#)
        expectEqual(below.data?["line"], 1)
        expectEqual(editor.file, before, "nothing committed, and no relay made for it")
        expectEqual(editor.undoHistory.undoName, step)
        // Hub's relay is for Pier, not Deep.
        _ = try drawn(#"edge "Hub" -> "Pier""#, on: editor)
        let other = try refused(#"edge "Dock" -> "Deep" share: "Hub""#, on: editor)
        expectEqual(other.reason, "invalid_value")
        expectEqual(other.message, #"edge "Dock" -> "Deep": share: "Hub" has no relay to "Deep" beside it"#)
        expectEqual(editor.relays().count, 1)
        // A dry run says the same.
        let dry = try refused(#"edge "Dock" -> "Deep" share: "Hub""#, on: editor, ["--dry-run"])
        expectEqual(dry.message, other.message)
    },
    test("share: \"A\" names a shape that is there, other than the edge's own start, and with its own relay: else it is refused, saying how") {
        let editor = try Harbor().editor()
        let none = try refused(#"edge "Dock" -> "Deep" share: "Nobody""#, on: editor)
        expectEqual(none.reason, "unknown_title")
        expectEqual(none.message, #"there's no shape called "Nobody""#)
        let own = try refused(#"edge "Dock" -> "Deep" share: "Dock""#, on: editor)
        expectEqual(own.reason, "invalid_value")
        expectEqual(own.message, #"edge "Dock" -> "Deep": share: "Dock" is the edge's own end"#)
        expectEqual(editor.relays().count, 0)
        expect(!editor.canUndo)
    },
    test("share: is for an edge that goes through a stand-in: one drawn straight is refused, via: or two boards make it one") {
        let editor = try Harbor().editor()
        let straight = try refused(#"edge "Hub" -> "Dock" share: true"#, on: editor)
        expectEqual(straight.reason, "invalid_value")
        expectEqual(straight.message, #"edge "Hub" -> "Dock": share: is for an edge that goes through a relay, and this one is drawn straight"#)
        expectEqual(straight.hint, "write via: relay to put one beside its start, or leave share: out")
        let via = try drawn("""
            edge "Hub" -> "Dock" via: relay
            edge "Gate" -> "Dock" via: relay share: true
            """, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.linkNames(), ["Hub -> relay Dock", "Gate -> relay Dock"])
        expectEqual(rows(via).last?["shared"], true)
    },
    test("share by a shape the script draws: its container is the board, so a shape on the board shares there") {
        let editor = try Harbor().editor()
        let result = try drawn("""
            tile "N" right of "Gate"
            edge "Hub" -> "Deep"
            edge "N" -> "Deep" share: true
            edge "Gate" -> "Deep" share: "Hub"
            """, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(rows(result).compactMap { $0["shared"] }, [true, true])
    },
    test("only within one container: a frame's shapes share its relay, a shape outside it does not and makes its own") {
        let (editor, pen) = try penned()
        let first = try drawn("""
            edge "A" -> "Deep"
            edge "B" -> "Deep" share: true
            edge "Out" -> "Deep" share: true
            """, on: editor)
        expectEqual(editor.relays().count, 2, "one for the frame's tiles, one for the tile outside it")
        expectEqual(editor.relay(of: "A"), editor.relay(of: "B"))
        expect(editor.relay(of: "Out") != editor.relay(of: "A"))
        expectEqual(rows(first).compactMap { $0["shared"] }, [true], "only B's arrow was shared")
        let inPen = try require(editor.relay(of: "A").flatMap { editor.document[$0] })
        expectEqual(editor.document.container(of: inPen.id, containingKinds: editor.registry.containingKinds), pen, "the relay beside A is in the pen")
        // A later run: C in the pen joins it; the board's relay is found by its container.
        let later = try drawn(#"edge "C" -> "Deep" share: true"#, on: editor)
        expectEqual(editor.relays().count, 2)
        expectEqual(editor.relay(of: "C"), editor.relay(of: "A"))
        expectEqual(rows(later).map { $0["shared"] }, [true])
    },
    test("two hosts in one frame: each keeps its group of arrows to its own relay, and share: \"A\" picks the group") {
        let (editor, _) = try penned()
        let result = try drawn("""
            edge "A" -> "Deep"
            edge "C" -> "Deep"
            edge "B" -> "Deep" share: "A"
            edge "D" -> "Deep" share: "C"
            """, on: editor)
        expectEqual(editor.relays().count, 2)
        expectEqual(editor.relay(of: "A"), editor.relay(of: "B"))
        expectEqual(editor.relay(of: "C"), editor.relay(of: "D"))
        expect(editor.relay(of: "A") != editor.relay(of: "C"))
        expectEqual(rows(result).filter { $0["kind"] == "link" }.map { $0["sharedWith"] }, [nil, nil, "A", "C"])
    },
    test("share: \"A\" with A in another container than the edge's start is refused, naming both") {
        let (editor, _) = try penned()
        _ = try drawn(#"edge "A" -> "Deep""#, on: editor)
        let before = editor.file
        let outside = try refused(#"edge "Out" -> "Deep" share: "A""#, on: editor)
        expectEqual(outside.reason, "invalid_value")
        expectEqual(outside.message, #"edge "Out" -> "Deep": share: "A" and "Out" aren't in the same container"#)
        expectEqual(outside.hint, "a reference is shared by shapes in one frame, or none: put them in the same one, or leave share: out")
        expectEqual(editor.file, before)
    },
    test("a run again: the arrows are unchanged with the same flags, and no relay or arrow is made") {
        let editor = try Harbor().editor()
        let script = """
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            edge "Gate" -> "Deep" share: "Hub"
            """
        _ = try drawn(script, on: editor)
        let made = editor.file, revision = editor.revision
        let again = try drawn(script, on: editor)
        expectEqual(rows(again), [
            ["line": 1, "did": "unchanged", "kind": "link", "from": "Hub", "to": "Deep", "via": "relay"],
            ["line": 2, "did": "unchanged", "kind": "link", "from": "Dock", "to": "Deep", "via": "relay", "shared": true],
            ["line": 3, "did": "unchanged", "kind": "link", "from": "Gate", "to": "Deep", "via": "relay", "shared": true, "sharedWith": "Hub"],
        ])
        expectEqual(messages(again), [])
        expectEqual(editor.file, made)
        expectEqual(editor.revision, revision)
        expectEqual(editor.relays().count, 1)
        // And an edge drawn without share: is not changed by a run that writes it with one.
        let plain = try Harbor().editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: plain)
        _ = try drawn(#"edge "Hub" -> "Deep" share: true"#, on: plain)
        expectEqual(plain.relays().count, 1)
        expectEqual(plain.linkEnds().count, 1)
    },
    test("delete edge keeps a shared relay while an arrow is on it, and takes it with the last") {
        let h = Harbor()
        let editor = try h.editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            edge "Gate" -> "Deep" share: true
            """, on: editor)
        let first = try drawn(#"delete edge "Hub" -> "Deep""#, on: editor)
        expectEqual(rows(first).map { $0["kind"] }, ["link"], "the host's arrow goes, the relay stays")
        expectEqual(editor.linkNames(), ["Dock -> relay Deep", "Gate -> relay Deep"])
        let second = try drawn(#"delete edge "Dock" -> "Deep""#, on: editor)
        expectEqual(rows(second).map { $0["kind"] }, ["link"])
        expectEqual(editor.relays().count, 1)
        let last = try drawn(#"delete edge "Gate" -> "Deep""#, on: editor)
        expectEqual(rows(last).map { $0["kind"] }, ["link", "relay"])
        expectEqual(editor.relays().count, 0)
        // And all of them in one run: the relay goes on the line that leaves it empty.
        let again = try Harbor().editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            """, on: again)
        let both = try drawn("""
            delete edge "Hub" -> "Deep"
            delete edge "Dock" -> "Deep"
            """, on: again)
        expectEqual(rows(both).map { $0["kind"] }, ["link", "link", "relay"])
        expectEqual(rows(both).map { $0["line"] }, [1, 2, 2])
        expectEqual(again.relays().count, 0)
    },
    test("delete \"X\" takes the relays X's arrows leave with none, and keeps a shared one: the host gone, the others still share it") {
        let editor = try Harbor().editor()
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            """, on: editor)
        let host = try drawn(#"delete "Hub""#, on: editor)
        expectEqual(rows(host).map { $0["kind"] }, ["tile", "link"], "the shape and its arrow; the relay stays")
        expectEqual(editor.relays().count, 1, "Dock's arrow is on it")
        // A later run still shares it, the host gone.
        _ = try drawn(#"edge "Gate" -> "Deep" share: true"#, on: editor)
        expectEqual(editor.relays().count, 1)
        _ = try drawn(#"delete "Dock""#, on: editor)
        expectEqual(editor.relays().count, 1, "Gate's is still on it")
        let last = try drawn(#"delete "Gate""#, on: editor)
        expectEqual(rows(last).map { $0["kind"] }, ["tile", "link", "relay"])
        expectEqual(editor.relays().count, 0)
    },
    test("a relay the run deletes is not shared: the edge below makes a new one") {
        let editor = try Harbor().editor()
        _ = try drawn(#"edge "Hub" -> "Deep""#, on: editor)
        let result = try drawn("""
            delete edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            """, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.linkNames(), ["Dock -> relay Deep"])
        expectEqual(rows(result).compactMap { $0["shared"] }, [])
        expectEqual(rows(result).map { $0["did"] }, ["deleted", "deleted", "created", "connected"])
    },
    test("one undo takes the relay and every arrow of the run back, and a redo brings them; a dry run changes nothing") {
        let editor = try Harbor().editor()
        let before = editor.file, step = editor.undoHistory.undoName
        let dry = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            edge "Gate" -> "Deep" share: true
            """, on: editor, ["--dry-run"])
        expectEqual(rows(dry).count, 4)
        expectEqual(editor.file, before)
        expectEqual(editor.undoHistory.undoName, step)
        _ = try drawn("""
            edge "Hub" -> "Deep"
            edge "Dock" -> "Deep" share: true
            edge "Gate" -> "Deep" share: true
            """, on: editor)
        let made = editor.file
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.file, before, "the relay and the three arrows")
        editor.redo()
        expectEqual(editor.file, made)
    },
    test("across boards: either end may be the far one, and the relay for a start is shared as one for an end is") {
        let h = Harbor()
        let editor = try h.editor()
        // The far end is the start: the relay is left of the end that stays, and runs into it.
        let result = try drawn("""
            edge "Deep" -> "Hub"
            edge "Deep" -> "Dock" share: true
            """, on: editor)
        expectEqual(editor.relays().count, 1)
        expectEqual(editor.relays().first?.props.stands.map(\.shape), [h.deep])
        expectEqual(editor.linkNames(), ["relay Deep -> Hub", "relay Deep -> Dock"])
        expectEqual(rows(result).last, ["line": 2, "did": "connected", "kind": "link", "from": "Deep", "to": "Dock", "via": "relay", "shared": true])
        // Another far shape is another relay, one on another board another still.
        let more = try drawn("""
            edge "Hub" -> "Pier" share: true
            edge "Dock" -> "Pier" share: true
            edge "Gate" -> "Reef" share: true
            """, on: editor)
        expectEqual(editor.relays().count, 3, "Deep's, Pier's and Reef's")
        expectEqual(rows(more).compactMap { $0["shared"] }, [true])
        // A run again, from either side: unchanged.
        let again = try drawn("""
            edge "Deep" -> "Hub"
            edge "Deep" -> "Dock" share: true
            """, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(rows(again).last?["shared"], true)
        expectEqual(editor.relays().count, 3)
        // Deleting the edge from the far end's board keeps the shared relay while another arrow is on it.
        let gone = try drawn(#"delete edge "Deep" -> "Hub""#, on: editor)
        expectEqual(rows(gone).map { $0["kind"] }, ["link"])
        expectEqual(editor.relays().count, 3)
    },
])
