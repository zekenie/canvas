@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Topology

// Forwarding through stand-ins (`EdgeForwarding`): what a stand-in stands for (duplicates, what it
// can't stand for, one hop, its most), the edges into and out of it in each view, standing edges,
// the cap on one carrier's copies, the reserved slot, what a commit reads, and the sparse tables.

private let views: [(name: String, view: EdgeView)] = [("resolved", .resolved), ("recorded", .recorded), ("literal", .literal)]

@MainActor let forwardingTests = Suite("Forwarding through stand-ins", [
    test("a stand-in's rule: one per kind, at least one shape, and the kinds that have one") {
        let h = try standing()
        expectEqual(h.topology.standInKinds, [Proxy.kind, Gate.kind])
        expectEqual(h.topology.snapshot().standInKinds, [Proxy.kind, Gate.kind])
        expectEqual(try graph().topology.standInKinds, [], "none without a rule")
        let report = try Registry(plugins: graphPlugins(more: [StandInsPlugin()])).report
        expect(report.contains("stands in → proxy"), "the report shows each rule:\n\(report)")

        expectThrows(RegistryError.invalid(point: "EdgeForwarding", reason: "stand-ins lets proxy stand for at most 0 shapes; at least 1")) {
            _ = try Registry(plugins: graphPlugins(more: [StandInsPlugin(most: 0)]))
        }
        expectThrows(RegistryError.conflict(point: "EdgeForwarding", key: "proxy", plugins: ["stand-ins", "stand-ins"])) {
            _ = try Registry(plugins: graphPlugins(more: [StandInsPlugin(twice: true)]))
        }
    },

    test("an edge into a stand-in is an edge into what it stands for, read back in each view") {
        let a = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID()
        let h = try standing(CanvasFile(root: board(box(a), box(b), proxy(r, [a]), link(l, b, r))))
        let topology = h.topology
        let through = forwarded(WireEdge.id, b, a, by: l, to: r), literal = edge(WireEdge.id, b, r, by: l)
        expectEqual(topology.forwards(of: r), [a])
        expectEqual(topology.standIns(for: a), [r])
        expectEqual(topology.forwarding(of: r), .record([a]))
        expectEqual(topology.forwarding(of: a), .none)

        expectEqual(topology.edges(of: a), [through, stands(r, for: a)], "B to A, through R, and R's own edge to A")
        expectEqual(topology.edges(of: a, .incoming, types: .within(WireEdge.id)), [through])
        expectEqual(topology.neighbors(of: b), [WireEdge.id: [a]])
        expectEqual(topology.edges(of: r), [stands(r, for: a)], "R is an end of nothing it forwards, as resolved")
        expectEqual(topology.edges(carriedBy: l), [through])
        expectEqual(topology.edges(carriedBy: r), [stands(r, for: a)])
        expectEqual(topology.edges(through: r), [through])
        expectEqual(topology.edges(ofType: .only(StandingEdge.id)), [stands(r, for: a)])
        expectEqual(through.literalSource, b)
        expectEqual(through.literalTarget, r)
        expectEqual(through.literal, literal)

        expectEqual(topology.edges(of: r, view: .literal), [literal], "as emitted: B to R, and no standing edge")
        expectEqual(topology.edges(of: a, view: .literal), [])
        expectEqual(topology.edges(of: b, view: .literal), [literal])
        expectEqual(topology.neighbors(of: b, view: .literal), [WireEdge.id: [r]])
        expectEqual(topology.edges(carriedBy: l, view: .literal), [literal])
        expectEqual(topology.edges(carriedBy: r, view: .literal), [])
        expectEqual(topology.edges(ofType: .all, view: .literal), [literal])
        expect(topology.hasEdges(of: r, .incoming, view: .literal))
        expect(!topology.hasEdges(of: r, .incoming))

        for (name, view) in views where view != .literal {
            expectEqual(topology.edges(of: a, view: view), topology.edges(of: a), "the recorded view is the resolved one with no stand-in for what's provided (\(name))")
            expectEqual(topology.edges(ofType: .all, view: view), topology.edges(ofType: .all))
        }
        let snapshot = topology.snapshot(.literal)
        expectEqual(snapshot.view, .literal)
        expectEqual(snapshot.edges(of: r), [literal])
        expectEqual(snapshot.presentTypes, [WireEdge.id])
        expectEqual(topology.snapshot().presentTypes, [WireEdge.id, StandingEdge.id])
        expectEqual(snapshot.forwards(of: r), [a], "what stands for what is the same in every view")
        expectEqual(snapshot.standIns(for: a), [r])
    },

    test("what a stand-in can't stand for is left out, and with nothing left an edge into it stays one into it") {
        let loaded = try hiddenFile()
        let a = ShapeID(), b = ShapeID(), gone = ShapeID(), shut = ShapeID(), r = ShapeID(), g = ShapeID(), l = ShapeID(), m = ShapeID()
        let records = [box(a), box(b), box(shut), proxy(r, [gone, id(10), id(11), r, g]), gate(g, [shut]), link(l, b, r), link(m, b, g)]
        let h = try standing(CanvasFile(root: CanvasDocument(shapes: loaded.file.root.shapes + records), children: loaded.file.children))
        let topology = h.topology
        expectEqual(topology.forwards(of: r), [], "missing, kept aside, on a board it can't show, itself, a stand-in")
        expectEqual(topology.forwarding(of: r), .record([]))
        expectEqual(topology.forwards(of: g), [], "not open")
        for (name, view) in views {
            expectEqual(topology.edges(carriedBy: l, view: view), [edge(WireEdge.id, b, r, by: l)], name)
            expectEqual(topology.edges(of: r, view: view), [edge(WireEdge.id, b, r, by: l)], name)
        }
        expectEqual(topology.edges(of: shut), [])
        expectEqual(topology.edges(carriedBy: r), [], "no standing edges")

        h.editor.transact { $0.update(shut) { $0.meta[Open.self] = true } }
        expectEqual(topology.forwards(of: g), [shut], "open now: a change to the target alone")
        expectEqual(topology.edges(carriedBy: m), [forwarded(WireEdge.id, b, shut, by: m, to: g)])
        expectEqual(topology.touched, [b, shut, g])
        h.editor.transact { $0.update(shut) { $0.meta[Open.self] = false } }
        expectEqual(topology.forwards(of: g), [])
        expectEqual(topology.edges(carriedBy: m), [edge(WireEdge.id, b, g, by: m)])
        h.editor.undo()
        expectEqual(topology.forwards(of: g), [shut])
    },

    test("a stand-in stands for each shape once, in order, up to its most, and an edge into it fans out to each") {
        let a = ShapeID(), c = ShapeID(), d = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID()
        let file = CanvasFile(root: board(box(a), box(c), box(d), box(b), proxy(r, [c, a, c, d, a]), link(l, b, r)))
        let h = try standing(file)
        expectEqual(h.topology.forwards(of: r), [c, a, d], "a name again is left out, the first kept")
        expectEqual(h.topology.edges(carriedBy: l), [c, a, d].map { forwarded(WireEdge.id, b, $0, by: l, to: r) })
        expectEqual(h.topology.edges(carriedBy: r), [c, a, d].map { stands(r, for: $0) })
        expectEqual(h.topology.neighbors(of: b), [WireEdge.id: [c, a, d]])
        expectEqual(h.topology.edges(of: r, view: .literal), [edge(WireEdge.id, b, r, by: l)], "the copies are one arrow, as emitted")
        expectEqual(h.topology.edges(ofType: .all, view: .literal), [edge(WireEdge.id, b, r, by: l)])
        try expectRebuilt(h, "with a name twice")

        let few = try standing(file, most: 2)
        expectEqual(few.topology.forwards(of: r), [c, a], "its most")
        expectEqual(few.topology.edges(carriedBy: l).count, 2)
    },

    test("one hop: a stand-in never stands for a stand-in, and its own edges are never forwarded") {
        let a = ShapeID(), c = ShapeID(), b = ShapeID(), r = ShapeID(), s = ShapeID(), l = ShapeID()
        let h = try standing(CanvasFile(root: board(box(a), box(c), box(b), proxy(r, [a], next: s), proxy(s, [r, c]), link(l, r, b))))
        let topology = h.topology
        expectEqual(topology.forwards(of: s), [c], "R is a stand-in")
        expectEqual(topology.edges(carriedBy: r), [edge(WireEdge.id, r, s, by: r), stands(r, for: a)], "R's own wire to S stays as emitted")
        expectEqual(topology.edges(carriedBy: l), [forwarded(WireEdge.id, a, b, by: l, from: r)], "from R is from A")
        expectEqual(topology.edges(of: c), [stands(s, for: c)])
        expectEqual(topology.edges(of: s), [edge(WireEdge.id, r, s, by: r), stands(s, for: c)])
    },

    test("an arrow from a shape to a stand-in for it is a loop, there once") {
        let a = ShapeID(), r = ShapeID(), l = ShapeID()
        let h = try standing(CanvasFile(root: board(box(a), proxy(r, [a]), link(l, a, r))))
        let loop = forwarded(WireEdge.id, a, a, by: l, to: r)
        expectEqual(h.topology.edges(of: a), [loop, stands(r, for: a)])
        expectEqual(h.topology.edges(of: a, .outgoing), [loop])
        expectEqual(h.topology.neighbors(of: a, .either, types: .only(WireEdge.id)), [WireEdge.id: [a]])
        expectEqual(h.topology.edges(of: a, view: .literal), [edge(WireEdge.id, a, r, by: l)])
    },

    test("one carrier's copies stop at the cap, though every edge it emits keeps one") {
        let fifty = (0..<50).map { _ in ShapeID() }, more = (0..<50).map { _ in ShapeID() }
        let r = ShapeID(), s = ShapeID(), l = ShapeID()
        let h = try standing(CanvasFile(root: CanvasDocument(shapes: (fifty + more).map(box) + [proxy(r, fifty), proxy(s, more), link(l, r, s)])))
        let carried = h.topology.edges(carriedBy: l)
        expectEqual(carried.count, EdgeForwarding.maxPairsPerCarrier, "50 by 50, held to the cap")
        expectEqual(EdgeForwarding.maxPairsPerCarrier, 256)
        expectEqual(Set(carried).count, carried.count)
        expectEqual(Array(carried.prefix(51)).map(\.source), Array(repeating: fifty[0], count: 50) + [fifty[1]], "source by source")
        expectEqual(h.topology.edges(carriedBy: l, view: .literal), [edge(WireEdge.id, r, s, by: l)])

        // A memo whose quotes go into six stand-ins for 50 each, then into a box: 250, then 6 to the
        // cap, then the box's one, past it.
        let proxies = (0..<6).map { _ in ShapeID() }, plain = ShapeID(), m = ShapeID()
        let targets = (0..<300).map { _ in ShapeID() }
        let notes = proxies.map { MemoNote("", cites: [Citation($0)]) } + [MemoNote("", cites: [Citation(plain)])]
        let shapes = targets.map(box) + [box(plain), memo(m, notes: notes)]
            + proxies.enumerated().map { proxy($1, Array(targets[($0 * 50)..<($0 * 50 + 50)])) }
        let cited = try standing(CanvasFile(root: CanvasDocument(shapes: shapes)))
        let quotes = cited.topology.edges(carriedBy: m)
        expectEqual(quotes.count, 257)
        expectEqual(quotes.filter { $0.literalTarget == proxies[5] }.count, 6)
        expectEqual(quotes.last, edge(QuoteEdge.id, m, plain, by: m, slot: "notes"))
        expectEqual(Set(cited.topology.edges(of: m, view: .literal)), Set(cited.editor.registry.edges(of: try require(cited.editor.document[m]))),
                    "every quote, as emitted")
    },

    test("a source can't emit Topology's own edges: the slot and the type are dropped") {
        let a = ShapeID()
        let rogue = Contributor(id: "rogue") { r in
            r.edges(Box.self) { record, _, sink in
                sink.emit(WireEdge.id, from: record.id, to: a, slot: StandingEdge.slot)
                sink.emit(StandingEdge.id, from: record.id, to: a)
                sink.emit(WireEdge.id, from: record.id, to: a)
            }
        }
        let h = try standing(CanvasFile(root: board(box(a))), more: [rogue])
        expectEqual(h.topology.edges(carriedBy: a), [edge(WireEdge.id, a, a, by: a)])
        expectEqual(h.topology.reservedEdgesDropped, 2)
        let record = try require(h.editor.document[a])
        expectEqual(h.editor.registry.edges(of: record), [edge(WireEdge.id, a, a, by: a)])
    },

    test("the stand-ins whose record names a shape are told whether or not they stand for it: a shape that is gone, one re-pointed away from, one deleted and brought back") {
        let a = ShapeID(), c = ShapeID(), r = ShapeID(), q = ShapeID(), gone = ShapeID()
        let h = try standing(CanvasFile(root: board(box(a), box(c), proxy(r, [a]), proxy(q, [gone, a]))))
        let topology = h.topology
        expectEqual(Set(topology.standIns(naming: a)), [r, q])
        expectEqual(topology.standIns(naming: gone), [q], "named, though it is nowhere")
        expectEqual(topology.standIns(for: gone), [], "and stood for by nothing")
        h.editor.transact { $0.update(r, as: Proxy.self) { $0.props.stands = [Citation(c)] } }
        expectEqual(topology.standIns(naming: a), [q])
        expectEqual(topology.standIns(naming: c), [r])
        h.editor.transact { $0.delete([a]) }
        expectEqual(topology.standIns(naming: a), [q], "a deleted shape is still named")
        expectEqual(topology.standIns(for: a), [])
        h.editor.undo()
        h.editor.undo()
        expectEqual(Set(topology.standIns(naming: a)), [r, q], "undone")
        expectEqual(topology.standIns(naming: c), [])
        h.editor.transact { $0.delete([q]) }
        expectEqual(topology.standIns(naming: gone), [], "a stand-in that is gone names nothing")
        expectEqual(topology.standIns(naming: ShapeID()), [])
    },

    test("the other way round: the one shape a stand-in's record names, whatever it stands for, and its kind; nothing of one that names several, a shape that isn't one, or one on a board the app can't show") {
        let a = ShapeID(), c = ShapeID(), b = ShapeID(), r = ShapeID(), q = ShapeID(), twice = ShapeID(), g = ShapeID(), gone = ShapeID()
        let hidden = ShapeID(), nowhere = ShapeID()      // an owner no shape of the file has: its board can't be shown
        let file = CanvasFile(root: board(box(a), box(c), box(b), proxy(r, [a]), proxy(q, [gone, a]), proxy(twice, [a, a]), gate(g, [c])),
                              children: [nowhere: board(proxy(hidden, [a]))])
        let h = try standing(file)
        let topology = h.topology
        expectEqual(topology.directTarget(of: r), a)
        expectEqual(topology.directTarget(of: twice), a, "named over again")
        expectEqual(topology.directTarget(of: q), nil, "it names two, one of them nowhere")
        expectEqual(topology.directTarget(of: g), c, "whether or not it may stand for it")
        expectEqual(topology.forwards(of: g), [], "the gate stands for nothing: the box isn't open")
        expectEqual(topology.standInKind(of: r), Proxy.kind)
        expectEqual(topology.standInKind(of: g), Gate.kind)
        expectEqual(topology.standInKind(of: b), nil, "a box is no stand-in")
        expectEqual(topology.directTarget(of: b), nil)
        expectEqual(topology.standInKind(of: hidden), nil, "a stand-in on a board the app can't show isn't one here")
        expectEqual(topology.directTarget(of: hidden), nil)
        expectEqual(Set(topology.standIns(naming: a)), [r, q, twice], "and names nothing")
        h.editor.transact { $0.update(r, as: Proxy.self) { $0.props.stands = [Citation(c)] } }
        expectEqual(topology.directTarget(of: r), c, "re-pointed")
        h.editor.transact { $0.delete([r]) }
        expectEqual(topology.standInKind(of: r), nil, "gone")
        expectEqual(topology.directTarget(of: r), nil)
        h.editor.undo()
        expectEqual(topology.directTarget(of: r), c, "undone")
        expectEqual(topology.standInKind(of: r), Proxy.kind)
    },

    test("re-pointing a stand-in, deleting what it stands for and undoing set again only what's at it, and touch every end") {
        let a = ShapeID(), c = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID(), m = ShapeID(), far = ShapeID()
        let h = try standing(CanvasFile(root: board(box(a), box(c), box(b), box(far), proxy(r, [a]), link(l, b, r), memo(m, lead: r))))
        let topology = h.topology, read = topology.recordsRead
        let onA = topology.revision(of: a), onR = topology.revision(of: r), onFar = topology.revision(of: far)
        h.editor.transact { $0.update(r, as: Proxy.self) { $0.props.stands = [Citation(c)] } }
        expectEqual(topology.recordsRead, read + 2, "the proxy's source and its rule, and no carrier")
        expectEqual(topology.edges(carriedBy: l), [forwarded(WireEdge.id, b, c, by: l, to: r)])
        expectEqual(topology.edges(carriedBy: m), [forwarded(QuoteEdge.id, m, c, by: m, to: r, slot: "lead")])
        expectEqual(topology.edges(of: a), [])
        expectEqual(topology.standIns(for: a), [])
        expectEqual(topology.standIns(for: c), [r])
        expectEqual(topology.touched, [b, a, c, r, m])
        expect(topology.revision(of: a) > onA)
        expect(topology.revision(of: r) > onR)
        expectEqual(topology.revision(of: far), onFar)

        h.editor.transact("Delete") { $0.delete([c]) }
        expectEqual(topology.forwards(of: r), [])
        expectEqual(topology.edges(carriedBy: l), [edge(WireEdge.id, b, r, by: l)], "nothing to stand for: back at the stand-in")
        h.editor.undo()
        expectEqual(topology.edges(carriedBy: l), [forwarded(WireEdge.id, b, c, by: l, to: r)])
        h.editor.undo()
        expectEqual(topology.edges(carriedBy: l), [forwarded(WireEdge.id, b, a, by: l, to: r)])
        h.editor.transact("Delete") { $0.delete([r]) }
        expectEqual(topology.edges(carriedBy: l), [], "the link lets go of a shape that goes, as it does of any")
        expectEqual(topology.edges(carriedBy: m), [edge(QuoteEdge.id, m, r, by: m, slot: "lead")], "a quote outlives it, as a name")
        expectEqual(topology.edges(of: a), [])
        h.editor.undo()
        expectEqual(Set(topology.edges(of: a)), [stands(r, for: a), forwarded(WireEdge.id, b, a, by: l, to: r),
                                                 forwarded(QuoteEdge.id, m, a, by: m, to: r, slot: "lead")],
                    "carriers that come in one commit come in no order among themselves")
        try expectRebuilt(h, "after undo")

        h.editor.transact { $0.insert(proxy(ShapeID(), [a])) }
        expectEqual(topology.standIns(for: a).count, 2, "two stand for it")
    },

    test("a commit that only moves shapes reads nothing, stand-ins and what they stand for among them") {
        let a = ShapeID(), b = ShapeID(), r = ShapeID(), g = ShapeID(), l = ShapeID(), m = ShapeID()
        let h = try standing(CanvasFile(root: board(open(a), box(b), proxy(r, [a]), gate(g, [a]), link(l, b, r), link(m, g, r))))
        let read = h.topology.recordsRead, all = h.topology.edges(ofType: .all)
        h.editor.transact { $0.moveBox(r, to: CGPoint(x: 300, y: 40)) }
        h.editor.transact { $0.translate([a, b, g], by: CGPoint(x: 5, y: 5)) }
        expectEqual(h.topology.recordsRead, read)
        expectEqual(h.topology.touched, [])
        expectEqual(h.topology.edges(ofType: .all), all)
    },

    test("stand-ins on boards below, and a chain of 2,000 boards: a commit there, its board deleted and undone, as reading afresh") {
        let owners = (0..<2_000).map { _ in ShapeID() }, a = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID(), m = ShapeID()
        var children: [ShapeID: CanvasDocument] = [:]
        for (index, owner) in owners.enumerated() {
            children[owner] = index + 1 < owners.count ? board(box(ShapeID()), pocket(owners[index + 1])) : board(proxy(r, [a]), link(m, r, b))
        }
        let h = try standing(CanvasFile(root: board(box(a), box(b), link(l, b, r), pocket(owners[0])), children: children))
        expectEqual(h.topology.edges(carriedBy: l), [forwarded(WireEdge.id, b, a, by: l, to: r)], "a stand-in 2,000 boards down")
        expectEqual(h.topology.edges(carriedBy: m), [forwarded(WireEdge.id, a, b, by: m, from: r)])
        let bottom = BoardID(owner: owners[1_999])
        h.editor.transact(on: bottom, "Re-point") { $0.update(r, as: Proxy.self) { $0.props.stands = [Citation(b)] } }
        expectEqual(h.editor.board, .root)
        expectEqual(h.topology.edges(carriedBy: l), [forwarded(WireEdge.id, b, b, by: l, to: r)])
        try expectRebuilt(h, "a commit on the board at the bottom")
        h.editor.transact("Delete") { $0.delete([owners[0]]) }
        expectEqual(h.topology.edges(carriedBy: l), [edge(WireEdge.id, b, r, by: l)], "the stand-in went with its board")
        expectEqual(h.topology.standIns(for: b), [])
        try expectRebuilt(h, "the chain deleted")
        h.editor.undo()
        expectEqual(h.topology.edges(carriedBy: l), [forwarded(WireEdge.id, b, b, by: l, to: r)])
        try expectRebuilt(h, "the chain back")
    },

    test("a file with no stand-ins keeps nothing apart from what its carriers emitted, and only those at a stand-in once there are") {
        let tree = Nest(), r = ShapeID(), x = ShapeID()
        let h = try standing(tree.file)
        expectEqual(h.topology.resolvedCarrierCount, 0)
        h.editor.transact { $0.insert(proxy(r, [tree.a])) }
        expectEqual(h.topology.resolvedCarrierCount, 1, "the stand-in's standing edge")
        h.editor.transact { $0.insert(memo(x, lead: r)) }
        expectEqual(h.topology.resolvedCarrierCount, 2, "and the memo quoting it; the others as they were")
        h.editor.transact("Delete") { $0.delete([r]) }
        expectEqual(h.topology.resolvedCarrierCount, 0)
        expectEqual(h.topology.edges(carriedBy: x), [edge(QuoteEdge.id, x, r, by: x, slot: "lead")])
        try expectRebuilt(h, "")
    },

    test("snapshots in each view answer off the main actor as the index does in that view") {
        let a = ShapeID(), c = ShapeID(), b = ShapeID(), r = ShapeID(), l = ShapeID()
        let h = try standing(CanvasFile(root: board(box(a), box(c), box(b), proxy(r, [a, c]), link(l, b, r))))
        for (name, view) in views {
            let snapshot = h.topology.snapshot(view)
            let far = try require(offMain {
                (snapshot.edges(of: r), snapshot.edges(of: a), snapshot.edges(ofType: .all), snapshot.edges(carriedBy: l), snapshot.neighbors(of: b),
                 snapshot.hasEdges(of: r, .incoming), snapshot.forwards(of: r), snapshot.standIns(for: c))
            })
            expectEqual(far.0, h.topology.edges(of: r, view: view), name)
            expectEqual(far.1, h.topology.edges(of: a, view: view), name)
            expectEqual(far.2, h.topology.edges(ofType: .all, view: view), name)
            expectEqual(far.3, h.topology.edges(carriedBy: l, view: view), name)
            expectEqual(far.4, h.topology.neighbors(of: b, view: view), name)
            expectEqual(far.5, h.topology.hasEdges(of: r, .incoming, view: view), name)
            expectEqual(far.6, [a, c])
            expectEqual(far.7, [r])
        }
        let held = h.topology.snapshot()
        h.editor.transact { $0.update(r, as: Proxy.self) { $0.props.stands = [] } }
        expectEqual(held.forwards(of: r), [a, c], "a snapshot held answers as then")
        expectEqual(held.edges(carriedBy: l).count, 2)
        expectEqual(h.topology.edges(carriedBy: l), [edge(WireEdge.id, b, r, by: l)])
    },

    test("through seeded commits, undo and boards it can't show: the index is as read afresh, its literal view what carriers emit, its recorded view its resolved one, and what it resolves what the rule says") {
        for seed: UInt64 in [5, 23, 24, 30, 31, 71] {
            let churn = try Turnover(seed: seed)
            var forwardedSteps = 0
            for step in 0..<150 {
                let what = churn.step(), context = "seed \(seed), step \(step), after \(what)"
                guard try expectRebuilt(churn.h, context), expectLiteral(churn.h, context), expectRecorded(churn.h, context),
                      expectResolved(churn.h, context) else { break }
                if churn.h.topology.resolvedCarrierCount > 0 { forwardedSteps += 1 }
            }
            expect(forwardedSteps > 60, "edges were forwarded through much of the run (\(forwardedSteps) of 150), seed \(seed)")
        }
    },
])

