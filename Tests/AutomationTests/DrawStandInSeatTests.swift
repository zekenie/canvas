@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// A stand-in an edge makes for a shape whose title another shape has (one of the file's, or one the run
// draws) is told where it sits (`StandIns.seat`), so it says where its shape is beside the name and is as
// wide as that: in what holds it (the edge's `in`), else in the frame of the shape beside it, else on the
// board. One for a shape whose title is its alone is told nothing. `measure` tells one where it sits when
// the end is written as a path: in the containers the path names, from those of the start's. Over the
// Harbor's relays, which say where they're told they sit (`relaySeating`), and a pen.

/// The Harbor with a second Deep (open) on Q's board, a pen on the root holding tiles A and B, and a tile
/// Out beside the pen.
@MainActor private func seated() throws -> CanvasEditor {
    let harbor = Harbor()
    let editor = try harbor.editor([pens], relays: relaysPlugin(seats: true))
    var deep = AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 400, y: 150, width: 120, height: 80), label: "Deep")))
    deep.meta[Open.self] = true
    editor.transact(on: BoardID(owner: harbor.q)) { $0.insert(deep) }
    let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 0, y: 600, width: 1000, height: 800), label: "Pen")))
    editor.transact { $0.insert(pen) }
    let held = ["A", "B"].enumerated().map { index, label in
        tile(label, CGRect(x: 40, y: 640 + 180 * CGFloat(index), width: 120, height: 80), in: editor).id
    }
    editor.transact { $0.setContainer(held, to: pen.id) }
    tile("Out", CGRect(x: 1200, y: 640, width: 120, height: 80), in: editor)
    return editor
}

/// The pills of measure's answer, as a tool reads them.
private struct Measured: Decodable {
    struct Pill: Decodable { let size: [Double] }
    let references: [Pill]
}

/// How wide `canvas measure` says the first pill of `script` is.
@MainActor private func pillWidth(measuring script: String, on editor: CanvasEditor) throws -> Double? {
    let measured = try run(["measure", "-"], on: editor, input: script).get()
    return try measured.decode(Measured.self).references.first?.size.first
}

@MainActor let drawStandInSeatTests = Suite("draw: a stand-in for a shape whose title another has is told where it sits", [
    test("beside a start in a frame it sits in the frame, beside one on the board on the board, as wide as it then says; a run again changes nothing") {
        let editor = try seated()
        let script = """
            edge "A" -> "P" > "Deep"
            edge "Out" -> "Q" > "Deep"
            """
        let dry = try drawn(script, on: editor, ["--dry-run"])
        let result = try drawn(script, on: editor)
        expectEqual(withoutIDs(rows(dry)), withoutIDs(rows(result)), "a dry run says what the real run does")
        expectEqual(editor.linkNames(), ["A -> relay Deep in Pen", "Out -> relay Deep in the board"])
        for relay in editor.relays() { expectEqual(relay.props.frame.width, Relay.width(saying: relay.props.says), "fitted to what it says") }
        let made = editor.file
        expectEqual(rows(try drawn(script, on: editor)).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(editor.file, made)
    },
    test("one for a shape whose title is its alone is told nothing") {
        let editor = try seated()
        _ = try drawn(#"edge "A" -> "Reef""#, on: editor)
        expectEqual(editor.linkNames(), ["A -> relay Reef"])
    },
    test("a title the run gives another shape counts, and one only a shape the run deletes has doesn't") {
        let editor = try seated()
        _ = try drawn("""
            tile board > "Reef" right of "Out"
            edge "A" -> "Q" > "Reef"
            """, on: editor)
        expectEqual(editor.relays().map(\.props.says), ["Reef in Pen"], "the run draws a second Reef")
        // A second Pier, on the root, that the run deletes: P's is the only Pier left.
        let deleting = try seated()
        tile("Pier", CGRect(x: 1200, y: 300, width: 120, height: 80), in: deleting)
        _ = try drawn("""
            delete board > "Pier"
            edge "A" -> "P" > "Pier"
            """, on: deleting)
        expectEqual(deleting.relays().map(\.props.says), ["Pier"])
        let kept = try seated()
        tile("Pier", CGRect(x: 1200, y: 300, width: 120, height: 80), in: kept)
        _ = try drawn(#"edge "A" -> "P" > "Pier""#, on: kept)
        expectEqual(kept.relays().map(\.props.says), ["Pier in Pen"], "and with it kept, two")
        // Q's Deep goes with Q's board, which the run deletes: P's is the only Deep left.
        let pocketed = try seated()
        _ = try drawn("""
            delete "Q"
            edge "A" -> "P" > "Deep"
            """, on: pocketed)
        expectEqual(pocketed.relays().map(\.props.says), ["Deep"])
    },
    test("an edge that says where its stand-in goes seats it in what holds it there, and it lands there at that size") {
        let editor = try seated()
        _ = try drawn(#"edge "Out" -> "P" > "Deep" in "Pen" right of "Pen" left (gap: 400) below "Pen" top (gap: 130)"#, on: editor)
        let relay = try require(editor.relays().first)
        expectEqual(relay.props.says, "Deep in Pen", "in the pen, though Out, the shape it would go beside, is on the board")
        expectEqual(relay.props.frame, CGRect(x: 400, y: 730, width: Relay.width(saying: "Deep in Pen"), height: 40))
    },
    test("an edge's in that names a subboard seats its stand-in at the top of that board, not in the frame of the shape beside it") {
        let harbor = Harbor()
        let editor = try harbor.editor([pens], relays: relaysPlugin(seats: true))
        var deep = AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 400, y: 150, width: 120, height: 80), label: "Deep")))
        deep.meta[Open.self] = true
        editor.transact(on: BoardID(owner: harbor.q)) { $0.insert(deep) }
        let inner = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 0, y: 600, width: 600, height: 400), label: "Inner")))
        let shore = AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 40, y: 640, width: 120, height: 80), label: "Shore")))
        editor.transact(on: BoardID(owner: harbor.p)) { transaction in
            transaction.insert(inner)
            transaction.insert(shore)
            transaction.setContainer([shore.id], to: inner.id)
        }
        _ = try drawn(#"edge "Shore" -> "Q" > "Deep" in "P" right of "Inner" (gap: 100)"#, on: editor)
        expectEqual(editor.relays(on: BoardID(owner: harbor.p)).map(\.props.says), ["Deep in the board"])
    },
    test("measure seats the pill of an end written as a path: in the containers the path names, from those of the start's path") {
        let editor = try seated()
        expectEqual(try pillWidth(measuring: #"edge "Pen" > "A" -> "P" > "Deep" via: relay"#, on: editor), Double(Relay.width(saying: "Deep in P from Pen")))
        expectEqual(try pillWidth(measuring: #"edge "A" -> "P" > "Deep" via: relay"#, on: editor), Double(Relay.width(saying: "Deep in P")), "a start named by its title alone sits at the top")
        expectEqual(try pillWidth(measuring: #"edge "A" -> "Reef" via: relay"#, on: editor), Double(Relay.width(saying: "Reef")), "an end named by its title alone is told nothing")
        let a = try require(shape("A", in: editor)).id
        expectEqual(try pillWidth(measuring: #"edge #\#(a) -> "P" > "Deep" via: relay"#, on: editor), Double(Relay.width(saying: "Deep")), "nor one whose start is named by its id")
    },
])
