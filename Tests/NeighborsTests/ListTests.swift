import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import CoreGraphics
import DetailPanel
import Keyboard
import Neighbors
import Queries
import Selection
import SwiftUI
import TestKit
import Topology

// What a shape's panel lists of what's connected to it (`NeighborList`, `NeighborDetailsPlugin`): each
// light's shapes under its title, what runs between left out, then what the shape is inside and what
// it holds; how a row reads; folding and searching; asking again as the file changes; and the tab on
// every shape. Every shape here is a fixture, named by a caption.

/// On the root: Square (S, a memo quoting Quay), Quay (Q), Bank (B, which S has a wire to), Cafe (C,
/// which has a wire to S), Mill (M, a memo quoting S), an uncaptioned box U, the pocket Park (P) and
/// the corral Kennel (K), which holds Gate (G). On Park's board: Xyst (X), which S has a wire to, and
/// the corral Ring (R), which holds Yard (Y), which S has a wire to, a wire from Xyst to Yard, and a link
/// bound only where it starts.
struct Town {
    let s = ShapeID(), q = ShapeID(), b = ShapeID(), c = ShapeID(), m = ShapeID(), u = ShapeID()
    let p = ShapeID(), k = ShapeID(), g = ShapeID(), x = ShapeID(), r = ShapeID(), y = ShapeID()
    let toB = ShapeID(), fromC = ShapeID(), toX = ShapeID(), toY = ShapeID(), inner = ShapeID()

    func file(adding extra: [AnyShapeRecord] = []) -> CanvasFile {
        let ring = AnyShapeRecord(ShapeRecord(id: r, Corral(CGRect(x: 0, y: 300, width: 400, height: 300))))
        return CanvasFile(root: CanvasDocument(shapes: [
            called("Square", memo(s, quoting: q, at: CGPoint(x: 400, y: 300))), called("Quay", box(q, at: CGPoint(x: 800, y: 300))),
            called("Bank", box(b, at: CGPoint(x: 400, y: 100))), called("Cafe", box(c, at: CGPoint(x: 100, y: 300))),
            called("Mill", memo(m, quoting: s, at: CGPoint(x: 400, y: 500))), box(u, at: CGPoint(x: 800, y: 100)),
            called("Park", pocket(p, at: CGPoint(x: 1200, y: 100))), called("Kennel", corral(k)), held(called("Gate", box(g)), in: k),
            link(toB, s, b), link(fromC, c, s), link(toX, s, x), link(toY, s, y),
        ] + extra), children: [p: CanvasDocument(shapes: [
            called("Xyst", box(x, at: CGPoint(x: 100, y: 100))), called("Ring", ring), held(called("Yard", box(y, at: CGPoint(x: 50, y: 350))), in: r),
            link(inner, x, y), link(ShapeID(), x, nil),
        ])])
    }
}

/// The record, captioned.
func called(_ caption: String, _ record: AnyShapeRecord) -> AnyShapeRecord {
    var record = record
    record[Caption.self] = caption
    return record
}

/// The lists' places in `NeighborList.groups`, with the test lights: theirs, then the two every list has.
enum Lists {
    static let wiredTo = 0, wiredFrom = 1, quotes = 2, quotedBy = 3, inside = 4, contains = 5
}

extension EditorHarness {
    var list: NeighborList { editor.neighborList! }

    /// Lets what's due happen (`ms` of the scheduler: an ask waits 100 after a commit) and the answer land.
    func settleList(after ms: Int = 0, file: StaticString = #fileID, line: UInt = #line) {
        wait(ms)
        spinRunLoop(until: { !list.isAsking }, file: file, line: line)
    }

    /// Watches a shape, as its panel's list appearing does, and waits for its lists.
    func watch(_ id: ShapeID, file: StaticString = #fileID, line: UInt = #line) {
        list.watch(id)
        settleList(file: file, line: line)
    }

    /// The shapes a list shows, in its order.
    func rows(_ group: Int) -> [ShapeID] { list.shown(in: group).rows.map(\.id) }

    /// How many a list says it has.
    func count(_ group: Int) -> Int { list.shown(in: group).count }

