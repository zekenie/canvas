@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// `canvas draw` and containers within a board (a pen here, for a frame): `in "X"` puts a shape in X,
// within it; what a script puts down over a container's edge goes wholly in or out by the in-or-out
// rule, as by hand; a read-only container takes nothing; deleting one leaves what it holds; and one
// a script moves takes what it holds along.

/// A box that holds shapes on its board (`ShapeContaining`), as a frame does, which a tool places,
/// 400 × 300, and never under 120 × 80: what a script draws containers with. Called by its label.
struct Pen: BoxShapeProps {
    static let kind: ShapeKind = "pen"
    static let properties = Properties<Pen>(title: "Pen") {
        Property("frame", \.frame).required()
        Property("label", \.label).description("What the pen is called.")
    }
    var frame: CGRect
    var label: String

    init(_ frame: CGRect, label: String = "") {
        self.frame = frame
        self.label = label
    }
}

extension Pen {
    init() { self.init(.zero) }
}

struct PenDefinition {}

extension PenDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pen>, in context: RenderContext) {}
}

extension PenDefinition: ShapeContaining {}

let pens = Contributor(id: "pens") { registrar in
    registrar.shape(PenDefinition()) { pen in
        pen.tool(label: "Pen", systemImage: "square.dashed", placing: pen.placement(size: CGSize(width: 400, height: 300), minimumSize: CGSize(width: 120, height: 80)) { Pen() })
    }
}

/// An editor with names and edges, pens, frozen shapes (`FreezingPlugin`) and pockets.
@MainActor private func penEditor(_ log: RefusalLog = RefusalLog()) throws -> CanvasEditor {
    try drawEditor([pens, FreezingPlugin(log: log), PocketsPlugin(), namedPockets])
}

/// Puts a pen on the board, labeled, and what it holds in it.
@MainActor @discardableResult private func pen(_ label: String, _ frame: CGRect, holding held: [ShapeID] = [], in editor: CanvasEditor) -> ShapeID {
    let record = AnyShapeRecord(ShapeRecord(Pen(frame, label: label)))
    editor.transact { $0.insert(record) }
    if !held.isEmpty { editor.transact { $0.setContainer(held, to: record.id) } }
    return record.id
}

/// Pen "Pen" (0, 0, 400 × 300) holding tile "M" (150, 100, 120 × 80): M's right is at 270, the pen's
/// at 400.
@MainActor private struct PenBoard {
    let pen: ShapeID, m: ShapeID

    init(_ editor: CanvasEditor, size: CGSize = CGSize(width: 400, height: 300)) {
        let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(origin: .zero, size: size), label: "Pen")))
        editor.transact { $0.insert(pen) }
        m = tile("M", CGRect(x: 150, y: 100, width: 120, height: 80), in: editor).id
        editor.transact { [m] in $0.setContainer(m, to: pen.id) }
        self.pen = pen.id
    }
}

