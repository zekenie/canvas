import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import Publishing
import Queries
import References
import Selection
import TestKit
import Titles
import Topology
import Validation

// What a dynamic reference finds: its query, asked of the engine in one batch for every reference
// whose answer may be out of date, on the recorded view, public shapes alone (those that aren't held
// back, counted, and made public by Make Public); handed to Topology,
// which forwards arrows into the pill to what it stands for (the first match, or every one). When
// it's asked (its own question at once, any other commit after 250 ms of quiet, a move never), what
// an undo or an All toggled back shows at once (the answer kept for that question), what a landing
// drops (an older answer, another question's), refusals (no matches, saying why; a word that reads
// the person refused unasked), the deadline (a failure, retried), "Finding…" only past 250 ms, a pill
// being typed into held back, and settling. All on the `ManualScheduler`.

/// Boxes "Alpha" and "Beta", public, and "Gamma", not, across the top; a public tile "From" below.
@MainActor private func boxes(_ h: EditorHarness) -> (alpha: ShapeID, beta: ShapeID, gamma: ShapeID, from: ShapeID) {
    let alpha = h.addBox("Alpha", at: CGRect(x: 100, y: 100, width: 100, height: 60))
    let beta = h.addBox("Beta", at: CGRect(x: 250, y: 100, width: 100, height: 60))
    let gamma = h.addBox("Gamma", public: false, at: CGRect(x: 400, y: 100, width: 100, height: 60))
    let from = h.addTile("From", at: CGRect(x: 100, y: 600, width: 100, height: 60))
    return (alpha, beta, gamma, from)
}

/// Writes the reference's query (and flag), as a gesture would: a step of its own.
@MainActor private func ask(_ h: EditorHarness, _ id: ShapeID, query: String, all: Bool? = nil) {
    h.editor.transact("Edit Reference") { $0.update(id, as: Reference.self) { record in
        ReferenceEdits.find(&record.props, words: "", query: query)
        if let all { record.props.all = all }
    } }
}

@MainActor private func found(_ h: EditorHarness, _ id: ShapeID) -> QueryMatches? {
    guard case .answered(let matches)? = h.status(id) else { return nil }
    return matches
}

/// `:picked`, the shapes selected: a word that reads the editor, as the shipped `:selected` does.
let pickedWord = Contributor(id: "picked") { registrar in
    registrar.queryPseudoClass("picked", "the person has it selected", example: "box:picked",
                               prepare: { (preparation: QueryPreparation) in Set(preparation.editor.selectedShapeIDs) },
                               matches: { shape, picked in picked.contains(shape.record.id) ? .yes : .no })
}

/// Names that make the batch run past its deadline once, when armed: boxes are named by derivation
/// (asked of the main actor), and the first asked while `armed` moves the clock 8 s on.
@MainActor final class SlowNames {
    weak var h: EditorHarness?
    var armed = false
}

@MainActor func slowNames(_ slow: SlowNames) -> Contributor {
    Contributor(id: "slow-names") { registrar in
        registrar.queryNames(attribute: TitleProperty.key.rawValue,
                             source: { kind, registry in registry.properties(for: kind).contains(TitleProperty.key) ? .derived : .none },
                             named: { _ in nil },
                             derived: { record, _ in
                                 if slow.armed {
                                     slow.armed = false
                                     slow.h?.wait(8_000)
                                 }
                                 return TitleProperty.folded(record[TitleProperty.self])
                             },
                             fold: { TitleProperty.folded($0) })
    }
}

