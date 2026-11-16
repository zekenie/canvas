@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import Observation
import Palette
import Queries
import QueryLanguage
import TestKit
import Titles
import Topology
import Validation

// The index: which shapes within each constrained place's reach break which of its constraints, kept by each commit and
// by the standing queries' answers. Pen is a corral 400 × 300 at (100, 100); Inner a corral in it at (150, 150), 200 ×
// 150. Discs 50 across, tiles 120 × 80.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)
private let innerRect = CGRect(x: 150, y: 150, width: 200, height: 150)

/// What a query says now, waited for as a query waits (for answers still to come, `:invalid` among them).
@MainActor func matched(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> Set<ShapeID> {
    let queries = try require(h.editor.queries, file: file, line: line)
    return Set(try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryRequest.every, properties: .none, settle: QueryBudget.settleWait))
    }.rows.map(\.id))
}

@MainActor let indexTests = Suite("Constraints: the index", [
    test("directly inside a place, or anywhere inside it: a disc in Inner breaks Pen's no discs only once it reaches anywhere inside") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let inner = h.corral("Inner", innerRect, in: pen)
        let direct = h.disc(at: CGPoint(x: 400, y: 320), in: pen), deep = h.disc(at: CGPoint(x: 200, y: 200), in: inner)
        let outside = h.disc(at: CGPoint(x: 700, y: 100))
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [direct])
        expectEqual(h.index.breaches(of: direct).map(\.constraint), [noDiscs])
        expectEqual(h.index.breaches(of: outside), [])
        expectEqual(h.issues(of: direct), ["Pen accepts no discs."])
        expectEqual(h.issues(of: deep), [])
        h.writer.setReach(.descendants, of: noDiscs, in: .shape(pen))
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [direct, deep])
        expectEqual(h.issues(of: deep), ["Pen accepts no discs."])
        expectEqual(h.index.constraints(of: .shape(pen)).map(\.constraint.reach), [.descendants])
    },
    test("nested places: a shape is held to the place it's in and to what reaches it from above, the nearest first") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [Constraint(says: "only tiles", query: "tile, corral", reach: .descendants)])
        let inner = h.corral("Inner", innerRect, [noDiscs], in: pen)
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: inner)
        h.settle()
        expectEqual(h.index.breaches(of: d).map(\.place), [.shape(inner), .shape(pen)], "the place it's directly in first")
        expectEqual(h.issues(of: d), ["Inner accepts no discs.", "Pen accepts only tiles."])
        expectEqual(h.breakers(of: .shape(inner)), [d])
        expectEqual(h.breakers(of: .shape(pen)), [d], "the corral it's in is one Pen takes")
    },
    test("a pocket's place is its board's top level: what's on it directly breaks it, what's in a corral there only when it reaches anywhere inside") {
        let h = try constraintHarness()
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        let board = BoardID(owner: drawer)
        let loose = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 50, height: 50))))
        let box = AnyShapeRecord(ShapeRecord(Corral(CGRect(x: 200, y: 0, width: 300, height: 300))))
        let held = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 250, y: 50, width: 50, height: 50))))
        h.editor.transact(on: board) { transaction in
            transaction.insert(loose)
            transaction.insert(box)
            transaction.insert(held.copy(as: held.id, container: box.id))
        }
        h.settle()
        expectEqual(h.breakers(of: .shape(drawer)), [loose.id])
        expectEqual(h.issues(ofShapeOnAnotherBoard: loose.id), ["Drawer accepts no discs."])
        h.writer.setReach(.descendants, of: noDiscs, in: .shape(drawer))
        h.settle()
        expectEqual(h.breakers(of: .shape(drawer)), [loose.id, held.id])
    },
    test("the root's list holds its top level, or the whole file: an untitled root is This board") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect)
        let top = h.disc(at: CGPoint(x: 700, y: 100)), held = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.writer.add(noDiscs, to: .root)
        h.settle()
        expectEqual(h.breakers(of: .root), [top])
        expectEqual(h.issues(of: top), ["This board accepts no discs."])
        h.editor.nameRoot("Plans")
        expectEqual(h.issues(of: top), ["Plans accepts no discs."], "a rename is no commit: its breakers are told")
        h.wait(0)
        h.editor.nameRoot("Ideas")
        expectEqual(h.issues(of: top), ["Ideas accepts no discs."], "and the next")
        h.writer.setReach(.descendants, of: noDiscs, in: .root)
        h.settle()
        expectEqual(h.breakers(of: .root), [top, held])
        expectEqual(h.index.breaches(of: held).map(\.place), [.root])
    },
    test("a standing query's flips: a tile made glossy fits, matte again breaks; while its answer is to come it keeps the verdict it had") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        let t = h.tile("T", at: CGPoint(x: 150, y: 150), in: pen)
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [t])
        h.editor.transact { $0.update(t, as: Tile.self) { $0.props.finish = .glossy } }
        expectEqual(h.breakers(of: .shape(pen)), [t], "kept until the answer lands: no ring blinks")
        expect(h.index.isBusy, "asking")
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [])
        expectEqual(h.issues(of: t), [])
        h.editor.undo()
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [t])
        expectEqual(h.issues(of: t), ["Pen accepts only glossy tiles."])
    },
    test("a constraint added to a full place: the shapes inside that break it are found once its query answers; taken away, they're let go") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect)
        let t = h.tile("T", at: CGPoint(x: 150, y: 150), in: pen), d = h.disc(at: CGPoint(x: 400, y: 320), in: pen)
        h.settle()
        h.writer.add(noDiscs, to: .shape(pen))
        expectEqual(h.breakers(of: .shape(pen)), [], "nothing yet: its query is asking")
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [d])
        expectEqual(h.issues(of: d), ["Pen accepts no discs."])
        expectEqual(h.issues(of: t), [])
        h.writer.remove(noDiscs, from: .shape(pen))
        expectEqual(h.breakers(of: .shape(pen)), [])
        expectEqual(h.issues(of: d), [])
        expectEqual(h.index.standingQuery(of: noDiscs) == nil, true, "its query let go with its last use")
    },
    test("a shape new to a place breaks nothing until its answer lands, then is flagged") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        h.settle()
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        expectEqual(h.index.breaches(of: d), [])
        expect(h.index.isBusy)
        h.settle()
        expectEqual(h.index.breaches(of: d).map(\.constraint), [noDiscs])
        expectEqual(h.issues(of: d), ["Pen accepts no discs."])
    },
    test("words not interpreted and a query the engine refuses check nothing, and the index says which") {
        let h = try constraintHarness()
        let words = Constraint(says: "only blue things")
        let scoped = Constraint(says: "only what's near", query: ":scope")
        let pen = h.corral("Pen", penRect, [words, scoped])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        expectEqual(h.index.state(of: words), .notInterpreted)
        guard case .refused(let error) = h.index.state(of: scoped) else { return expect(false, "refused") }
        expectEqual(error.reason, .unsupported)
        expectEqual(h.index.state(of: noDiscs), .standing, "one that reads, held or not")
        expectEqual(h.index.breaches(of: d), [])
        expectEqual(h.index.constraints(of: .shape(pen)).map(\.constraint), [words, scoped])
    },
    test("while a standing query is asking Topology isn't settled, so :invalid waits for its answers and lists the breaker") {
        let h = try constraintHarness(Given(), [ValidationQueriesPlugin()])
        let pen = h.corral("Pen", penRect, [noDiscs])
        h.settle()
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        expect(h.editor.topology?.isSettling == true, "kept settling while its answer is out")
        expectEqual(try matched(":invalid", on: h), [d], "waited for")
        expect(h.editor.topology?.isSettling == false)
    },
    test("a shape moved deep into a place costs its places and what it carries, never the board; a move within a place asks nothing") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let inner = h.corral("Inner", innerRect, in: pen)
        for x in stride(from: 0, to: 2000, by: 60) { h.disc(at: CGPoint(x: CGFloat(x), y: 700)) }
        let d = h.disc(at: CGPoint(x: 900, y: 100))
        h.settle()
        let judged = h.index.shapesJudged, walked = h.index.placesWalked
        let queries = try require(h.editor.queries)
        let whole = queries.standingWholeAsks, walks = queries.universeWalks
        h.editor.transact("Move") { $0.setContainer(d, to: inner) }
        expectEqual(h.index.shapesJudged - judged, 1, "the shape alone, by its places")
        expectEqual(h.index.placesWalked, walked, "no place's members gone through")
        h.settle()
        expectEqual(h.index.breaches(of: d), [], "children only: Inner holds it")
        expectEqual(queries.standingWholeAsks, whole, "no whole file asked")
        expectEqual(queries.universeWalks, walks, "and no walk")
        let moved = h.index.shapesJudged
        h.editor.transact("Shift") { $0.translate([d], by: CGPoint(x: 10, y: 0)) }
        expectEqual(h.index.shapesJudged, moved, "a move within its place judges nothing")
        // Inner put on the board: it and what it carries are judged, under a constraint that reaches anywhere inside.
        h.writer.setReach(.descendants, of: noDiscs, in: .shape(pen))
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [d])
        let before = h.index.shapesJudged
        h.editor.transact("Out") { $0.setContainer(inner, to: nil) }
        expectEqual(h.index.shapesJudged - before, 2, "Inner and the disc it carries")
        expectEqual(h.breakers(of: .shape(pen)), [])
    },
    test("a commit that writes hundreds of shapes in a constrained place costs a linear walk of them: what it wrote is worked out once, not for each shape judged") {
        @MainActor func putIn(_ count: Int) throws -> Duration {
            let h = try constraintHarness()
            let pen = h.corral("Pen", penRect, [onlyTiles])
            let tiles = (0..<count).map { n in h.tile("T\(n)", at: CGPoint(x: CGFloat(n % 40) * 130, y: 700 + CGFloat(n / 40) * 90)) }
            h.settle()
            let judged = h.index.shapesJudged
            // Shapes that exist, put in one commit: each is changed beyond moving (its container), so `edited` is a set built.
            let elapsed = threadCPUTime { h.editor.transact("Put in") { $0.setContainer(tiles, to: pen) } }
            expect(h.index.shapesJudged - judged <= 2 * count, "each shape judged by its place, not again for each other: \(h.index.shapesJudged - judged)")
            h.settle()
            expectEqual(h.breakers(of: .shape(pen)), [])
            return elapsed
        }
        _ = try putIn(100)
        let small = try putIn(400)
        let large = try putIn(2400)
        // Six times the shapes: some six times the time (a walk), never thirty-six (a rebuild of the written set for each).
        expect(large < small * 14 + .milliseconds(20), "400 shapes took \(small), 2,400 took \(large)")
    },
    test("what a commit wrote is worked out once, and not at all while no place judges: 2,000 shapes edited in a file with no constrained places build none") {
        let h = try constraintHarness()
        let tiles = (0..<2000).map { n in h.tile("T\(n)", at: CGPoint(x: CGFloat(n % 40) * 130, y: 700 + CGFloat(n / 40) * 90)) }
        h.settle()
        let none = h.index.writtenSetsBuilt
        h.editor.transact("Retitle") { transaction in
            for t in tiles { transaction.update(t, as: Tile.self) { $0.props.label = "again" } }
        }
        expectEqual(h.index.writtenSetsBuilt - none, 0, "no place, nothing judged: no set")
        let pen = h.corral("Pen", penRect, [onlyTiles])
        h.settle()
        let before = h.index.writtenSetsBuilt
        h.editor.transact("Put in") { $0.setContainer(tiles, to: pen) }
        expectEqual(h.index.writtenSetsBuilt - before, 1, "the shapes it wrote, once, for every shape judged")
        h.settle()
    },
    test("a place's lists from elsewhere come before its own, and one changed with no commit is heard") {
        let given = Given()
        let h = try constraintHarness(given)
        let charter = h.add(Charter(CGRect(x: 900, y: 0, width: 200, height: 100), name: "Sprint"))
        let pen = h.corral("Pen", penRect, [onlyTiles])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        expectEqual(h.index.breaches(of: d).map(\.constraint), [onlyTiles])
        let swatch = Swatch(RGB(hex: 0x4465E9))
        given.lists[pen] = [ConstraintSource(holder: charter, swatch: swatch, constraints: [noDiscs])]
        let revision = h.editor.revision
        h.index.inheritedConstraintsDidChange(of: [pen])
        expectEqual(h.editor.revision, revision, "no commit")
        expectEqual(h.index.sources(of: .shape(pen)).map(\.swatch), [swatch])
        expectEqual(h.index.constraints(of: .shape(pen)).map(\.origin), [.inherited(charter), .own])
        h.settle()
        expectEqual(h.index.breaches(of: d).map(\.constraint), [noDiscs, onlyTiles], "the given list first")
        expectEqual(h.issues(of: d), ["Pen accepts no discs.", "Pen accepts only tiles."], "Validation told with no commit")
        given.lists[pen] = nil
        h.index.inheritedConstraintsDidChange(of: [pen])
        expectEqual(h.index.breaches(of: d).map(\.constraint), [onlyTiles])
    },
    test("a place is never judged by its own constraints, and what keeps a list its own way is no place: nothing is judged against it") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles])
        let charter = h.add(Charter(CGRect(x: 600, y: 100, width: 300, height: 200), name: "Sprint"))
        h.writer.add(noDiscs, to: .shape(charter))
        h.disc(at: CGPoint(x: 650, y: 150))
        h.settle()
        expectEqual(h.index.breaches(of: pen), [], "Pen is no tile, and is not inside itself")
        expectEqual(h.index.constraints(of: .shape(charter)), [], "a holder has no place")
        expectEqual(h.breakers(of: .shape(charter)), [])
    },
    test("what a place's breakers and a shape's breaches are observed by is told as they change, with no commit to the shape") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        let t = h.tile("T", at: CGPoint(x: 150, y: 150), finish: .glossy, in: pen)
        h.settle()
        let placeTold = Flag(), shapeTold = Flag()
        withObservationTracking { _ = h.index.breakers(of: .shape(pen)) } onChange: { placeTold.set() }
        withObservationTracking { _ = h.index.breaches(of: t) } onChange: { shapeTold.set() }
        h.editor.transact { $0.update(t, as: Tile.self) { $0.props.finish = .matte } }
        expect(!placeTold.isSet && !shapeTold.isSet, "nothing yet: its answer is to come")
        h.settle()
        expect(placeTold.isSet && shapeTold.isSet, "told as the answer lands")
    },
    test("a holder's sources are told by what gives it lists, not by every commit: told with no commit, and by no retitle or move of another shape") {
        let given = Given()
        let h = try constraintHarness(given)
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 150, height: 150))
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        h.settle()
        let index = h.index
        @MainActor func tracking() -> Flag {
            let told = Flag()
            withObservationTracking { MainActor.assumeIsolated { _ = index.sources(of: .shape(charter)) } } onChange: { told.set() }
            return told
        }
        var told = tracking()
        given.lists[charter] = [ConstraintSource(holder: other, constraints: [noDiscs])]
        index.inheritedConstraintsDidChange(of: [charter])
        h.wait(0)
        expect(told.isSet, "what gives it lists said so, with no commit")
        expectEqual(index.sources(of: .shape(charter)).map(\.holder), [other])
        told = tracking()
        h.editor.transact("Retitle") { $0.update(other) { $0[TitleProperty.self] = "Other2" } }
        expect(!told.isSet, "an unrelated retitle tells it nothing")
        h.editor.transact("Move") { $0.translate([other], by: CGPoint(x: 5, y: 5)) }
        expect(!told.isSet, "nor a move, as a drag makes at every event")
        h.editor.transact("Edit") { $0.update(charter, as: Charter.self) { $0.props.list = "[]" } }
        expect(!told.isSet, "nor an edit of its own")
    },
    test("a file put in place tells the holders: a holder's section observed, the file put in place with another list given, told and read as it is; one the file has no more is let go of and told nothing") {
        let given = Given()
        let h = try constraintHarness(given)
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 150, height: 150))
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        let second = h.add(Charter(CGRect(x: 600, y: 420, width: 100, height: 80), name: "Sprint2"))
        h.settle()
        let index = h.index
        let both = h.editor.file
        given.lists[charter] = [ConstraintSource(holder: other, constraints: [noDiscs])]
        given.lists[second] = [ConstraintSource(holder: other, constraints: [noDiscs])]
        expectEqual(index.sources(of: .shape(charter)).first?.constraints, [noDiscs])
        expectEqual(index.sources(of: .shape(second)).first?.constraints, [noDiscs])
        h.editor.transact("Delete") { $0.delete([second]) }
        let one = h.editor.file
        @MainActor func tracking(_ id: ShapeID) -> Flag {
            let told = Flag()
            withObservationTracking { MainActor.assumeIsolated { _ = index.sources(of: .shape(id)) } } onChange: { told.set() }
            return told
        }
        // What gives the lists changed with the file put in place, and no commit to the holders says so.
        given.lists[charter] = [ConstraintSource(holder: other, constraints: [noDiscs, onlyTiles])]
        var told = tracking(charter), toldSecond = tracking(second)
        h.editor.replaceFile(with: both)
        h.settle()
        h.wait(0)
        expect(told.isSet, "a holder's section is told when a file is put in place")
        expectEqual(index.sources(of: .shape(charter)).first?.constraints, [noDiscs, onlyTiles], "and reads the list as it is")
        expect(toldSecond.isSet, "so is every holder the index was asked of that the file holds")
        // One the file has no more is let go of: nobody is told of it, and the ones left still are.
        told = tracking(charter)
        toldSecond = tracking(second)
        given.lists[charter] = [ConstraintSource(holder: other, constraints: [onlyTiles])]
        h.editor.replaceFile(with: one)
        h.settle()
        h.wait(0)
        expect(told.isSet, "the holder left is told")
        expectEqual(index.sources(of: .shape(charter)).first?.constraints, [onlyTiles])
        expect(!toldSecond.isSet, "the holder gone from the file is not")
    },
    test("a place renamed gives its breakers' issues its new name; one deleted lets its breakers go") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        h.editor.transact("Rename") { $0.update(pen) { $0[TitleProperty.self] = "Backlog" } }
        expectEqual(h.issues(of: d), ["Backlog accepts no discs."])
        h.editor.transact("Untitle") { $0.update(pen) { $0[TitleProperty.self] = nil } }
        expectEqual(h.issues(of: d), ["This corral accepts no discs."])
        h.editor.transact("Delete") { $0.delete([pen]) }
        expectEqual(h.index.breaches(of: d), [])
        expectEqual(h.issues(of: d), [])
        h.editor.undo()
        h.settle()
        expectEqual(h.issues(of: d), ["This corral accepts no discs."], "an undo that puts a misfit back flags it")
    },
    test("the root's list holds its top level only: a disc in a place is no member of it, judged at once by a query that stands already") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let top = h.disc(at: CGPoint(x: 700, y: 100)), held = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [held])
        h.writer.add(noDiscs, to: .root)
        expectEqual(h.breakers(of: .root), [top], "answered already: decided at once, the disc in Pen not among its members")
        h.settle()
        expectEqual(h.breakers(of: .root), [top])
        expectEqual(h.index.breaches(of: held).map(\.place), [.shape(pen)])
    },
    test("a constraint changed but for its query keeps its query standing and its answers: no whole file asked, a misfit moved in at once refused") {
        let h = try constraintHarness()
        for x in stride(from: 0, to: 3000, by: 60) { h.disc(at: CGPoint(x: CGFloat(x), y: 900)) }
        let pen = h.corral("Pen", penRect, [noDiscs])
        let t = h.tile("T", at: CGPoint(x: 150, y: 150), in: pen), d = h.disc(at: CGPoint(x: 600, y: 150))
        let inside = h.disc(at: CGPoint(x: 400, y: 320), in: pen)
        h.settle()
        let queries = try require(h.editor.queries)
        let query = try require(h.index.standingQuery(of: noDiscs))
        let whole = queries.standingWholeAsks, judged = h.index.shapesJudged
        h.writer.setReach(.descendants, of: noDiscs, in: .shape(pen))
        let deep = Constraint(says: "no discs", query: ":not(disc)", reach: .descendants)
        expect(h.index.standingQuery(of: deep) === query, "the same standing query")
        expectEqual(queries.standingWholeAsks, whole, "the file not asked again")
        expectEqual(h.breakers(of: .shape(pen)), [inside], "judged by the answers it had")
        h.editor.transact("Put") { $0.setContainer(d, to: pen) }
        expectEqual(h.editor.holder(of: d), nil, "refused in the same turn")
        h.writer.replace(deep, with: Constraint(says: "nothing round", query: ":not(disc)", reach: .descendants), in: .shape(pen))
        expect(h.index.standingQuery(of: noDiscs) === query, "reworded: the same")
        h.editor.undo()
        h.editor.undo()
        h.settle()
        expect(h.index.standingQuery(of: noDiscs) === query, "and through undo")
        expectEqual(queries.standingWholeAsks, whole, "no whole file asked")
        expect(h.index.shapesJudged - judged <= 12, "the members, each change: \(h.index.shapesJudged - judged)")
        expectEqual(h.breakers(of: .shape(pen)), [inside])
        _ = t
    },
    test("a first answer over a big board judges the members of the places that use the query, never the board") {
        let h = try constraintHarness()
        h.editor.transact { transaction in
            for i in 0..<3000 {
                transaction.insert(AnyShapeRecord(ShapeRecord(Disc(CGRect(x: CGFloat(i % 100) * 60, y: 900 + CGFloat(i / 100) * 60, width: 50, height: 50)))))
            }
        }
        let pen = h.corral("Pen", penRect)
        let t = h.tile("T", at: CGPoint(x: 150, y: 150), in: pen), d = h.disc(at: CGPoint(x: 400, y: 320), in: pen)
        h.settle()
        let judged = h.index.shapesJudged
        h.writer.add(Constraint(says: "no tiles", query: ":not(tile)"), to: .shape(pen))
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [t])
        expect(h.index.shapesJudged - judged <= 12, "Pen's two, as the list changed and as each answer landed, of 3,000: \(h.index.shapesJudged - judged)")
        _ = d
    },
    test("a constraint a place has from elsewhere and as its own is judged once, as from elsewhere; its row is listed both ways") {
        let given = Given()
        let h = try constraintHarness(given)
        let work = h.add(Charter(CGRect(x: 900, y: 0, width: 200, height: 100), name: "Work"))
        let charter = h.add(Charter(CGRect(x: 900, y: 200, width: 200, height: 100), name: "Sprint"))
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        // As a type and the type it builds on would give the same words.
        given.lists[pen] = [ConstraintSource(holder: work, constraints: [noDiscs, onlyTiles]), ConstraintSource(holder: charter, constraints: [onlyTiles])]
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.settle()
        expectEqual(h.issues(of: d), ["Pen accepts no discs.", "Pen accepts only tiles."], "each once")
        expectEqual(h.index.breaches(of: d).map(\.origin), [.inherited(work), .inherited(work)], "from where it first comes")
        expectEqual(h.index.constraints(of: .shape(pen)).map(\.origin), [.inherited(work), .inherited(work), .inherited(charter), .own])
        expectEqual(h.index.breakers(of: PlacedConstraint(place: .shape(pen), origin: .own, constraint: noDiscs)), [])
        given.lists[pen] = nil
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.settle()
        expectEqual(h.index.breaches(of: d).map(\.origin), [.own], "its own judges it again")
        expectEqual(h.issues(of: d), ["Pen accepts no discs."])
    },
    test("a place turned into a kind that holds no constraints goes, and its breakers with it") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 400, y: 320), in: pen)
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [d])
        var turned = false
        h.editor.transact("Turn") { turned = $0.turn(pen, into: Charter(penRect)) }
        expect(turned)
        h.settle()
        expectEqual(h.index.constraints(of: .shape(pen)), [])
        expectEqual(h.breakers(of: .shape(pen)), [])
        expectEqual(h.index.breaches(of: d), [])
        expectEqual(h.index.standingQuery(of: noDiscs) == nil, true, "its query let go")
    },
    test("a query the engine refuses stands once the file makes it read (an edge type a shape brings), and judges its members") {
        let h = try constraintHarness(Given(), [tethers()])
        let untethered = Constraint(says: "nothing tethered", query: ":not(:edge-to(*, tether))")
        let pen = h.corral("Pen", penRect, [untethered])
        let t = h.tile("T", at: CGPoint(x: 150, y: 150), in: pen)
        h.settle()
        guard case .refused(let error) = h.index.state(of: untethered) else { return expect(false, "refused: no tether yet") }
        expectEqual(error.reason, .unknownEdgeType)
        h.tile("U", at: CGPoint(x: 300, y: 150), urgent: true, in: pen)
        expectEqual(h.index.state(of: untethered), .standing, "an added shape brings it")
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)).count, 1, "the tethered one")
        expectEqual(h.index.breaches(of: t), [])
        // Another, read once an edit brings its edge type.
        let g = try constraintHarness(Given(), [tethers()])
        let fold = g.corral("Fold", penRect, [untethered])
        let u = g.tile("U", at: CGPoint(x: 150, y: 150), in: fold)
        g.settle()
        g.editor.transact("Urgent") { $0.update(u) { $0[Urgent.self] = true } }
        expectEqual(g.index.state(of: untethered), .standing)
        g.settle()
        expectEqual(g.breakers(of: .shape(fold)), [u])
    },
    test("refused queries are asked again only when an edge type could undo the refusal: twenty refused cost a keystroke nothing") {
        let h = try constraintHarness(Given(), [tethers()])
        let queries = try require(h.editor.queries)
        let pen = h.corral("Pen", penRect, (0..<20).map { Constraint(says: "word \($0)", query: ":no-such-word-\($0)") })
        let tethered = h.corral("Fold", CGRect(x: 600, y: 100, width: 300, height: 200), [Constraint(says: "nothing tethered", query: ":not(:edge-to(*, tether))")])
        let t = h.tile("T", at: CGPoint(x: 150, y: 150), in: pen)
        let u = h.tile("U", at: CGPoint(x: 650, y: 150), in: tethered)
        h.settle()
        guard case .refused(let error) = h.index.state(of: Constraint(says: "word 3", query: ":no-such-word-3")) else { return expect(false, "refused") }
        expectEqual(error.reason, .unknownPseudoClass)
        let checks = queries.checks
        h.editor.transact("Retitle") { $0.update(t) { $0[TitleProperty.self] = "Renamed" } }
        h.tile("V", at: CGPoint(x: 150, y: 250), in: pen)
        h.editor.transact("Delete") { $0.delete([t]) }
        expectEqual(queries.checks - checks, 0, "no refused query read again: an edge type undoes none of the twenty, and the one it could waits for one")
        expectEqual(h.index.state(of: Constraint(says: "nothing tethered", query: ":not(:edge-to(*, tether))")) == .standing, false, "still refused")
        // A shape that brings the edge type: the one query that waited for it is asked, and read.
        let before = queries.checks
        h.editor.transact("Urgent") { $0.update(u) { $0[Urgent.self] = true } }
        expectEqual(queries.checks - before, 2, "the one an edge type could undo: asked, then stood")
        h.settle()
        expectEqual(h.breakers(of: .shape(tethered)), [u])
    },
    test("a refused query that names a shape by id (a container of a kind that holds none) is asked again when a commit removes or rewrites that shape; another shape's commit asks it nothing") {
        let h = try constraintHarness()
        let queries = try require(h.editor.queries)
        let d = h.disc(at: CGPoint(x: 600, y: 100)), other = h.disc(at: CGPoint(x: 700, y: 100))
        let c = Constraint(says: "in the disc", query: "#\(d.rawValue.uuidString) > tile")
        h.corral("Pen", penRect, [c])
        h.settle()
        guard case .refused(let error) = h.index.state(of: c) else { return expect(false, "refused: \(h.index.state(of: c))") }
        expectEqual(error.reason, .cannotContain)
        expectEqual(error.shapesNamed, [d.rawValue], "the shape is the refusal's data")
        let checks = queries.checks
        h.editor.transact("Other") { $0.delete([other]) }
        h.editor.transact("Retitle") { $0.update(d) { _ in } }
        expectEqual(queries.checks - checks, 0, "a commit that reaches no shape it names reads no refused query again")
        h.editor.transact("Delete") { $0.delete([d]) }
        expectEqual(queries.checks - checks, 2, "the commit that removes it: asked, then stood")
        expectEqual(h.index.state(of: c), .standing, "the refusal depended on the disc being in the file")
        h.settle()
    },
    test("a refusal that depended on a shape's kind is undone when a commit on another board rewrites that shape, and one for an edge type when another board brings it") {
        let h = try constraintHarness(Given(), [tethers()])
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150))
        let board = BoardID(owner: drawer)
        let held = AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 250, y: 50, width: 120, height: 80), label: "T", finish: .matte)))
        let box = AnyShapeRecord(ShapeRecord(Corral(CGRect(x: 200, y: 0, width: 300, height: 300))))
        h.editor.transact(on: board) { transaction in
            transaction.insert(box)
            transaction.insert(held.copy(as: held.id, container: box.id))
        }
        let nothingTethered = Constraint(says: "nothing tethered", query: ":not(:edge-to(*, tether))")
        let inTile = Constraint(says: "in the tile", query: "#\(held.id.rawValue.uuidString) > disc")
        h.corral("Pen", penRect, [nothingTethered, inTile])
        h.settle()
        for each in [nothingTethered, inTile] {
            guard case .refused = h.index.state(of: each) else { return expect(false, "refused before: \(each.says)") }
        }
        let queries = try require(h.editor.queries)
        h.editor.transact(on: board) { $0.update(held.id) { $0[Urgent.self] = true } }
        expect(queries.presentEdgeTypes.contains("tether"), "the other board brought the edge type")
        expectEqual(h.index.state(of: nothingTethered), .standing, "an edge type brought from another board stands the refused query")
        guard case .refused = h.index.state(of: inTile) else { return expect(false, "still the tile's: it is no container") }
        h.settle()
        h.editor.transact(on: board) { $0.delete([held.id]) }
        expectEqual(h.index.state(of: inTile), .standing, "the shape went, on another board")
        h.settle()
    },
    test("the shapes gone it remembers are bounded: past the limit the oldest half is let go, and a cut's shape it forgot goes in") {
        let h = try constraintHarness()
        h.index.goneLimit = 4
        let pen = h.corral("Pen", penRect, [noDiscs])
        let discs = (0..<5).map { h.disc(at: CGPoint(x: 600 + CGFloat($0) * 60, y: 150)) }
        h.settle()
        var records: [ShapeID: AnyShapeRecord] = [:]
        for d in discs {
            records[d] = h.editor.document[d]
            h.editor.transact("Cut") { $0.delete([d]) }
        }
        @MainActor func pasteBack(_ id: ShapeID) -> Bool {
            let record = records[id]!
            return h.editor.transactWhole("Paste") { transaction -> Bool in
                transaction.treatAsMoved([id])
                transaction.insert(record.copy(as: id, container: pen))
                guard case .settled = transaction.settle([id]) else { throw Transaction.Refused() }
                return true
            } == true
        }
        expect(pasteBack(discs[0]), "the oldest, let go of: no answer, in")
        expect(pasteBack(discs[1]), "the next oldest too")
        expect(!pasteBack(discs[2]), "remembered: refused")
        expect(!pasteBack(discs[4]), "the newest: refused")
    },
])

/// Tethers: an urgent tile is tied to the place it's in by an edge of a type no plugin declares, so a query that names
/// it reads only while the file has one.
@MainActor func tethers() -> Contributor {
    Contributor(id: "tethers") { r in
        r.edges(Tile.self) { record, _, sink in
            guard record[Urgent.self] == true, let container = record.container else { return }
            sink.emit("tether", from: record.id, to: container)
        }
    }
}

extension EditorHarness {
    /// What Validation says of a shape on a board not shown, its rules run over that board.
    func issues(ofShapeOnAnotherBoard id: ShapeID) -> [String] {
        guard let board = editor.file.board(containing: id), let record = editor.file.record(id) else { return [] }
        let shapes = ShapeContext(document: editor.contents(of: board), registry: editor.registry)
        return editor.registry.validationIssues(of: record, in: shapes, editor: editor).map(\.message)
    }
}
