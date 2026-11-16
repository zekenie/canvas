@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// What a place takes in (`registrar.admission`): a judge that refuses discs moved into the corrals it
// names ("picky"), or onto the boards of the pockets it names, standing in for a container's constraints.
// Like the plugin that will, it lets in a shape new to the file (no place it leaves), so a test puts a disc
// in a picky corral with an insert (and so stands in for a misfit already inside). CanvasTesting's corrals stand in for frames, a fixture drag tool
// (ContainerTests') for Selection: a corral 400 × 300 at (100, 100), the pen.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)

/// What the judge refuses, and every ask it heard.
@MainActor private final class Picky {
    var corrals: Set<ShapeID> = []
    var boards: Set<BoardID> = []
    /// Whether a disc a container carries counts, as a rule reaching anywhere inside would.
    var deep = false
    var asks: [(arrivals: [Arrival], isChange: Bool)] = []

    struct Arrival: Equatable {
        let id: ShapeID
        let from: ShapePlace?
        let to: ShapePlace
        let carried: [ShapeID]
        let isNew: Bool

        /// New, unless said, where it leaves no place.
        init(id: ShapeID, from: ShapePlace?, to: ShapePlace, carried: [ShapeID], isNew: Bool? = nil) {
            (self.id, self.from, self.to, self.carried) = (id, from, to, carried)
            self.isNew = isNew ?? (from == nil)
        }
    }
}

@MainActor private func judging(_ picky: Picky) -> Contributor {
    Contributor(id: "picky") { r in
        r.admission { admission in
            picky.asks.append((admission.arrivals.map { Picky.Arrival(id: $0.record.id, from: $0.from, to: $0.to, carried: $0.carried, isNew: $0.isNew) },
                               admission.isChange))
            for arrival in admission.arrivals where !arrival.isNew {
                let shapes = [arrival.record] + (picky.deep ? arrival.carried.compactMap { admission.context.shape($0) } : [])
                guard shapes.contains(where: { $0.kind == Disc.kind }) else { continue }
                switch arrival.to {
                case .container(let id) where picky.corrals.contains(id): return .refuses(shaking: [id], saying: "Pen takes no discs.")
                case .board(let board) where picky.boards.contains(board): return .refuses(shaking: [], saying: nil)
                default: continue
                }
            }
            return .admits
        }
    }
}

@MainActor private func admissionHarness(_ picky: Picky, _ log: RefusalLog = RefusalLog(), picks: Picks = Picks()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), PocketsPlugin(), FreezingPlugin(log: log), dragPlugin(picks), judging(picky)])
}

extension EditorHarness {
    fileprivate func origin(of shape: ShapeID) -> CGPoint? { editor.document[shape]?.box?.origin }

    /// A disc 50 across at `origin`, in `container` if one, put in by an insert (new: let in).
    fileprivate func disc(at origin: CGPoint, side: CGFloat = 50, in container: ShapeID? = nil) -> ShapeID {
        let id = ShapeID()
        let record = AnyShapeRecord(ShapeRecord(id: id, Disc(CGRect(origin: origin, size: CGSize(width: side, height: side)))))
        editor.transact { $0.insert(record.copy(as: id, container: container)) }
        return id
    }

    fileprivate func box(at origin: CGPoint, side: CGFloat = 50) -> ShapeID {
        add(Box(CGRect(origin: origin, size: CGSize(width: side, height: side))))
    }
}

