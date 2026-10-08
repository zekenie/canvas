import CoreGraphics
import DrawScript
import TestKit

@MainActor let obstacleTests = Suite("Keeping clear of the board", [
    test("a box held from below is pushed on past what it lands on, and says so") {
        let drawn = draw(#"card "N" right of "P""#, on: Board([("P", rect(0, 0, 200, 100)), ("Q", rect(300, 0, 100, 100))]))
        expectRect(drawn["N"], rect(440, 0, 200, 100))
        expectEqual(drawn.pushedPast("N"), ["Q"])
        expectEqual(drawn.solution?.pushes, [LayoutSolution.Push(box: 0, past: .obstacle(1), way: .right)])
    },
    test("a box held from above (left of, above) is pushed back before it") {
        let drawn = draw(#"card "N" left of "P""#, on: Board([("P", rect(1000, 0, 200, 100)), ("Q", rect(650, 0, 100, 100))]))
        expectRect(drawn["N"], rect(410, 0, 200, 100))
        expectEqual(drawn.solution?.pushes, [LayoutSolution.Push(box: 0, past: .obstacle(1), way: .left)])
    },
    test("a box held both ways with room goes on past, if there's room; else no_room naming what it cleared") {
        let roomy = draw(#"card "N" right of "A" left of "B" level with "A""#,
                         on: Board([("A", rect(0, 0, 200, 100)), ("B", rect(1400, 0, 200, 100)), ("Q", rect(300, 0, 400, 100))]))
        expectRect(roomy["N"], rect(740, 0, 200, 100))
        let tight = draw(#"card "N" right of "A" left of "B" level with "A""#,
                         on: Board([("A", rect(0, 0, 200, 100)), ("B", rect(1000, 0, 200, 100)), ("Q", rect(300, 0, 400, 100))]))
        expectError(tight, .noRoom, #""N" is right of "A" and left of "B", and there's no room between them clear of "Q""#, line: 1)
        expectEqual(tight.error?.hint, "place it elsewhere, or say overlap: allow")
    },
    test("a box held exactly on both axes can't move, and says what it overlaps") {
        let drawn = draw(#"box "N" on "P""#, on: Board([("P", rect(0, 0, 200, 100)), ("Q", rect(100, 20, 200, 60))]))
        expectError(drawn, .unordered, #""N" is on "P" and can't move, but it overlaps "Q""#)
        expectEqual(drawn.error?.hint, "say overlap: allow, or place it elsewhere")
    },
    test("a box held on one axis goes along the other") {
        // Level with P holds it vertically; right of P leaves it free to go on across.
        let drawn = draw(#"card "N" right of "P" level with "P""#, on: Board([("P", rect(0, 0, 200, 100)), ("Q", rect(300, 50, 100, 100))]))
        expectRect(drawn["N"], rect(440, 0, 200, 100))
    },
    test("overlap: allow isn't pushed") {
        let drawn = draw(#"card "N" right of "P" overlap: allow"#, on: Board([("P", rect(0, 0, 200, 100)), ("Q", rect(300, 0, 100, 100))]))
        expectRect(drawn["N"], rect(280, 0, 200, 100))
        expectEqual(drawn.solution?.pushes, [])
    },
    test("a zone isn't in the way: a shape that wholly holds what the box is placed against") {
        let holds = draw(#"card "N" right of "A""#, on: Board([("Z", rect(0, 0, 1000, 1000)), ("A", rect(100, 100, 200, 100))]))
        expectRect(holds["N"], rect(380, 100, 200, 100))
        expectEqual(holds.zones("N"), ["Z"])
        let holdsTarget = draw(#"card "N" right of "A""#, on: Board([("Z", rect(0, 0, 500, 500)), ("A", rect(100, 100, 200, 100))]))
        expectRect(holdsTarget["N"], rect(380, 100, 200, 100))
        expectEqual(holdsTarget.zones("N"), ["Z"], "it hangs over Z's edge, and still sits in it")
        let neither = draw(#"card "N" right of "A""#, on: Board([("Z", rect(350, 0, 500, 500)), ("A", rect(0, 100, 200, 100))]))
        expectRect(neither["N"], rect(890, 100, 200, 100))
        expectEqual(neither.pushedPast("N"), ["Z"])
        expectEqual(neither.zones("N"), [])
        // A shape the box's size where it would land holds it, but isn't bigger: it's in the way.
        let same = draw(#"card "N" right of "A""#, on: Board([("A", rect(0, 100, 200, 100)), ("Q", rect(280, 100, 200, 100))]))
        expectRect(same["N"], rect(520, 100, 200, 100))
        expectEqual(same.pushedPast("N"), ["Q"])
        // What it's inside or on is no zone of it.
        let on = draw(#"box "N" on "A""#, on: Board([("A", rect(0, 0, 1000, 1000))]))
        expectEqual(on.zones("N"), [])
    },
    test("what holds only the box where it lands is in the way, however big: a zone holds what it's placed against, at twice that one's area") {
        // A card 240 wide where a 200-wide one lands holds it, but it's the next card, not a zone.
        let wider = draw(#"card "N" right of "A""#, on: Board([("A", rect(0, 100, 200, 100)), ("Q", rect(270, 100, 240, 100))]))
        expectRect(wider["N"], rect(550, 100, 200, 100))
        expectEqual(wider.pushedPast("N"), ["Q"])
        // A note beside a card, where the next card is.
        let note = draw(#"box "Note" right of "A" size: 200x200"#, on: Board([("A", rect(280, 350, 240, 200)), ("B", rect(600, 350, 240, 200))]))
        expectRect(note["Note"], rect(880, 350, 200, 200))
        expectEqual(note.pushedPast("Note"), ["B"])
        // A rectangle beside a note, where the next note (2.5 times its area) or card (3 times) is.
        for (next, width) in [("note", 200), ("card", 240)] {
            let small = draw(#"box "R" right of "A" size: 160x100"#,
                             on: Board([("A", rect(0, 0, 200, 200)), ("B", rect(280, 0, CGFloat(width), 200))]))
            expectEqual(small["R"], rect(320 + CGFloat(width), 50, 160, 100), next)
            expectEqual(small.pushedPast("R"), ["B"], next)
        }
        // Even a shape many times its size, if it holds only the box.
        let big = draw(#"card "N" right of "A""#, on: Board([("A", rect(0, 100, 200, 100)), ("Z", rect(250, 0, 1000, 1000))]))
        expectRect(big["N"], rect(1290, 100, 200, 100))
        expectEqual(big.pushedPast("N"), ["Z"])
        // Twice the area of what it's placed against is a zone; a little less isn't.
        let zone = draw(#"card "N" right of "A""#, on: Board([("A", rect(0, 100, 200, 100)), ("Z", rect(0, 100, 400, 100))]))
        expectRect(zone["N"], rect(280, 100, 200, 100))
        expectEqual(zone.pushedPast("N"), [])
        expectEqual(zone.zones("N"), ["Z"])
        let less = draw(#"card "N" right of "A""#, on: Board([("A", rect(0, 100, 200, 100)), ("Z", rect(0, 100, 399, 100))]))
        expectEqual(less.pushedPast("N"), ["Z"])
    },
    test("a restated box's zone is also the region it already sits in: aligned across columns, a card stays in its own, and one placed against it joins it") {
        // Kanban: T1 in ColA lines up with T5 in ColB. Held on both axes (the alignment, and x kept),
        // it could go nowhere if ColA were in its way.
        let columns: [(String, CGRect)] = [("ColA", rect(0, 0, 300, 1000)), ("ColB", rect(340, 0, 300, 1000)),
                                           ("T1", rect(50, 300, 200, 100)), ("T5", rect(390, 120, 200, 100))]
        for (script, at) in [(#"card "T1" level with "T5" top"#, rect(50, 70, 200, 100)),
                             (#"card "T1" top level with "T5""#, rect(50, 120, 200, 100)),
                             (#"card "T1" level with "T5""#, rect(50, 120, 200, 100))] {
            let drawn = draw(script, on: Board(columns))
            expectRect(drawn["T1"], at)
            expectEqual(drawn.error, nil, script)
            expectEqual(drawn.pushedPast("T1"), [], script)
            expectEqual(drawn.zones("T1"), ["ColA"], script)
        }
        // Where it lands, it may hang over the region's edge: it's still a zone (the caller says so).
        var high = columns
        high[3].1 = rect(390, 20, 200, 100)
        let over = draw(#"card "T1" level with "T5" top"#, on: Board(high))
        expectRect(over["T1"], rect(50, -30, 200, 100))
        expectEqual(over.pushedPast("T1"), [])
        expectEqual(over.zones("T1"), ["ColA"])
        // Restated, it's on the region for a reason of its own, though the region holds nothing
        // else: a new card placed against it lands in the column with it.
        let joined = draw("""
            card "T5" top level with "T1"
            card "T6" below "T5"
            """, on: Board(columns))
        expectRect(joined["T5"], rect(390, 300, 200, 100))
        expectRect(joined["T6"], rect(390, 480, 200, 100))
        expectEqual(joined.pushedPast("T6"), [])
        expectEqual(joined.zones("T6"), ["ColB"])
        // Only what holds where it is now: a neighbor it's moved onto from elsewhere is in the way,
        // as it is for a new shape (a 160x100 box beside a note, where the next note is).
        let moved = draw(#"box "R" right of "A""#,
                         on: Board([("A", rect(0, 0, 200, 200)), ("B", rect(280, 0, 200, 200)), ("R", rect(1000, 1000, 160, 100))]))
        expectRect(moved["R"], rect(520, 50, 160, 100))
        expectEqual(moved.pushedPast("R"), ["B"])
        expectEqual(moved.zones("R"), [])
        // However snug: a note it already sat on, and fills most of, isn't in its way.
        let snug = draw(#"box "R" right of "A""#,
                        on: Board([("A", rect(0, 0, 200, 200)), ("B", rect(280, 0, 200, 200)), ("R", rect(290, 10, 160, 150))]))
        expectRect(snug["R"], rect(280, 25, 160, 150))
        expectEqual(snug.pushedPast("R"), [])
        expectEqual(snug.zones("R"), ["B"])
        // A slot less than twice the area of the card in it: restated where it is, the card is unmoved.
        let slot = draw(#"card "S1" level with "R""#,
                        on: Board([("Slot", rect(0, 0, 300, 260)), ("S1", rect(30, 30, 240, 200)), ("R", rect(460, 30, 240, 200))]))
        expectRect(slot["S1"], rect(30, 30, 240, 200))
        expectEqual(slot.error, nil)
        expectEqual(slot.zones("S1"), ["Slot"])
    },
    test("a box placed against the view sits on a region that holds all the view; one that lands wholly on a region that holds other shapes sits on it") {
        // Zoomed into a big frame: a corner of the view is a corner of the frame's inside.
        let frame = [("Frame", rect(0, 0, 2000, 2000))]
        let view = rect(100, 100, 800, 600)
        let legend = draw(#"card "Legend" inside view top-right"#, on: Board(frame, view: view))
        expectRect(legend["Legend"], rect(660, 140, 200, 100))
        expectEqual(legend.pushedPast("Legend"), [])
        expectEqual(legend.zones("Legend"), ["Frame"])
        let note = draw(#"box "N" inside view top-left"#, on: Board(frame, view: view))
        expectRect(note["N"], rect(140, 140, 100, 100))
        expectEqual(note.zones("N"), ["Frame"])
        // A region that fills most of the window is one too, whatever the box's size.
        let snug = draw(#"card "Legend" inside view top-right"#, on: Board([("Frame", rect(50, 50, 900, 700))], view: view))
        expectRect(snug["Legend"], rect(660, 140, 200, 100))
        expectEqual(snug.zones("Legend"), ["Frame"])
        let big = draw(#"card "Legend" inside view top-right size: 1500x1500"#, on: Board(frame, view: rect(0, 0, 2000, 2000)))
        expectRect(big["Legend"], rect(460, 40, 1500, 1500))
        expectEqual(big.zones("Legend"), ["Frame"])
        // A shape in the view's corner is still in the way.
        let corner = draw(#"card "Legend" inside view top-right"#, on: Board(frame + [("Q", rect(700, 120, 180, 150))], view: view))
        expectRect(corner["Legend"], rect(660, 334, 200, 100))
        expectEqual(corner.pushedPast("Legend"), ["Q"])
        expectEqual(corner.zones("Legend"), ["Frame"])
        // One that holds only part of the view is a neighbor.
        let part = draw(#"card "Legend" inside view top-right"#, on: Board([("Z", rect(500, 0, 1500, 400))], view: view))
        expectEqual(part.pushedPast("Legend"), ["Z"])
        expectEqual(part.zones("Legend"), [])
        // With a sliver of canvas beside it, a frame that holds other shapes is still one to land
        // wholly on, in any corner; holding nothing, it's in the way, and the view has no room.
        let sliver = rect(-10, 100, 800, 600)
        for (corner, at) in [("top-left", rect(30, 140, 200, 100)), ("top-right", rect(550, 140, 200, 100)),
                             ("bottom-left", rect(30, 560, 200, 100)), ("bottom-right", rect(550, 560, 200, 100))] {
            let held = draw(#"card "Legend" inside view "# + corner, on: Board(frame + [("A", rect(1000, 1000, 200, 100))], view: sliver))
            expectRect(held["Legend"], at)
            expectEqual(held.pushedPast("Legend"), [], corner)
            expectEqual(held.zones("Legend"), ["Frame"], corner)
            let empty = draw(#"card "Legend" inside view "# + corner, on: Board(frame, view: sliver))
            expectError(empty, .noRoom, #""Legend" is inside view "# + corner + #", and there's no room left in view clear of "Frame""#, line: 1)
        }
        // A board framed by one region: its corner is inside the frame, which holds another shape.
        let board = draw(#"card "Legend" inside board top-right"#, on: Board([("Frame", rect(0, 0, 2000, 1200)), ("A", rect(100, 100, 200, 100))]))
        expectRect(board["Legend"], rect(1760, 40, 200, 100))
        expectEqual(board.zones("Legend"), ["Frame"])
        // A lone shape that's the whole board holds nothing else: inside it, there's no room.
        let lone = draw(#"card "Legend" inside board top-right"#, on: Board([("Only", rect(0, 0, 600, 400))]))
        expectError(lone, .noRoom, #""Legend" is inside board top-right, and there's no room left in board clear of "Only""#, line: 1)
    },
    test("a free box counts as one a zone holds only when it's on it for a reason of its own: two can't put each other on an empty shape") {
        // A rectangle and its caption, where the next note is: each would hold the other on it.
        let notes: [(String, CGRect)] = [("A", rect(0, 0, 200, 200)), ("N", rect(280, 0, 200, 200))]
        let captioned = draw("""
            box "R" right of "A" size: 160x100
            box "Caption" below "R" (gap: none) size: 160x50
            """, on: Board(notes))
        expectRect(captioned["R"], rect(520, 50, 160, 100))
        expectRect(captioned["Caption"], rect(520, 150, 160, 50))
        expectEqual(captioned.pushedPast("R"), ["N"])
        expectEqual(captioned.solution?.pushes, [LayoutSolution.Push(box: 0, past: .obstacle(1), way: .right),
                                                 LayoutSolution.Push(box: 1, past: .obstacle(1), way: .right, along: 0, placementsHold: true)])
        // Two placed against neither the note nor each other, landing on it together.
        let board: [(String, CGRect)] = [("S1", rect(0, 0, 200, 200)), ("S2", rect(280, 0, 160, 100)), ("S3", rect(20, 280, 160, 100))]
        for script in [#"box "S14" above "S3" size: 140x100"#, #"box "S15" left of "S2" size: 180x40"#,
                       "box \"S14\" above \"S3\" size: 140x100\nbox \"S15\" left of \"S2\" size: 180x40"] {
            let drawn = draw(script, on: Board(board))
            if script.contains("S14") {
                expectRect(drawn["S14"], rect(30, -164, 140, 100))
                expectEqual(drawn.pushedPast("S14"), ["S1"], script)
            }
            if script.contains("S15") {
                expectRect(drawn["S15"], rect(-220, 30, 180, 40))
                expectEqual(drawn.pushedPast("S15"), ["S1"], script)
            }
        }
        // Two legends in the corners of a view half on an empty frame.
        let half = rect(-720, 500, 1440, 900)
        let legends = draw("""
            box "L1" inside view top-right
            box "L2" inside view bottom-right
            """, on: Board([("Frame", rect(0, 0, 3000, 3000))], view: half))
        expectRect(legends["L1"], rect(-140, 540, 100, 100))
        expectRect(legends["L2"], rect(-140, 1260, 100, 100))
        expectEqual(legends.pushedPast("L1"), ["Frame"])
        expectEqual(legends.pushedPast("L2"), ["Frame"])
        // Two small boxes, one right of the other, where the next card is: the second goes along.
        let small = draw("""
            box "L1" right of "A" size: 60x40
            box "L2" right of "L1" (gap: none) size: 60x40
            """, on: Board([("A", rect(0, 0, 200, 200)), ("C", rect(280, 0, 240, 200))]))
        expectRect(small["L1"], rect(560, 80, 60, 40))
        expectRect(small["L2"], rect(620, 80, 60, 40))
        expectEqual(small.pushedPast("L1"), ["C"])
        expectEqual(small.pushedPast("L2"), [])
        // Two cards lined up with an empty lane, each held where it would land in it. The hint
        // offers placing it elsewhere first (an empty region may be a note, whose words it would
        // cover), then how to start the lane.
        let lanes: [(String, CGRect)] = [("Todo", rect(0, 0, 320, 1100)), ("Doing", rect(360, 0, 320, 1100)),
                                         ("T1", rect(40, 40, 240, 200)), ("T2", rect(40, 304, 240, 200))]
        for script in [#"card "T1" left level with "Doing""#, "card \"T1\" left level with \"Doing\"\ncard \"T2\" left level with \"Doing\""] {
            let lined = draw(script, on: Board(lanes))
            expectError(lined, .unordered, #""T1" is left level with "Doing" and can't move, but it overlaps "Doing""#, line: 1)
            expectEqual(lined.error?.hint, #""Doing" holds nothing yet, so it's in the way: place it elsewhere, or, if "Doing" is meant to hold shapes, place a first one inside it"#, script)
        }
        // With a card hanging over its edge, the lane holds part of one: the hint says so.
        let over = draw(#"card "T1" left level with "Doing""#, on: Board(lanes + [("Over", rect(600, 700, 240, 200))]))
        expectError(over, .unordered, #""T1" is left level with "Doing" and can't move, but it overlaps "Doing""#, line: 1)
        expectEqual(over.error?.hint, #""Doing" holds no shape wholly yet, so it's in the way: place it elsewhere, or, if "Doing" is meant to hold shapes, place a first one inside it"#)
        // As the hint says: the first inside it, and the next lands among it.
        let started = draw("""
            card "T1" inside "Doing" top-left
            card "T2" left level with "Doing"
            """, on: Board(lanes))
        expectRect(started["T1"], rect(400, 40, 240, 200))
        expectRect(started["T2"], rect(360, 304, 240, 200))
        expectEqual(started.zones("T2"), ["Doing"])
        expectEqual(started.pushedPast("T2"), [])
    },
    test("a free box placed inside a zone counts as one it holds, whatever line it's on: a box landing on the zone sits among it") {
        let board: [(String, CGRect)] = [("A", rect(0, 0, 200, 200)), ("Zone", rect(280, 0, 900, 600))]
        let alone = draw(#"box "Probe" right of "A" (gap: 200)"#, on: Board(board))
        expectRect(alone["Probe"], rect(1220, 50, 100, 100))
        expectEqual(alone.pushedPast("Probe"), ["Zone"])
        for script in ["box \"In\" inside \"Zone\" bottom-right\nbox \"Probe\" right of \"A\" (gap: 200)",
                       "box \"Probe\" right of \"A\" (gap: 200)\nbox \"In\" inside \"Zone\" bottom-right"] {
            let drawn = draw(script, on: Board(board))
            expectRect(drawn["In"], rect(1040, 460, 100, 100))
            expectRect(drawn["Probe"], rect(400, 50, 100, 100))
            expectEqual(drawn.pushedPast("Probe"), [], script)
            expectEqual(drawn.zones("Probe"), ["Zone"], script)
        }
        // Placed against it, a box counts in turn, and what's placed against that one may hang
        // over the zone's edge (the caller says so). Written last first, each line waits on the
        // next to count, so the zone counts them from the one inside it up, whatever the order.
        let lines = [#"box "In" inside "Zone" left"#, #"box "Next" right of "In" size: 500x100"#,
                     #"box "Last" right of "Next" (gap: tight) size: 200x100"#]
        for script in [lines.joined(separator: "\n"), lines.reversed().joined(separator: "\n")] {
            let chain = draw(script, on: Board(board))
            expectRect(chain["Next"], rect(500, 250, 500, 100))
            expectRect(chain["Last"], rect(1040, 250, 200, 100))
            expectEqual(chain.zones("Next"), ["Zone"], script)
            expectEqual(chain.zones("Last"), ["Zone"], script)
            expectEqual(chain.pushedPast("Last"), [], script)
        }
        // Placed against a box the zone counts, a box is on the zone only if it's at least twice
        // that one's area, as for a shape on the board: one that fills most of it is a neighbor,
        // and what hangs over the zone's edge from it is pushed off.
        let small = [("Z", rect(280, 0, 700, 300))]
        let filled = draw("""
            box "T" inside "Z" top-left size: 600x200
            box "X" below "T" (gap: none) size: 100x80
            """, on: Board(small))
        expectRect(filled["X"], rect(570, 364, 100, 80))
        expectEqual(filled.pushedPast("X"), ["Z"])
        let roomy = draw("""
            box "T" inside "Z" top-left size: 300x200
            box "X" below "T" (gap: none) size: 100x80
            """, on: Board(small))
        expectRect(roomy["X"], rect(420, 240, 100, 80))
        expectEqual(roomy.pushedPast("X"), [])
        expectEqual(roomy.zones("X"), ["Z"])
    },
    test("a box landing among board shapes on a zone counts in turn; one landing only among the script's own doesn't, so what hangs over the edge from it is pushed off") {
        let board: [(String, CGRect)] = [("A", rect(0, 0, 200, 200)), ("Zone", rect(280, 0, 900, 600))]
        let script = """
            box "X" right of "A" (gap: 200) size: 160x100
            box "Y" right of "X" size: 700x100
            """
        // With a shape of the board's in the zone, X lands among it and counts: Y, placed against
        // X, hangs over the zone's edge.
        let held = draw(script, on: Board(board + [("In", rect(1040, 460, 100, 100))]))
        expectRect(held["X"], rect(400, 50, 160, 100))
        expectRect(held["Y"], rect(640, 50, 700, 100))
        expectEqual(held.pushedPast("Y"), [])
        expectEqual(held.zones("Y"), ["Zone"])
        // With it drawn in the same script, X sits on the zone among it, but is on it only because
        // In is, so it doesn't count in turn: Y is pushed off.
        let drawn = draw(#"box "In" inside "Zone" bottom-right"# + "\n" + script, on: Board(board))
        expectRect(drawn["X"], rect(400, 50, 160, 100))
        expectEqual(drawn.zones("X"), ["Zone"])
        expectRect(drawn["Y"], rect(1220, 50, 700, 100))
        expectEqual(drawn.pushedPast("Y"), ["Zone"])
        // Placed against In itself, it hangs over.
        let against = draw("""
            box "In" inside "Zone" bottom-right
            box "Y" above "In" size: 700x100
            """, on: Board(board))
        expectEqual(against.pushedPast("Y"), [])
        expectEqual(against.zones("Y"), ["Zone"])
    },
    test("a note that holds a shape of its own is a zone for a smaller one landing wholly on it; what it holds is still in the way") {
        let board: [(String, CGRect)] = [("A", rect(0, 0, 200, 200)), ("N", rect(280, 0, 200, 200)), ("Badge", rect(300, 20, 40, 40))]
        // Clear of the badge, it sits on the note.
        let beside = draw(#"box "R" right of "A" size: 100x60"#, on: Board(board))
        expectRect(beside["R"], rect(280, 70, 100, 60))
        expectEqual(beside.pushedPast("R"), [])
        expectEqual(beside.zones("R"), ["N"])
        // On the badge, it's pushed past it, and stays on the note if it's still wholly on it...
        let over = draw(#"box "R" right of "A" top level with "A" size: 60x60"#, on: Board(board))
        expectRect(over["R"], rect(380, 0, 60, 60))
        expectEqual(over.pushedPast("R"), ["Badge"])
        expectEqual(over.zones("R"), ["N"])
        // ...and past the note too if it isn't.
        let wider = draw(#"box "R" right of "A" top level with "A" size: 120x60"#, on: Board(board))
        expectRect(wider["R"], rect(520, 0, 120, 60))
        expectEqual(wider.pushedPast("R"), ["Badge", "N"])
        // Without the badge, the note holds nothing else: it's in the way.
        let empty = draw(#"box "R" right of "A" size: 100x60"#, on: Board(Array(board.prefix(2))))
        expectRect(empty["R"], rect(520, 70, 100, 60))
        expectEqual(empty.pushedPast("R"), ["N"])
    },
    test("a box's own placements hold it against the new shapes they name: it's pushed the way that leaves them be") {
        // Centered below H, D can't go across without taking H out of its corner: it goes down.
        let view = rect(0, 0, 1000, 800)
        let corner = draw("""
            card "H" inside view top-left
            card "D" below "H"
            """, on: Board([("E", rect(190, 250, 200, 200))], view: view))
        expectRect(corner["H"], rect(40, 40, 200, 100))
        expectRect(corner["D"], rect(40, 514, 200, 100))
        expectEqual(corner.solution?.pushes, [LayoutSolution.Push(box: 1, past: .obstacle(0), way: .below)])
        // overlap: allow keeps H from being pushed, and it isn't dragged either.
        let allowed = draw("""
            card "H" inside view top-left overlap: allow
            card "D" below "H"
            """, on: Board([("E", rect(190, 250, 200, 200))], view: view))
        expectRect(allowed["H"], rect(40, 40, 200, 100))
        expectRect(allowed["D"], rect(40, 514, 200, 100))
        // N, centered below A, is pushed down past Q, and A stays right of X.
        let below = draw("""
            card "A" right of "X"
            card "N" below "A"
            """, on: Board([("X", rect(0, 0, 200, 100)), ("Q", rect(300, 150, 100, 300))]))
        expectRect(below["A"], rect(280, 0, 200, 100))
        expectRect(below["N"], rect(280, 514, 200, 100))
        expectEqual(below.solution?.pushes, [LayoutSolution.Push(box: 1, past: .obstacle(1), way: .below)])
        // Held both ways by what it names (A, never pushed), it can't move at all.
        let held = draw("""
            card "A" right of "X" overlap: allow
            box "N" on "A"
            """, on: Board([("X", rect(0, 0, 200, 100)), ("Q", rect(300, -50, 60, 60))]))
        expectError(held, .unordered, #""N" is on "A" and can't move, but it overlaps "Q""#, line: 2)
    },
    test("every box a push moves says so: what it went along with, and whether its placements still hold") {
        // N is pushed right past Q; D, centered below N, goes with it and is still where it says.
        let dragged = draw("""
            card "N" right of "P"
            card "D" below "N"
            """, on: Board([("P", rect(0, 0, 200, 100)), ("Q", rect(300, 0, 100, 100))]))
        expectRect(dragged["N"], rect(440, 0, 200, 100))
        expectRect(dragged["D"], rect(440, 180, 200, 100))
        expectEqual(dragged.solution?.pushes, [
            LayoutSolution.Push(box: 0, past: .obstacle(1), way: .right),
            LayoutSolution.Push(box: 1, past: .obstacle(1), way: .right, along: 0, placementsHold: true),
        ])
        expectEqual(dragged.pushedPast("D"), [], "it went along with N, and wasn't kept clear of Q itself")
        // Kept clear of W, C goes right, still centered below T, and takes T with it: T's own
        // placement, right of W, now leaves more room than it says.
        let target = draw("""
            card "W" below "A"
            card "T" right of "W" above "W"
            card "C" below "T" size: 600x100
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectRect(target["C"], rect(240, 180, 600, 100))
        expectRect(target["T"], rect(440, 0, 200, 100))
        expectEqual(target.solution?.pushes, [
            LayoutSolution.Push(box: 2, past: .free(0), way: .right, placementsHold: true),
            LayoutSolution.Push(box: 1, past: .free(0), way: .right, along: 2),
        ])
    },
    test("obstacles are scanned in stacking order, however they're handed over, each pushed past once") {
        let board = Board([("P", rect(0, 0, 200, 100)), ("Q1", rect(300, 0, 100, 100)), ("Q2", rect(430, 0, 100, 100))])
        let inOrder = draw(#"card "N" right of "P""#, on: board)
        let reversed = draw(#"card "N" right of "P""#, on: board, obstacleOrder: { Array($0.reversed()) + $0 })
        for drawn in [inOrder, reversed] {
            expectRect(drawn["N"], rect(570, 0, 200, 100))
            expectEqual(drawn.pushedPast("N"), ["Q1", "Q2"])
            expectEqual(drawn.solution?.pushes.map(\.past), [.obstacle(1), .obstacle(2)])
        }
    },
    test("a box goes past as many shapes in a row as it lands on, one at a time, each once") {
        let row = (1...12).map { ("Q\($0)", rect(CGFloat(200 + 140 * $0), 0, 100, 100)) }
        let drawn = draw(#"card "N" right of "P""#, on: Board([("P", rect(0, 0, 200, 100))] + row))
        // Each is 140 on from the last: 100 wide and 40 clear, so it goes past the whole row.
        expectRect(drawn["N"], rect(200 + 140 * 12 + 100 + 40, 0, 200, 100))
        expectEqual(drawn.pushedPast("N"), row.map(\.0))
    },
    test("10,000 shapes on the board cost what's near the boxes placed") {
        var shapes: [(String, CGRect)] = [("P", rect(0, 0, 200, 100))]
        for index in 0..<10_000 { shapes.append(("S\(index)", rect(CGFloat(index % 100) * 400 - 20_000, CGFloat(index / 100) * 400 + 1000, 200, 100))) }
        var asked = 0
        let drawn = draw(#"card "N" right of "P""#, on: Board(shapes), obstacleOrder: { found in
            asked += found.count
            return found
        })
        expectRect(drawn["N"], rect(280, 0, 200, 100))
        expectEqual(asked, 0)
        expectEqual(drawn.namesAsked.value, 0)
    },
    test("obstacles overlapping each other are left alone, and names are asked for only when a message needs one") {
        let drawn = draw(#"card "N" right of "P""#, on: Board([("P", rect(0, 0, 200, 100)), ("Q", rect(100, 0, 100, 100)), ("R", rect(1000, 0, 100, 100))]))
        expectRect(drawn["N"], rect(280, 0, 200, 100))
        expectEqual(drawn.namesAsked.value, 0)
        let failed = draw(#"box "N" on "P""#, on: Board([("P", rect(0, 0, 200, 100)), ("Q", rect(100, 20, 200, 60))]))
        expect(failed.error != nil)
        expectEqual(failed.namesAsked.value, 1)
    },
    test("obstacles are asked for near each box, not all at once") {
        var asked: [CGRect] = []
        let far = LayoutProblem.Obstacle(id: 7, rect: rect(5000, 5000, 100, 100))
        let clause = try shape(#"card right of "P""#).clauses[0]
        let problem = LayoutProblem(
            free: [LayoutProblem.Free(line: 1, name: "\"N\"", size: CGSize(width: 200, height: 100),
                                      clauses: [LayoutProblem.ResolvedClause(clause, refs: [.fixed(0)])])],
            fixed: [LayoutProblem.Fixed(rect: rect(0, 0, 200, 100))],
            obstacles: { area in
                asked.append(area)
                return [far].filter { $0.rect.intersects(area) }
            })
        expectRect(try problem.solve().rects[0], rect(280, 0, 200, 100))
        // Where it lands, as it's placed, then again for the zones it sits in there.
        expectEqual(asked, [rect(280, 0, 200, 100), rect(280, 0, 200, 100)])
    },
])

@MainActor let freeSeparationTests = Suite("Keeping clear of each other", [
    test("two boxes the placements order on one axis are pushed apart along it") {
        let drawn = draw("""
            card "B" right of "A"
            card "C" right of "B" left
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectRect(drawn["B"], rect(280, 0, 200, 100))
        expectRect(drawn["C"], rect(520, 0, 200, 100))
        expectEqual(drawn.solution?.pushes, [LayoutSolution.Push(box: 1, past: .free(0), way: .right)])
        expectEqual(drawn.pushedPast("C"), ["B"])
    },
    test("ordered on both axes, they part along the one they overlap least on") {
        let drawn = draw("""
            card "B" right of "A"
            card "C" below-right of "B" top-left
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectRect(drawn["C"], rect(360, 164, 200, 100))
        expectEqual(drawn.solution?.pushes.map(\.way), [.below])
    },
    test("an even overlap parts across") {
        let drawn = draw("""
            box "B" right of "A"
            box "C" below-right of "B" top-left (gap: 50)
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectRect(drawn["C"], rect(420, 50, 100, 100))
    },
    test("two boxes nothing orders are unordered: never a guess") {
        let drawn = draw("""
            card "B" right of "A"
            card "C" right of "A" (gap: 100)
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectError(drawn, .unordered, #""B" and "C" overlap, and nothing says which side of the other either one sits on"#, line: 2)
        expectEqual(drawn.error?.hint, "place one against the other, or say overlap: allow")
    },
    test("a box the caller made up yields to a box nothing orders it against, past it the way its placements leave it free") {
        // Two pills right of two boxes side by side: the first lands on the second box and is pushed past it,
        // the second is right of that box, and nothing orders the pair, which for boxes a script wrote is unordered.
        let board = Board([("A", rect(0, 0, 100, 100)), ("B", rect(180, 0, 100, 100))])
        let said = draw("""
            box "P" right of "A"
            box "Q" right of "B"
            """, on: board)
        expectEqual(said.error?.reason, .unordered)
        let drawn = draw("""
            pill "P" right of "A"
            pill "Q" right of "B"
            """, on: board)
        expectEqual(drawn.error, nil)
        expectRect(drawn["P"], rect(320, 35, 60, 30))
        expectRect(drawn["Q"], rect(420, 35, 60, 30))
        expectEqual(drawn.pushedPast("P"), ["B"])
        expectEqual(drawn.pushedPast("Q"), ["P"], "the later yields to the earlier")
        // The same two the other way round in the script: the later still goes past the earlier.
        let reversed = draw("""
            pill "Q" right of "B"
            pill "P" right of "A"
            """, on: board)
        expectEqual(reversed.error, nil)
        expectRect(reversed["Q"], rect(360, 35, 60, 30))
        expectRect(reversed["P"], rect(460, 35, 60, 30))
        // A pill clashing with a box the script wrote that nothing orders it against yields to it, whichever is first.
        let beside = draw("""
            card "N" right of "A" (gap: 100)
            pill "P" right of "A"
            """, on: Board([("A", rect(0, 0, 100, 100))]))
        expectEqual(beside.error, nil)
        expectRect(beside["N"], rect(200, 0, 200, 100))
        expect(!(beside["P"]?.intersects(beside["N"] ?? .null) ?? true), "\(String(describing: beside["P"]))")
        expectEqual(beside.pushedPast("P"), ["N"])
    },
    test("an order only through the board never flips two boxes past each other") {
        let drawn = draw("""
            card "A" inside "Z" top-left
            card "B" inside "Z" top-right
            """, on: Board([("Z", rect(0, 0, 300, 400))]))
        expectError(drawn, .unordered, #""A" and "B" overlap, and nothing says which side of the other either one sits on"#)
    },
    test("an order only through the board counts when it's the way round they already are") {
        // A (left of P) reaches B (right of Q) only through the board, and is left of it: A goes
        // before B. Held from above, A is what gives way, and then it clears Q the same way.
        let drawn = draw("""
            card "A" left of "P"
            card "B" right of "Q"
            """, on: Board([("Q", rect(0, 0, 150, 100)), ("P", rect(480, 0, 100, 100))]))
        expectRect(drawn["A"], rect(-240, 0, 200, 100))
        expectRect(drawn["B"], rect(230, 0, 200, 100))
        expectEqual(drawn.pushedPast("A"), ["B", "Q"])
        expectEqual(drawn.solution?.pushes.map(\.way), [.left, .left])
        expectEqual(drawn.pushedPast("B"), [])
    },
    test("pairs inside or on each other, or allowed to, aren't parted") {
        let on = draw("""
            card "A" right of "Hub"
            box "B" on "A" top-right
            """, on: Board([hub]))
        expectRect(on["B"], rect(430, -50, 100, 100))
        let allowed = draw("""
            card "B" right of "A"
            card "C" right of "A" (gap: 100) overlap: allow
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectRect(allowed["C"], rect(300, 0, 200, 100))
    },
])

@MainActor let anchorTests = Suite("A drawing with nothing to hang on", [
    test("one unplaced shape goes in the middle of the view") {
        let drawn = draw(#"card "A""#, on: Board(view: rect(0, 0, 1000, 800)))
        expectRect(drawn["A"], rect(400, 350, 200, 100))
    },
    test("what's placed against it comes with it, the whole drawing centered") {
        let drawn = draw("""
            card "A"
            card "B" right of "A"
            """, on: Board(view: rect(0, 0, 1000, 800)))
        expectRect(drawn["A"], rect(260, 350, 200, 100))
        expectRect(drawn["B"], rect(540, 350, 200, 100))
    },
    test("with the middle taken, the nearest clear spot on the rings around it, a normal gap clear") {
        let drawn = draw(#"card "A""#, on: Board([("O", rect(-50, -50, 100, 100))], view: rect(-500, -400, 1000, 800)))
        expectRect(drawn["A"], rect(-100, -250, 200, 100))
    },
    test("shapes placed on the board by the same script are in the way too") {
        let drawn = draw("""
            card "C" right of "P"
            card "A"
            """, on: Board([("P", rect(-480, -50, 200, 100))], view: rect(-500, -400, 1000, 800)))
        expectRect(drawn["C"], rect(-200, -50, 200, 100))
        expectRect(drawn["A"], rect(-100, -250, 200, 100))
    },
    test("nowhere clear near the view: right of the board, top-aligned with it") {
        let walls = [("West", rect(-10000, -10000, 10000, 20000)), ("East", rect(0, -10000, 10000, 20000))]
        let drawn = draw(#"card "A""#, on: Board(walls, view: rect(-500, -400, 1000, 800)))
        expectRect(drawn["A"], rect(10160, -10000, 200, 100))
    },
    test("a region that holds the whole view isn't in the way: the drawing is drawn on it, clear of what's on it") {
        let view = rect(-500, -400, 1000, 800)
        let frame = ("Frame", rect(-3000, -3000, 6000, 5000))
        let drawn = draw(#"card "A""#, on: Board([frame], view: view))
        expectRect(drawn["A"], rect(-100, -50, 200, 100))
        expectEqual(drawn.zones("A"), ["Frame"])
        // What's on it is still in the way, and so is one that holds only part of the view.
        let held = draw(#"card "A""#, on: Board([frame, ("O", rect(-50, -50, 100, 100))], view: view))
        expectRect(held["A"], rect(-100, -250, 200, 100))
        expectEqual(held.zones("A"), ["Frame"])
        let part = draw(#"card "A""#, on: Board([("Half", rect(-3000, -3000, 3000, 5000))], view: view))
        expectRect(part["A"], rect(100, -50, 200, 100))
        expectEqual(part.zones("A"), [])
        // What's placed against it comes along, onto the region too.
        let two = draw("""
            card "A"
            card "B" below "A"
            """, on: Board([frame], view: view))
        expectRect(two["A"], rect(-100, -140, 200, 100))
        expectRect(two["B"], rect(-100, 40, 200, 100))
        expectEqual(two.zones("A"), ["Frame"])
        expectEqual(two.zones("B"), ["Frame"])
        // Wider than the region, it hangs over its edges, and still sits on it (the caller says so).
        let wide = draw(#"card "A" size: 1600x100"#, on: Board([("Frame", rect(-600, -500, 1200, 1000))], view: view))
        expectRect(wide["A"], rect(-800, -50, 1600, 100))
        expectEqual(wide.zones("A"), ["Frame"])
        // The drawing is on the region for a reason of its own, so a shape restated onto the region
        // (overlap: allow, since the drawing is placed after it) lands among it, and sits on it; on
        // the region alone, it doesn't.
        let beside: [(String, CGRect)] = [frame, ("P", rect(-3500, 0, 200, 200)), ("R", rect(-3500, 2500, 120, 80))]
        let restated = #"box "R" right of "P" (gap: 400) overlap: allow"#
        let among = draw("card \"Loose\"\n" + restated, on: Board(beside, view: view))
        expectRect(among["R"], rect(-2900, 60, 120, 80))
        expectEqual(among.zones("Loose"), ["Frame"])
        expectEqual(among.zones("R"), ["Frame"])
        let alone = draw(restated, on: Board(beside, view: view))
        expectRect(alone["R"], rect(-2900, 60, 120, 80))
        expectEqual(alone.zones("R"), [])
    },
    test("on a ring, nearest the middle first, then higher, then further left") {
        // A wall up and down the middle: nothing above or below clears it, so of the spots six
        // steps out, left comes before right.
        let drawn = draw(#"card "A""#, on: Board([("Wall", rect(-50, -1000, 100, 2000))], view: rect(-500, -400, 1000, 800)))
        expectRect(drawn["A"], rect(-340, -50, 200, 100))
    },
    test("an unplaced shape tied to the board through what's placed against it is unplaced") {
        let drawn = draw("""
            card "A"
            card "B" right of "A" below "P"
            """, on: Board([("P", rect(0, 0, 200, 100))]))
        expectError(drawn, .unplaced,
                    #""A" says nothing about where it sits horizontally, and nothing placed against it ties it to the board that way"#, line: 1)
        expectEqual(drawn.error?.hint, "place it, or leave everything placed against it unplaced too")
    },
    test("shapes placed only against each other are unanchored, per axis") {
        let both = draw("""
            card "B" right of "C"
            card "C" left of "B"
            """)
        expectError(both, .unanchored, #"nothing ties "B" to the board horizontally"#, line: 1)
        expectEqual(both.error?.hint, "place it (or what it's placed against) against a shape on the board, or leave one shape unplaced to draw them in view")
        let vertical = draw("""
            card "B" right of "P" level with "C"
            card "C" right of "B"
            """, on: Board([("P", rect(0, 0, 200, 100))]))
        expectError(vertical, .unanchored, #"nothing ties "B" to the board vertically"#)
    },
    test("the spot is the first clear one on the rings, as trying each in turn finds") {
        var seed: UInt64 = 7
        /// A number from 0 up to `range`, in thirds (so not always a whole number).
        func next(_ range: CGFloat) -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(Int((seed >> 33) % UInt64(range * 3))) / 3
        }
        // A few small shapes near the middle, and many big ones further out, which push the spot
        // out further.
        for (count, spread, largest) in [(30, CGFloat(1000), CGFloat(400)), (120, 2500, 1000)] {
            for _ in 0..<20 {
                let shapes = (0..<count).map { ("S\($0)", rect(next(2 * spread) - spread, next(1.6 * spread) - 0.8 * spread, 20 + next(largest), 20 + next(largest))) }
                let view = rect(-500, -400, 1000, 800)
                let drawn = draw(#"card "A""#, on: Board(shapes, view: view))
                expectRect(drawn["A"], firstClear(CGSize(width: 200, height: 100), clearOf: shapes.map(\.1).filter { !$0.contains(view) }))
            }
        }
    },
    test("only one new shape may say nothing about where it goes") {
        let drawn = draw("""
            card "A"
            card "B"
            card "C" right of "A"
            """)
        expectError(drawn, .unplaced, #"exactly one new shape may say nothing about where it goes, but 2 do: "A" and "B""#, line: 2)
    },
])

/// Where one unplaced box goes on a board with the view's middle at the origin, found the slow way
/// the solver doesn't take: each spot on the rings in turn, tried against every shape (those in its
/// way: not one that holds the whole view).
func firstClear(_ size: CGSize, clearOf shapes: [CGRect]) -> CGRect {
    let margin = LayoutProblem.anchorClearance, step = LayoutProblem.ringStep
    let middle = CGPoint(x: size.width / 2, y: size.height / 2)
    func taken(_ rect: CGRect) -> Bool {
        shapes.contains { other in
            min(rect.maxX, other.maxX) - max(rect.minX, other.minX) > 1e-6 && min(rect.maxY, other.maxY) - max(rect.minY, other.minY) > 1e-6
        }
    }
    for ring in 0...LayoutProblem.rings {
        var spots: [(Int, Int)] = []
        for j in -ring...ring {
            for i in -ring...ring where max(abs(i), abs(j)) == ring { spots.append((i, j)) }
        }
        spots.sort { ($0.0 * $0.0 + $0.1 * $0.1, $0.1, $0.0) < ($1.0 * $1.0 + $1.1 * $1.1, $1.1, $1.0) }
        for (i, j) in spots {
            let at = CGRect(origin: CGPoint(x: CGFloat(i) * step - middle.x, y: CGFloat(j) * step - middle.y), size: size)
            if !taken(at.insetBy(dx: -margin, dy: -margin)) { return at }
        }
    }
    let board = shapes.reduce(CGRect.null) { $0.union($1) }
    return CGRect(origin: CGPoint(x: board.maxX + LayoutProblem.fallbackGap, y: board.minY), size: size)
}

@MainActor let extremeTests = Suite("Sizes past any board", [
    test("a box too big to count cells of, or a gap past the board, is placed, never a crash") {
        // A script can't write either (the parser refuses them), but a restated shape's size is
        // whatever the board says, and the solver takes a problem from any caller.
        let huge = CGSize(width: 1e300, height: 1e300)
        let alone = LayoutProblem(free: [LayoutProblem.Free(line: 1, name: "\"A\"", size: huge)],
                                  obstacles: { _ in [LayoutProblem.Obstacle(id: 0, rect: rect(0, 0, 100, 100))] },
                                  boardBounds: rect(0, 0, 100, 100))
        expectEqual(try alone.solve().rects, [CGRect(origin: CGPoint(x: 260, y: 0), size: huge)])
        let far = LayoutProblem.ResolvedClause(relation: .direction(.right), targets: [LayoutProblem.ResolvedTarget(.fixed(0), written: "\"P\"")],
                                               gap: .units(1e300), written: #"right of "P" (gap: 1e300)"#)
        let card = CGSize(width: 200, height: 100)
        let gapped = LayoutProblem(free: [LayoutProblem.Free(line: 1, name: "\"C\"", size: card, clauses: [far]),
                                          LayoutProblem.Free(line: 2, name: "\"A\"", size: card)],
                                   fixed: [LayoutProblem.Fixed(rect: rect(0, 0, 200, 100))])
        let rects = try gapped.solve().rects
        expectEqual(rects[0].minX, 1e300)
        expectRect(rects[1], rect(-100, -50, 200, 100))
    },
    test("a drawing as big as a script may write is placed in a moment, however many shapes are near") {
        var shapes: [(String, CGRect)] = []
        for index in 0..<2_000 { shapes.append(("S\(index)", rect(CGFloat(index % 50) * 300 - 7_500, CGFloat(index / 50) * 300 - 6_000, 200, 100))) }
        let board = Board(shapes, view: rect(-500, -400, 1000, 800))
        for size in ["100000x100000", "20000x20000", "8000x6000", "200x100"] {
            var drawn: Drawn?
            let took = threadCPUTime { drawn = draw(#"card "Zone" size: \#(size)"#, on: board) }
            expect(drawn?.solution != nil, "\(size): \(drawn?.error?.description ?? "")")
            expect(took < .milliseconds(500), "\(size) took \(took)")
        }
        // Where nothing near the view is clear, right of the board, top-aligned with it.
        expectRect(draw(#"card "Zone" size: 8000x6000"#, on: board)["Zone"], rect(7_560, -6_000, 8000, 6000))
    },
])
