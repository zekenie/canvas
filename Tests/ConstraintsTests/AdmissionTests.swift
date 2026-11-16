@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import Selection
import TestKit

// Refusing through the core: a shape moved into a constraint's reach from outside it that its query answers no for is
// refused as a drop into a locked frame is (back where it was, no step, the place shakes, its words heard once); moving
// within a place asks nothing, leaving is free, and a shape made there goes in. Pen is a corral 400 × 300 at (100,
// 100); the select tool drags.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)
private let innerRect = CGRect(x: 150, y: 150, width: 200, height: 150)
private let noTiles = Constraint(says: "no tiles", query: ":not(tile)")

@MainActor let admissionTests = Suite("Constraints: refusing what's moved in", [
    test("a disc dropped into a place that accepts no discs goes back, no step; the hint shows nothing and says nothing; the release says the words once") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 600, y: 150))
        h.settle()
        let step = h.editor.undoHistory.undoName
        h.editor.setTool(.select)
        h.press(at: CGPoint(x: 625, y: 175))
        h.drag(to: CGPoint(x: 500, y: 175))
        h.drag(to: CGPoint(x: 300, y: 175))
        expectEqual(h.editor.hintedShapeID, nil, "no outline over a place that would refuse it")
        expectEqual(h.editor.announcements, [], "a try says nothing")
        h.release()
        expectEqual(h.origin(of: d), CGPoint(x: 600, y: 150))
        expectEqual(h.editor.holder(of: d), nil)
        expectEqual(log.refusals, [[pen]], "the place shakes")
        expectEqual(h.editor.announcements, ["Pen accepts no discs."])
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
    },
    test("only coming in is refused: a misfit made inside moves within its place and leaves it freely") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        expectEqual(h.editor.holder(of: d), pen, "made there, it went in")
        h.drop(from: CGPoint(x: 225, y: 225), to: CGPoint(x: 325, y: 245))
        expectEqual(h.origin(of: d), CGPoint(x: 300, y: 220), "moved within Pen")
        expectEqual(h.editor.holder(of: d), pen)
        h.drop(from: CGPoint(x: 325, y: 245), to: CGPoint(x: 725, y: 245))
        expectEqual(h.editor.holder(of: d), nil, "left Pen")
        expectEqual(log.refusals, [])
        expectEqual(h.editor.announcements, [])
    },
    test("a drop of a tile and a disc together is refused whole") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let t = h.tile("T", at: CGPoint(x: 600, y: 250)), d = h.disc(at: CGPoint(x: 600, y: 150))
        h.settle()
        h.editor.selectedShapeIDs = [t, d]
        h.drop(from: CGPoint(x: 625, y: 175), to: CGPoint(x: 325, y: 175))
        expectEqual([h.origin(of: t), h.origin(of: d)], [CGPoint(x: 600, y: 250), CGPoint(x: 600, y: 150)])
        expectEqual([h.editor.holder(of: t), h.editor.holder(of: d)], [nil, nil])
        expectEqual(log.refusals, [[pen]])
    },
    test("a corral dropped with a disc in it: let in by a constraint on what's directly inside, refused by one that reaches anywhere inside") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", CGRect(x: 100, y: 100, width: 600, height: 500), [noDiscs])
        let fold = h.corral("Fold", CGRect(x: 900, y: 100, width: 200, height: 150))
        let d = h.disc(at: CGPoint(x: 950, y: 150), in: fold)
        h.settle()
        h.drop(from: CGPoint(x: 905, y: 240), to: CGPoint(x: 205, y: 240))
        expectEqual(h.editor.holder(of: fold), pen, "Fold is no disc")
        expectEqual(h.editor.holder(of: d), fold)
        h.editor.undo()
        h.writer.setReach(.descendants, of: noDiscs, in: .shape(pen))
        h.settle()
        h.drop(from: CGPoint(x: 905, y: 240), to: CGPoint(x: 205, y: 240))
        expectEqual(h.editor.holder(of: fold), nil, "what it carries is refused")
        expectEqual(h.editor.announcements.last, "Pen accepts no discs.")
    },
    test("the root refuses what comes onto its top level: the arrivals shake, as no shape holds its list") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect)
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.writer.add(noDiscs, to: .root)
        h.settle()
        h.drop(from: CGPoint(x: 225, y: 225), to: CGPoint(x: 725, y: 225))
        expectEqual(h.editor.holder(of: d), pen, "back in Pen")
        expectEqual(log.refusals, [[d]])
        expectEqual(h.editor.announcements, ["This board accepts no discs."])
    },
    test("shapes made in a place go in: an insert's, a paste's copy; a cut's shapes pasted back are moved, and refused") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let made = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        expectEqual(h.editor.holder(of: made), pen)
        let copy = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 300, y: 200, width: 50, height: 50))))
        h.editor.transact("Paste") { transaction in
            transaction.insert(copy.copy(as: copy.id, container: pen))
            _ = transaction.settle([copy.id])
        }
        expectEqual(h.editor.holder(of: copy.id), pen, "a paste's copy is new: it goes in")
        h.settle()
        expectEqual(h.index.breaches(of: copy.id).map(\.constraint), [noDiscs], "flagged")
        // A cut's: the shape itself, from nowhere the transaction says, moved.
        let cut = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 600, y: 200, width: 50, height: 50))))
        h.editor.transact { $0.insert(cut) }
        h.settle()
        h.editor.transact("Cut") { $0.delete([cut.id]) }
        let pasted: Bool? = h.editor.transactWhole("Paste") { transaction in
            transaction.treatAsMoved([cut.id])
            transaction.insert(cut.copy(as: cut.id, container: pen))
            guard case .settled = transaction.settle([cut.id]) else { throw Transaction.Refused() }
            return true
        }
        expect(pasted == nil, "refused whole")
        expectEqual(h.editor.document[cut.id], nil)
    },
    test("a corral turned into a pocket in one transaction, keeping its id, takes what it held onto its board as no arrival: a misfit flagged there already stays flagged, with none refused; a shape moved in from outside is still judged") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        let t = h.tile("T", at: CGPoint(x: 200, y: 300), in: pen)
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [d], "the disc is flagged in Pen")
        let step = h.editor.undoHistory.undoName
        let turned: Bool? = h.editor.transactWhole("Turn") { transaction in
            guard transaction.turn(pen, into: Pocket(penRect)), transaction.move([d, t], toBoardOwnedBy: pen) else { throw Transaction.Refused() }
            return true
        }
        expect(turned == true, "it turns: what stays under the holder is no arrival")
        expectEqual(log.refusals, [], "nothing shakes")
        expectEqual(h.editor.document[pen]?.kind, Pocket.kind, "a pocket now")
        expectEqual(h.editor.file.board(containing: d), BoardID(owner: pen), "the disc is on its board")
        expectEqual(h.editor.undoHistory.undoName, "Turn")
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [d], "and still flagged there")
        h.editor.undo()
        expectEqual(h.editor.undoHistory.undoName, step)
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [d], "flagged in the corral again")
        // The control: a disc from outside the place, put on the pocket's board, is still refused.
        h.editor.redo()
        h.settle()
        let outside = h.disc(at: CGPoint(x: 600, y: 150))
        h.settle()
        let moved: Bool? = h.editor.transactWhole("Move") { transaction in
            guard transaction.move([outside], toBoardOwnedBy: pen) else { throw Transaction.Refused() }
            return true
        }
        expect(moved == nil, "a disc from outside is refused")
        expectEqual(h.editor.file.board(containing: outside), .root, "and stays")
    },
    test("a cut's corral pasted back into a place reaching anywhere inside, its disc inserted after it and nothing settled, is refused") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", CGRect(x: 100, y: 100, width: 600, height: 500), [Constraint(says: "no discs anywhere inside", query: ":not(disc)", reach: .descendants)])
        let fold = h.corral("Fold", CGRect(x: 900, y: 100, width: 200, height: 150))
        let d = h.disc(at: CGPoint(x: 950, y: 150), in: fold)
        h.settle()
        let foldRecord = try require(h.editor.document[fold]), discRecord = try require(h.editor.document[d])
        h.editor.transact("Cut") { $0.delete([fold, d]) }
        let pasted: Bool? = h.editor.transactWhole("Paste") { transaction in
            transaction.treatAsMoved([fold, d])
            var f = foldRecord.copy(as: fold, container: pen)
            f.box = CGRect(x: 150, y: 150, width: 200, height: 150)
            var e = discRecord.copy(as: d, container: fold)
            e.box = CGRect(x: 200, y: 200, width: 50, height: 50)
            transaction.insert(f)
            transaction.insert(e)
            return true
        }
        expect(pasted == nil, "refused: the disc it carries comes under Pen")
        expectEqual(h.editor.document[fold], nil)
        expectEqual(h.editor.announcements.last, "Pen accepts no discs anywhere inside.")
    },
    test("a move onto a pocket's board that accepts no discs is refused, committing nothing; setContainer into Pen too") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 900, y: 400))
        h.settle()
        let revision = h.editor.revision
        h.editor.transact("Move") { $0.move([d], toBoardOwnedBy: drawer) }
        expectEqual(h.editor.file.board(containing: d), .root)
        expectEqual(h.editor.revision, revision, "nothing committed")
        h.editor.transact("Put") { $0.setContainer(d, to: pen) }
        expectEqual(h.editor.holder(of: d), nil)
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals.last, [pen])
        expectEqual(h.editor.announcements.suffix(1), ["Pen accepts no discs."])
        let t = h.tile("T", at: CGPoint(x: 900, y: 500))
        h.settle()
        h.editor.transact("Move") { $0.move([t], toBoardOwnedBy: drawer) }
        expectEqual(h.editor.file.board(containing: t), BoardID(owner: drawer), "a tile goes")
    },
    test("a shape whose answer is still to come is let in, and flagged once it lands") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        let t = h.tile("T", at: CGPoint(x: 600, y: 150), finish: .glossy)
        h.settle()
        h.editor.transact { $0.update(t, as: Tile.self) { $0.props.finish = .matte } }
        expect(h.index.isBusy, "asked again")
        h.drop(from: CGPoint(x: 660, y: 190), to: CGPoint(x: 300, y: 190))
        expectEqual(h.editor.holder(of: t), pen, "no answer yet: in")
        h.settle()
        expectEqual(h.issues(of: t), ["Pen accepts only glossy tiles."])
        // Answered now: a matte tile moved in from outside is refused.
        h.editor.undo()
        h.settle()
        expectEqual(h.editor.holder(of: t), nil)
        h.drop(from: CGPoint(x: 660, y: 190), to: CGPoint(x: 300, y: 190))
        expectEqual(h.editor.holder(of: t), nil, "refused")
    },
    test("a shape asked again (an edit does) is judged by the last answer it had, by a try and by a commit: a no refuses, a yes admits") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        let m = h.tile("M", at: CGPoint(x: 600, y: 150)), g = h.tile("G", at: CGPoint(x: 600, y: 300), finish: .glossy)
        h.settle()
        h.editor.transact("Edit") { $0.update(m, as: Tile.self) { $0.props.label = "Rough" } }
        h.editor.transact("Edit") { $0.update(g, as: Tile.self) { $0.props.label = "Smooth" } }
        expect(h.index.isBusy, "both asked again")
        expect(!h.editor.admits([m], into: .container(pen)), "the try: it last answered no")
        expect(h.editor.admits([g], into: .container(pen)), "the try: it last answered yes")
        let step = h.editor.undoHistory.undoName
        h.drop(from: CGPoint(x: 660, y: 190), to: CGPoint(x: 300, y: 190))
        expectEqual(h.editor.holder(of: m), nil, "refused by the answer it had")
        expectEqual(log.refusals.last, [pen])
        expectEqual(h.editor.announcements.last, "Pen accepts only glossy tiles.")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        h.drop(from: CGPoint(x: 660, y: 340), to: CGPoint(x: 300, y: 240))
        expectEqual(h.editor.holder(of: g), pen, "admitted by the answer it had")
        h.settle()
        expectEqual(h.index.breaches(of: g), [], "and it still fits")
        expectEqual(h.editor.holder(of: m), nil, "the answer that lands changes nothing here")
    },
    test("a shape's answer that is still to come for want of any (new to the file, a first answer not landed) is no refusal; a cut's shape pasted back goes by the last answer it had") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        let t = h.tile("T", at: CGPoint(x: 600, y: 150))
        expect(h.index.isBusy)
        expect(h.editor.admits([t], into: .container(pen)), "the first answer hasn't landed")
        h.settle()
        expect(!h.editor.admits([t], into: .container(pen)))
        let u = h.tile("U", at: CGPoint(x: 600, y: 300))
        expect(h.index.isBusy)
        expect(h.editor.admits([u], into: .container(pen)), "new to the file")
        h.drop(from: CGPoint(x: 660, y: 340), to: CGPoint(x: 300, y: 240))
        expectEqual(h.editor.holder(of: u), pen, "and it goes in")
        h.settle()
        expectEqual(h.issues(of: u), ["Pen accepts only glossy tiles."], "flagged once answered")
        // Edited, cut and pasted back before the query answered the edit.
        h.editor.transact("Edit") { $0.update(t, as: Tile.self) { $0.props.label = "Rough" } }
        expect(h.index.isBusy)
        let record = try require(h.editor.document[t])
        h.editor.transact("Cut") { $0.delete([t]) }
        let pasted: Bool? = h.editor.transactWhole("Paste") { transaction in
            transaction.treatAsMoved([t])
            transaction.insert(record.copy(as: t, container: pen))
            guard case .settled = transaction.settle([t]) else { throw Transaction.Refused() }
            return true
        }
        expect(pasted == nil, "it last answered no")
        expectEqual(h.editor.document[t], nil)
    },
    test("a shape the move itself rewrote has no answer yet: in, then judged by what it is now") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        let t = h.tile("T", at: CGPoint(x: 600, y: 150)), u = h.tile("U", at: CGPoint(x: 600, y: 300))
        h.settle()
        h.editor.transact("Both") { transaction in
            transaction.update(t, as: Tile.self) { $0.props.label = "Rough" }
            transaction.setContainer(t, to: pen)
        }
        expectEqual(h.editor.holder(of: t), pen, "its answer was of what it was: in")
        h.settle()
        expectEqual(h.issues(of: t), ["Pen accepts only glossy tiles."], "still matte: flagged once answered")
        h.editor.transact("Both") { transaction in
            transaction.update(u, as: Tile.self) { $0.props.finish = .glossy }
            transaction.setContainer(u, to: pen)
        }
        expectEqual(h.editor.holder(of: u), pen, "made glossy as it moves: in")
        h.settle()
        expectEqual(h.index.breaches(of: u), [], "and fits")
    },
    test("a place a shape is under already takes it in deeper: a disc moved from Pen into Inner meets Inner's constraints, not Pen's again") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [Constraint(says: "no discs anywhere inside", query: ":not(disc)", reach: .descendants)])
        let inner = h.corral("Inner", innerRect, in: pen)
        let d = h.disc(at: CGPoint(x: 400, y: 330), in: pen)
        h.settle()
        h.drop(from: CGPoint(x: 425, y: 355), to: CGPoint(x: 225, y: 225))
        expectEqual(h.editor.holder(of: d), inner, "it was under Pen already")
        let g = try constraintHarness()
        let pen2 = g.corral("Pen", penRect)
        g.corral("Inner", innerRect, [noDiscs], in: pen2)
        let e = g.disc(at: CGPoint(x: 400, y: 330), in: pen2)
        g.settle()
        g.drop(from: CGPoint(x: 425, y: 355), to: CGPoint(x: 225, y: 225))
        expectEqual(g.editor.holder(of: e), pen2, "Inner accepts no discs")
        expectEqual(g.editor.announcements.last, "Inner accepts no discs.")
    },
])

