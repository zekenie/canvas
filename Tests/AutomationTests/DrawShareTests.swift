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

/// The Harbor with a pen "Fold" on the root (1400, 0, 600 × 400) holding tile "E" (1700, 200), its top-left clear.
@MainActor private func folded() throws -> (editor: CanvasEditor, fold: ShapeID) {
    let editor = try Harbor().editor([pens])
    let fold = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 1400, y: 0, width: 600, height: 400), label: "Fold")))
    editor.transact { $0.insert(fold) }
    let e = tile("E", CGRect(x: 1700, y: 200, width: 120, height: 80), in: editor)
    editor.transact { $0.setContainer(e.id, to: fold.id) }
    return (editor, fold.id)
}

// An edge through a stand-in may say where the stand-in it makes goes, in a shape's placements and `in`: there,
// placed as a shape statement is, instead of beside its end. What a tool that lays a board out writes for a
// stand-in several shapes share, which it puts between them: the first edge places it, the others share it.
@MainActor let drawStandInPlacedTests = Suite("draw: an edge's placements put the stand-in it makes", [
    test("an exact offset in a frame: the relay lands there and in it, and the frame's others share it") {
        let (editor, pen) = try penned()
        let script = """
            edge "A" -> "Deep" in "Pen" right of "Pen" left (gap: 400) below "Pen" top (gap: 130)
            edge "B" -> "Deep" share: "A"
            edge "C" -> "Deep" share: "A"
            """
        let before = editor.file
        let dry = try drawn(script, on: editor, ["--dry-run"])
        expectEqual(editor.file, before, "a dry run changes nothing")
        let result = try drawn(script, on: editor)
        expectEqual(withoutIDs(rows(dry)), withoutIDs(rows(result)), "and says what the real run does")
        expectEqual(editor.relays().count, 1)
        let relay = try require(editor.relays().first)
        expectEqual(relay.frame.origin, CGPoint(x: 400, y: 730), "its top-left that far from the pen's")
        expectEqual(editor.document.container(of: relay.id, containingKinds: editor.registry.containingKinds), pen, "in the pen")
        expectEqual(editor.linkNames(), ["A -> relay Deep", "B -> relay Deep", "C -> relay Deep"])
        let changes = rows(result)
        expectEqual(changes.map { $0["did"] }, ["created", "connected", "connected", "connected"])
        expectEqual(changes[0]["kind"], "relay")
        expectEqual(changes[0]["pushedPast"], nil)
        expectEqual(changes[3], ["line": 3, "did": "connected", "kind": "link", "from": "C", "to": "Deep", "via": "relay", "shared": true, "sharedWith": "A"])
        expectEqual(messages(result).filter { !$0.contains("outside the view") }, [], "nothing pushed, nothing over an edge (the pen is below the view)")
        // A run again is the same edges: unchanged, the relay where it is, whatever the placement says now.
        let made = editor.file
        let again = try drawn(script.replacingOccurrences(of: "(gap: 400)", with: "(gap: 600)"), on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(editor.file, made)
    },
    test("in alone puts the relay against the frame's top-left, 40 in, as a shape in one goes") {
        let (editor, fold) = try folded()
        _ = try drawn(#"edge "E" -> "Deep" in "Fold""#, on: editor)
        let relay = try require(editor.relays().first)
        expectEqual(relay.frame.origin, CGPoint(x: 1440, y: 40))
        expectEqual(editor.document.container(of: relay.id, containingKinds: editor.registry.containingKinds), fold)
    },
    test("a relay an edge places is held to its placements as a shape is: pushed past what it lands on, said, with what to change") {
        let (editor, _) = try penned()
        // Over B's right end: less of it across than down, so it goes right, past B.
        let result = try drawn(#"edge "A" -> "Deep" right of "B" left (gap: 100) below "B" top (gap: 10)"#, on: editor)
        let relay = try require(editor.relays().first), b = try require(shape("B", in: editor)?.box)
        expectEqual(relay.frame.origin, CGPoint(x: b.maxX + 40, y: b.minY + 10), "pushed right, clear of B by the clearance, and still 10 below its top")
        expectEqual(rows(result).first?["pushedPast"], ["B"])
        expectEqual(messages(result).filter { !$0.contains("outside the view") },
                    [#"the relay to "Deep" was pushed right past "B" to keep clear of it, so it no longer sits against "B" left — place it on another side"#])
    },
    test("share: true with placements makes the relay there when there's none to share, and takes the one there is when there is") {
        let (editor, _) = try penned()
        let result = try drawn("""
            edge "A" -> "Deep" share: true in "Pen" right of "Pen" left (gap: 400) below "Pen" top (gap: 130)
            edge "B" -> "Deep" share: true in "Pen" right of "Pen" left (gap: 600) below "Pen" top (gap: 130)
            """, on: editor)
        expectEqual(editor.relays().count, 1, "B shares the relay A's edge made in the pen, so it places none")
        expectEqual(editor.relays().first?.frame.origin, CGPoint(x: 400, y: 730))
        expectEqual(rows(result).compactMap { $0["shared"] }, [true])
    },
    test("an edge drawn straight places nothing: a placement on one is refused, and on one drawn through a relay already it changes nothing") {
        let editor = try Harbor().editor()
        let straight = try refused(#"edge "Hub" -> "Dock" right of "Gate""#, on: editor)
        expectEqual(straight.reason, "invalid_value")
        expectEqual(straight.message, #"edge "Hub" -> "Dock": right of "Gate" places the relay an edge goes through, and this one is drawn straight"#)
        expectEqual(straight.hint, #"write via: relay to put one there, or leave right of "Gate" out"#)
        expectEqual(editor.relays().count, 0)
        expect(!editor.canUndo)
        // With via: it places one; written again, through the relay it is, the edge is unchanged and the relay stays.
        _ = try drawn(#"edge "Hub" -> "Dock" via: relay below "Gate""#, on: editor)
        let relay = try require(editor.relays().first), gate = try require(shape("Gate", in: editor)?.box)
        expectEqual(relay.frame.minY, gate.maxY + 80, "below Gate")
        expectEqual(relay.frame.midX, gate.midX)
        let made = editor.file
        for script in [#"edge "Hub" -> "Dock" via: relay right of "Gate""#, #"edge "Hub" -> "Dock" right of "Gate""#] {
            let again = try drawn(script, on: editor)
            expectEqual(rows(again).map { $0["did"] }, ["unchanged"], script)
            expectEqual(editor.file, made, script)
        }
    },
    test("what its placements and in name is on the board the run draws on, or the run is refused for drawing on two") {
        let (editor, _) = try penned()
        let before = editor.file
        // Shut is on P's board and can't be stood for, so the run is there; the pen is on the root.
        let held = try refused(#"edge "Shut" -> "Dock" in "Pen""#, on: editor)
        expectEqual(held.reason, "several_boards")
        // A placement against a shape on another board, the same.
        let far = try refused(#"edge "A" -> "Deep" right of "Pier""#, on: editor)
        expectEqual(far.reason, "several_boards")
        // A frame this script draws holds nothing yet.
        let drawnHere = try refused("""
            pen "Later" right of "Gate"
            edge "A" -> "Deep" in "Later"
            """, on: editor)
        expectEqual(drawnHere.reason, "unsupported")
        expectEqual(editor.file, before)
    },
])