@MainActor let answerTests = Suite("What a dynamic reference finds", [
    test("a query stands for its first public match in file order, and with All for every one: arrows into the pill read as into them") {
        let h = try referenceHarness()
        let (alpha, beta, gamma, from) = boxes(h)
        let first = h.addReference(query: "box")
        let all = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 400))
        h.connect(from, first)
        h.connect(from, all)
        expectEqual(h.status(first), .finding(slow: false), "asked, not answered yet")
        expectEqual(h.state(of: first), .finding(text: "box"))
        expectEqual(h.standsFor(first), [], "nothing, until the answer comes")
        h.answer()
        expectEqual(h.standsFor(first), [alpha], "the first in file order")
        expectEqual(h.standsFor(all), [alpha, beta], "every public one: not Gamma")
        expect(!h.standsFor(all).contains(gamma))
        expectEqual(Set(h.editor.wired(from: from)), [alpha, beta], "the tile's wires read as into what the pills stand for")
        expectEqual(found(h, first)?.ids, [alpha, beta], "a first-match pill is given what All would add, for its panel")
        expectEqual(found(h, first)?.count, 2)
        let appearance = try require(h.editor.shape(inFile: alpha).flatMap { h.editor.registry.mentionAppearance(of: $0) })
        expectEqual(h.state(of: first), .found(text: "box", ReferenceFound(all: false, count: 2, ids: [alpha, beta], first: appearance)))
        expectEqual(h.state(of: all), .found(text: "box", ReferenceFound(all: true, count: 2, ids: [alpha, beta], first: nil)))
        guard case .answered(let matches)? = h.status(all) else { return expect(false, "answered") }
        expectEqual(matches.heldBack, 1, "Gamma, a box that isn't public: counted apart, stood for by neither")
        expectEqual(h.editor.topology?.forwarding(of: all), .provided([alpha, beta]))
    },
    test("what a query finds that isn't public is held back: with none public it stands for nothing and says how many; made public, it stands for them") {
        let h = try referenceHarness()
        let a = h.addBox("A", public: false, at: CGRect(x: 100, y: 100, width: 100, height: 60))
        let b = h.addBox("B", public: false, at: CGRect(x: 250, y: 100, width: 100, height: 60))
        let from = h.addTile("From", at: CGRect(x: 100, y: 600, width: 100, height: 60))
        let id = h.addReference(query: "box", all: true)
        h.connect(from, id)
        h.answer()
        expectEqual(h.state(of: id), .privateMatches(text: "box", count: 2))
        expect(h.state(of: id)?.standsForNothing == true, "dashed, as a pill for one shape that isn't public")
        expectEqual(h.standsFor(id), [])
        expectEqual(h.editor.wired(from: from), [id], "the wire stays at the pill")
        try require(h.editor.references).makeMatchesPublic(of: id)
        _ = spinRunLoop(until: { h.editor.document[b]?[PublicProperty.self] == true })
        expectEqual(h.editor.document[a]?[PublicProperty.self], true)
        expectEqual(h.editor.undoHistory.undoName, "Make Public", "one step for both")
        h.answer(after: 250)
        expectEqual(h.standsFor(id), [a, b])
        expectEqual(Set(h.editor.wired(from: from)), [a, b])
        h.editor.undo()
        h.answer(after: 250)
        expectEqual(h.state(of: id), .privateMatches(text: "box", count: 2), "private again: held back again")
        expectEqual(h.standsFor(id), [])
    },
    test("a first-match pill is given eight matches and an All one fifty; the count is all of them") {
        let h = try referenceHarness()
        var ids: [ShapeID] = []
        for index in 0..<60 {
            let frame = CGRect(x: CGFloat(index % 10) * 60, y: CGFloat(index / 10) * 60, width: 50, height: 50)
            ids.append(h.addBox("B\(index)", at: frame))
        }
        let first = h.addReference(query: "box", at: CGPoint(x: 0, y: 700))
        let all = h.addReference(query: "box", all: true, at: CGPoint(x: 300, y: 700))
        h.answer()
        expectEqual(found(h, first)?.ids, Array(ids.prefix(8)))
        expectEqual(found(h, first)?.count, 60)
        expectEqual(found(h, all)?.ids, Array(ids.prefix(50)))
        expectEqual(h.standsFor(all), Array(ids.prefix(50)), "at most fifty")
        expectEqual(h.standsFor(first), [ids[0]])
    },
    test("any other commit asks after 250 ms of quiet, every commit waiting again; one batch for every reference") {
        let h = try referenceHarness()
        let (alpha, beta, _, _) = boxes(h)
        let first = h.addReference(query: "box:not([title=\"Alpha\"])")
        let all = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 400))
        h.answer()
        let state = try require(h.editor.references)
        let asked = state.batchesAsked
        let delta = h.addBox("Delta", at: CGRect(x: 550, y: 100, width: 100, height: 60))
        expect(state.isFinding, "a wait is armed")
        expect(h.editor.topology?.isSettling == true, "and the edges aren't settled")
        h.wait(249)
        expectEqual(state.batchesAsked, asked, "not yet")
        let epsilon = h.addBox("Epsilon", at: CGRect(x: 700, y: 100, width: 100, height: 60))
        h.wait(249)
        expectEqual(state.batchesAsked, asked, "each commit waits again")
        h.wait(1)
        expectEqual(state.batchesAsked, asked + 1, "one batch, for both")
        h.answer()
        expectEqual(h.standsFor(all), [alpha, beta, delta, epsilon])
        expectEqual(h.standsFor(first), [beta])
        expectEqual(state.batchesAsked, asked + 1)
        expect(h.editor.topology?.isSettling == false)
    },
    test("a commit that only moves shapes asks nothing") {
        let h = try referenceHarness()
        let (alpha, _, _, _) = boxes(h)
        let id = h.addReference(query: "box", all: true)
        h.answer()
        let state = try require(h.editor.references)
        let asked = state.batchesAsked
        h.editor.transact { $0.moveBox(alpha, to: CGPoint(x: 120, y: 130)) }
        h.editor.transact { $0.moveBox(id, to: CGPoint(x: 420, y: 330)) }
        expect(!state.isFinding, "no wait armed")
        h.wait(1_000)
        expectEqual(state.batchesAsked, asked)
    },
    test("its own query or flag changed is asked at once, on the scheduler's next turn, with no wait for quiet") {
        let h = try referenceHarness()
        let (alpha, beta, _, from) = boxes(h)
        let id = h.addReference(query: "tile")
        h.answer()
        expectEqual(h.standsFor(id), [from])
        let state = try require(h.editor.references)
        let asked = state.batchesAsked
        ask(h, id, query: "box", all: true)
        expectEqual(h.standsFor(id), [], "another question: nothing until it's answered")
        expectEqual(h.editor.topology?.forwarding(of: id), .pending)
        h.wait(0)
        expectEqual(state.batchesAsked, asked + 1, "asked at once")
        h.answer()
        expectEqual(h.standsFor(id), [alpha, beta])
    },
    test("an undo or a redo shows the answer kept for the question it puts back at once, then asks it again") {
        let h = try referenceHarness()
        let (alpha, beta, _, from) = boxes(h)
        let id = h.addReference(query: "box", all: true)
        h.answer()
        ask(h, id, query: "tile", all: true)
        h.answer()
        expectEqual(h.standsFor(id), [from])
        h.editor.undo()
        expectEqual(found(h, id)?.ids, [alpha, beta], "the pill says it at once")
        let state = try require(h.editor.references)
        let asked = state.batchesAsked
        h.wait(0)
        expectEqual(h.standsFor(id), [alpha, beta], "and Topology has it in the hop, before any batch lands")
        expectEqual(state.batchesAsked, asked + 1, "asked again all the same")
        expect(state.isFinding)
        h.answer()
        expectEqual(h.standsFor(id), [alpha, beta])
        h.editor.redo()
        h.wait(0)
        expectEqual(h.standsFor(id), [from])
        h.answer()
    },
    test("All toggled on, off and undone snaps back to the answer kept for each, never dropped as older") {
        let h = try referenceHarness()
        let (alpha, beta, _, _) = boxes(h)
        let id = h.addReference(query: "box")
        h.answer()
        expectEqual(h.standsFor(id), [alpha])
        let state = try require(h.editor.references)
        state.setAll(true, of: id)
        expectEqual(h.editor.undoHistory.undoName, "Match All")
        h.answer()
        expectEqual(h.standsFor(id), [alpha, beta])
        state.setAll(false, of: id)
        expectEqual(h.editor.undoHistory.undoName, "Match First")
        h.wait(0)
        expectEqual(h.standsFor(id), [alpha], "off: the first's answer at once")
        h.answer()
        h.editor.undo()
        h.wait(0)
        expectEqual(h.standsFor(id), [alpha, beta], "undone: every one's at once, though older than the first's")
        h.answer()
        expectEqual(h.standsFor(id), [alpha, beta])
        h.editor.undo()
        h.wait(0)
        expectEqual(h.standsFor(id), [alpha])
        h.answer()
        expectEqual(h.reference(id)?.frame.width, ReferenceEdits.width(of: try require(h.reference(id))), "no refit: the count's room is kept")
    },
    test("a deleted reference's answers are kept for its undo: it snaps back at once, then asks again") {
        let h = try referenceHarness()
        let (alpha, beta, _, _) = boxes(h)
        let id = h.addReference(query: "box", all: true)
        h.answer()
        let state = try require(h.editor.references)
        h.editor.transact { $0.delete([id]) }
        expect(state.isRemembered(id), "kept past its deletion")
        h.editor.undo()
        expectEqual(found(h, id)?.ids, [alpha, beta], "the answer kept for it, at once")
        h.answer()
        expectEqual(h.standsFor(id), [alpha, beta])
    },
    test("the answers kept are bounded: for at most 256 references, the least recently landed let go first") {
        let h = try referenceHarness()
        _ = boxes(h)
        let state = try require(h.editor.references)
        // One that is answered, then deleted: its answers are kept for its undo.
        let first = h.addReference(query: "box")
        h.answer()
        h.editor.transact { $0.delete([first]) }
        expect(state.isRemembered(first), "kept past its deletion")
        // The 255 more that fill the bound, answered in one batch, all landed after it.
        var made: [ShapeID] = []
        for i in 0..<255 { made.append(h.addReference(query: "box", at: CGPoint(x: 400 + CGFloat(i), y: 300))) }
        h.answer()
        expectEqual(state.memoCount, 256, "full, the deleted one's among them")
        expect(state.isRemembered(first))
        // One more: the least recently landed one's goes, the deleted one's, which no batch has landed since.
        let newest = h.addReference(query: "box", at: CGPoint(x: 400, y: 500))
        h.answer()
        expectEqual(state.memoCount, 256, "bounded, not 257")
        expect(!state.isRemembered(first), "the least recently landed one's let go")
        expect(state.isRemembered(newest), "the newest is kept")
        expect(made.allSatisfy(state.isRemembered), "and every other: each batch lands every reference again")
        // However many more are made, it holds.
        for i in 0..<10 { h.addReference(query: "tile", at: CGPoint(x: 400 + CGFloat(i), y: 600)) }
        h.answer()
        expectEqual(state.memoCount, 256, "and so on, past the bound with every one alive")
    },
    test("an answer older than the latest for its question is dropped, and an answer to another question") {
        let h = try referenceHarness()
        let (alpha, beta, _, _) = boxes(h)
        let id = h.addReference(query: "box", all: true)
        h.answer()
        let state = try require(h.editor.references)
        let revision = try require(found(h, id)).revision
        let key = ReferenceState.key(query: "box", all: true)
        state.land(QueryMatches(canonical: "box", ids: [beta], count: 1, revision: revision - 1), for: id, key: key)
        expectEqual(h.standsFor(id), [alpha, beta], "older: dropped")
        state.land(QueryMatches(canonical: "tile", ids: [beta], count: 1, revision: revision + 5), for: id, key: ReferenceState.key(query: "tile", all: true))
        expectEqual(h.standsFor(id), [alpha, beta], "another question's: dropped")
        state.land(QueryMatches(canonical: "box", ids: [beta], count: 1, revision: revision + 1), for: id, key: key)
        expectEqual(h.standsFor(id), [beta], "newer: taken")
    },
    test("a batch's answer that lands after the question changed is dropped, and the new question asked") {
        let h = try referenceHarness()
        let (alpha, _, _, from) = boxes(h)
        let id = h.addReference(query: "box")
        let state = try require(h.editor.references)
        h.wait(0)
        let landed = state.batchesLanded
        ask(h, id, query: "tile")
        _ = spinRunLoop(until: { state.batchesLanded > landed })
        expectEqual(h.standsFor(id), [], "the box's answer isn't the tile's")
        expectEqual(h.status(id), .finding(slow: false))
        h.answer()
        expectEqual(h.standsFor(id), [from])
        expect(!h.standsFor(id).contains(alpha))
    },
    test("a title no shape has is no matches, saying why: dashed, nothing forwarded, nothing pending; an undo that brings the shape back heals it") {
        let h = try referenceHarness()
        let (alpha, _, _, from) = boxes(h)
        let id = h.addReference(query: "\"Alpha\"")
        h.connect(from, id)
        h.answer()
        expectEqual(h.standsFor(id), [alpha])
        h.editor.transact { $0.delete([alpha]) }
        h.answer(after: 250)
        guard case .refused(let message)? = h.status(id) else { return expect(false, "refused: \(String(describing: h.status(id)))") }
        expect(message.contains("Alpha"), message)
        expectEqual(h.state(of: id), .refused(text: "\"Alpha\"", message: message))
        expect(h.state(of: id)?.standsForNothing == true)
        expectEqual(h.editor.topology?.forwarding(of: id), .provided([]), "answered: none")
        expectEqual(h.editor.wired(from: from), [id], "the wire reads at the pill")
        h.editor.undo()
        h.answer(after: 250)
        expectEqual(h.standsFor(id), [alpha])
    },
    test("a query that reads what the person is doing isn't asked: refused, naming the word, and warned of") {
        let h = try referenceHarness([pickedWord])
        _ = boxes(h)
        let state = try require(h.editor.references)
        let asked = state.batchesAsked
        let id = h.addReference(query: "box:picked")
        h.answer()
        expectEqual(h.status(id), .refused("“:picked” can’t be used here."))
        expectEqual(state.batchesAsked, asked, "nothing asked of the engine")
        expectEqual(h.editor.topology?.forwarding(of: id), .provided([]))
        expectEqual(h.editor.validation?.result(for: id)?.issues ?? [], [.warning("“:picked” can’t be used here.", field: "query")],
                    "the same gate as the answers': a stored query reads only the file")
    },
    test("a query the engine can't read is refused in its words, and warned of; a query it can is no issue") {
        let h = try referenceHarness()
        _ = boxes(h)
        let id = h.addReference(query: "box[")
        h.answer()
        guard case .refused(let message)? = h.status(id) else { return expect(false, "refused") }
        let issues = try require(h.editor.validation?.result(for: id)).issues
        expectEqual(issues, [.warning(message, field: "query")])
        ask(h, id, query: "box")
        expectEqual(h.editor.validation?.result(for: id)?.issues ?? [], [])
        let refusedName = h.addReference(query: "\"Nobody\"", at: CGPoint(x: 400, y: 500))
        h.answer()
        expectEqual(h.editor.validation?.result(for: refusedName)?.issues ?? [], [], "a name no shape has is the pill's to say, not an issue")
    },
    test("with no engine, a query finds nothing and says so") {
        let h = try referenceHarness(queries: false)
        _ = boxes(h)
        let id = h.addReference(query: "box")
        h.answer()
        expectEqual(h.status(id), .unavailable)
        expectEqual(h.state(of: id), .cannotFind(text: "box"))
        expect(h.state(of: id)?.standsForNothing == true)
        let content = try require(h.editor.references).queryContent(of: try require(h.reference(id)), id: id)
        expectEqual(content.status?.text, "Unavailable")
    },
    test("past the deadline it's a failure that can be retried") {
        let slow = SlowNames()
        let h = try referenceHarness(names: slowNames(slow))
        slow.h = h
        let (alpha, _, _, _) = boxes(h)
        slow.armed = true
        let id = h.addReference(query: "\"Alpha\"")
        h.answer()
        expectEqual(h.status(id), .failed(.tooSlow))
        expectEqual(h.state(of: id), .failed(text: "\"Alpha\"", .tooSlow))
        let state = try require(h.editor.references)
        let content = state.queryContent(of: try require(h.reference(id)), id: id)
        expectEqual(content.status, ReferenceStatusLine(text: "Too slow", isWarning: true, isBusy: false, action: .retry))
        state.retry(id)
        h.answer()
        expectEqual(h.standsFor(id), [alpha])
    },
    test("it's said to be finding only once the answer has been out 250 ms") {
        let h = try referenceHarness()
        _ = boxes(h)
        let id = h.addReference(query: "box")
        let state = try require(h.editor.references)
        h.wait(0)
        expectEqual(h.status(id), .finding(slow: false))
        expectEqual(state.queryContent(of: try require(h.reference(id)), id: id).status, nil, "a quick answer never flashes")
        h.wait(250)
        expectEqual(h.status(id), .finding(slow: true))
        expectEqual(state.queryContent(of: try require(h.reference(id)), id: id).status,
                    ReferenceStatusLine(text: "Finding…", isWarning: false, isBusy: true, action: nil))
        h.answer()
        expect(found(h, id) != nil)
    },
    test("a pill being typed into isn't asked until editing ends") {
        let h = try referenceHarness()
        let (alpha, beta, _, _) = boxes(h)
        let id = h.addReference(query: "box", all: true)
        let other = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 500))
        h.answer()
        h.editor.selectedShapeIDs = [id]
        expect(h.key("\r"), "Return edits it")
        expectEqual(h.editor.editingShapeID, id)
        let delta = h.addBox("Delta", at: CGRect(x: 550, y: 100, width: 100, height: 60))
        h.answer(after: 250)
        expectEqual(h.standsFor(other), [alpha, beta, delta])
        expectEqual(h.standsFor(id), [alpha, beta], "held back while it's edited")
        h.editor.endEditing()
        h.answer()
        expectEqual(h.standsFor(id), [alpha, beta, delta])
    },
    test("Topology's edges settle once the answers land: a waiter is let go then") {
        let h = try referenceHarness()
        _ = boxes(h)
        let id = h.addReference(query: "box")
        let topology = try require(h.editor.topology)
        h.answer()
        expect(!topology.isSettling)
        _ = h.addBox("Delta", at: CGRect(x: 550, y: 100, width: 100, height: 60))
        expect(topology.isSettling, "a wait is armed")
        var settled: Bool?
        Task { @MainActor in settled = await topology.settled(timeout: .seconds(60)) }
        _ = spinRunLoop(until: { true })
        expectEqual(settled, nil, "still waiting")
        h.wait(250)
        expect(topology.isSettling, "a batch is out")
        _ = spinRunLoop(until: { settled != nil })
        expectEqual(settled, true)
        expect(found(h, id) != nil)
    },
])