// MARK: Holding the index to the rules

/// Every shape in the file, and a missing one: what questions are asked about.
@MainActor private func questioned(_ h: EditorHarness) -> [ShapeID] {
    var found = h.file.root.shapes.map(\.id)
    for (_, board) in h.file.children.sorted(by: { $0.key.description < $1.key.description }) { found += board.shapes.map(\.id) }
    return found + [id(3)]
}

/// Holds the index to one that reads the file afresh, in every view: each shape's edges, each
/// carrier's, the file's, and what stands for what.
@MainActor @discardableResult
private func expectRebuilt(_ h: EditorHarness, _ context: String, file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
    let fresh = try require(CanvasEditor(registry: h.editor.registry, file: h.file, showing: h.editor.board).topology)
    let index = h.topology
    var problems: [String] = []
    for (name, view) in views {
        if Set(index.edges(ofType: .all, view: view)) != Set(fresh.edges(ofType: .all, view: view)) { problems.append("the file's edges, \(name)") }
        for id in questioned(h) {
            if Set(index.edges(of: id, view: view)) != Set(fresh.edges(of: id, view: view)) { problems.append("edges(of: \(id)), \(name)") }
            if index.edges(carriedBy: id, view: view) != fresh.edges(carriedBy: id, view: view) { problems.append("edges(carriedBy: \(id)), \(name)") }
        }
    }
    for id in questioned(h) {
        if index.forwards(of: id) != fresh.forwards(of: id) { problems.append("forwards(of: \(id))") }
        if Set(index.standIns(for: id)) != Set(fresh.standIns(for: id)) { problems.append("standIns(for: \(id))") }
        if index.forwarding(of: id) != fresh.forwarding(of: id) { problems.append("forwarding(of: \(id))") }
        if Set(index.edges(through: id)) != Set(fresh.edges(through: id)) { problems.append("edges(through: \(id))") }
    }
    if index.resolvedCarrierCount != fresh.resolvedCarrierCount { problems.append("carriers kept apart") }
    expect(problems.isEmpty, "as reading the file afresh, \(context): \(problems.prefix(4).joined(separator: "; "))", file: file, line: line)
    return problems.isEmpty
}

