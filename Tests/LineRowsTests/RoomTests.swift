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
    test("a tally laid out wider while it's typed is painted, and hit, above the tally beside it that its widening overlaps, back in its place as editing ends") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])
        let beside = b.tally("pears", ["bosc"], at: CGPoint(x: 360, y: 100))
        let overlap = CGRect(x: 360, y: 100, width: 40, height: 40)
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [beside], "apart at rest")
        b.begin(id)
        b.type("w")
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [beside], "not wider yet: nothing of it where the pears are")
        b.type(String(repeating: "w", count: 60))
        expect((b.frame(id)?.width ?? 0) > 300, "laid out across the pears")
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [beside, id], "painted above what it now overlaps")
        expectEqual(b.editor.shape(at: CGPoint(x: 370, y: 125)), id, "and hit there first")
        expectEqual(b.frame(beside)?.origin, CGPoint(x: 360, y: 100), "nothing moved")
        b.press(.escape)
        expectEqual(b.editor.paintOrder(in: CGRect(x: 100, y: 100, width: 400, height: 60)).map(\.id), [id, beside], "back in its place")
    },
    test("a tally laid out taller by its waiting line is painted, and hit, above the tally under it, and says where its room beyond its box is, for what is drawn over the shapes (pills) to leave out; back as editing ends") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])                                  // stored 240 by 40, laid out to 160
        let below = b.tally("pears", ["bosc"], at: CGPoint(x: 100, y: 170))
        let overlap = CGRect(x: 120, y: 165, width: 40, height: 10)
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [below], "apart at rest")
        expect(b.editor.editedShapeOverflow == nil, "nothing edited: no room beyond a box")
        b.begin(id)
        expectEqual(try require(b.frame(id)).maxY, 180, "the waiting line drawn: a line taller")
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [below, id], "painted above what its waiting line overlaps")
        expectEqual(b.editor.shape(at: CGPoint(x: 130, y: 170)), id, "and hit there first")
        let overflow = try require(b.editor.editedShapeOverflow)
        expectEqual(overflow.id, id)
        expectEqual(overflow.areas, [CGRect(x: 100, y: 160, width: 240, height: 20)],
                    "its room under its frame at rest, the waiting line's alone: never from the box it stores, a row shorter (review R25)")
        expectEqual(b.frame(below)?.origin, CGPoint(x: 100, y: 170), "nothing moved")
        b.press(.escape)
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [below], "back in its place")
        expect(b.editor.editedShapeOverflow == nil)
    },
    test("a tally whose stored height is a row's, edited at a row with no waiting line shown and no line wider, is not lifted over the tally under its rows; once a row commits and its rows at rest grow, it still isn't (review R25)") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green", "blue", "pink", "gold"])           // stores 240 by 40, lays out to 120 at rest
        let under = b.tally("pears", ["bosc"], at: CGPoint(x: 100, y: 150))            // inside the rows' room at rest, under the box it stores
        let overlap = CGRect(x: 120, y: 150, width: 40, height: 10)
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [id, under], "at rest")
        b.begin(id, at: CGPoint(x: 130, y: 120))
        expect(b.focus?.hasPrefix("row") == true, "the caret in a row: \(b.focus ?? "none")")
        expect(b.editor.editedShapeOverflow == nil, "laid out as it is at rest: no room beyond it")
        expectEqual(b.editor.paintOrder(in: overlap).map(\.id), [id, under], "not lifted from a box a row tall")
        b.press(.escape)
        b.begin(id)
        b.type("plum")
        b.press(.return)
        b.press(.escape)
        b.begin(id, at: CGPoint(x: 130, y: 120))
        expect(b.editor.editedShapeOverflow == nil, "a row more at rest: the frame at rest is its own, never lifted over the tally it pushed")
        b.press(.escape)
    },
    test("a line wider than the tally, committed, pushes only what is under the tally at rest, never what is under its widening") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])                                  // 100…360 across, ends at 160
        let under = b.tally("pears", ["bosc"], at: CGPoint(x: 100, y: 180))          // under it
        let wideSide = b.tally("plums", ["fig"], at: CGPoint(x: 380, y: 185))        // under only what typing widens it to
        b.begin(id)
        b.type(String(repeating: "w", count: 60))
        expect((b.frame(id)?.width ?? 0) > 280, "laid out wider than it stores, so wide it covers the plums' column")
        b.press(.return)
        expectEqual(b.frame(under)?.minY, 200, "what is under the tally pushed by the line")
        expectEqual(b.frame(wideSide)?.minY, 185, "not under it at rest: never pushed for a widening")
        b.press(.escape)
        expectEqual(b.frame(wideSide)?.minY, 185)
    },
    test("a row committed into a folded tally pushes by what its fold gains, not by the every row it shows while edited") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green", "blue 2", "pink", "gold"])    // 120 tall, 80 folded: ends at 180
        b.editor.selectedShapeIDs = [id]
        b.press(.controlCommandUp)
        let below = b.tally("pears", ["bosc"], at: CGPoint(x: 100, y: 200))          // a gap of 20 under the fold
        b.begin(id)
        b.type("plain")
        b.press(.return)
        expectEqual(b.frame(below)?.minY, 200, "a row the fold hides gains the folded tally nothing")
        b.type("plum 7")
        b.press(.return)
        b.press(.escape)
        expectEqual(b.frame(id)?.maxY, 200, "folded back to its marks, one more")
        expectEqual(b.frame(below)?.minY, 220, "pushed by the line the fold gained, the gap of 20 kept")
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