@MainActor let admissionTests = Suite("Admission", [
    test("a drop a place refuses goes back, gliding from where it was dropped: the press leaves no step, what the verdict names shakes, and what it says is heard") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 590, y: 150))
        h.editor.transact("Shift") { $0.translate([d], by: CGPoint(x: 10, y: 0)) }
        h.press(at: CGPoint(x: 625, y: 175))
        h.drag(to: CGPoint(x: 560, y: 175))
        h.drag(to: CGPoint(x: 495, y: 175))                             // at 470: 60% in
        expectEqual(h.editor.hintedShapeID, nil, "no outline over a place that would refuse it")
        expectEqual(h.editor.announcements, [], "a try says nothing")
        h.release()
        expectEqual(h.origin(of: d), CGPoint(x: 600, y: 150))
        expectEqual(h.editor.holder(of: d), nil)
        expectEqual(h.editor.drawingOffset(of: d), CGPoint(x: -130, y: 0), "drawn where it was dropped")
        expectEqual(log.refusals, [[pen]])
        expectEqual(h.editor.announcements, ["Pen takes no discs."])
        h.wait(256)
        expectEqual(h.editor.drawingOffset(of: d), .zero)
        expectEqual(h.editor.undoHistory.undoName, "Shift", "the press left no step")
    },
    test("a drop of a box and a disc together is refused whole: both go back") {
        let picky = Picky(), log = RefusalLog(), picks = Picks()
        let h = try admissionHarness(picky, log, picks: picks)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 600, y: 150)), b = h.box(at: CGPoint(x: 600, y: 250))
        picks.ids = [b, d]
        h.press(at: CGPoint(x: 625, y: 175))
        h.drag(to: CGPoint(x: 495, y: 175))
        h.release()
        expectEqual([h.origin(of: b), h.origin(of: d)], [CGPoint(x: 600, y: 250), CGPoint(x: 600, y: 150)])
        expectEqual([h.editor.holder(of: b), h.editor.holder(of: d)], [nil, nil])
        expectEqual(log.refusals, [[pen]])
        expectEqual(picky.asks.last?.arrivals.map(\.id).sorted { $0.description < $1.description }, [b, d].sorted { $0.description < $1.description },
                    "asked about together")
    },
    test("the hint is gone over a place that would refuse what's dragged and kept over one that takes it, asked once each time it changes, as a try; the release asks as a change") {
        let picky = Picky()
        let h = try admissionHarness(picky)
        let pen = h.add(Corral(penRect)), other = h.add(Corral(CGRect(x: 100, y: 500, width: 400, height: 300)))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 600, y: 150))
        picky.asks = []
        h.press(at: CGPoint(x: 625, y: 175))
        h.drag(to: CGPoint(x: 560, y: 175))
        expectEqual(picky.asks.count, 0, "over no container, nothing to ask")
        h.drag(to: CGPoint(x: 495, y: 175))
        h.drag(to: CGPoint(x: 490, y: 175))
        expectEqual(h.editor.hintedShapeID, nil)
        expectEqual(picky.asks.count, 1, "asked once while the container under it stays the same")
        h.drag(to: CGPoint(x: 495, y: 575))                             // at (470, 550): 60% in the other
        expectEqual(h.editor.hintedShapeID, other)
        h.release()
        expectEqual(h.editor.holder(of: d), other)
        expectEqual(picky.asks.map(\.isChange), [false, false, true], "the hint's tries, then the release")
        expectEqual(picky.asks.map { $0.arrivals.map(\.to) }, [[.container(pen)], [.container(other)], [.container(other)]])
        expectEqual(picky.asks.last?.arrivals.first?.from, .board(.root))
    },
    test("a drop out of a corral onto the board is let in, asked as leaving the corral for the board's top level") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        expectEqual(h.editor.holder(of: d), pen, "put in new, by an insert")
        h.press(at: CGPoint(x: 225, y: 225))
        h.drag(to: CGPoint(x: 625, y: 225))
        h.release()
        expectEqual(h.editor.holder(of: d), nil)
        expectEqual(h.origin(of: d), CGPoint(x: 600, y: 200))
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: d, from: .container(pen), to: .board(.root), carried: [])])
        expectEqual(log.refusals, [])
    },
    test("setContainer into a place that refuses changes nothing, all or nothing for a list, heard refused, leaving no step and what there was to redo") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 150, y: 150)), b = h.box(at: CGPoint(x: 250, y: 150))
        h.editor.transact("Shift") { $0.translate([b], by: CGPoint(x: 10, y: 0)) }
        h.editor.undo()
        let revision = h.editor.revision
        h.editor.transact { $0.setContainer([b, d], to: pen) }
        expectEqual([h.editor.holder(of: b), h.editor.holder(of: d)], [nil, nil])
        expectEqual(log.refusals, [[pen]])
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.redoName, "Shift")
        h.editor.transact { $0.setContainer(b, to: pen) }
        expectEqual(h.editor.holder(of: b), pen, "a box it takes")
    },
    test("a move onto a board that refuses changes nothing, the shapes themselves shaking where the verdict names none; onto one that takes it, it moves") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let p = h.add(Pocket(CGRect(x: 600, y: 0, width: 100, height: 100))), q = h.add(Pocket(CGRect(x: 800, y: 0, width: 100, height: 100)))
        picky.boards = [BoardID(owner: p)]
        let d = h.disc(at: CGPoint(x: 150, y: 150))
        h.editor.transact("Shift") { $0.translate([d], by: CGPoint(x: 10, y: 0)) }
        h.editor.undo()
        let moved = h.editor.transactWhole("Move") { transaction -> Bool in
            guard transaction.move([d], to: BoardID(owner: p)) else { throw Transaction.Refused() }
            return true
        }
        expectEqual(moved, nil)
        expectEqual(h.editor.file.board(containing: d), .root)
        expectEqual(log.refusals, [[d]])
        expectEqual(h.editor.undoHistory.redoName, "Shift", "what there was to redo stays")
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: d, from: .board(.root), to: .board(BoardID(owner: p)), carried: [])])
        expect(h.editor.transact("Move") { $0.move([d], to: BoardID(owner: q)) })
        expectEqual(h.editor.file.board(containing: d), BoardID(owner: q))
    },
    test("a corral moved onto a board is asked about with what it carries: a rule reaching anywhere inside refuses the disc it holds") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let p = h.add(Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))
        picky.boards = [BoardID(owner: p)]
        let k = h.add(Corral(CGRect(x: 0, y: 0, width: 200, height: 200)))
        let d = h.disc(at: CGPoint(x: 20, y: 20), in: k)
        expect(h.editor.transact("Move") { $0.move([k], to: BoardID(owner: p)) }, "a carried disc comes into nothing new directly")
        expectEqual(h.editor.file.board(containing: k), BoardID(owner: p))
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: k, from: .board(.root), to: .board(BoardID(owner: p)), carried: [d])],
                    "put down nowhere there, judged where it is as the transaction ends")
        h.editor.undo()
        picky.deep = true
        let revision = h.editor.revision
        h.editor.transact("Move") { _ = $0.move([k], to: BoardID(owner: p)) }
        expectEqual(h.editor.file.board(containing: k), .root, "anywhere inside, it does: the move can't go back alone, so nothing commits")
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals, [[k]])
    },
    test("a move onto another board is judged where it's put down there, from where it was: into a container there, the board's top level takes no part") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let p = h.add(Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))
        let there = BoardID(owner: p)
        picky.boards = [there]
        let inner = AnyShapeRecord(ShapeRecord(Corral(CGRect(x: 0, y: 0, width: 400, height: 300))))
        h.editor.transact(on: there) { $0.insert(inner) }
        let d = h.disc(at: CGPoint(x: 150, y: 150)), e = h.disc(at: CGPoint(x: 250, y: 450))
        picky.asks = []
        let moved = h.editor.transactWhole("Move") { transaction -> Bool in
            guard transaction.move([d], to: there) else { throw Transaction.Refused() }
            guard case .settled = transaction.settle([d], on: there) else { throw Transaction.Refused() }
            return true
        }
        expectEqual(moved, true)
        expectEqual(h.editor.file.board(containing: d), there)
        expectEqual(h.editor.file[there].container(of: d, containingKinds: h.editor.registry.containingKinds), inner.id)
        expectEqual(picky.asks.map(\.arrivals), [[Picky.Arrival(id: d, from: .board(.root), to: .container(inner.id), carried: [])]], "asked once, where it lands")
        expectEqual(log.refusals, [])
        let refused = h.editor.transactWhole("Move") { transaction -> Bool in
            guard transaction.move([e], to: there) else { throw Transaction.Refused() }
            guard case .settled = transaction.settle([e], on: there) else { throw Transaction.Refused() }
            return true
        }
        expectEqual(refused, nil, "put down on that board's top level, it's refused there")
        expectEqual(h.editor.file.board(containing: e), .root)
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: e, from: .board(.root), to: .board(there), carried: [])])
        expectEqual(log.refusals, [[e]])
    },
    test("a container put down around a shape in a place that refuses it, and one beside, takes that place in: the shape, put back where it was, is carried, never asked about as coming in") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 110, y: 110), in: pen), b = h.box(at: CGPoint(x: 520, y: 420))
        picky.asks = []
        let made = try require(h.editor.place(ShapeRecord(Corral()), around: [d, b], padding: 10))
        expectEqual([h.editor.holder(of: d), h.editor.holder(of: pen), h.editor.holder(of: b)], [pen, made, made])
        expectEqual(log.refusals, [])
        expect(!picky.asks.contains { $0.arrivals.contains { $0.id == d } }, "never asked about passing through the new one")
        expectEqual(picky.asks.last?.arrivals.first { $0.id == pen }, Picky.Arrival(id: pen, from: .board(.root), to: .container(made), carried: [d]))
        expectEqual(picky.asks.last?.arrivals.first { $0.id == b }, Picky.Arrival(id: b, from: .board(.root), to: .container(made), carried: []))
        h.editor.undo()
        // A new one that refuses discs anywhere inside it refuses the place that carries one.
        picky.deep = true
        let refusing = ShapeID()
        picky.corrals = [pen, refusing]
        let before = h.editor.document
        expectEqual(h.editor.place(ShapeRecord(id: refusing, Corral()), around: [d, b], padding: 10), nil)
        expectEqual(h.editor.document, before, "nothing put down")
        expectEqual(log.refusals, [[refusing]])
    },
    test("a shape put back into the file under its id, said to be moved (a cut's, pasted), is asked about as moved from no place: refused where a drop is") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 600, y: 150))
        let record = try require(h.editor.document[d])
        h.editor.transact("Cut") { $0.delete([d]) }
        var inPen = record
        inPen.box?.origin = CGPoint(x: 200, y: 200)
        picky.asks = []
        let pasted = h.editor.transactWhole("Paste") { transaction -> Bool in
            transaction.treatAsMoved([d])
            transaction.insert(inPen)
            guard case .settled = transaction.settle([d]) else { throw Transaction.Refused() }
            return true
        }
        expectEqual(pasted, nil)
        expectEqual(h.editor.document[d], nil)
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: d, from: nil, to: .container(pen), carried: [], isNew: false)])
        expectEqual(log.refusals, [[pen]])
        // Put in with the container: the insert's own ask is told so too.
        h.editor.transact("Paste") { transaction in
            transaction.treatAsMoved([d])
            transaction.insert(inPen.copy(as: d, container: pen))
        }
        expectEqual(h.editor.holder(of: d), nil, "on the board directly")
        expectEqual(log.refusals, [[pen], [pen]])
        h.editor.undo()
        // Not said, it's new here, and let in.
        let made = h.editor.transactWhole("Paste") { transaction -> Bool in
            transaction.insert(inPen)
            guard case .settled = transaction.settle([d]) else { throw Transaction.Refused() }
            return true
        }
        expectEqual(made, true)
        expectEqual(h.editor.holder(of: d), pen)
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: d, from: nil, to: .container(pen), carried: [])])
    },
    test("a container put back moved before what it holds, with no settle, is judged where it is as the transaction ends, carrying it") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        picky.deep = true
        let k = h.add(Corral(CGRect(x: 600, y: 150, width: 100, height: 100)))
        let d = h.disc(at: CGPoint(x: 610, y: 160), side: 40, in: k)
        let corral = try require(h.editor.document[k]), disc = try require(h.editor.document[d])
        h.editor.transact("Cut") { $0.delete([k, d]) }
        @MainActor func pasteBack(settling: Bool) -> Bool? {
            h.editor.transactWhole("Paste") { transaction -> Bool in
                transaction.treatAsMoved([k, d])
                var inPen = corral.copy(as: k, container: pen)
                inPen.box = CGRect(x: 150, y: 150, width: 100, height: 100)
                var held = disc.copy(as: d, container: k)
                held.box = CGRect(x: 160, y: 160, width: 40, height: 40)
                transaction.insert(inPen)
                transaction.insert(held)
                if settling { guard case .settled = transaction.settle([k, d]) else { throw Transaction.Refused() } }
                return true
            }
        }
        picky.asks = []
        expectEqual(pasteBack(settling: false), nil, "refused whole")
        expectEqual(h.editor.document[k], nil)
        expectEqual(h.editor.document[d], nil)
        expectEqual(picky.asks.map(\.arrivals), [[Picky.Arrival(id: k, from: nil, to: .container(pen), carried: [], isNew: false)],
                                                [Picky.Arrival(id: k, from: nil, to: .container(pen), carried: [d], isNew: false)]],
                    "the insert's ask carried nothing; the end's carries the disc")
        expectEqual(log.refusals, [[pen]])
        // A plain transaction commits nothing either.
        let revision = h.editor.revision
        h.editor.transact("Paste") { transaction in
            transaction.treatAsMoved([k, d])
            transaction.insert(corral.copy(as: k, container: pen))
            transaction.insert(disc.copy(as: d, container: k))
        }
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.document[k], nil)
        // Settled after its inserts, it's judged by the settle and not again.
        picky.asks = []
        expectEqual(pasteBack(settling: true), nil)
        expectEqual(picky.asks.count, 2, "the insert's and the settle's")
        // Let in, the end asks again and lets it in.
        picky.deep = false
        expectEqual(pasteBack(settling: false), true)
        expectEqual(h.editor.holder(of: k), pen)
        expectEqual(h.editor.holder(of: d), k)
    },
    test("a container dropped into a place is judged with what it holds") {
        let picky = Picky(), log = RefusalLog(), picks = Picks()
        let h = try admissionHarness(picky, log, picks: picks)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let k = h.add(Corral(CGRect(x: 600, y: 150, width: 100, height: 100)))
        let d = h.disc(at: CGPoint(x: 610, y: 160), side: 40, in: k)
        picks.ids = [k]
        h.press(at: CGPoint(x: 690, y: 240))
        h.drag(to: CGPoint(x: 390, y: 240))                             // k at (300, 150): wholly in the pen
        h.release()
        expectEqual(h.editor.holder(of: k), pen, "the disc it carries is in it, not directly in the pen")
        expectEqual(h.editor.holder(of: d), k)
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: k, from: .board(.root), to: .container(pen), carried: [d])])
        h.editor.undo()
        expectEqual(h.editor.holder(of: k), nil)
        picky.deep = true
        h.press(at: CGPoint(x: 690, y: 240))
        h.drag(to: CGPoint(x: 390, y: 240))
        expectEqual(h.editor.hintedShapeID, nil)
        h.release()
        expectEqual(h.editor.holder(of: k), nil)
        expectEqual(h.origin(of: k), CGPoint(x: 600, y: 150))
        expectEqual(h.origin(of: d), CGPoint(x: 610, y: 160), "carried back with it")
        expectEqual(log.refusals, [[pen]])
    },
    test("a corral resized over a shape a place refuses leaves it out where it is, heard by no one, and takes in the rest") {
        let picky = Picky(), log = RefusalLog()
        let h = try admissionHarness(picky, log)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 480, y: 200)), b = h.box(at: CGPoint(x: 480, y: 300))
        h.editor.transact("Resize") { transaction in
            transaction.update(pen) { $0.box = CGRect(x: 100, y: 100, width: 450, height: 300) }
            transaction.settle(container: pen)
        }
        expectEqual(h.editor.holder(of: d), nil)
        expectEqual(h.origin(of: d), CGPoint(x: 480, y: 200))
        expectEqual(h.editor.holder(of: b), pen)
        expectEqual(log.refusals, [])
        expectEqual(h.editor.announcements, [])
    },
    test("a shape staying where it is is never asked about, dropped or settled") {
        let picky = Picky()
        let h = try admissionHarness(picky)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        picky.asks = []
        h.editor.transact { transaction in
            transaction.translate([d], by: CGPoint(x: 10, y: 0))
            _ = transaction.settle([d])
        }
        h.press(at: CGPoint(x: 235, y: 225))
        h.drag(to: CGPoint(x: 335, y: 225))
        h.release()
        expectEqual(h.editor.holder(of: d), pen)
        expectEqual(picky.asks.count, 0)
    },
    test("a shape new to the file is asked about with no place it leaves: an insert that comes with a container, and one settled where it's put down") {
        let picky = Picky()
        let h = try admissionHarness(picky)
        let pen = h.add(Corral(penRect))
        picky.corrals = [pen]
        picky.asks = []
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        expectEqual(picky.asks.map(\.arrivals), [[Picky.Arrival(id: d, from: nil, to: .container(pen), carried: [])]])
        expectEqual(picky.asks.map(\.isChange), [true])
        let e = ShapeID()
        h.editor.transact { transaction in
            transaction.insert(ShapeRecord(id: e, Disc(CGRect(x: 470, y: 150, width: 50, height: 50))))
            _ = transaction.settle([e])
        }
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: e, from: nil, to: .container(pen), carried: [])])
        expectEqual(h.editor.holder(of: e), pen, "let in")
        let f = ShapeID()
        h.editor.transact { transaction in
            transaction.insert(ShapeRecord(id: f, Disc(CGRect(x: 700, y: 150, width: 50, height: 50))))
            _ = transaction.settle([f])
        }
        expectEqual(picky.asks.last?.arrivals, [Picky.Arrival(id: f, from: nil, to: .board(.root), carried: [])], "onto the board's top level")
    },
    test("with no judge installed nothing is asked, and everything is let in") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), dragPlugin()])
        let pen = h.add(Corral(penRect))
        let d = h.add(Disc(CGRect(x: 600, y: 150, width: 50, height: 50)))
        expect(!h.editor.registry.report.contains("admission"), h.editor.registry.report)
        expect(h.editor.admits([d], into: .container(pen)))
        let picky = Picky()
        let judged = try admissionHarness(picky)
        expect(judged.editor.registry.report.contains("admission"), judged.editor.registry.report)
        let other = judged.add(Corral(penRect))
        picky.corrals = [other]
        let e = judged.disc(at: CGPoint(x: 600, y: 150))
        picky.asks = []
        expect(!judged.editor.admits([e], into: .container(other)))
        expectEqual(picky.asks.map(\.isChange), [false], "editor.admits is a try")
        expectEqual(judged.editor.holder(of: e), nil, "and changes nothing")
    },
])
