import CoreGraphics
import DrawScript
import TestKit

// Cards are 200 × 100, boxes 100 × 100, discs 120 × 120 (fixtureSizes). Gaps: none 0, tight 40,
// normal 80 (the default), wide 160; `inside` is tight; pushed apart, boxes keep 40 across and 64
// down; a list steps 64.

/// A card on the board at the origin.
let hub = ("Hub", rect(0, 0, 200, 100))

@MainActor let relationTests = Suite("Placing against a shape", [
    test("each direction clears the target by the gap, and a lone one centers the other axis") {
        let board = Board([("B", rect(0, 0, 200, 100))])
        expectRect(draw(#"card "A" right of "B""#, on: board)["A"], rect(280, 0, 200, 100))
        expectRect(draw(#"card "A" left of "B""#, on: board)["A"], rect(-280, 0, 200, 100))
        expectRect(draw(#"card "A" below "B""#, on: board)["A"], rect(0, 180, 200, 100))
        expectRect(draw(#"card "A" above "B""#, on: board)["A"], rect(0, -180, 200, 100))
        expectRect(draw(#"box "A" right of "B""#, on: board)["A"], rect(280, 0, 100, 100))
        expectRect(draw(#"disc "A" below "B""#, on: board)["A"], rect(40, 180, 120, 120))
    },
    test("a corner is two directions at once, the gap off both") {
        let board = Board([("B", rect(0, 0, 200, 100))])
        expectRect(draw(#"card "A" above-right of "B""#, on: board)["A"], rect(280, -180, 200, 100))
        expectRect(draw(#"card "A" below-left of "B""#, on: board)["A"], rect(-280, 180, 200, 100))
        expectRect(draw(#"card "A" above-left of "B""#, on: board)["A"], rect(-280, -180, 200, 100))
        expectRect(draw(#"card "A" below-right of "B""#, on: board)["A"], rect(280, 180, 200, 100))
    },
    test("level with shares the vertical middle; a side level with shares that side") {
        let board = Board([("B", rect(0, 0, 200, 100)), ("C", rect(600, 400, 300, 200))])
        expectRect(draw(#"card "A" right of "B" level with "C""#, on: board)["A"], rect(280, 450, 200, 100))
        expectRect(draw(#"card "A" right of "B" top level with "C""#, on: board)["A"], rect(280, 400, 200, 100))
        expectRect(draw(#"card "A" right of "B" bottom level with "C""#, on: board)["A"], rect(280, 500, 200, 100))
        expectRect(draw(#"card "A" below "B" left level with "C""#, on: board)["A"], rect(600, 180, 200, 100))
        expectRect(draw(#"card "A" below "B" right level with "C""#, on: board)["A"], rect(700, 180, 200, 100))
    },
    test("a part narrows the target: a side is a segment, a point has no size") {
        let board = Board([("B", rect(0, 0, 200, 100))])
        expectRect(draw(#"card "A" right of "B" top"#, on: board)["A"], rect(280, -50, 200, 100))
        expectRect(draw(#"card "A" right of "B" top-right"#, on: board)["A"], rect(280, -50, 200, 100))
        expectRect(draw(#"card "A" below "B" left"#, on: board)["A"], rect(-100, 180, 200, 100))
        expectRect(draw(#"card "A" level with "B" bottom right of "B""#, on: board)["A"], rect(280, 50, 200, 100))
    },
    test("a direction against a side clears that side by the gap, so two put a shape's top-left at an exact offset from the target's, past it or held in it") {
        let board = Board([("F", rect(100, 50, 300, 200))])
        expectRect(draw(#"card "A" right of "F" left (gap: 400) below "F" top (gap: 250)"#, on: board)["A"], rect(500, 300, 200, 100))
        // Held in F (`in`), an offset that lands on it is where it says: what holds it isn't in its way.
        let f = rect(100, 50, 800, 600)
        let clauses = try shape(#"card right of "F" left (gap: 120) below "F" top (gap: 40)"#).clauses
        let held = LayoutProblem(free: [LayoutProblem.Free(line: 1, name: "\"N\"", size: CGSize(width: 200, height: 100),
                                                           clauses: clauses.map { LayoutProblem.ResolvedClause($0, refs: [.fixed(0)]) },
                                                           holder: LayoutProblem.Holder(.fixed(0), written: #"in "F""#))],
                                 fixed: [LayoutProblem.Fixed(rect: f, obstacle: 0)],
                                 obstacles: { area in [LayoutProblem.Obstacle(id: 0, rect: f)].filter { $0.rect.intersects(area) } }, name: { _ in "\"F\"" })
        let solved = try held.solve()
        expectRect(solved.rects[0], rect(220, 90, 200, 100))
        expectEqual(solved.pushes, [])
    },
    test("a part the caller puts elsewhere (a corner on an outline) is where it says") {
        let clause = try shape(#"card right of "B" top-right"#).clauses[0]
        let problem = LayoutProblem(
            free: [LayoutProblem.Free(line: 1, name: "\"A\"", size: CGSize(width: 200, height: 100),
                                      clauses: [LayoutProblem.ResolvedClause(clause, refs: [.fixed(0)], partRects: [0: rect(170, 15, 0, 0)])])],
            fixed: [LayoutProblem.Fixed(rect: rect(0, 0, 200, 100))])
        expectRect(try problem.solve().rects[0], rect(250, -35, 200, 100))
    },
    test("several targets: a direction clears the furthest, centering takes the span of them all") {
        let board = Board([("A", rect(0, 0, 200, 100)), ("B", rect(0, 300, 300, 100))])
        expectRect(draw(#"card "N" right of "A" and "B""#, on: board)["N"], rect(380, 150, 200, 100))
        expectRect(draw(#"card "N" left of "A" and "B""#, on: board)["N"], rect(-280, 150, 200, 100))
        expectRect(draw(#"card "N" below "A" and "B""#, on: board)["N"], rect(50, 480, 200, 100))
    },
    test("a lone direction's centering is dropped once another placement speaks for that axis") {
        let board = Board([("A", rect(0, 0, 200, 100)), ("C", rect(0, 500, 200, 100))])
        expectRect(draw(#"card "N" right of "A" below "C""#, on: board)["N"], rect(280, 680, 200, 100))
    },
    test("on centers on the part, or the middle, and may overlap what it's on") {
        let board = Board([("B", rect(0, 0, 200, 100))])
        let middle = draw(#"box "N" on "B""#, on: board)
        expectRect(middle["N"], rect(50, 0, 100, 100))
        expectEqual(middle.pushedPast("N"), [])
        expectRect(draw(#"box "N" on "B" top-right"#, on: board)["N"], rect(150, -50, 100, 100))
    },
    test("outside is wholly beyond the part") {
        let board = Board([("Z", rect(0, 0, 800, 600))])
        expectRect(draw(#"card "N" outside "Z" right"#, on: board)["N"], rect(880, 250, 200, 100))
        expectRect(draw(#"card "N" outside "Z" top-left"#, on: board)["N"], rect(-280, -180, 200, 100))
    },
    test("a gap: the bracket's; else the larger of the shape's gap: and its target's; else normal") {
        let board = Board([("A", rect(0, 0, 200, 100))])
        expectRect(draw(#"card "N" right of "A" (gap: 10) gap: wide"#, on: board)["N"], rect(210, 0, 200, 100))
        expectRect(draw(#"card "N" right of "A" (gap: none)"#, on: board)["N"], rect(200, 0, 200, 100))
        expectRect(draw(#"card "N" right of "A" gap: wide"#, on: board)["N"], rect(360, 0, 200, 100))
        let target = draw("""
            card "B" right of "A" gap: wide
            card "N" below "B" gap: tight
            """, on: board)
        expectRect(target["B"], rect(360, 0, 200, 100))
        expectRect(target["N"], rect(360, 260, 200, 100))
        // A shape restated without placements stays put, and its gap: counts as a target's.
        let restated = draw("""
            card "A" gap: wide
            card "N" right of "A"
            """, on: board)
        expectRect(restated["N"], rect(360, 0, 200, 100))
    },
])

@MainActor let insideTests = Suite("Inside", [
    test("inside a corner, a side or an edge's middle, a tight gap in") {
        let board = Board([("Z", rect(0, 0, 800, 600))])
        expectRect(draw(#"card "N" inside "Z" top-left"#, on: board)["N"], rect(40, 40, 200, 100))
        expectRect(draw(#"card "N" inside "Z" top-right"#, on: board)["N"], rect(560, 40, 200, 100))
        expectRect(draw(#"card "N" inside "Z" bottom-left"#, on: board)["N"], rect(40, 460, 200, 100))
        expectRect(draw(#"card "N" inside "Z" bottom-right"#, on: board)["N"], rect(560, 460, 200, 100))
        expectRect(draw(#"card "N" inside "Z" right"#, on: board)["N"], rect(560, 250, 200, 100))
        expectRect(draw(#"card "N" inside "Z" left"#, on: board)["N"], rect(40, 250, 200, 100))
        expectRect(draw(#"card "N" inside "Z" top"#, on: board)["N"], rect(300, 40, 200, 100))
        expectRect(draw(#"card "N" inside "Z" bottom"#, on: board)["N"], rect(300, 460, 200, 100))
        expectRect(draw(#"card "N" inside "Z" top-center"#, on: board)["N"], rect(300, 40, 200, 100))
    },
    test("inside takes its bracketed gap, never the shape's gap:") {
        let board = Board([("Z", rect(0, 0, 800, 600))])
        expectRect(draw(#"card "N" inside "Z" top-left (gap: 10)"#, on: board)["N"], rect(10, 10, 200, 100))
        expectRect(draw(#"card "N" inside "Z" top-left gap: wide"#, on: board)["N"], rect(40, 40, 200, 100))
    },
    test("inside view: the window's part of the board is a box like any other") {
        let board = Board(view: rect(1000, 1000, 1000, 800))
        expectRect(draw(#"card "Legend" inside view top-right"#, on: board)["Legend"], rect(1760, 1040, 200, 100))
    },
    test("inside stays inside: a shape that doesn't fit is no_room") {
        let board = Board([("Z", rect(0, 0, 800, 600))])
        let drawn = draw(#"card "N" inside "Z" top-left size: 900x100"#, on: board)
        expectError(drawn, .noRoom, #""N" is inside "Z" top-left, and there's no room left in "Z""#, line: 1)
        expectEqual(drawn.error?.hint, #"make "Z" bigger, or this smaller"#)
        // The view and the board can't be made bigger from a script.
        let view = draw(#"card "N" inside view top-left size: 1200x100"#, on: Board(view: rect(0, 0, 1000, 800)))
        expectError(view, .noRoom, #""N" is inside view top-left, and there's no room left in view"#, line: 1)
        expectEqual(view.error?.hint, "make this smaller, or place it elsewhere")
        let whole = draw(#"card "N" inside board top-left size: 900x100"#, on: board)
        expectError(whole, .noRoom, #""N" is inside board top-left, and there's no room left in board"#, line: 1)
        expectEqual(whole.error?.hint, "make this smaller, or place it elsewhere")
    },
    test("pushed clear of a shape inside, it stays inside, or it's no_room naming what it cleared") {
        let roomy = draw(#"card "N" inside "Z" top-left"#, on: Board([("Z", rect(0, 0, 800, 600)), ("Q", rect(100, 60, 600, 60))]))
        expectRect(roomy["N"], rect(40, 184, 200, 100))
        expectEqual(roomy.pushedPast("N"), ["Q"])
        let tight = draw(#"card "N" inside "Z" top-left"#, on: Board([("Z", rect(0, 0, 800, 250)), ("Q", rect(100, 60, 600, 60))]))
        expectError(tight, .noRoom, #""N" is inside "Z" top-left, and there's no room left in "Z" clear of "Q""#)
        expectEqual(tight.error?.hint, "place it elsewhere, or say overlap: allow")
    },
    test("a list inside stacks down from the corner, and a list too long for it is no_room") {
        let board = Board([("Z", rect(0, 0, 800, 600))])
        let two = draw("""
            card inside "Z" top-left
            card inside "Z" top-left
            """, on: board)
        expectRect(two.rect(onLine: 1), rect(40, 40, 200, 100))
        expectRect(two.rect(onLine: 2), rect(40, 204, 200, 100))
        let five = draw(Array(repeating: #"card inside "Z" top-left"#, count: 5).joined(separator: "\n"), on: board)
        expectError(five, .noRoom, #"the card on line 1 is inside "Z" top-left, and there's no room left in "Z""#)
    },
    test("held (in), a box stays within its holder wherever its placements put it there, and may overlap it; out of it, it's no_room") {
        // Z (0, 0, 800 × 600) holds nothing else, so it's no zone; B is left of it.
        let z = rect(0, 0, 800, 600), b = rect(-300, 100, 200, 100)
        let obstacles = [LayoutProblem.Obstacle(id: 0, rect: z), LayoutProblem.Obstacle(id: 1, rect: b)]
        let far = try shape(#"card right of "B" (gap: 340)"#).clauses[0], near = try shape(#"card right of "B""#).clauses[0]
        let held = { (clause: Clause, holder: Bool) in
            LayoutProblem(free: [LayoutProblem.Free(line: 1, name: "\"N\"", size: CGSize(width: 200, height: 100),
                                                    clauses: [LayoutProblem.ResolvedClause(clause, refs: [.fixed(1)])],
                                                    holder: holder ? LayoutProblem.Holder(.fixed(0), written: #"in "Z""#) : nil)],
                          fixed: [LayoutProblem.Fixed(rect: z, obstacle: 0), LayoutProblem.Fixed(rect: b, obstacle: 1)],
                          obstacles: { area in obstacles.filter { $0.rect.intersects(area) } }, name: { _ in "\"Z\"" })
        }
        let within = try held(far, true).solve()
        expectRect(within.rects[0], rect(240, 100, 200, 100))
        expectEqual(within.pushes, [], "what holds it isn't in its way")
        expect(try held(far, false).solve().rects[0].minX >= 800, "without, it's pushed out")
        let outside = held(near, true)
        do throws(ScriptError) {
            _ = try outside.solve()
            expect(false, "placed out of what holds it")
        } catch {
            expectEqual(error.reason, .noRoom)
            expectEqual(error.message, #""N" is in "Z", and there's no room left in "Z""#)
        }
    },
    test("held directly (Holder.direct), a box goes in its holder itself: a shape in the holder that holds another is in its way, not a zone it lands on") {
        // G, in Z at its top-left, holds H: by itself a zone (rule c) for a box landing wholly on it.
        let z = rect(0, 0, 1000, 600), g = rect(20, 20, 400, 300), h = rect(300, 200, 50, 50)
        let obstacles = [LayoutProblem.Obstacle(id: 0, rect: z), LayoutProblem.Obstacle(id: 1, rect: g), LayoutProblem.Obstacle(id: 2, rect: h)]
        let clause = try shape(#"card inside "Z" top-left"#).clauses[0]
        let held = { (direct: Bool) in
            LayoutProblem(free: [LayoutProblem.Free(line: 1, name: "\"N\"", size: CGSize(width: 200, height: 100),
                                                    clauses: [LayoutProblem.ResolvedClause(clause, refs: [.fixed(0)])],
                                                    holder: LayoutProblem.Holder(.fixed(0), written: #"in "Z""#, direct: direct))],
                          fixed: [LayoutProblem.Fixed(rect: z, obstacle: 0)],
                          obstacles: { area in obstacles.filter { $0.rect.intersects(area) } }, name: { _ in "\"Z\"" })
        }
        let onIt = try held(false).solve()
        expectRect(onIt.rects[0], rect(40, 40, 200, 100))
        expectEqual(onIt.zones[0].map(\.id), [1], "in Z as `in` has it, it lands on G, which holds H")
        let direct = try held(true).solve()
        expectRect(direct.rects[0], rect(40, 384, 200, 100))
        expectEqual(direct.pushes, [LayoutSolution.Push(box: 0, past: .obstacle(1), way: .below)], "pushed past G, the way it overlaps least")
        expectEqual(direct.zones[0], [], "and on nothing")
    },
    test("what a box carries is never in its way: a container moved over where its contents were") {
        let m = rect(100, 100, 100, 100), l = rect(-300, 0, 200, 100)
        let clause = try shape(#"card right of "L""#).clauses[0]
        let moved = { (carrying: Set<Int>) in
            LayoutProblem(free: [LayoutProblem.Free(line: 1, name: "\"F\"", size: CGSize(width: 400, height: 300),
                                                    clauses: [LayoutProblem.ResolvedClause(clause, refs: [.fixed(0)])],
                                                    current: rect(0, 0, 400, 300), carries: carrying)],
                          fixed: [LayoutProblem.Fixed(rect: l, obstacle: 1)],
                          obstacles: { area in [LayoutProblem.Obstacle(id: 0, rect: m), LayoutProblem.Obstacle(id: 1, rect: l)].filter { $0.rect.intersects(area) } })
        }
        let carrying = try moved([0]).solve()
        expectRect(carrying.rects[0], rect(-20, -100, 400, 300))
        expectEqual(carrying.pushes, [])
        expectEqual(carrying.zones[0], [], "nor a zone of it")
        expect(try moved([]).solve().pushes.count > 0, "not carrying it, it's kept clear of it")
    },
    test("what a restated box carries is where it takes it, for every other box: one placed where it was isn't kept clear of it, one in the box is, there; the inner of two carrying it takes it") {
        // F carries M and K, E (restated in F) carries K too. F goes below L, to (-600, 500), and M
        // with it to (-520, 780); E right of L, to (800, -100), and K with E to (820, -80).
        let l = rect(-300, 0, 200, 100), m = rect(80, 280, 100, 100), k = rect(40, 40, 50, 50)
        let obstacles = [LayoutProblem.Obstacle(id: 0, rect: m), LayoutProblem.Obstacle(id: 1, rect: l), LayoutProblem.Obstacle(id: 2, rect: k)]
        @MainActor func clauses(_ line: String, _ refs: [LayoutProblem.Ref]) throws -> [LayoutProblem.ResolvedClause] {
            try shape(line).clauses.map { LayoutProblem.ResolvedClause($0, refs: refs) }
        }
        let box = CGSize(width: 100, height: 100)
        let problem = LayoutProblem(
            free: [LayoutProblem.Free(line: 1, name: "\"F\"", size: CGSize(width: 800, height: 400), clauses: try clauses(#"card below "L" (gap: 400)"#, [.fixed(0)]),
                                      current: rect(0, 0, 800, 400), carries: [0, 2]),
                   LayoutProblem.Free(line: 2, name: "\"E\"", size: CGSize(width: 300, height: 300), clauses: try clauses(#"card right of "L" (gap: 900)"#, [.fixed(0)]),
                                      current: rect(20, 20, 300, 300), carries: [2]),
                   // Where M was.
                   LayoutProblem.Free(line: 3, name: "\"G\"", size: box, clauses: try clauses(#"box right of "L" (gap: 180) below "L" (gap: 180)"#, [.fixed(0)])),
                   // Where K would be, had it gone with F.
                   LayoutProblem.Free(line: 4, name: "\"H\"", size: box, clauses: try clauses(#"box inside "F" top-left"#, [.free(0)])),
                   // Over where M goes, (-560, 760): pushed right past it, 40 on.
                   LayoutProblem.Free(line: 5, name: "\"J\"", size: box, clauses: try clauses(#"box inside "F" bottom-left"#, [.free(0)]))],
            fixed: [LayoutProblem.Fixed(rect: l, obstacle: 1)],
            obstacles: { area in obstacles.filter { $0.rect.intersects(area) } })
        let solved = try problem.solve()
        for (got, expected) in zip(solved.rects, [rect(-600, 500, 800, 400), rect(800, -100, 300, 300), rect(80, 280, 100, 100),
                                                  rect(-560, 540, 100, 100), rect(-380, 760, 100, 100)]) {
            expectRect(got, expected)
        }
        expectEqual(solved.pushes, [LayoutSolution.Push(box: 4, past: .obstacle(0), way: .right)])
        expectEqual(solved.zones.map(\.count), [0, 0, 0, 0, 0])
    },
    test("a box kept clear of what a restated box carries follows it when that box is pushed on later") {
        // N, inside F at its top-left, lands on M where F takes it, (-380, 200), and goes below it,
        // 144 below F's top. Then F, below L at (-400, 180), is pushed down past W to 514, and N with it.
        let l = rect(-300, 0, 200, 100), m = rect(20, 20, 200, 60), w = rect(-150, 400, 50, 50)
        let obstacles = [LayoutProblem.Obstacle(id: 0, rect: m), LayoutProblem.Obstacle(id: 1, rect: l), LayoutProblem.Obstacle(id: 2, rect: w)]
        let inside = try shape(#"box inside "F" top-left"#).clauses[0], below = try shape(#"card below "L""#).clauses[0]
        let problem = LayoutProblem(
            free: [LayoutProblem.Free(line: 1, name: "\"N\"", size: CGSize(width: 100, height: 100),
                                      clauses: [LayoutProblem.ResolvedClause(inside, refs: [.free(1)])]),
                   LayoutProblem.Free(line: 2, name: "\"F\"", size: CGSize(width: 400, height: 300),
                                      clauses: [LayoutProblem.ResolvedClause(below, refs: [.fixed(0)])], current: rect(0, 0, 400, 300), carries: [0])],
            fixed: [LayoutProblem.Fixed(rect: l, obstacle: 1)],
            obstacles: { area in obstacles.filter { $0.rect.intersects(area) } })
        let solved = try problem.solve()
        expectRect(solved.rects[1], rect(-400, 514, 400, 300))
        expectRect(solved.rects[0], rect(-360, 658, 100, 100))
        expectEqual(solved.pushedPast, [[.obstacle(0)], [.obstacle(2)]])
    },
    test("moved out of a zone by another pair kept apart, it's no_room naming that pair") {
        // N is kept clear of the zone drawn with it by going down, and takes A, which it's
        // centered on, out of the zone.
        let drawn = draw("""
            card "Zone" right of "X" size: 1000x600
            card "A" inside "Zone" top-left
            card "N" right of "A"
            """, on: Board([("X", rect(0, 0, 200, 100))]))
        expectError(drawn, .noRoom, #""A" is inside "Zone" top-left, and there's no room left in "Zone" with "N" kept clear of "Zone""#, line: 3)
        expectEqual(drawn.error?.hint, "place it elsewhere, or say overlap: allow")
    },
])

@MainActor let axisTests = Suite("Axes", [
    test("two directions on one axis and nothing on the other: a new shape is unplaced") {
        let board = Board([("A", rect(0, 0, 200, 100)), ("B", rect(1000, 0, 200, 100))])
        let drawn = draw(#"card "N" right of "A" left of "B""#, on: board)
        expectError(drawn, .unplaced, #""N" does not say where it sits vertically: right of "A" and left of "B" would put it in different places"#, line: 1)
        expectEqual(drawn.error?.hint, #"add a placement that does, as level with "A" or below "A""#)
    },
    test("an alignment alone says nothing about the other axis") {
        let drawn = draw(#"card "N" level with "A""#, on: Board([("A", rect(0, 0, 200, 100))]))
        expectError(drawn, .unplaced, #""N" says nothing about where it sits horizontally"#)
        expectEqual(drawn.error?.hint, #"add a placement that does, as left level with "A" or right of "A""#)
    },
    test("a restated shape keeps where it is on an axis nothing settles") {
        let board = Board([("A", rect(0, 0, 200, 100)), ("B", rect(1000, 0, 200, 100)), ("R", rect(500, 500, 200, 100))])
        expectRect(draw(#"card "R" level with "A""#, on: board)["R"], rect(500, 0, 200, 100))
        expectRect(draw(#"card "R" right of "A" left of "B""#, on: board)["R"], rect(280, 500, 200, 100))
        expectRect(draw(#"card "R" level with "A" size: 100x50"#, on: board)["R"], rect(500, 25, 100, 50))
    },
    test("a restated shape with a lone direction is centered as a new one is") {
        let board = Board([("A", rect(0, 0, 200, 100)), ("R", rect(500, 500, 200, 100))])
        expectRect(draw(#"card "R" below "A""#, on: board)["R"], rect(0, 180, 200, 100))
    },
    test("left of and above hold a box at its upper bound; what's placed after it follows") {
        let chain = draw("""
            card "A" left of "P"
            card "B" left of "A"
            """, on: Board([("P", rect(1000, 0, 200, 100))]))
        expectRect(chain["A"], rect(720, 0, 200, 100))
        expectRect(chain["B"], rect(440, 0, 200, 100))
        let hanging = draw("""
            card "T" above-left of "Bd"
            card "S" below "T"
            """, on: Board([("Bd", rect(0, 1000, 200, 100))]))
        expectRect(hanging["T"], rect(-280, 820, 200, 100))
        expectRect(hanging["S"], rect(-280, 1000, 200, 100))
    },
    test("placements that leave no room are no_room, quoting them") {
        let drawn = draw(#"card "N" right of "A" left of "B" level with "A""#, on: Board([("A", rect(0, 0, 200, 100)), ("B", rect(400, 0, 200, 100))]))
        expectError(drawn, .noRoom, #""N" is right of "A" and left of "B", and there's no room between them"#, line: 1)
        expectEqual(drawn.error?.hint, "drop or change one of them, or ask for a smaller gap")
        let loop = draw("""
            card "A" right of "Hub"
            card "B" right of "A" level with "A"
            card "C" left of "A" right of "B" level with "A"
            """, on: Board([hub]))
        expectError(loop, .noRoom, line: 3)
        expect(loop.error?.message.hasSuffix("can't all hold: there's no room horizontally") == true, loop.error?.message ?? "")
    },
    test("a shape placed against itself is circular") {
        expectError(draw(#"card "A" right of "A""#), .circular, #""A" is placed against itself"#)
    },
    test("a problem the caller built wrong is internal, never a crash") {
        let clause = try shape(#"card right of "B""#).clauses[0]
        func solved(_ free: LayoutProblem.Free) -> ScriptError.Reason? {
            reason(solving: LayoutProblem(free: [free], fixed: [LayoutProblem.Fixed(rect: rect(0, 0, 10, 10))]))
        }
        let size = CGSize(width: 10, height: 10)
        expectEqual(solved(LayoutProblem.Free(line: 1, name: "a", size: CGSize(width: 0, height: 10))), .internal)
        expectEqual(solved(LayoutProblem.Free(line: 1, name: "a", size: CGSize(width: CGFloat.nan, height: 10))), .internal)
        expectEqual(solved(LayoutProblem.Free(line: 1, name: "a", size: size, clauses: [LayoutProblem.ResolvedClause(clause, refs: [.fixed(3)])])), .internal)
        expectEqual(solved(LayoutProblem.Free(line: 1, name: "a", size: size, clauses: [LayoutProblem.ResolvedClause(clause, refs: [.obstacle(0)])])), .internal)
        expectEqual(solved(LayoutProblem.Free(line: 1, name: "a", size: size, clauses: [LayoutProblem.ResolvedClause(clause, refs: [.free(4)])])), .internal)
        expectEqual(solved(LayoutProblem.Free(line: 1, name: "a", size: size, clauses: [LayoutProblem.ResolvedClause(clause, refs: [.fixed(0)])])), nil)
        expectEqual(try LayoutProblem(free: []).solve(), LayoutSolution(rects: [], pushes: []))
    },
])

@MainActor let listTests = Suite("Lists", [
    test("shapes placed alike stack down the page as one, centered as one, 64 apart") {
        let drawn = draw("""
            card "A" right of "Hub"
            card "B" right of "Hub"
            card "C" right of "Hub"
            """, on: Board([hub]))
        expectRect(drawn["A"], rect(280, -164, 200, 100))
        expectRect(drawn["B"], rect(280, 0, 200, 100))
        expectRect(drawn["C"], rect(280, 164, 200, 100))
        expectEqual(drawn.solution?.pushes.count, 0)
    },
    test("the step is the members' gap: when they all say the same one") {
        let drawn = draw("""
            card "A" right of "Hub" gap: tight
            card "B" right of "Hub" gap: tight
            card "C" right of "Hub" gap: tight
            """, on: Board([hub]))
        expectRect(drawn["A"], rect(240, -140, 200, 100))
        expectRect(drawn["B"], rect(240, 0, 200, 100))
        expectRect(drawn["C"], rect(240, 140, 200, 100))
        let mixed = draw("""
            card "A" right of "Hub" gap: tight
            card "B" right of "Hub"
            """, on: Board([hub]))
        expectEqual(mixed["A"]?.minY, -82)
        expectEqual(mixed["B"]?.minY, 82)
    },
    test("below a shape, each member centers across on its own") {
        let drawn = draw("""
            box "A" below "Hub"
            box "B" below "Hub"
            """, on: Board([hub]))
        expectRect(drawn["A"], rect(50, 180, 100, 100))
        expectRect(drawn["B"], rect(50, 344, 100, 100))
    },
    test("placements quoted back alike are alike; overlap: allow shapes aren't listed") {
        let alike = draw("""
            card "A" right "Hub"
            card "B" right of "Hub"
            """, on: Board([hub]))
        expectRect(alike["A"], rect(280, -82, 200, 100))
        expectRect(alike["B"], rect(280, 82, 200, 100))
        let allowed = draw("""
            card "A" right of "Hub" overlap: allow
            card "B" right of "Hub"
            card "C" right of "Hub"
            """, on: Board([hub]))
        expectRect(allowed["A"], rect(280, 0, 200, 100))
        expectRect(allowed["B"], rect(280, -82, 200, 100))
        expectRect(allowed["C"], rect(280, 82, 200, 100))
    },
    test("boxes the caller made up, placed alike, are a list of their own, 16 apart") {
        let drawn = draw("""
            pill "P1" right of "Hub"
            pill "P2" right of "Hub"
            pill "P3" right of "Hub"
            """, on: Board([hub]))
        expectRect(drawn["P1"], rect(280, -11, 60, 30))
        expectRect(drawn["P2"], rect(280, 35, 60, 30))
        expectRect(drawn["P3"], rect(280, 81, 60, 30))
        expectEqual(drawn.solution?.pushes.count, 0)
    },
    test("a box the script wrote is never listed with them: it's placed as it says, and they give way to it as one") {
        // H is right of G as the pills are, but it's no member of their list, which would center the list on G,
        // H and all, and take H off G's middle. The pills yield past H, as one.
        let drawn = draw("""
            card "G" below "X" size: 200x200
            card "H" right of "G" size: 200x200
            pill "P1" right of "G"
            pill "P2" right of "G"
            pill "P3" right of "G"
            """, on: Board([("X", rect(0, 0, 200, 200))]))
        expectRect(drawn["G"], rect(0, 280, 200, 200))
        expectRect(drawn["H"], rect(280, 280, 200, 200))
        expectRect(drawn["P1"], rect(520, 319, 60, 30))
        expectRect(drawn["P2"], rect(520, 365, 60, 30))
        expectRect(drawn["P3"], rect(520, 411, 60, 30))
        expectEqual(drawn.pushedPast("P1"), ["H"])
        expectEqual(drawn.pushedPast("P2"), [])
        expectEqual(drawn.solution?.pushes.map(\.along), [nil, 2, 2], "the rest went along with the first")
    },
    test("a list moves as one across: a member pushed past a wall takes the others with it") {
        // Only P2 meets W; the whole column goes right past it.
        let pills = draw("""
            card "G" below "X" size: 200x200
            pill "P1" right of "G"
            pill "P2" right of "G"
            pill "P3" right of "G"
            """, on: Board([("X", rect(0, 0, 200, 200)), ("W", rect(300, 360, 100, 40))]))
        expectRect(pills["P1"], rect(440, 319, 60, 30))
        expectRect(pills["P2"], rect(440, 365, 60, 30))
        expectRect(pills["P3"], rect(440, 411, 60, 30))
        expectEqual(pills.pushedPast("P2"), ["W"])
        expectEqual(pills.solution?.pushes.map(\.box), [2, 1, 3])
        expectEqual(pills.solution?.pushes.map(\.along), [nil, 2, 2])
        // Shapes the script wrote too: only C meets W, held down the page by A's centering on Hub.
        let cards = draw("""
            card "A" right of "Hub"
            card "B" right of "Hub"
            card "C" right of "Hub"
            """, on: Board([hub, ("W", rect(300, 200, 100, 30))]))
        expectRect(cards["A"], rect(440, -164, 200, 100))
        expectRect(cards["B"], rect(440, 0, 200, 100))
        expectRect(cards["C"], rect(440, 164, 200, 100))
        expectEqual(cards.pushedPast("C"), ["W"])
    },
    test("a list is only as free as its members: a later one can't drag its head off a centering") {
        // C overlaps W least down the page, but A is centered on G, so the list goes across, and G stays put.
        let drawn = draw("""
            card "G" below "X"
            card "A" right of "G"
            card "B" right of "G"
            card "C" right of "G"
            """, on: Board([("X", rect(0, 0, 200, 200)), ("W", rect(300, 530, 400, 30))]))
        expectRect(drawn["G"], rect(0, 280, 200, 100))
        expectRect(drawn["A"], rect(740, 116, 200, 100))
        expectRect(drawn["C"], rect(740, 444, 200, 100))
        expectEqual(drawn.pushedPast("C"), ["W"])
        expectEqual(drawn.pushedPast("G"), [])
    },
])

@MainActor let regionTests = Suite("Region alignments", [
    test("centering on shapes that move apart is measured on a solve") {
        let drawn = draw("""
            card "B" right of "A"
            card "N" below "A" and "B"
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectRect(drawn["B"], rect(280, 0, 200, 100))
        expectRect(drawn["N"], rect(140, 180, 200, 100))
        let level = draw("""
            card "B" below "A"
            card "N" right of "A" level with "A" and "B"
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectRect(level["N"], rect(280, 90, 200, 100))
    },
    test("aligning with a shape that's placed against you in turn is circular") {
        let drawn = draw("""
            card "N" right of "A" level with "A" and "B"
            card "B" below "N"
            """, on: Board([("A", rect(0, 0, 200, 100))]))
        expectError(drawn, .circular,
                    #""N" is level with "A" and "B", but "B" is placed vertically against "N" in turn, so neither can wait for the other"#, line: 1)
    },
    test("a region is measured again after a shape in it is pushed, until nothing more moves") {
        let drawn = draw("""
            card "B" right of "A"
            card "N" below "A" and "B"
            """, on: Board([("A", rect(0, 0, 200, 100)), ("Q", rect(400, 0, 100, 100))]))
        expectRect(drawn["B"], rect(540, 0, 200, 100))
        expectRect(drawn["N"], rect(270, 180, 200, 100))
    },
    test("a path only through the board never makes an alignment circular") {
        let drawn = draw("""
            card "B" right of "A"
            card "N" below "A" and "B"
            card "X" right of "N" left of "P" level with "N"
            """, on: Board([("A", rect(0, 0, 200, 100)), ("P", rect(2000, 0, 200, 100))]))
        expectRect(drawn["N"], rect(140, 180, 200, 100))
        expectRect(drawn["X"], rect(420, 180, 200, 100))
    },
    test("an alignment against a shape that's aligned itself waits for it: they're settled in rounds") {
        let board = Board([("X", rect(0, 0, 200, 100))])
        let chain = draw("""
            card "Web" right of "X"
            card "API" right of "Web"
            card "Hub" below "Web" and "API"
            card "Log" below "Hub" and "API"
            """, on: board)
        expectRect(chain["Hub"], rect(420, 180, 200, 100))
        expectRect(chain["Log"], rect(490, 360, 200, 100))
        let swapped = draw("""
            card "Web" right of "X"
            card "API" right of "Web"
            card "Log" below "Hub" and "API"
            card "Hub" below "Web" and "API"
            """, on: board)
        expectRect(swapped["Log"], rect(490, 360, 200, 100))
        // In a drawing with nothing to hang on, the same shapes.
        let drawing = draw("""
            card "Web"
            card "API" right of "Web"
            card "Hub" below "Web" and "API"
            card "Log" below "Hub" and "API"
            """, on: Board(view: rect(0, 0, 1000, 800)))
        let web = try require(drawing["Web"])
        expectRect(drawing["Hub"], rect(web.minX + 140, web.minY + 180, 200, 100))
        expectRect(drawing["Log"], rect(web.minX + 210, web.minY + 360, 200, 100))
    },
    test("an alignment is measured where what it lines up with settles, not where it stood before") {
        // N's middle, below T at first, settles level with A and B; M lines up with it there.
        let drawn = draw("""
            card "B" below "A"
            card "N" right of "A" below "T" level with "A" and "B"
            card "M" right of "N" level with "N" and "A"
            """, on: Board([("A", rect(0, 0, 200, 100)), ("T", rect(-2000, -600, 100, 100))]))
        expectRect(drawn["N"], rect(280, 90, 200, 100))
        expectRect(drawn["M"], rect(560, 45, 200, 100))
    },
])