/// The shapes on boards the editor can show, and what each emits as its kind's sources say.
@MainActor private func emitted(_ h: EditorHarness) -> [(ShapeID, [Edge])] {
    questioned(h).compactMap { id in h.editor.shape(inFile: id).map { (id, h.editor.registry.edges(of: $0)) } }
}

/// Holds the literal view to what carriers emit: each carrier's, in order, and each shape's.
@MainActor func expectLiteral(_ h: EditorHarness, _ context: String, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    let carried = emitted(h), all = carried.flatMap(\.1)
    var problems: [String] = []
    for (id, edges) in carried where h.topology.edges(carriedBy: id, view: .literal) != edges { problems.append("carried by \(id)") }
    for id in questioned(h) where Set(h.topology.edges(of: id, view: .literal)) != Set(all.filter { $0.source == id || $0.target == id }) {
        problems.append("edges(of: \(id))")
    }
    if Set(h.topology.edges(ofType: .all, view: .literal)) != Set(all) { problems.append("the file's") }
    expect(problems.isEmpty, "the literal view is what's emitted, \(context): \(problems.prefix(4).joined(separator: "; "))", file: file, line: line)
    return problems.isEmpty
}

/// Holds the recorded view to the resolved one, with no stand-in for what's provided: exactly.
@MainActor private func expectRecorded(_ h: EditorHarness, _ context: String, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    var problems: [String] = []
    for id in questioned(h) {
        if h.topology.edges(of: id, view: .recorded) != h.topology.edges(of: id) { problems.append("edges(of: \(id))") }
        if h.topology.edges(carriedBy: id, view: .recorded) != h.topology.edges(carriedBy: id) { problems.append("carried by \(id)") }
        if h.topology.neighbors(of: id, view: .recorded) != h.topology.neighbors(of: id) { problems.append("neighbors(of: \(id))") }
    }
    if h.topology.edges(ofType: .all, view: .recorded) != h.topology.edges(ofType: .all) { problems.append("the file's") }
    expect(problems.isEmpty, "the recorded view is the resolved one, \(context): \(problems.prefix(4).joined(separator: "; "))", file: file, line: line)
    return problems.isEmpty
}