@MainActor let fitTests = Suite("Constraints: making what's placed fit", [
    test("a tile placed in a place that accepts only glossy tiles is made glossy; one that accepts only urgent things, urgent") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 400, height: 300), [onlyUrgent])
        h.settle()
        let placement = try require(h.editor.registry.placement(for: Tile.kind))
        h.editor.place(placement, at: CGPoint(x: 300, y: 250))
        let t = try require(h.editor.document.shapes.last)
        expectEqual(h.editor.holder(of: t.id), pen)
        expectEqual(t.typed(as: Tile.self)?.props.finish, .glossy)
        expectEqual(h.editor.undoHistory.undoName, "Add Tile", "in the placement's own step")
        h.editor.place(placement, at: CGPoint(x: 800, y: 250))
        let u = try require(h.editor.document.shapes.last)
        expectEqual(h.editor.holder(of: u.id), other)
        expectEqual(u[Urgent.self], true, "the word's owner writes it")
        h.settle()
        expectEqual([h.index.breaches(of: t.id), h.index.breaches(of: u.id)], [[], []], "they fit")
    },
    test("what reaches anywhere inside from an outer place is written too, the outermost first, a place's given lists before its own") {
        let given = Given()
        let h = try constraintHarness(given)
        // Outer's matte is written first, so Inner's glossy, written last, holds.
        let outer = h.corral("Outer", CGRect(x: 100, y: 100, width: 600, height: 500),
                             [Constraint(says: "only urgent things anywhere inside", query: ":urgent", reach: .descendants),
                              Constraint(says: "only matte tiles anywhere inside", query: #"tile[finish="matte"]"#, reach: .descendants)])
        let inner = h.corral("Inner", CGRect(x: 150, y: 150, width: 400, height: 300),
                             [Constraint(says: "only glossy tiles", query: #"tile[finish="glossy"]"#)], in: outer)
        given.lists[inner] = [ConstraintSource(holder: outer, constraints: [Constraint(says: "only plain tiles", query: #"tile[finish="matte"][label="Plain"]"#)])]
        h.index.inheritedConstraintsDidChange(of: [inner])
        h.settle()
        let placement = try require(h.editor.registry.placement(for: Tile.kind))
        h.editor.place(placement, at: CGPoint(x: 350, y: 300))
        let t = try require(h.editor.document.shapes.last?.typed(as: Tile.self))
        expectEqual(h.editor.holder(of: t.id), inner)
        expectEqual(t[Urgent.self], true, "from Outer")
        expectEqual(t.props.label, "Plain", "the given list's")
        expectEqual(t.props.finish, .glossy, "Inner's own, written after its given list and after Outer's")
    },
    test("an open kind is turned by the first constraint that names a kind and kept after; a tool's kind stays") {
        let h = try constraintHarness(Given(), [CardsPlugin()])
        let pen = h.corral("Pen", penRect, [Constraint(says: "only tiles", query: "tile"), Constraint(says: "only cards", query: "card")])
        h.settle()
        let card = try require(h.editor.registry.placement(for: Card.kind))
        h.editor.place(card.openingKind(), at: CGPoint(x: 300, y: 250))
        let turned = try require(h.editor.document.shapes.last)
        expectEqual(turned.kind, Tile.kind, "made a tile")
        expectEqual(h.editor.holder(of: turned.id), pen)
        h.editor.endEditing()
        h.editor.place(card, at: CGPoint(x: 200, y: 200))
        let kept = try require(h.editor.document.shapes.last)
        expectEqual(kept.kind, Card.kind, "a tool's kind is closed")
        h.editor.endEditing()
        h.settle()
        expectEqual(h.index.breaches(of: turned.id).map(\.constraint.says), ["only cards"], "a tile, as the first made it")
        expectEqual(h.index.breaches(of: kept.id).map(\.constraint.says), ["only tiles"])
    },
    test("an open kind already of the kind the first constraint names is spent on it: a later one doesn't turn it") {
        let h = try constraintHarness(Given(), [CardsPlugin()])
        let pen = h.corral("Pen", penRect, [Constraint(says: "only tiles", query: "tile"), Constraint(says: "only cards", query: "card")])
        h.settle()
        let tile = try require(h.editor.registry.placement(for: Tile.kind))
        h.editor.place(tile.openingKind(), at: CGPoint(x: 300, y: 250))
        let made = try require(h.editor.document.shapes.last)
        expectEqual(made.kind, Tile.kind, "a tile, as only tiles asks")
        expectEqual(h.editor.holder(of: made.id), pen)
        h.editor.endEditing()
        // Of a choice, the first alternative: a card, which the next keeps.
        let other = h.corral("Other", CGRect(x: 600, y: 100, width: 400, height: 300),
                             [Constraint(says: "cards or tiles", query: "card, tile"), Constraint(says: "only tiles", query: "tile")])
        h.settle()
        h.editor.place(tile.openingKind(), at: CGPoint(x: 800, y: 250))
        let chosen = try require(h.editor.document.shapes.last)
        expectEqual(chosen.kind, Card.kind)
        expectEqual(h.editor.holder(of: chosen.id), other)
    },
    test("words not interpreted and refused queries are passed over; what still doesn't fit goes in, flagged") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [Constraint(says: "only blue things"), Constraint(says: "near", query: ":scope"), onlyGlossy, noTiles])
        h.settle()
        let placement = try require(h.editor.registry.placement(for: Tile.kind))
        h.editor.place(placement, at: CGPoint(x: 300, y: 250))
        let t = try require(h.editor.document.shapes.last)
        expectEqual(t.typed(as: Tile.self)?.props.finish, .glossy)
        expectEqual(h.editor.holder(of: t.id), pen, "in")
        h.settle()
        expectEqual(h.issues(of: t.id), ["Pen accepts no tiles."], ":not is never written")
    },
    test("outside every constrained place nothing is written") {
        let h = try constraintHarness()
        h.corral("Pen", penRect, [onlyGlossy])
        h.settle()
        let placement = try require(h.editor.registry.placement(for: Tile.kind))
        h.editor.place(placement, at: CGPoint(x: 800, y: 250))
        expectEqual(h.editor.document.shapes.last?.typed(as: Tile.self)?.props.finish, .matte)
    },
])