    /// The row of a shape in a list, as drawn.
    func line(_ id: ShapeID, in group: Int, file: StaticString = #fileID, line: UInt = #line) -> NeighborLine? {
        guard let row = list.shown(in: group).rows.first(where: { $0.id == id }) else {
            expect(false, "no row for the shape in list \(group)", file: file, line: line)
            return nil
        }
        return list.line(for: row, in: group)
    }
}

@MainActor let listTests = Suite("Neighbors: the lists in a shape's panel", [
    test("each light's shapes are listed under its title, what runs between left out, then what the shape is inside and holds") {
        let town = Town()
        let h = try listHarness(town.file())
        expectEqual(h.list.groups.map(\.title), ["Wired To", "Wired From", "Quotes", "Quoted By", "Inside", "Contains"])
        expectEqual(h.list.groups.map { $0.color.flatMap(Light.init(color:)) }, [.out, .into, .quotes, .quoted, nil, nil], "a light's list has its color")
        expect(!h.list.hasLanded, "nothing is asked until a list is on screen")
        h.watch(town.s)
        expect(h.list.hasLanded)
        expectEqual(h.rows(Lists.wiredTo), [town.b, town.x, town.y], "the shapes its wires end at, on any board, in file order; no link")
        expectEqual(h.rows(Lists.wiredFrom), [town.c])
        expectEqual(h.rows(Lists.quotes), [town.q])
        expectEqual(h.rows(Lists.quotedBy), [town.m])
        expectEqual(h.rows(Lists.inside), [], "on the root, in no corral")
        expectEqual(h.rows(Lists.contains), [], "a memo holds nothing: the engine refuses the question, and the list is empty")
        expectEqual(h.list.groups.indices.map(h.count), [3, 1, 1, 1, 0, 0])
        expectEqual(h.list.total, 6)
        #if DEBUG
        expectEqual(h.list.asked, 1, "one ask for the six lists")
        #endif
    },
    test("a link's lists are where it ends and where it starts") {
        let town = Town()
        let h = try listHarness(town.file())
        h.watch(town.toB)
        expectEqual(h.rows(Lists.wiredTo), [town.b])
        expectEqual(h.rows(Lists.wiredFrom), [town.s])
    },
    test("Inside lists what a shape is in, outermost first, and Contains what's directly in it: a corral's shapes, a pocket's board") {
        let town = Town()
        let h = try listHarness(town.file())
        h.watch(town.y)
        expectEqual(h.rows(Lists.inside), [town.p, town.r], "the pocket whose board it's on, then the corral it's in there")
        h.watch(town.p)
        expectEqual(h.line(town.x, in: Lists.contains)?.detail, nil, "what it holds is on its own board, which needs no saying")
        expectEqual(h.rows(Lists.contains).filter { h.editor.shape(inFile: $0)?.kind != CanvasTesting.Link.kind }, [town.x, town.r],
                    "its board's shapes in no corral, and the corral: not what the corral holds")
        expect(!h.rows(Lists.contains).contains(town.inner), "nor the link between two of them: what runs between isn't listed")
        expectEqual(h.count(Lists.contains), 3, "a link bound at one end is no connection, so it's a shape the board holds")
        expectEqual(h.rows(Lists.inside), [])
        h.watch(town.k)
        expectEqual(h.rows(Lists.contains), [town.g])
        h.watch(town.g)
        expectEqual(h.rows(Lists.inside), [town.k])
        expectEqual(h.rows(Lists.contains), [])
    },
    test("a row reads as its kind's symbol, its name or its kind's, the board it's on when that isn't the one shown, and its light's caption") {
        let town = Town()
        let h = try listHarness(town.file(adding: [link(ShapeID(), town.s, town.u)]))
        h.watch(town.s)
        let bank = h.line(town.b, in: Lists.wiredTo)
        expectEqual(bank?.name, "Bank")
        expectEqual(bank?.detail, nil, "on the board shown")
        expectEqual(bank?.caption, nil, "its light gives none")
        expectEqual(bank?.symbol, h.editor.registry.label(of: Box.kind).systemImage ?? "square.dashed")
        expectEqual(h.line(town.u, in: Lists.wiredTo)?.name, h.editor.registry.label(of: Box.kind).name, "an uncaptioned box is called what its kind is")
        expectEqual(h.line(town.x, in: Lists.wiredTo)?.detail, "Park", "on the pocket's board")
        expectEqual(bank?.spoken, "Bank", "a row reads its name, then its board and its caption when it has them")
        expectEqual(h.line(town.x, in: Lists.wiredTo)?.spoken.hasSuffix(", Park"), true)
        expectEqual(h.line(town.y, in: Lists.wiredTo)?.spoken, "Yard, Park › Ring")
        expectEqual(h.line(town.m, in: Lists.quotedBy)?.spoken.hasPrefix("Mill, "), true)
        expectEqual(h.line(town.y, in: Lists.wiredTo)?.detail, "Park › Ring", "in a corral on the pocket's board: its path, the pocket's name and the corral's")
        expectEqual(h.line(town.y, in: Lists.wiredTo)?.place, [PlaceStep(name: "Park", opensBoard: true), PlaceStep(name: "Ring")],
                    "the steps the row folds in its room: the pocket is a board, the corral a region")
        expectEqual(h.line(town.x, in: Lists.wiredTo)?.place, [PlaceStep(name: "Park", opensBoard: true)], "the board it is on")
        expectEqual(bank?.place, [], "no place, no steps")
        expectEqual(h.line(town.m, in: Lists.quotedBy)?.caption, "Mill quotes \(town.s.description.prefix(4))", "what its light says of the two shapes")
        // From the pocket's board, a shape on the root is on the board the file names.
        expect(h.enter(town.p))
        h.watch(town.x)
        expectEqual(h.rows(Lists.wiredFrom), [town.s])
        expectEqual(h.line(town.s, in: Lists.wiredFrom)?.detail, "Board", "the root, while the file has no name")
        h.editor.nameRoot("Plan")
        expectEqual(h.line(town.s, in: Lists.wiredFrom)?.detail, "Plan")
        expectEqual(h.line(town.s, in: Lists.wiredFrom)?.place, [PlaceStep(name: "Plan", opensBoard: true)], "the file's name leads, a board")
        expectEqual(h.rows(Lists.inside), [town.p])
        expectEqual(h.line(town.p, in: Lists.inside)?.detail, "Plan", "the pocket's card is on the root")
    },
    test("a folded list keeps its count and shows no rows, for every shape; unfolded, its rows are asked for") {
        let town = Town()
        let h = try listHarness(town.file())
        h.watch(town.s)
        h.list.setFolded(Lists.wiredTo, true)
        expect(h.list.isFolded(Lists.wiredTo))
        expect(!h.list.showsRows(of: Lists.wiredTo))
        expectEqual(h.rows(Lists.wiredTo), [])
        expectEqual(h.count(Lists.wiredTo), 3, "still counted")
        expectEqual(h.rows(Lists.wiredFrom), [town.c], "the others as they were")
        expect(!h.list.isAsking, "folding asks nothing")
        // Another shape: the list is still folded, and only counted (no rows are read for it).
        h.watch(town.c)
        expectEqual(h.count(Lists.wiredTo), 1)
        expectEqual(h.list.listing?.groups[Lists.wiredTo].rows, nil, "a folded list's rows aren't read")
        expectEqual(h.list.listing?.groups[Lists.wiredFrom].rows, [], "an open one's are, though it has none")
        #if DEBUG
        let asked = h.list.asked
        #endif
        h.list.setFolded(Lists.wiredTo, false)
        expect(h.list.isAsking, "unfolded with no rows read: asked for them")
        h.settleList()
        expectEqual(h.rows(Lists.wiredTo), [town.s])
        #if DEBUG
        expectEqual(h.list.asked, asked + 1)
        #endif
        // Folded and unfolded with its rows read already: nothing asked.
        h.list.setFolded(Lists.wiredTo, true)
        h.list.setFolded(Lists.wiredTo, false)
        expect(!h.list.isAsking)
        expectEqual(h.rows(Lists.wiredTo), [town.s])
    },
    test("typed text keeps the rows whose names it matches, the best first, in folded lists too, and goes with the shape") {
        let town = Town()
        let bay = ShapeID(), ebb = ShapeID()
        let h = try listHarness(town.file(adding: [called("Bay", box(bay)), called("Ebb Bank", box(ebb)), link(ShapeID(), town.s, bay), link(ShapeID(), town.s, ebb)]))
        h.list.setFolded(Lists.wiredFrom, true)
        h.watch(town.s)
        expectEqual(h.rows(Lists.wiredTo), [town.b, town.x, town.y, bay, ebb], "file order: the pocket's board right after the pocket")
        h.list.setSearch("ba")
        expectEqual(h.list.search, "ba")
        expectEqual(h.count(Lists.wiredFrom), 1, "a folded list keeps its head until its rows are read to be searched")
        h.settleList()                                           // the folded list's rows are read to be searched
        expectEqual(h.count(Lists.wiredFrom), 0, "Cafe doesn't match")
        expectEqual(h.rows(Lists.wiredTo), [town.b, bay, ebb], "Bank and Bay start with it, in the list's order; Ebb Bank has it at a word's start")
        expectEqual(h.count(Lists.wiredTo), 3, "a searched list counts what matched")
        expectEqual(h.rows(Lists.quotes), [], "Quay doesn't match")
        expectEqual(h.count(Lists.quotes), 0)
        h.list.setSearch("caf")
        h.settleList()
        expectEqual(h.rows(Lists.wiredFrom), [town.c], "a folded list is searched too")
        expect(h.list.showsRows(of: Lists.wiredFrom))
        expectEqual(h.list.total, 8, "the total is of all, searched or not")
        h.list.setSearch("zzz")
        expectEqual(h.list.groups.indices.map(h.count), [0, 0, 0, 0, 0, 0])
        h.list.setSearch("")
        expectEqual(h.rows(Lists.wiredTo), [town.b, town.x, town.y, bay, ebb], "as it was")
        expectEqual(h.rows(Lists.wiredFrom), [], "folded again")
        expectEqual(h.count(Lists.wiredFrom), 1)
        h.list.setSearch("ba")
        h.watch(town.b)
        expectEqual(h.list.search, "", "another shape's lists aren't searched for what was typed for the last")
    },
    test("a row says where it is by its path, so shapes called alike are told apart; what the board shown is inside, and the subject, is left out") {
        let town = Town()
        let yard = ShapeID(), kennelled = ShapeID()
        let h = try listHarness(town.file(adding: [held(called("Yard", box(yard)), in: town.k), link(ShapeID(), town.s, yard),
                                                   held(called("Kennel Gate", box(kennelled)), in: town.k), link(ShapeID(), town.s, kennelled)]))
        h.watch(town.s)
        expectEqual(h.line(town.b, in: Lists.wiredTo)?.detail, nil, "directly on the board shown")
        expectEqual(h.line(yard, in: Lists.wiredTo)?.detail, "Kennel", "in a corral on the board shown: the corral")
        expectEqual(h.line(town.y, in: Lists.wiredTo)?.name, "Yard")
        expectEqual(h.line(town.y, in: Lists.wiredTo)?.detail, "Park › Ring", "another Yard, on the pocket's board")
        // From inside the pocket, its own name and its owner's containers are left out; the corral on its board is not.
        expect(h.enter(town.p))
        h.watch(town.p)
        expectEqual(h.line(town.x, in: Lists.contains)?.detail, nil, "what the subject holds needs no saying")
        expectEqual(h.line(town.r, in: Lists.contains)?.detail, nil)
        h.watch(town.r)
        expectEqual(h.line(town.y, in: Lists.contains)?.detail, nil, "inside the subject, which is a corral on the board shown")
        h.watch(town.y)
        expectEqual(h.line(town.r, in: Lists.inside)?.detail, nil, "the corral it is in, on the board shown")
        expectEqual(h.line(town.p, in: Lists.inside)?.detail, "Board", "the pocket's card is on the root, in no container")
    },
    test("typed text of several words also keeps the rows whose containers the earlier words name: the name's strong matches, then paths, then the loose name") {
        let town = Town()
        let yard = ShapeID(), parkYard = ShapeID(), loose = ShapeID()
        let h = try listHarness(town.file(adding: [held(called("Yard", box(yard)), in: town.k), link(ShapeID(), town.s, yard),
                                                   called("Park Yard", box(parkYard)), link(ShapeID(), town.s, parkYard),
                                                   called("Pa rk y a r d", box(loose)), link(ShapeID(), town.s, loose)]))
        h.watch(town.s)
        h.list.setSearch("yard")
        expectEqual(h.rows(Lists.wiredTo), [town.y, yard, parkYard, loose], "one word is the name's alone, as ever: Yard twice, a word of Park Yard, the subsequence")
        h.list.setSearch("park yard")
        expectEqual(h.rows(Lists.wiredTo), [parkYard, town.y, loose], "its own name has both; the Yard in Park; then the name as a subsequence")
        h.list.setSearch("ring yard")
        expectEqual(h.rows(Lists.wiredTo), [town.y], "any container on the path, not only the nearest or the first")
        h.list.setSearch("kennel yard")
        expectEqual(h.rows(Lists.wiredTo), [yard], "the other Yard")
        h.list.setSearch("yard kennel")
        expectEqual(h.rows(Lists.wiredTo), [], "in order: the container comes first")
    },
    test("the lists follow the file: asked again once commits have stopped for a moment, never for moves, and an answer that reads the same shows nothing") {
        let town = Town()
        let h = try listHarness(town.file())
        h.watch(town.b)                                          // Bank: wired from Square
        expectEqual(h.rows(Lists.wiredFrom), [town.s])
        #if DEBUG
        let asked = h.list.asked, shown = h.list.shown
        #endif
        // Two commits in a run are one ask, once they've stopped.
        let first = ShapeID(), second = ShapeID()
        h.editor.transact("Link") { $0.insert(link(first, town.c, town.b)) }
        h.wait(60)
        h.editor.transact("Link") { $0.insert(link(second, town.u, town.b)) }
        h.wait(60)
        expectEqual(h.rows(Lists.wiredFrom), [town.s], "not yet: the last commit was 60 ms ago")
        h.settleList(after: 40)
        expectEqual(h.rows(Lists.wiredFrom), [town.s, town.c, town.u])
        #if DEBUG
        expectEqual(h.list.asked, asked + 1, "one ask for the run")
        expectEqual(h.list.shown, shown + 1)
        #endif
        // A rename shows in the row.
        h.editor.transact("Rename") { $0.update(town.c) { $0[Caption.self] = "Cantina" } }
        h.settleList(after: 100)
        expectEqual(h.line(town.c, in: Lists.wiredFrom)?.name, "Cantina")
        // Moves ask nothing.
        #if DEBUG
        let before = h.list.asked
        #endif
        h.editor.transact("Move") { $0.moveBox(town.b, to: CGPoint(x: 900, y: 900)) }
        h.editor.transact("Move") { $0.moveBox(town.c, to: CGPoint(x: 950, y: 950)) }
        h.wait(200)
        expect(!h.list.isAsking)
        #if DEBUG
        expectEqual(h.list.asked, before, "a drag costs a look at its change set")
        // A commit that changes nothing listed asks, and its answer is shown though it reads the same:
        // a row's name is read as it's drawn, and the commit may have changed what a shape is called.
        let shownBefore = h.list.shown
        h.editor.transact("Add") { $0.insert(box(ShapeID(), at: CGPoint(x: 1500, y: 1500))) }
        h.settleList(after: 100)
        expectEqual(h.list.asked, before + 1)
        expectEqual(h.list.shown, shownBefore + 1, "shown again, the names read again")
        // An answer nothing in the file asked for (a list folded and unfolded again) that reads the same isn't.
        h.list.unwatch(town.b)
        h.watch(town.b)
        expectEqual(h.list.shown, shownBefore + 1, "the same shape watched again: the same lists, nothing shown anew")
        #endif
        // A wire deleted, and its undo.
        h.editor.transact("Delete") { $0.delete([second]) }
        h.settleList(after: 100)
        expectEqual(h.rows(Lists.wiredFrom), [town.s, town.c])
        h.editor.undo()
        h.settleList(after: 100)
        expectEqual(h.rows(Lists.wiredFrom), [town.s, town.c, town.u])
    },
    test("a shape put in a corral joins what the corral holds, and what it's inside says so") {
        let town = Town()
        let h = try listHarness(town.file())
        h.watch(town.k)
        expectEqual(h.rows(Lists.contains), [town.g])
        h.editor.put([town.u], in: town.k)
        h.settleList(after: 100)
        expectEqual(Set(h.rows(Lists.contains)), [town.g, town.u])
        h.watch(town.u)
        expectEqual(h.rows(Lists.inside), [town.k])
    },
    test("a shape with no title is called what the table of contents calls it, read again after a commit though the lists read the same") {
        let town = Town()
        let jot = ShapeID()
        let record = AnyShapeRecord(ShapeRecord(id: jot, Memo(unit.offsetBy(dx: 100, dy: 700), text: "Remember the milk", lead: Citation(town.s))))
        let h = try listHarness(town.file(adding: [record]))
        h.watch(town.s)                                          // quoted by Mill, which has a caption, and by the memo, which has none
        expectEqual(h.rows(Lists.quotedBy), [town.m, jot])
        expectEqual(h.line(jot, in: Lists.quotedBy)?.name, "Remember the milk", "its row in the table of contents, not its kind's name")
        expectEqual(h.line(town.m, in: Lists.quotedBy)?.name, "Mill", "a titled shape, its title")
        let stamp = h.list.listing?.stamp
        h.editor.transact("Edit") { $0.update(jot, as: Memo.self) { $0.props.text = "Remember the eggs" } }
        h.settleList(after: 100)
        expectEqual(h.rows(Lists.quotedBy), [town.m, jot], "the lists read as they did")
        expectEqual(h.list.listing?.stamp, stamp.map { $0 + 1 }, "and the rows are drawn again")
        expectEqual(h.line(jot, in: Lists.quotedBy)?.name, "Remember the eggs")
        h.list.setSearch("eggs")
        expectEqual(h.rows(Lists.quotedBy), [jot], "and it is found by that name")
        // Edited while its list is off screen (another tab), with nothing heard: read again when the list is back.
        h.list.setSearch("")
        h.list.unwatch(town.s)
        h.editor.transact("Edit") { $0.update(jot, as: Memo.self) { $0.props.text = "Remember the tea" } }
        h.watch(town.s)
        expectEqual(h.line(jot, in: Lists.quotedBy)?.name, "Remember the tea")
    },
    test("the shape itself is never listed, though it matches") {
        let s = ShapeID(), l = ShapeID()
        let h = try listHarness(CanvasFile(root: board(called("Self", memo(s, quoting: s)), link(l, s, s))))
        h.watch(s)
        expectEqual(h.list.groups.indices.map(h.count), [0, 0, 0, 0, 0, 0])
        h.list.setFolded(Lists.quotes, true)
        h.list.watch(l)
        h.watch(s)
        expectEqual(h.count(Lists.quotes), 0, "nor counted, in a folded list")
    },
    test("a stand-in is listed with what it stands for, as both are lit: an arrow into a pill points to the pill and to the shape") {
        let town = Town()
        let pillID = ShapeID(), wire = ShapeID()
        let h = try listHarness(town.file(adding: [called("Pill", pill(pillID, standingFor: [town.q], at: CGPoint(x: 800, y: 500))), link(wire, town.c, pillID)]))
        h.watch(town.c)
        expectEqual(h.rows(Lists.wiredTo), [town.s, town.q, pillID], "Square; Quay, through the pill (the resolved view); and the pill, as drawn (the literal view)")
        h.watch(town.q)
        expectEqual(h.rows(Lists.wiredFrom), [town.c, pillID], "what points through the pill, and the pill that stands for it")
        h.watch(pillID)
        expectEqual(h.rows(Lists.wiredTo), [town.q], "what it stands for")
        expectEqual(h.rows(Lists.wiredFrom), [town.c], "what's drawn into it")
    },
    test("an answer provided for a stand-in, with no commit, asks again") {
        let town = Town()
        let lensID = ShapeID(), wire = ShapeID()
        let h = try listHarness(town.file(adding: [called("Lens", lens(lensID, asks: "what?", at: CGPoint(x: 800, y: 500))), link(wire, town.c, lensID)]))
        h.watch(town.c)
        expectEqual(h.rows(Lists.wiredTo), [town.s, lensID], "the lens stands for nothing yet")
        h.editor.topology?.provide([lensID: ProvidedForwarding(key: ForwardingKey("what?"), shapes: [town.q], revision: 1)])
        h.settleList()
        expectEqual(h.rows(Lists.wiredTo), [town.s, town.q, lensID])
    },
    test("nothing is asked for a list that isn't on screen") {
        let town = Town()
        let h = try listHarness(town.file())
        h.watch(town.b)
        h.list.unwatch(town.s)
        expectEqual(h.list.subject?.shape, town.b, "another shape's list going changes nothing")
        h.list.unwatch(town.b)
        expectEqual(h.list.subject, nil)
        expect(!h.list.hasLanded)
        h.editor.transact("Link") { $0.insert(link(ShapeID(), town.c, town.b)) }
        h.wait(200)
        expect(!h.list.isAsking)
        #if DEBUG
        expectEqual(h.list.asked, 1)
        #endif
        // A list that goes with its answer on the way lands nothing.
        h.list.watch(town.s)
        h.list.unwatch(town.s)
        expect(!h.list.isAsking)
        expectEqual(h.list.total, 0)
    },
    test("a row goes to its shape, on whichever board, one step back, and hovers it: on the canvas, or as a shape hovered elsewhere") {
        let town = Town()
        let h = try listHarness(town.file())
        h.editor.selection = town.s
        h.watch(town.s)
        h.list.hover(town.b)
        expectEqual(h.editor.hovered, town.b)
        h.list.endHover(town.c)
        expectEqual(h.editor.hovered, town.b, "another row's leaving lets go of nothing")
        h.list.endHover(town.b)
        expectEqual(h.editor.hovered, nil)
        h.list.hover(town.x)
        expectEqual(h.editor.hovered, nil, "not on the board shown")
        expectEqual(h.editor.hoveredElsewhere, town.x)
        h.list.endHover(town.x)
        expectEqual(h.editor.hoveredElsewhere, nil)
        h.editor.hovered = town.c                                // the canvas's own hover
        h.list.endHover(town.c)
        expectEqual(h.editor.hovered, town.c, "a row lets go only of the hover it set")
        h.list.go(to: town.b)
        expectEqual(h.editor.selection, town.s, "on the scheduler's next turn")
        h.wait(0)
        expectEqual(h.editor.selection, town.b)
        h.list.go(to: town.x)
        h.wait(0)
        expectEqual(h.editor.board, BoardID(owner: town.p))
        expectEqual(h.editor.selection, town.x)
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, town.b)
    },
    test("without the engine the lists land empty") {
        let town = Town()
        let h = try listHarness(town.file(), queries: false)
        h.list.watch(town.s)
        expect(!h.list.isAsking)
        expect(h.list.hasLanded)
        expectEqual(h.list.total, 0)
    },
    test("the tab is on every shape's panel, its plugin a face that needs the panel and no light") {
        let town = Town()
        let h = try listHarness(town.file())
        for id in [town.s, town.b, town.p, town.k, town.toB] {
            let layout = h.editor.detailPanel!.layout(for: h.editor.document[id]!)
            expect(layout.tabs.contains(.of(NeighborsTab.self)), "on a \(h.editor.document[id]!.kind)")
            expectEqual(layout.sections(in: .of(NeighborsTab.self)).map(\.section), ["neighbors"])
        }
        expectEqual(DetailTabID.of(NeighborsTab.self).title, "Connections")
        // No light, no Neighbors: the lists are what it's inside and what it holds.
        let bare = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PocketsPlugin(), CorralsPlugin(),
                                               QueriesPlugin(), DetailPanelPlugin(), NeighborDetailsPlugin()], file: CanvasFile(root: board(corral(town.k), held(box(town.g), in: town.k))))
        expectEqual(bare.list.groups.map(\.title), ["Inside", "Contains"])
        bare.list.watch(town.g)
        spinRunLoop(until: { !bare.list.isAsking })
        expectEqual(bare.list.shown(in: 0).rows.map(\.id), [town.k])
        // Without the panel, whose tab it is, it's refused.
        do {
            _ = try Registry(plugins: [NeighborsPlugin(), NeighborDetailsPlugin()])
            expect(false, "a list with the lists and no panel should be refused")
        } catch let error as RegistryError {
            expect("\(error)".contains("detail-panel"), "\(error)")
        }
    },
    test("in the panel, a selected shape's lists are asked for as they appear, and let go of as they go; long lists get a search field") {
        let town = Town()
        let extra = (0..<19).map { _ in ShapeID() }
        let h = try listHarness(town.file(adding: extra.flatMap { [called("Extra", box($0)), link(ShapeID(), town.b, $0)] }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DetailPanelView(editor: h.editor))
        defer { window.close() }
        h.editor.selection = town.c
        window.spin { h.list.subject?.shape == town.c && h.list.hasLanded }
        expectEqual(h.rows(Lists.wiredTo), [town.s])
        expectEqual(window.searchFields.count, 0, "one shape listed: nothing to search")
        h.editor.selection = town.b                              // wired from Square, to nineteen more
        window.spin { h.list.subject?.shape == town.b && h.list.hasLanded }
        expectEqual(h.count(Lists.wiredTo), 19)
        window.settle()
        expectEqual(window.searchFields.count, 1, "twenty shapes listed, with Square")
        h.editor.selection = nil
        window.spin { h.list.subject?.shape == nil }
        expect(!h.list.isAsking)
        // The same shape again: its lists, which read as they did, are drawn again all the same.
        #if DEBUG
        let drawn = h.list.linesDrawn
        h.editor.selection = town.b
        window.spin { h.list.subject?.shape == town.b && !h.list.isAsking }
        window.settle()
        expect(h.list.linesDrawn > drawn, "the rows of a shape selected again are drawn")
        #endif
    },
    test("a long list is all there, and only its rows in view are drawn") {
        let hub = ShapeID()
        let spokes = (0..<3_000).map { _ in ShapeID() }
        let h = try listHarness(CanvasFile(root: CanvasDocument(shapes: [called("Hub", box(hub))] + spokes.flatMap { [called("Spoke", box($0)), link(ShapeID(), hub, $0)] })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DetailPanelView(editor: h.editor))
        defer { window.close() }
        h.editor.selection = hub
        window.spin(until: { h.list.subject?.shape == hub && h.list.hasLanded }, timeout: 10)
        window.settle()
        expectEqual(h.count(Lists.wiredTo), 3_000)
        expectEqual(h.rows(Lists.wiredTo).count, 3_000, "every one of them, no cut")
        #if DEBUG
        expect(h.list.linesDrawn > 0 && h.list.linesDrawn < 300, "drew \(h.list.linesDrawn) rows of 3,000 in a panel 700 points tall")
        #endif
    },
    test("a list past what a query used to be cut at is all there too, counted and listed whole, and only its rows in view are drawn") {
        let hub = ShapeID()
        let many = 10_500
        let spokes = (0..<many).map { _ in ShapeID() }
        let h = try listHarness(CanvasFile(root: CanvasDocument(shapes: [called("Hub", box(hub))] + spokes.flatMap { [called("Spoke", box($0)), link(ShapeID(), hub, $0)] })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DetailPanelView(editor: h.editor))
        defer { window.close() }
        h.editor.selection = hub
        window.spin(until: { h.list.subject?.shape == hub && h.list.hasLanded }, timeout: 20)
        window.settle()
        expectEqual(h.count(Lists.wiredTo), many)
        expectEqual(h.rows(Lists.wiredTo).count, many, "every one of them, none cut at 10,000")
        #if DEBUG
        expect(h.list.linesDrawn > 0 && h.list.linesDrawn < 300, "drew \(h.list.linesDrawn) rows of \(many) in a panel 700 points tall")
        #endif
    },
])

extension NSWindow {
    /// The panel's text fields that are a search field's (its placeholder says so).
    var searchFields: [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.placeholderString == "Search" { found.append(field) }
            view.subviews.forEach(walk)
        }
        contentView.map(walk)
        return found
    }
}