/// Holds the resolved view to the rule, worked out here from the records alone: what each proxy and
/// gate stands for, and every carrier's edges forwarded through them.
@MainActor private func expectResolved(_ h: EditorHarness, _ context: String, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    func live(_ id: ShapeID) -> AnyShapeRecord? { h.editor.shape(inFile: id).flatMap { $0.isOpaque ? nil : $0 } }
    func isStandIn(_ record: AnyShapeRecord) -> Bool { record.kind == Proxy.kind || record.kind == Gate.kind }
    func targets(of id: ShapeID) -> [ShapeID] {
        guard let record = live(id) else { return [] }
        let named: [Citation], gated: Bool
        if let proxy = record.typed(as: Proxy.self) { (named, gated) = (proxy.props.stands, false) }
        else if let gate = record.typed(as: Gate.self) { (named, gated) = (gate.props.stands, true) }
        else { return [] }
        var taken: [ShapeID] = []
        for citation in named where !taken.contains(citation.shape) && citation.shape != id && taken.count < 50 {
            guard let target = live(citation.shape), !isStandIn(target), !gated || target.meta[Open.self] == true else { continue }
            taken.append(citation.shape)
        }
        return taken
    }
    var expected: Set<Edge> = [], problems: [String] = []
    for (id, edges) in emitted(h) {
        let forwards = targets(of: id)
        if h.topology.forwards(of: id) != forwards { problems.append("forwards(of: \(id))") }
        if let record = live(id), isStandIn(record) {
            expected.formUnion(edges)
            expected.formUnion(forwards.map { stands(id, for: $0) })
            continue
        }
        for edge in edges {
            let sources = targets(of: edge.source), targets = targets(of: edge.target)
            if sources.isEmpty, targets.isEmpty {
                expected.insert(edge)
                continue
            }
            for source in sources.isEmpty ? [edge.source] : sources {
                for target in targets.isEmpty ? [edge.target] : targets {
                    expected.insert(forwarded(edge.type, source, target, by: id, from: sources.isEmpty ? nil : edge.source,
                                              to: targets.isEmpty ? nil : edge.target, slot: edge.slot, count: edge.count))
                }
            }
        }
    }
    if Set(h.topology.edges(ofType: .all)) != expected { problems.append("the file's edges") }
    expect(problems.isEmpty, "resolved as the rule says, \(context): \(problems.prefix(4).joined(separator: "; "))", file: file, line: line)
    return problems.isEmpty
}