/// A row's bounds, as `[[x, y], [width, height]]`.
private func at(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> JSON {
    .array([.array([.number(Double(x)), .number(Double(y))]), .array([.number(Double(width)), .number(Double(height))])])
}

@MainActor let drawContainerTests = Suite("draw: containers", [
    test("in a pen puts a shape within it, against its top-left, 40 in, and in it; several, a list down from there") {
        let editor = try penEditor()
        let empty = pen("Pen", CGRect(x: 0, y: 0, width: 600, height: 500), in: editor)
        let result = try drawn(#"tile "A" in "Pen""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created"])
        expectEqual(rows(result).first?["at"], at(40, 40, 120, 80))
        expectEqual(editor.holder(of: try require(shape("A", in: editor)).id), empty)
        expectEqual(messages(result), [])
        expectEqual(result["on"]?["board"], "root")
        let list = try drawn(#"tile "B" in "Pen""# + "\n" + #"tile "C" in "Pen""#, on: editor)
        expectEqual(rows(list).map { $0["at"] }, [at(40, 184, 120, 80), at(40, 328, 120, 80)], "as a list, kept clear of A")
        expectEqual(["B", "C"].map { editor.holder(of: shape($0, in: editor)!.id) }, [empty, empty])
    },
    test("in may name a pen that has no title by its id: the shape goes within it as for a title, a shape with none restated in it moves in, and a shape that holds nothing is cannot_contain") {
        let editor = try penEditor()
        let empty = pen("", CGRect(x: 0, y: 0, width: 600, height: 500), in: editor)
        let result = try drawn("tile \"A\" in #\(empty)", on: editor)
        expectEqual(rows(result).first?["at"], at(40, 40, 120, 80))
        expectEqual(editor.holder(of: try require(shape("A", in: editor)).id), empty)
        expectEqual(result["on"]?["board"], "root")
        let out = tile("", CGRect(x: 800, y: 600, width: 120, height: 80), in: editor)
        let moved = try drawn("tile #\(out.id) in #\(empty)", on: editor)
        expectEqual(rows(moved).map { $0["did"] }, ["moved"])
        expectEqual(rows(moved).first?["id"], .string(out.id.description))
        expectEqual(editor.holder(of: out.id), empty)
        expectEqual(try refused("tile \"B\" in #\(out.id)", on: editor).reason, "cannot_contain")
    },
    test("in a pen with placements keeps the shape within it as they place it; one that won't fit, or that they'd put outside it, is no_room") {
        let editor = try penEditor()
        let board = PenBoard(editor)
        // 40 in from the pen's bottom, at 260, so right below M, at 180.
        _ = try drawn(#"tile "Below" in "Pen" below "M" (gap: none)"#, on: editor)
        let below = try require(shape("Below", in: editor))
        expectEqual(below.box, CGRect(x: 150, y: 180, width: 120, height: 80))
        expectEqual(editor.holder(of: below.id), board.pen)
        let big = try refused(#"tile "Big" in "Pen" size: 400x80"#, on: editor)
        expectEqual(big.reason, "no_room")
        expectEqual(big.message, #""Big" is in "Pen", and there's no room left in "Pen""#)
        expectEqual(big.hint, #"make "Pen" bigger, or this smaller"#)
        expectEqual(try refused(#"tile "Far" in "Pen" right of "M""#, on: editor).reason, "no_room")
        expectEqual(editor.document.shapes.count, 3, "nothing drawn")
    },
    test("in a pen, a shape placed against a sibling that would cross the pen's inner edge only on the axis its placement leaves free slides along it, keeping its side of the sibling, and says so") {
        let editor = try penEditor()
        _ = pen("Pen", CGRect(x: 0, y: 0, width: 800, height: 700), in: editor)
        let first = try drawn(#"tile "A" in "Pen""#, on: editor)
        expectEqual(rows(first).first?["at"], at(40, 40, 120, 80))
        // Right of A (40..160 wide at 40, so gap past 160), a tall one centered on A's middle (80): it would start at -70.
        let right = try drawn(#"tile "R" in "Pen" right of "A" size: 120x300"#, on: editor)
        let r = try require(shape("R", in: editor)).box ?? .zero
        expectEqual(r.minY, 40, "slid down to the inset")
        expect(r.minX > 160, "right of A still")
        expectEqual(messages(right), [#""R" was slid down to stay inside "Pen""#])
    },
    test("in a pen, left of, below and above slide the same way: along the axis the placement leaves free, inside the pen, and said") {
        // M is at (150, 100), 120 × 80: its middle is at (210, 140). Each script on a board of its own, so none is in another's way.
        @MainActor func fresh() throws -> CanvasEditor {
            let editor = try penEditor()
            _ = PenBoard(editor, size: CGSize(width: 600, height: 500))
            return editor
        }
        var editor = try fresh()
        let left = try drawn(#"tile "L" in "Pen" left of "M" (gap: tight) size: 60x300"#, on: editor)
        let l = try require(shape("L", in: editor)).box ?? .zero
        expect(l.maxX < 150, "left of M: \(l)")
        expectEqual(l.minY, 40, "centered on M's middle it would start at -10: slid down")
        expectEqual(messages(left), [#""L" was slid down to stay inside "Pen""#])
        editor = try fresh()
        let below = try drawn(#"tile "B" in "Pen" below "M" size: 500x40"#, on: editor)
        let b = try require(shape("B", in: editor)).box ?? .zero
        expect(b.minY > 180, "below M: \(b)")
        expectEqual(b.minX, 40, "centered it would start at -40: slid right")
        expectEqual(messages(below), [#""B" was slid right to stay inside "Pen""#])
        editor = try fresh()
        let above = try drawn(#"tile "U" in "Pen" above "M" (gap: tight) size: 500x20"#, on: editor)
        let u = try require(shape("U", in: editor)).box ?? .zero
        expect(u.maxY < 100, "above M: \(u)")
        expectEqual(u.minX, 40)
        expect(messages(above).contains(#""U" was slid right to stay inside "Pen""#), "\(messages(above))")
    },
    test("in a pen, a shape that would cross the far edge slides back: left of the pen's right inset, up from its bottom one") {
        let editor = try penEditor()
        _ = PenBoard(editor, size: CGSize(width: 600, height: 500))
        // E sits right of M, centered on its middle across (y 140); W below E, 500 wide, centered on E's middle (x ~ 360 + 50).
        _ = try drawn(#"tile "E" in "Pen" right of "M" size: 100x40"#, on: editor)
        let e = try require(shape("E", in: editor)).box ?? .zero
        let wide = try drawn(#"tile "W" in "Pen" below "E" size: 480x40"#, on: editor)
        let w = try require(shape("W", in: editor)).box ?? .zero
        expect(w.minY > e.maxY, "below E: \(w)")
        expectEqual(w.maxX, 560, "centered it would end at \(e.midX + 240): slid left to the inset")
        expectEqual(messages(wide), [#""W" was slid left to stay inside "Pen""#])
    },
    test("in a pen, a shape centered on a tile near the pen's bottom slides up, not past the inset") {
        let editor = try penEditor()
        _ = pen("Pen", CGRect(x: 0, y: 0, width: 800, height: 500), in: editor)
        _ = try drawn(#"tile "A" in "Pen""#, on: editor)
        _ = try drawn(#"tile "X" in "Pen" below "A" (gap: 200)"#, on: editor)
        let x = try require(shape("X", in: editor)).box ?? .zero
        // X's middle is at 360: 260 tall, Y would run 230 to 490, past the 460 the inset leaves.
        let result = try drawn(#"tile "Y" in "Pen" right of "X" size: 100x260"#, on: editor)
        let y = try require(shape("Y", in: editor)).box ?? .zero
        expect(y.minX > x.maxX, "right of X: \(y)")
        expectEqual(y.maxY, 460, "slid up to the inset")
        expectEqual(messages(result), [#""Y" was slid up to stay inside "Pen""#])
    },
    test("in a pen, a shape too tall for it on the free axis is still no_room, and one that just fits slides to the inset") {
        let editor = try penEditor()
        _ = pen("Pen", CGRect(x: 0, y: 0, width: 800, height: 400), in: editor)
        _ = try drawn(#"tile "A" in "Pen""#, on: editor)
        let tall = try refused(#"tile "T" in "Pen" right of "A" size: 120x340"#, on: editor)
        expectEqual(tall.reason, "no_room")
        expectEqual(tall.message, #""T" is in "Pen", and there's no room left in "Pen""#)
        expectEqual(editor.document.shapes.count, 2, "nothing drawn")
        // Fits exactly (400 - 80 = 320): slides to the inset.
        let fits = try drawn(#"tile "F" in "Pen" right of "A" size: 120x320"#, on: editor)
        let f = try require(shape("F", in: editor)).box ?? .zero
        expectEqual(f.minY, 40)
        expectEqual(messages(fits), [#""F" was slid down to stay inside "Pen""#])
    },
    test("in a pen, two shapes of different widths below one sibling, in one script, slide into it together: the wider one in, the other still centered under it") {
        let editor = try penEditor()
        _ = pen("Pen", CGRect(x: 0, y: 0, width: 800, height: 700), in: editor)
        let script = """
        tile "A" in "Pen"
        tile "B1" in "Pen" below "A" size: 100x40
        tile "B2" in "Pen" below "A" size: 200x40
        """
        let result = try drawn(script, on: editor)
        let b1 = try require(shape("B1", in: editor)).box ?? .zero, b2 = try require(shape("B2", in: editor)).box ?? .zero
        expectEqual(b2.minX, 40, "the wide one at the inset: centered on A it would start at 0")
        expectEqual(b1.midX, b2.midX, "the list stays one column")
        expect(b1.minY > 120 && b2.minY > b1.maxY, "below A, B2 under B1: \(b1) \(b2)")
        expectEqual(messages(result), [#""B2" was slid right to stay inside "Pen""#])
    },
    test("in a pen, a slid shape that lands on a sibling is kept clear of it as any shape is: slid first, then pushed past it, both said, and the same script drawn again leaves it unchanged") {
        let editor = try penEditor()
        _ = pen("Pen", CGRect(x: 0, y: 0, width: 800, height: 700), in: editor)
        _ = try drawn(#"tile "A" in "Pen""#, on: editor)
        _ = try drawn(#"tile "S" in "Pen" right of "A" (gap: tight) size: 120x80"#, on: editor)
        let s = try require(shape("S", in: editor)).box ?? .zero
        expectEqual(s, CGRect(x: 200, y: 40, width: 120, height: 80))
        let script = #"tile "R" in "Pen" right of "A" size: 120x300"#
        let result = try drawn(script, on: editor)
        let r = try require(shape("R", in: editor)).box ?? .zero
        expectEqual(r, CGRect(x: 360, y: 40, width: 120, height: 300), "slid down to the inset, then right past S")
        expectEqual(messages(result), [#""R" was slid down to stay inside "Pen""#,
                                      #""R" was pushed right past "S" to keep clear of it, so it no longer sits against "A" — place it on another side, or say overlap: allow"#])
        // An agent redraws the same script: the shape is where it was.
        let again = try drawn(script, on: editor)
        expectEqual(rows(again).first?["did"], "unchanged")
        expectEqual(try require(shape("R", in: editor)).box, r)
        expectEqual(messages(again), messages(result))
    },
    test("a shape in the pen restated stays where it is; one elsewhere restated in it moves in, against its top-left") {
        let editor = try penEditor()
        let board = PenBoard(editor, size: CGSize(width: 600, height: 500))
        let restated = try drawn(#"tile "M" in "Pen" finish: glossy"#, on: editor)
        expectEqual(rows(restated).map { $0["did"] }, ["updated"])
        expectEqual(editor.document[board.m]?.box, CGRect(x: 150, y: 100, width: 120, height: 80))
        let out = tile("Out", CGRect(x: 800, y: 600, width: 120, height: 80), in: editor)
        let moved = try drawn(#"tile "Out" in "Pen""#, on: editor)
        expectEqual(rows(moved).map { $0["did"] }, ["moved"])
        expectEqual(editor.document[out.id]?.box, CGRect(x: 310, y: 40, width: 120, height: 80), "pushed right past M, within the pen")
        expectEqual(editor.holder(of: out.id), board.pen)
    },
    test("put down over a pen's edge, a shape goes wholly in or out, by most of its area: nudged, said, and gliding there") {
        let editor = try penEditor()
        let board = PenBoard(editor)
        // Right of M, 80 out: (350, 100); 120 wide, 50 of it inside: out, to 16 past the edge.
        let out = try drawn(#"tile "O" right of "M""#, on: editor, ["--dry-run"])
        expectEqual(rows(out).first?["at"], at(416, 100, 120, 80))
        expectEqual(messages(out), [#""O" was over the edge of "Pen", so it was nudged out"#])
        // 90 wide, 50 of it inside: in, to 16 inside the edge.
        let into = try drawn(#"tile "N" right of "M" size: 90x80"#, on: editor)
        expectEqual(rows(into).first?["at"], at(294, 100, 90, 80))
        expectEqual(messages(into), [#""N" was over the edge of "Pen", so it was nudged in"#])
        let n = try require(shape("N", in: editor)).id
        expectEqual(editor.holder(of: n), board.pen)
        expectEqual(editor.drawingOffset(of: n), CGPoint(x: 56, y: 0), "drawn where it was placed, gliding in")
        // Wholly inside, it goes in with nothing to say.
        let inside = try drawn(#"tile "I" below "M" (gap: tight)"#, on: editor)
        expectEqual(messages(inside), [])
        expectEqual(editor.holder(of: try require(shape("I", in: editor)).id), board.pen)
    },
    test("a read-only pen takes nothing: in it is refused, and so is a run that would put a shape in it; what's in it is read-only too") {
        let log = RefusalLog()
        let editor = try penEditor(log)
        let board = PenBoard(editor)
        editor.freeze([board.pen])
        let before = editor.document, step = editor.undoHistory.undoName
        let into = try refused(#"tile "X" in "Pen""#, on: editor)
        expectEqual(into.reason, "read_only")
        expectEqual(into.message, #""Pen" is read-only (locked, say), so nothing goes in it"#)
        expectEqual(into.hint, #"leave in "Pen" out, or ask the user to unlock it"#)
        let inside = try refused(#"tile "Y" inside "Pen" bottom-right"#, on: editor)
        expectEqual(inside.reason, "read_only")
        expectEqual(inside.message, #""Y" would go in "Pen", which is read-only (locked, say)"#)
        expectEqual(inside.hint, #"place it clear of "Pen", or ask the user to unlock it"#)
        expectEqual(try refused(#"tile "M" finish: glossy"#, on: editor).reason, "read_only", "M is in a locked pen")
        expectEqual(try refused(#"delete "M""#, on: editor).reason, "read_only")
        expectEqual(editor.document, before, "nothing committed")
        expectEqual(editor.undoHistory.undoName, step, "and no step")
        expectEqual(log.refusals, [], "an agent's refused run shakes nothing")
    },
    test("deleting a pen leaves what it holds where it is, in what held the pen; one holding a locked shape is deleted all the same") {
        let editor = try penEditor()
        let inner = tile("T", CGRect(x: 60, y: 60, width: 120, height: 80), in: editor).id
        let innerPen = pen("Inner", CGRect(x: 40, y: 40, width: 300, height: 200), holding: [inner], in: editor)
        let outer = pen("Outer", CGRect(x: 0, y: 0, width: 600, height: 400), holding: [innerPen], in: editor)
        editor.freeze([inner])
        let result = try drawn(#"delete "Inner""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["deleted"])
        expectEqual(messages(result), [])
        expectEqual(editor.document[innerPen], nil)
        expectEqual(editor.holder(of: inner), outer, "in what held it")
        expectEqual(editor.document[inner]?.box, CGRect(x: 60, y: 60, width: 120, height: 80))
        editor.undo()
        expectEqual(editor.holder(of: inner), innerPen)
        editor.freeze([outer])
        expectEqual(try refused(#"delete "Inner""#, on: editor).reason, "read_only", "in a locked pen")
    },
    test("a run with pens is one step: undone, the board is as it was; a dry run changes nothing") {
        let editor = try penEditor()
        let board = PenBoard(editor, size: CGSize(width: 600, height: 500))
        let before = editor.document, step = editor.undoHistory.undoName
        let script = #"tile "A" in "Pen""# + "\n" + #"tile "N" below "M""#
        let dry = try drawn(script, on: editor, ["--dry-run"])
        expectEqual(dry["dryRun"], true)
        expectEqual(editor.document, before)
        expectEqual(editor.undoHistory.undoName, step)
        let real = try drawn(script, on: editor)
        expectEqual(rows(real).map { $0["at"] }, rows(dry).map { $0["at"] }, "a dry run says what a real one does")
        expectEqual(messages(real), messages(dry))
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.document, before)
        editor.redo()
        expectEqual(["A", "N"].map { editor.holder(of: shape($0, in: editor)!.id) }, [board.pen, board.pen])
    },
    test("in a pen this script draws is unsupported; in the shape itself, or one it holds, is circular") {
        let editor = try penEditor()
        _ = PenBoard(editor)
        let drawnHere = try refused(#"pen "New" right of "Pen""# + "\n" + #"tile "T" in "New""#, on: editor)
        expectEqual(drawnHere.reason, "unsupported")
        expectEqual(drawnHere.data?["line"], 2)
        let itself = try refused(#"pen "Pen" in "Pen""#, on: editor)
        expectEqual(itself.reason, "circular")
        expectEqual(itself.message, #""Pen" is in itself"#)
        let inner = pen("Inner", CGRect(x: 1000, y: 0, width: 200, height: 200), in: editor)
        let outer = pen("Outer", CGRect(x: 950, y: -50, width: 400, height: 400), holding: [inner], in: editor)
        expectEqual(editor.holder(of: inner), outer)
        let holding = try refused(#"pen "Outer" in "Inner""#, on: editor)
        expectEqual(holding.reason, "circular")
        expectEqual(holding.message, #""Outer" holds "Inner", so it can't be in it"#)
    },
    test("a pen a placement moves takes what it holds along, and isn't kept clear of it; a placement against what it holds is refused") {
        let editor = try penEditor()
        let board = PenBoard(editor)
        tile("Left", CGRect(x: -200, y: 0, width: 120, height: 80), in: editor)
        // Right of Left, 80 on, centered on it: (0, -110), over where M was.
        let result = try drawn(#"pen "Pen" right of "Left""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["moved"])
        expectEqual(rows(result).first?["at"], at(0, -110, 400, 300))
        expectEqual(editor.document[board.m]?.box, CGRect(x: 150, y: -10, width: 120, height: 80), "taken along")
        expectEqual(editor.holder(of: board.m), board.pen)
        let against = try refused(#"pen "Pen" below "Left""# + "\n" + #"tile "X" below "M""#, on: editor)
        expectEqual(against.reason, "unsupported")
        expectEqual(against.message, #""X" is below "M", and "M" moves with "Pen", which this script moves"#)
        // Restated with placements of its own, a shape it holds goes where they say.
        _ = try drawn(#"pen "Pen" below "Left""# + "\n" + #"tile "M" right of "Left""#, on: editor)
        let m = try require(editor.document[board.m]?.box)
        expectEqual(m.origin, CGPoint(x: 0, y: 0), "right of Left, as its placement says")
        expectEqual(editor.holder(of: board.m), nil, "and out of the pen, which is below it now")
    },
    test("a pen locked or unlocked by the statement that moves it takes what it holds along either way") {
        let editor = try penEditor()
        let board = PenBoard(editor)
        tile("Left", CGRect(x: -200, y: 0, width: 120, height: 80), in: editor)
        _ = try drawn(#"pen "Pen" right of "Left" frozen: true"#, on: editor)
        expect(editor.isReadOnly(board.pen))
        expectEqual(editor.document[board.m]?.box, CGRect(x: 150, y: -10, width: 120, height: 80))
        _ = try drawn(#"pen "Pen" below "Left" frozen: false"#, on: editor)
        expect(!editor.isReadOnly(board.pen))
        let pen = try require(editor.document[board.pen]?.box)
        expectEqual(editor.document[board.m]?.box, CGRect(x: pen.minX + 150, y: pen.minY + 100, width: 120, height: 80))
    },
    test("pens one run moves are each judged where the others land: one moved over most of where another was goes where it's placed, pushed past nothing and nudged into nothing") {
        let editor = try penEditor()
        tile("Anchor", CGRect(x: -600, y: 0, width: 120, height: 80), in: editor)
        let ma = tile("MA", CGRect(x: 90, y: 60, width: 120, height: 80), in: editor).id
        let mb = tile("MB", CGRect(x: 490, y: 60, width: 120, height: 80), in: editor).id
        let a = pen("A", CGRect(x: 0, y: 0, width: 300, height: 200), holding: [ma], in: editor)
        let b = pen("B", CGRect(x: 400, y: 0, width: 300, height: 200), holding: [mb], in: editor)
        // A to (450, 0), over 250 of B's 300 columns, MB's among them; B to (450, 300), below where A lands.
        for allow in ["", " overlap: allow"] {
            let script = #"pen "A" right of "Anchor" left (gap: 1050) below "Anchor" top (gap: none)"# + allow + "\n"
                + #"pen "B" right of "Anchor" left (gap: 1050) below "Anchor" top (gap: 300)"# + allow
            let result = try drawn(script, on: editor)
            expectEqual(rows(result).map { $0["at"] }, [at(450, 0, 300, 200), at(450, 300, 300, 200)], allow)
            expectEqual(rows(result).map { $0["pushedPast"] }, [nil, nil], allow)
            expectEqual(messages(result), [], allow)
            expectEqual(editor.document[ma]?.box, CGRect(x: 540, y: 60, width: 120, height: 80), allow)
            expectEqual(editor.document[mb]?.box, CGRect(x: 540, y: 360, width: 120, height: 80), allow)
            expectEqual([ma, mb, a, b].map { editor.holder(of: $0) }, [a, b, nil, nil], allow)
            editor.undo()
        }
    },
    test("a shape in a pen the run moves is kept clear of what the pen holds where the pen takes it, not where it was") {
        let editor = try penEditor()
        tile("Anchor", CGRect(x: -600, y: 0, width: 120, height: 80), in: editor)
        let m = tile("M", CGRect(x: 100, y: 60, width: 120, height: 80), in: editor).id
        let a = pen("A", CGRect(x: 0, y: 0, width: 440, height: 260), holding: [m], in: editor)
        // A to (360, 0), and M with it to (460, 60), under where N would land, 40 in from A's top-left.
        let result = try drawn(#"pen "A" right of "Anchor" left (gap: 960) below "Anchor" top (gap: none)"# + "\n" + #"tile "N" in "A""#, on: editor)
        expectEqual(rows(result).map { $0["at"] }, [at(360, 0, 440, 260), at(620, 40, 120, 80)])
        expectEqual(rows(result).last?["pushedPast"], ["M"])
        expectEqual(editor.document[m]?.box, CGRect(x: 460, y: 60, width: 120, height: 80))
        expectEqual(editor.holder(of: try require(shape("N", in: editor)).id), a)
    },
    test("right of board, in a run that moves a pen, is right of the shapes that stay, not of what the pen takes along") {
        let editor = try penEditor()
        tile("Anchor", CGRect(x: -600, y: 0, width: 120, height: 80), in: editor)
        let m = tile("M", CGRect(x: 90, y: 60, width: 120, height: 80), in: editor).id
        pen("A", CGRect(x: 0, y: 0, width: 300, height: 200), holding: [m], in: editor)
        // A to (-1100, -60), left of Anchor, with M; the board that stays is Anchor alone.
        let result = try drawn(#"pen "A" left of "Anchor" (gap: 200)"# + "\n" + #"tile "X" right of board"#, on: editor)
        expectEqual(rows(result).map { $0["at"] }, [at(-1100, -60, 300, 200), at(-400, 0, 120, 80)])
        expectEqual(editor.document[m]?.box, CGRect(x: -1010, y: 0, width: 120, height: 80))
    },
    test("resized where it stays, a pen puts what's over its new edge wholly in or out; a shape grown over its pen's edge is nudged too") {
        let editor = try penEditor()
        let board = PenBoard(editor)
        // 250 wide, M (150…270) is 100 of its 120 inside: nudged in, to 16 inside.
        let narrowed = try drawn(#"pen "Pen" size: 250x300"#, on: editor)
        expectEqual(rows(narrowed).map { $0["did"] }, ["moved"])
        expectEqual(messages(narrowed), [#"a shape over the edge of "Pen" was nudged wholly in or out of it"#])
        expectEqual(editor.document[board.m]?.box, CGRect(x: 114, y: 100, width: 120, height: 80))
        expectEqual(editor.holder(of: board.m), board.pen)
        editor.undo()
        // M 300 wide, from 150: 250 of it inside the pen's 400.
        let grown = try drawn(#"tile "M" size: 300x80"#, on: editor)
        expectEqual(rows(grown).first?["at"], at(84, 100, 300, 80))
        expectEqual(messages(grown), [#""M" was over the edge of "Pen", so it was nudged in"#])
    },
    test("a pen on another board: in it draws there, in it") {
        let pocket = ShapeID(), inner = ShapeID()
        var named = AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        named[Nickname.self] = "P"
        let file = CanvasFile(root: CanvasDocument(shapes: [named]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inner, Pen(CGRect(x: 0, y: 0, width: 400, height: 300), label: "Inner")))])])
        let editor = try penEditor()
        editor.replaceFile(with: file)
        let result = try drawn(#"tile "X" in "Inner""#, on: editor)
        expectEqual(result["on"]?["board"], .string(pocket.description))
        let board = editor.contents(of: BoardID(owner: pocket))
        let x = try require(board.shapes.first { $0.typed(as: Tile.self)?.props.label == "X" })
        expectEqual(board.container(of: x.id, containingKinds: editor.registry.containingKinds), inner)
        expectEqual(x.box, CGRect(x: 40, y: 40, width: 120, height: 80))
        expectEqual(editor.board, .root, "the window stays where it is")
    },
    test("kinds says what each kind holds, for in to name: shapes for a pen, a board for a pocket") {
        let editor = try penEditor()
        let all = try run(["kinds"], on: nil, registry: editor.registry).get().arrayValue ?? []
        func kind(_ name: String) -> JSON? { all.first { $0["kind"]?.stringValue == name } }
        expectEqual(kind("pen")?["holds"], "shapes")
        expectEqual(kind("pen")?["drawable"], true)
        expectEqual(kind("pocket")?["holds"], "board")
        expectEqual(kind("tile")?["holds"], nil)
    },
    test("a size under the smallest its placement draws is invalid_value, as a size too big is; kinds says it") {
        let editor = try penEditor()
        let before = editor.file
        let small = try refused(#"pen "Small" size: 100x50"#, on: editor)
        expectEqual(small.reason, "invalid_value")
        expectEqual(small.message, "size: 100x50 is too small: a pen is at least 120x80")
        expectEqual(small.hint, "write size: 120x80, or bigger")
        let flat = try refused(#"pen "Flat" right of board size: 300x40"#, on: editor)
        expectEqual(flat.hint, "write size: 300x80, or bigger", "only the side that's short grows")
        let styled = try refused("style slim size: 300x40\n" + #"pen "Slim" style: slim"#, on: editor)
        expectEqual(styled.reason, "invalid_value", "a style's size too")
        expectEqual(editor.file, before, "nothing drawn")
        // At the smallest it's drawn; one already smaller is left as it is when a script doesn't size it.
        expectEqual(rows(try drawn(#"pen "Least" size: 120x80"#, on: editor)).first?["at"]?.arrayValue?.last, [120, 80])
        pen("Tiny", CGRect(x: 1000, y: 0, width: 60, height: 40), in: editor)
        expectEqual(rows(try drawn(#"pen "Tiny""#, on: editor)).first?["did"], "unchanged")
        expectEqual(rows(try drawn(#"pen "Tiny" size: 60x40"#, on: editor)).first?["did"], "unchanged", "restated at the size it is, a run again")
        expectEqual(try refused(#"pen "Tiny" size: 60x50"#, on: editor).reason, "invalid_value", "but not to another size under it")
        // What has no smallest takes any size.
        expectEqual(rows(try drawn(#"tile "Speck" below "Least" size: 4x2"#, on: editor)).first?["did"], "created")
        let all = try run(["kinds"], on: nil, registry: editor.registry).get().arrayValue ?? []
        expectEqual(all.first { $0["kind"] == "pen" }?["smallest"], "120x80")
        expectEqual(all.first { $0["kind"] == "tile" }?["smallest"], nil)
    },
])
