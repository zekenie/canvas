@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import LineRows
import Selection
import TestKit

// Making room below a tally as its entries grow (`MakesRoomAsItGrows`, the core's push): a row committed pushes the
// tally below it down in the same step; the waiting line, the width while typing and a fold are views, and push nothing.
// A tally is 20 world units a line and 10 above and below them; one 2 entries tall at (100, 100) ends at 160.

@MainActor let roomTests = Suite("Making room", [
    test("a row committed pushes the tally below down by its line, in its step; the waiting line pushes nothing") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])
        let below = b.tally("pears", ["bosc"], at: CGPoint(x: 100, y: 180))          // a gap of 20
        b.begin(id)
        expectEqual(try require(b.frame(id)).maxY, 180, "the waiting line drawn: a line taller")
        expectEqual(b.frame(below)?.minY, 180, "not pushed for a line nobody wrote")
        b.type("blue")
        b.press(.return)
        expectEqual(b.labels(id), ["red", "green", "blue"])
        expectEqual(b.frame(below)?.minY, 200, "pushed by the line written, the gap of 20 kept")
        expectEqual(b.undoName, "Add Entry")
        b.type("gold")
        b.press(.return)
        expectEqual(b.frame(below)?.minY, 220)
        b.press(.escape)
        expectEqual(b.frame(below)?.minY, 220, "ending editing moves nothing")
        b.editor.undo()
        expectEqual(b.labels(id), ["red", "green", "blue"])
        expectEqual(b.frame(below)?.minY, 200, "one Undo takes the line and the move")
    },
    test("a long line laid out wider while it's typed moves nothing, and nothing goes sideways") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])
        let beside = b.tally("pears", ["bosc"], at: CGPoint(x: 360, y: 100))
        b.begin(id)
        b.type(String(repeating: "w", count: 60))
        expect((b.frame(id)?.width ?? 0) > 260, "laid out wider than it stores")
        expectEqual(b.frame(beside)?.origin, CGPoint(x: 360, y: 100))
        b.press(.escape)
    },
    test("a fold and an unfold move nothing, nor does editing a folded tally show its every row") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green", "blue 2", "pink", "gold"])    // 120 tall: ends at 220
        b.editor.selectedShapeIDs = [id]
        b.press(.controlCommandUp)                                                    // 80 tall: ends at 180
        let below = b.tally("pears", ["bosc"], at: CGPoint(x: 100, y: 190))
        b.editor.selectedShapeIDs = [id]
        b.press(.controlCommandDown)
        expectEqual(b.frame(id)?.maxY, 220, "unfolded over it")
        expectEqual(b.frame(below)?.minY, 190, "a view: nothing pushed")
        b.press(.controlCommandUp)
        b.begin(id)
        expectEqual(b.frame(below)?.minY, 190, "every row shown while it's edited: nothing pushed")
        b.press(.escape)
        expectEqual(b.frame(below)?.minY, 190)
    },
    test("a row taken out pulls nothing up") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green", "blue"])                         // ends at 180
        let below = b.tally("pears", ["bosc"], at: CGPoint(x: 100, y: 190))
        b.editor.transact("Delete Entry") { $0.update(id, as: Tally.self) { $0.props.rows.removeLast() } }
        expectEqual(b.frame(below)?.minY, 190)
    },
])