// MARK: Seeded commits

/// A reproducible stream of choices.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Seeded commits of every kind among stand-ins, on the hidden file (box 1, link 2 to a missing
/// shape 3, and the gadget 10, kept aside, whose board the editor can't show) with more on its root:
/// pocket 100, whose board holds an open box, a link and pocket 103, whose board holds a proxy; and
/// proxies, a gate and a link between two stand-ins. Each commit's new shapes are numbered from 110.
@MainActor final class Turnover {
    let h: EditorHarness
    /// With lenses among the proxies, and answers given to them as the commits come (`provide`).
    private let lenses: Bool
    /// The answers the index should still hold, as the lenses' key and answers say: held by the
    /// answers a step gave that were taken, until a commit lets one go (`keepHeld`).
    private(set) var answers: [ShapeID: ProvidedForwarding] = [:]
    private var revisions: [ShapeID: Int] = [:]
    private var random: Seeded
    private var next = 110

    init(seed: UInt64, lenses: Bool = false) throws {
        self.lenses = lenses
        let hidden = try hiddenFile().file
        var children = hidden.children
        children[id(100)] = board(open(id(101)), link(id(102), id(101), id(108)), pocket(id(103)))
        children[id(103)] = board(proxy(id(104), [id(1), id(101)]), link(id(105), id(104), id(1)))
        var root = hidden.root.shapes + [pocket(id(100)), proxy(id(106), [id(101), id(11), id(10)]), gate(id(107), [id(1), id(101)]),
                                         proxy(id(108), [id(1)]), link(id(109), id(106), id(107))]
        if lenses { root += [lens(id(900), asks: "q0"), link(id(901), id(1), id(900)), link(id(902), id(900), id(101))] }
        let file = CanvasFile(root: CanvasDocument(shapes: root), children: children)
        h = lenses ? try lensing(file) : try standing(file)
        random = Seeded(state: seed)
    }