// Words typed into a pill that read as a query are that query, in the step that typed them (no model
// is asked); other words wait to be interpreted.

@MainActor let typedQueryTests = Suite("Words that read as a query", [
    test("committed from the words row, words that read as a query are that query, canonical, in the step that typed them, and found") {
        let h = try referenceHarness()
        let plan = h.addBox("Plan B", at: CGRect(x: 100, y: 100, width: 150, height: 100))
        let pricing = h.addBox("Pricing and plans", at: CGRect(x: 100, y: 400, width: 150, height: 100))
        let field = try h.placeReference()
        defer { field.close() }
        field.type("box ,  tile")
        expectEqual(field.titles, ["box ,  tile"], "nothing public is called that: the words row alone")
        field.returnKey()
        expectEqual(h.editor.editingShapeID, nil)
        let props = try require(h.reference(field.id))
        expectEqual(props.words, "box ,  tile", "the words as typed")
        expectEqual(props.query, "box, tile", "the query, canonical")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference", "in the step that placed and typed it")
        h.answer()
        expectEqual(h.standsFor(field.id), [plan], "its first match")
        h.editor.undo()
        expectEqual(h.editor.document[field.id], nil, "one step")
        _ = pricing
    },
    test("⌥Return on words that don't read as a query leaves them to be interpreted; leaving the field with words that do makes them the query") {
        let h = try referenceHarness()
        h.addBox("Plan B", at: CGRect(x: 100, y: 100, width: 150, height: 100))
        let field = try h.placeReference()
        field.type("plan")
        expect(field.titles.count > 1, "a shape matches")
        field.returnKey(.option)
        let words = try require(h.reference(field.id))
        expectEqual(words.words, "plan")
        expectEqual(words.query, nil, "no kind is called plan: words, for the model")
        expectEqual(h.state(of: field.id), .notInterpreted(text: "plan"))
        field.close()
        let other = try h.placeReference(at: CGPoint(x: 600, y: 600))
        other.type("tile")
        other.escape()
        other.escape()
        expectEqual(h.editor.editingShapeID, nil, "left")
        expectEqual(h.reference(other.id)?.query, "tile", "left with words that read as a query: that query")
        other.close()
    },
    test("a pill opened and left as it was makes no step; typed into, its query follows its new words") {
        let h = try referenceHarness()
        h.addBox("Plan B", at: CGRect(x: 100, y: 100, width: 150, height: 100))
        let id = h.addReference(words: "box", query: "box")
        let steps = h.editor.undoHistory.undoName
        let field = try h.editReference(id)
        field.escape()
        field.escape()
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        expectEqual(h.reference(id)?.query, "box")
        field.close()
        let again = try h.editReference(id)
        again.type("tile")
        again.returnKey()
        again.close()
        expectEqual(h.reference(id)?.words, "tile")
        expectEqual(h.reference(id)?.query, "tile")
        expectEqual(h.editor.undoHistory.undoName, "Edit Reference")
    },
])