    /// One commit, a switch or an undo, chosen at random; what it was.
    func step() -> String {
        if lenses, Int.random(in: 0..<100, using: &random) < 25 { return provide() }
        let shown = h.editor.document.shapes
        switch Int.random(in: 0..<100, using: &random) {
        case 0..<30:
            let record = newShape()
            h.editor.transact("Add") { t in
                if record.kind == Pocket.kind {
                    t.insert(record, contents: [record.id: board(proxy(fresh(), [target(), target()].compactMap { $0 }), link(fresh(), target(), target()))])
                } else {
                    t.insert(record)
                }
            }
            return "adding \(record.kind) \(record.id)"
        case 30..<50:
            guard let record = pick(shown.filter { $0.id != id(10) }) else { return "nothing" }
            h.editor.transact("Change") { rewire(record.id, in: &$0) }
            return "rewiring \(record.kind) \(record.id)"
        case 50..<60:
            let doomed = Set((0..<Int.random(in: 1...2, using: &random)).compactMap { _ in pick(shown.filter { $0.id != id(10) })?.id })
            h.editor.transact("Delete") { $0.delete(doomed) }
            return "deleting \(doomed.count)"
        case 60..<66:
            guard let record = pick(shown.filter { $0.box != nil }) else { return "nothing" }
            h.editor.transact("Move") { $0.moveBox(record.id, to: CGPoint(x: Int.random(in: 0...500, using: &random), y: 0)) }
            return "moving \(record.id)"
        case 66..<76:
            let boards = [.root] + questioned(h).compactMap { h.editor.shape(inFile: $0) }.filter { $0.kind == Pocket.kind }
                .map { BoardID(owner: $0.id) }.filter(h.editor.canShow)
            guard let board = pick(boards.filter { $0 != h.editor.board }), let rewired = pick(h.file[board].shapes) else { return "nothing" }
            h.editor.transact(on: board, "Elsewhere") { rewire(rewired.id, in: &$0) }
            return "a commit on another board"
        case 76..<80:
            h.editor.transact(on: BoardID(owner: id(10)), "Hidden") { $0.insert(proxy(fresh(), [id(1)])) }
            return "a commit refused on the gadget's board"
        case 80..<86:
            let boards = [.root] + shown.filter { $0.kind == Pocket.kind }.map { BoardID(owner: $0.id) }
            guard let board = pick(boards) else { return "nothing" }
            h.editor.showBoard(board)
            return "showing a board"
        case 86..<94:
            h.editor.undo()
            return "undo"
        default:
            h.editor.redo()
            return "redo"
        }
    }

    /// Gives a lens an answer: mostly for the key it asks now, and a recent one; sometimes for
    /// another, or an older one, which the index drops.
    private func provide() -> String {
        let all = questioned(h).filter { h.editor.shape(inFile: $0)?.kind == Lens.kind }
        guard let id = pick(all), let asks = h.editor.shape(inFile: id)?.typed(as: Lens.self)?.props.asks else { return "no lens to answer" }
        let key = Int.random(in: 0..<6, using: &random) == 0 ? "stale" : asks
        var revision = revisions[id, default: 0] + 1
        revisions[id] = revision
        if Int.random(in: 0..<6, using: &random) == 0 { revision = max(0, revision - 3) }
        let given = ProvidedForwarding(key: ForwardingKey(key), shapes: (0..<Int.random(in: 0...5, using: &random)).compactMap { _ in target() },
                                       revision: revision)
        let takes = h.topology.forwarding(of: id) != .none && key == asks
        h.topology.provide([id: given])
        if takes, answers[id].map({ given.revision >= $0.revision }) ?? true { answers[id] = given }
        return "answering lens \(id) with \(given.shapes.count) shapes at \(revision) for \(key)"
    }

    /// Forgets the answers a commit made the index let go of: those of lenses that ask another
    /// question, were deleted or hidden.
    func keepHeld() {
        for id in Array(answers.keys) {
            if case .provided = h.topology.forwarding(of: id) { continue }
            answers[id] = nil
        }
    }

    private func fresh() -> ShapeID {
        defer { next += 1 }
        return id(next)
    }

    private func pick<T>(_ choices: [T]) -> T? { choices.isEmpty ? nil : choices[Int.random(in: 0..<choices.count, using: &random)] }

    /// A shape an edge or a stand-in may name: any shape in the file, the gadget's too, one missing,
    /// or none.
    private func target() -> ShapeID? {
        let roll = Int.random(in: 0..<10, using: &random)
        return roll == 0 ? nil : roll == 1 ? id(3) : pick(questioned(h))
    }

    private func targets() -> [ShapeID] { (0..<Int.random(in: 0...3, using: &random)).compactMap { _ in target() } }

    private func newShape() -> AnyShapeRecord {
        let id = fresh()
        switch Int.random(in: 0..<8, using: &random) {
        case 0: return box(id)
        case 1: return open(id)
        case 2: return pocket(id)
        case 3, 4: return lenses && Bool.random(using: &random) ? lens(id, asks: "q\(Int.random(in: 0..<3, using: &random))")
                                                              : proxy(id, targets(), next: Bool.random(using: &random) ? target() : nil)
        case 5: return gate(id, targets())
        case 6: return memo(id, notes: [MemoNote("x", cites: targets().map(Citation.init))], lead: target())
        default: return link(id, target(), target())
        }
    }

    /// Points what `id` names somewhere else, as its kind has it; any other shape is opened or shut.
    private func rewire(_ id: ShapeID, in t: inout Transaction) {
        let first = target(), second = target(), some = targets()
        switch t.document[id]?.kind {
        case Link.kind?: t.update(id, as: Link.self) { $0.props.from = first; $0.props.to = second }
        case Proxy.kind?: t.update(id, as: Proxy.self) { $0.props.stands = some.map(Citation.init); $0.props.next = first }
        case Gate.kind?: t.update(id, as: Gate.self) { $0.props.stands = some.map(Citation.init) }
        case Lens.kind?: t.update(id, as: Lens.self) { $0.props.asks = "q\(some.count % 3)" }
        case Memo.kind?: t.update(id, as: Memo.self) { $0.props.lead = first.map(Citation.init) }
        default: t.update(id) { $0.meta[Open.self] = $0.meta[Open.self] == true ? nil : true }
        }
    }
}
