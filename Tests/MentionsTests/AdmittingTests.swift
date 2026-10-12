import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import TestKit
import Titles

// What the `@` picker lists on the line of a slash command that takes one shape: `candidates`'
// `kinds`, the most kinds of shape to list, and `admitting`, the rule a shape must pass besides the
// text's scope, headless. The rule is asked wherever a shape would be listed (recent picks, nearby,
// the boards the text is inside, matches, a narrow scope's members), never of what the scope or the
// kinds refuse; with kinds only the catalog's shapes of those kinds are ranked, as a scope's members
// are, so a command that takes few of a big board's shapes costs what they are, and an empty query
// lists every one, on every board, the nearest board first; and with neither nothing changes. The
// text view that gets them from the command on its line is `slashTests`'.

private func frame(_ i: Int) -> CGRect { CGRect(x: i * 150, y: 0, width: 120, height: 80) }

/// A rule admitting exactly these shapes.
@MainActor private func among(_ ids: [ShapeID]) -> @MainActor (ShapeID) -> Bool {
    let admitted = Set(ids)
    return { admitted.contains($0) }
}

/// A board for the rule's tests: a jot (the text's shape) at the origin, then along its row, nearest
/// first, a plate, a token, a plate, a token, and so on, six of each.
@MainActor private final class Row {
    let h: EditorHarness
    let owner: ShapeID
    let plates: [ShapeID]
    let tokens: [ShapeID]
    var state: MentionState { h.editor.mentionState }

    init() throws {
        let h = try mentionHarness()
        self.owner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))
        self.plates = (0..<6).map { h.editor.add(Plate(frame(2 * $0 + 1)), titled: "Plate \($0)") }
        self.tokens = (0..<6).map { h.add(Token(frame(2 * $0 + 2), caption: "Token \($0)")) }
        self.h = h
    }

    func candidates(_ query: String = "", kinds: Set<ShapeKind>? = nil, admitting rule: (@MainActor (ShapeID) -> Bool)? = nil) -> MentionCandidates {
        state.candidates(matching: query, in: AnyMentionable.self, for: owner, kinds: kinds, admitting: rule)
    }
}

@MainActor let admittingTests = Suite("Picking what a command takes", [
    test("an empty query lists the recent picks and the nearest shapes the rule admits, and none it doesn't") {
        let r = try Row()
        r.state.didPick(r.tokens[5])
        r.state.didPick(r.plates[5])
        let all = r.candidates()
        expectEqual(all.recent.map(\.id), [r.plates[5], r.tokens[5]])
        expectEqual(all.nearby.map(\.id), [r.plates[0], r.tokens[0], r.plates[1], r.tokens[1]], "nearest first, plates and tokens between")

        let plates = r.candidates(admitting: among(r.plates))
        expectEqual(plates.recent.map(\.id), [r.plates[5]], "the token picked first isn't one it takes")
        expectEqual(plates.nearby.map(\.id), Array(r.plates.prefix(4)), "the four nearest plates, the tokens between left out")
        let tokens = r.candidates(admitting: among(r.tokens))
        expectEqual(tokens.recent.map(\.id), [r.tokens[5]])
        expectEqual(tokens.nearby.map(\.id), Array(r.tokens.prefix(4)))
        expectEqual(r.candidates(admitting: among([])), MentionCandidates(), "none admitted, none listed")
        expectEqual(r.candidates(admitting: among([r.owner])), MentionCandidates(), "the text's own shape is never nearby, whatever the rule")
    },

    test("a typed query's matches are what the rule admits, ranked as without it, the best 50 of those") {
        let r = try Row()
        let all = r.candidates("t").matches.map(\.id)
        expectEqual(Set(all), Set(r.plates + r.tokens), "\"t\" is in every label")
        let plates = r.candidates("t", admitting: among(r.plates)).matches.map(\.id)
        expectEqual(plates, all.filter { r.plates.contains($0) }, "the same order, less what the rule refuses")
        expectEqual(r.candidates("token", admitting: among(r.plates)).matches, [], "what matches but isn't admitted is no match")

        let h = try mentionHarness()
        let items = (0..<60).map { h.editor.add(Plate(frame($0)), titled: "Item \($0)") }
        for i in 0..<60 { _ = h.add(Token(frame(60 + i), caption: "Item \(i)")) }
        let state = h.editor.mentionState
        expectEqual(state.candidates(matching: "item", in: AnyMentionable.self, for: nil).matches.count, 50)
        let listed = state.candidates(matching: "item", in: AnyMentionable.self, for: nil, admitting: among(items)).matches
        expectEqual(listed.count, 50, "fifty plates, though a hundred and twenty shapes match")
        expect(listed.allSatisfy { items.contains($0.id) })
    },

    test("what the rule refuses doesn't count toward the eight matches that keep the typo pass from running") {
        let h = try mentionHarness()
        let target = h.editor.add(Plate(frame(0)), titled: "Grocery List")
        for i in 1...8 { _ = h.add(Token(frame(i), caption: "Grocexy \(i)")) }
        let state = h.editor.mentionState
        let unruled = state.candidates(matching: "grocexy", in: AnyMentionable.self, for: nil).matches.map(\.id)
        expectEqual(unruled.count, 8)
        expect(!unruled.contains(target), "eight better matches: no typo pass")
        let ruled = state.candidates(matching: "grocexy", in: AnyMentionable.self, for: nil, admitting: among([target])).matches.map(\.id)
        expectEqual(ruled, [target], "none of them listed, so fewer than eight: the typo pass runs, and finds the plate")
    },

    test("a scope that admits few ranks its members, the rule is asked of those alone, and of every one: matches and nearby") {
        let h = try mentionHarness()
        let owner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))
        let plates = (0..<3).map { h.editor.add(Plate(frame($0 + 1)), titled: "Alpha plate \($0)") }
        let tokens = (0..<3).map { h.add(Token(frame($0 + 4), caption: "Alpha token \($0)")) }
        let jot = h.add(Jot(frame(7), text: "Alpha jot"))
        let endpoint = h.add(Endpoint(frame(8), path: "Alpha"))
        let state = h.editor.mentionState
        var asked: Set<ShapeID> = []
        let tokensOnly: @MainActor (ShapeID) -> Bool = { id in
            asked.insert(id)
            return tokens.contains(id)
        }
        // `Blockers`: plates and tokens, not jots or endpoints.
        let members = Set(state.candidates(matching: "alpha", in: Blockers.self, for: owner).matches.map(\.id))
        expectEqual(members, Set(plates + tokens))
        let typed = state.candidates(matching: "alpha", in: Blockers.self, for: owner, admitting: tokensOnly)
        expectEqual(Set(typed.matches.map(\.id)), Set(tokens), "the members it admits")
        expectEqual(asked, Set(plates + tokens), "asked of each member, and never of the jot or the endpoint the scope refuses")
        expect(!asked.contains(jot) && !asked.contains(endpoint))
        asked = []
        let near = state.candidates(matching: "", in: Blockers.self, for: owner, admitting: tokensOnly)
        expectEqual(near.nearby.map(\.id), tokens, "the nearest members it admits, nearest first")
        expect(asked.isSubset(of: Set(plates + tokens)), "still the scope's members alone")
        // And the other scopes are as they were.
        expectEqual(Set(state.candidates(matching: "alpha", in: AnyMentionable.self, for: owner, admitting: among([jot])).matches.map(\.id)), [jot])
    },

    test("the boards the text is inside are listed only if the rule admits them, the board shown's own shapes first") {
        let pocket = ShapeID(), owner = ShapeID(), inner = ShapeID(), outer = ShapeID()
        @MainActor func plate(_ id: ShapeID, _ title: String, x: Double) -> AnyShapeRecord {
            var plate = ShapeRecord(id: id, Plate(CGRect(x: x, y: 0, width: 120, height: 80)))
            plate[TitleProperty.self] = title
            return AnyShapeRecord(plate)
        }
        let root = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 1200, y: 1200, width: 100, height: 100)))),
                                           plate(outer, "Outer plate", x: 1000)])
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: owner, Jot(CGRect(x: 20, y: 20, width: 200, height: 200)))),
                                             plate(inner, "Inner plate", x: 300)])
        let mentionablePockets = Contributor(id: "mentionable-pockets") { $0.mentionable(Pocket.self, label: { _ in "Pouch" }) }
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin(), mentionablePockets]), file: CanvasFile(root: root, children: [pocket: inside]))
        expect(h.editor.showBoard(BoardID(owner: pocket)))
        let state = h.editor.mentionState
        @MainActor func nearby(_ rule: (@MainActor (ShapeID) -> Bool)?) -> [ShapeID] {
            state.candidates(matching: "", in: AnyMentionable.self, for: owner, admitting: rule).nearby.map(\.id)
        }
        expectEqual(nearby(nil), [inner, pocket], "the plate beside it, then the pocket it's inside")
        expectEqual(nearby(among([inner, pocket])), [inner, pocket])
        expectEqual(nearby(among([inner])), [inner], "the pocket isn't one the command takes")
        expectEqual(nearby(among([pocket])), [pocket], "the plate isn't, the pocket is")
        expectEqual(nearby(among([outer])), [], "a plate on the root isn't nearby, and its board isn't one the text is inside")
        let matches = { (query: String, rule: (@MainActor (ShapeID) -> Bool)?) in
            state.candidates(matching: query, in: AnyMentionable.self, for: owner, admitting: rule).matches.map(\.id)
        }
        expectEqual(matches("plate", nil), [inner, outer], "matches from any board of the file")
        expectEqual(matches("plate", among([outer])), [outer], "a shape on another board is asked of too")
    },

    test("with kinds, an empty query lists them on every board: the board shown's nearest first, the boards it's inside, then the others, the nearest board first; as many as a query lists") {
        // The root holds pockets A and B and a plate; A's board the text's jot, a plate and pocket C;
        // B's board a plate, and C's another.
        let a = ShapeID(), b = ShapeID(), c = ShapeID(), owner = ShapeID()
        let onRoot = ShapeID(), onA = ShapeID(), onB = ShapeID(), onC = ShapeID()
        @MainActor func plate(_ id: ShapeID, x: Double) -> AnyShapeRecord {
            var plate = ShapeRecord(id: id, Plate(CGRect(x: x, y: 0, width: 120, height: 80)))
            plate[TitleProperty.self] = "Plate"
            return AnyShapeRecord(plate)
        }
        @MainActor func pocket(_ id: ShapeID, x: Double) -> AnyShapeRecord {
            AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: 1200, width: 100, height: 100))))
        }
        let root = CanvasDocument(shapes: [pocket(a, x: 0), pocket(b, x: 200), plate(onRoot, x: 400)])
        let boardA = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: owner, Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))),
                                             plate(onA, x: 300), pocket(c, x: 600)])
        let mentionablePockets = Contributor(id: "mentionable-pockets") { $0.mentionable(Pocket.self, label: { _ in "Pouch" }) }
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin(), mentionablePockets]),
                                  file: CanvasFile(root: root, children: [a: boardA, b: CanvasDocument(shapes: [plate(onB, x: 0)]),
                                                                          c: CanvasDocument(shapes: [plate(onC, x: 0)])]))
        expect(h.editor.showBoard(BoardID(owner: a)))
        let state = h.editor.mentionState
        @MainActor func nearby(_ kinds: Set<ShapeKind>?, _ rule: (@MainActor (ShapeID) -> Bool)? = nil) -> [ShapeID] {
            state.candidates(matching: "", in: AnyMentionable.self, for: owner, kinds: kinds, admitting: rule).nearby.map(\.id)
        }
        let kinds: Set<ShapeKind> = [Plate.kind, Pocket.kind]
        expectEqual(nearby(kinds), [onA, c, a, b, onRoot, onC, onB],
                    "A's plate and pocket C, nearest first; A, the board it's inside; one board away, the root's (B, its plate) and C's plate; then B's, two away")
        expectEqual(nearby(kinds, among([onB, onRoot])), [onRoot, onB], "the rule asked of each")
        expectEqual(nearby(nil), [onA, c, a], "without kinds, as ever: what's near on the board shown and the boards it's inside")
        expectEqual(nearby([Plate.kind]), [onA, onRoot, onC, onB], "the plates alone")

        h.editor.transact(on: BoardID(owner: b)) { t in
            for i in 1...60 { t.insert(plate(ShapeID(), x: Double(200 * i))) }
        }
        expectEqual(nearby([Plate.kind]).count, MentionRanking.maxMatches, "sixty more on B's board: no more than a query lists")
    },

    test("a rule that admits everything lists what no rule does, for every kind of query") {
        let r = try Row()
        r.state.didPick(r.tokens[2])
        r.state.didPick(r.plates[1])
        let everything = among(r.plates + r.tokens + [r.owner])
        for query in ["", "plate", "tok", "t", "zzzzq", "tokan", "plate 3"] {
            expectEqual(r.candidates(query, admitting: everything), r.candidates(query), "\"\(query)\"")
        }
    },

    test("kinds narrow what's listed to the shapes of those kinds, whatever the rule says: recent picks, nearby and matches") {
        let r = try Row()
        r.state.didPick(r.tokens[5])
        r.state.didPick(r.plates[5])
        let anything: @MainActor (ShapeID) -> Bool = { _ in true }

        let tokens = r.candidates(kinds: [Token.kind], admitting: anything)
        expectEqual(tokens.recent.map(\.id), [r.tokens[5]], "the plate picked last isn't a token")
        expectEqual(tokens.nearby.map(\.id), Array(r.tokens.prefix(5)), "every other token, not four: nearest first, the plates between left out")
        expectEqual(Set(r.candidates("t", kinds: [Token.kind], admitting: anything).matches.map(\.id)), Set(r.tokens),
                    "\"t\" is in every label: the tokens only")
        expectEqual(r.candidates("plate", kinds: [Token.kind], admitting: anything).matches, [], "what matches but isn't of the kinds is no match")
        expectEqual(r.candidates(kinds: []), MentionCandidates(), "no kinds, nothing")
        expectEqual(r.candidates("t", kinds: []), MentionCandidates())

        let both = r.candidates(kinds: [Plate.kind, Token.kind])
        let alternating = (0..<5).flatMap { [r.plates[$0], r.tokens[$0]] }
        expectEqual(both.nearby.map(\.id), alternating, "the kinds of both, in the order the listing without any has")
        expectEqual(Array(both.nearby.prefix(4)), r.candidates().nearby, "which lists the first four")
        let ruled = r.candidates(kinds: [Plate.kind, Token.kind], admitting: among(Array(r.plates.dropFirst()) + r.tokens))
        expectEqual(ruled.nearby.map(\.id), Array(alternating.dropFirst()), "and the rule is asked of each: the first plate isn't admitted")
        expectEqual(r.candidates(kinds: [Jot.kind]), MentionCandidates(), "the text's own shape is a jot, and never nearby")
    },

    test("with kinds, an empty query reads their shapes whole for the nearest and a typed one ranks them alone: the rule is asked of those, never of the board") {
        let h = try mentionHarness()
        let owner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))
        // A big board of plates all around, and three tokens far from the owner (a square grown
        // around it would gather every plate on the way).
        let plates = (0..<400).map { h.editor.add(Plate(CGRect(x: 300 + 150 * ($0 % 20), y: 150 * ($0 / 20), width: 120, height: 80)), titled: "Plate \($0)") }
        let tokens = [h.add(Token(CGRect(x: 9000, y: 9000, width: 60, height: 60), caption: "Far one")),
                      h.add(Token(CGRect(x: 12_000, y: 9000, width: 60, height: 60), caption: "Far two")),
                      h.add(Token(CGRect(x: 15_000, y: 9000, width: 60, height: 60), caption: "Far three"))]
        let state = h.editor.mentionState
        var asked: Set<ShapeID> = []
        let rule: @MainActor (ShapeID) -> Bool = { id in
            asked.insert(id)
            return true
        }
        let near = state.candidates(matching: "", in: AnyMentionable.self, for: owner, kinds: [Token.kind], admitting: rule)
        expectEqual(near.nearby.map(\.id), tokens, "the nearest of the three, however far they are")
        expect(asked.isSubset(of: Set(tokens)), "the rule was asked of the tokens alone: \(asked.count) shapes")
        asked = []
        let typed = state.candidates(matching: "far", in: AnyMentionable.self, for: owner, kinds: [Token.kind], admitting: rule)
        expectEqual(Set(typed.matches.map(\.id)), Set(tokens))
        expect(asked.isSubset(of: Set(tokens)))

        asked = []
        let wide = state.candidates(matching: "", in: AnyMentionable.self, for: owner, admitting: { id in
            asked.insert(id)
            return tokens.contains(id)
        })
        expectEqual(wide.nearby.map(\.id), tokens, "the same rule without kinds finds them too")
        expect(asked.count > 100 && asked.isSuperset(of: Set(plates.prefix(50))), "after asking it of the plates a square grown over the board gathered: \(asked.count)")
    },

    test("a kind's shapes are kept as shapes come, change and go: what the picker lists for them, typed or not, follows each commit, an undo and a file put in place") {
        let h = try mentionHarness()
        let state = h.editor.mentionState
        let owner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))
        let first = h.add(Token(frame(1), caption: "Alpha one"))
        @MainActor func typed() -> [ShapeID] {
            state.candidates(matching: "alpha", in: AnyMentionable.self, for: owner, kinds: [Token.kind]).matches.map(\.id)
        }
        @MainActor func near() -> [ShapeID] {
            state.candidates(matching: "", in: AnyMentionable.self, for: owner, kinds: [Token.kind]).nearby.map(\.id)
        }
        expectEqual(typed(), [first], "the members are made at the first ask")
        expectEqual(near(), [first])
        let second = h.add(Token(frame(2), caption: "Alpha two"))
        expectEqual(typed(), [first, second], "one that came")
        expectEqual(near(), [first, second])
        let plate = h.editor.add(Plate(frame(3)), titled: "Alpha plate")
        expectEqual(typed(), [first, second], "a shape of another kind isn't one")
        h.editor.transact { $0.update(first, as: Token.self) { $0.props.caption = "Beta" } }
        expectEqual(typed(), [second], "renamed away from the query")
        expectEqual(near(), [first, second], "and still a token to list")
        h.editor.transact { $0.update(second, as: Token.self) { $0.props.caption = "" } }
        expectEqual(near(), [first], "a token with no name is no one to pick: out of the catalog, and out of the members")
        h.editor.transact { $0.update(second, as: Token.self) { $0.props.caption = "Alpha again" } }
        expectEqual(typed(), [second], "and back with one")
        h.editor.transact { $0.delete([second]) }
        expectEqual(typed(), [], "one that went")
        expectEqual(near(), [first])
        h.editor.undo()
        expectEqual(typed(), [second], "and came back")
        h.editor.redo()
        expectEqual(typed(), [])
        h.editor.rename(plate, "Alpha plate two")
        expectEqual(state.candidates(matching: "alpha", in: AnyMentionable.self, for: owner, kinds: [Plate.kind]).matches.map(\.id), [plate],
                    "another set of kinds, made at its own first ask, is kept as well")
        expectEqual(typed(), [], "and the first is as it was")

        // A file put in place takes the members afresh.
        let other = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: other, Token(frame(0), caption: "Alpha elsewhere")))]))
        h.editor.replaceFile(with: file)
        expectEqual(state.candidates(matching: "alpha", in: AnyMentionable.self, for: nil, kinds: [Token.kind]).matches.map(\.id), [other])
        expectEqual(state.candidates(matching: "alpha", in: AnyMentionable.self, for: nil, kinds: [Plate.kind]).matches, [])
    },

    test("with kinds, the shapes ranked are the file's: those on another board are members too, their board not shown") {
        let pocket = ShapeID(), owner = ShapeID(), inner = ShapeID()
        let root = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 1200, y: 1200, width: 100, height: 100)))),
                                           AnyShapeRecord(ShapeRecord(id: owner, Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine")))])
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inner, Token(frame(1), caption: "Alpha inside")))])
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]), file: CanvasFile(root: root, children: [pocket: inside]))
        let state = h.editor.mentionState
        @MainActor func found() -> [ShapeID] {
            state.candidates(matching: "alpha", in: AnyMentionable.self, for: owner, kinds: [Token.kind]).matches.map(\.id)
        }
        expectEqual(found(), [inner], "a token on the pocket's board, the root shown")
        let added = ShapeRecord(id: ShapeID(), Token(frame(2), caption: "Alpha too"))
        h.editor.transact(on: BoardID(owner: pocket)) { $0.insert(added) }
        expectEqual(found().count, 2, "one added to the other board")
        h.editor.transact(on: BoardID(owner: pocket)) { $0.delete([inner]) }
        expectEqual(found(), [added.id], "and one taken from it")
        h.editor.transact { $0.delete([pocket]) }
        expectEqual(found(), [], "the board's owner deleted: its shapes go with it")
        h.editor.undo()
        expectEqual(found(), [added.id], "and come back")
    },

    test("kinds and a scope are both asked of each shape: what the scope refuses isn't listed, and the rule isn't asked of it") {
        let h = try mentionHarness()
        let owner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))
        let plate = h.editor.add(Plate(frame(1)), titled: "Alpha plate")
        let token = h.add(Token(frame(2), caption: "Alpha token"))
        let jot = h.add(Jot(frame(3), text: "Alpha jot"))
        let state = h.editor.mentionState
        var asked: Set<ShapeID> = []
        let rule: @MainActor (ShapeID) -> Bool = { id in
            asked.insert(id)
            return true
        }
        // `Blockers` takes plates and tokens, not jots.
        let both = state.candidates(matching: "alpha", in: Blockers.self, for: owner, kinds: [Plate.kind, Jot.kind], admitting: rule)
        expectEqual(both.matches.map(\.id), [plate], "the plate is a plate, and a blocker; the jot is of a kind named, and no blocker")
        expect(!asked.contains(jot) && !asked.contains(token), "the rule is asked of what the kinds and the scope both admit")
        let only = state.candidates(matching: "", in: Only<Plate>.self, for: owner, kinds: [Plate.kind, Token.kind])
        expectEqual(only.nearby.map(\.id), [plate], "a scope of one kind, and kinds of two")
        expectEqual(state.candidates(matching: "alpha", in: Blockers.self, for: owner, kinds: [Jot.kind]).matches, [], "kinds the scope refuses")
    },

    test("the picker lists what its rule admits as the query is typed, and says so when nothing is: Nothing to mention, No matches") {
        let r = try Row()
        @MainActor func picker(_ rule: @escaping @MainActor (ShapeID) -> Bool) -> MentionPicker {
            let picker = MentionPicker(at: 0, mentions: r.state, scope: AnyMentionable.self, owner: r.owner, admitting: rule)
            expectEqual(picker.read("@" as NSString, selection: NSRange(location: 1, length: 0), isEdit: true), nil)
            return picker
        }
        @MainActor func type(_ query: String, in picker: MentionPicker) {
            let text = ("@" + query) as NSString
            expectEqual(picker.read(text, selection: NSRange(location: text.length, length: 0), isEdit: true), nil)
        }
        let nothing = picker(among([]))
        expectEqual(nothing.rows, [.empty("Nothing to mention")])
        expectEqual(nothing.highlighted, nil)
        type("plate", in: nothing)
        expectEqual(nothing.rows, [.empty("No matches")])

        let plates = picker(among(r.plates))
        expectEqual(plates.rows.compactMap(\.candidate?.id), Array(r.plates.prefix(4)))
        expectEqual(plates.rows.first, .header("Nearby"))
        expectEqual(plates.highlighted, 1)
        type("plate 3", in: plates)
        expectEqual(plates.rows.compactMap(\.candidate?.id).first, r.plates[3], "the rule still applies to each query")
        type("token", in: plates)
        expectEqual(plates.rows, [.empty("No matches")], "a token matches, but isn't a plate")
        expectEqual(plates.highlighted, nil)
        type("t", in: plates)
        expectEqual(Set(plates.rows.compactMap(\.candidate?.id)), Set(r.plates))
    },

    test("the picker takes the kinds too: only their shapes, as the query is typed; Nothing to mention when the board has none") {
        let r = try Row()
        @MainActor func picker(_ kinds: Set<ShapeKind>) -> MentionPicker {
            let picker = MentionPicker(at: 0, mentions: r.state, scope: AnyMentionable.self, owner: r.owner, kinds: kinds, admitting: { _ in true })
            expectEqual(picker.read("@" as NSString, selection: NSRange(location: 1, length: 0), isEdit: true), nil)
            return picker
        }
        let tokens = picker([Token.kind])
        expectEqual(tokens.rows.first, .header("Nearby"))
        expectEqual(tokens.rows.compactMap(\.candidate?.id), r.tokens, "all six, nearest first")
        _ = tokens.read("@plate" as NSString, selection: NSRange(location: 6, length: 0), isEdit: true)
        expectEqual(tokens.rows, [.empty("No matches")], "a plate matches, and isn't of the kinds")
        _ = tokens.read("@token 3" as NSString, selection: NSRange(location: 8, length: 0), isEdit: true)
        expectEqual(tokens.rows.compactMap(\.candidate?.id).first, r.tokens[3])
        expectEqual(picker([Endpoint.kind]).rows, [.empty("Nothing to mention")], "no endpoint on the board")
    },

    test("among: a typed query ranks only the given shapes, and the rest of the file is no match") {
        let r = try Row()
        let given = [r.plates[1], r.tokens[3], r.plates[4]]
        let found = r.state.candidates(matching: "t", in: AnyMentionable.self, for: r.owner, among: given).matches.map(\.id)
        expectEqual(Set(found), Set(given), "\"t\" is in every label: the given alone")
        let plain = r.candidates("t").matches.map(\.id)
        expectEqual(found, plain.filter { given.contains($0) }, "ranked as without it, less the rest")
        expectEqual(r.state.candidates(matching: "endpoint", in: AnyMentionable.self, for: r.owner, among: given).matches, [], "what matches but isn't given is no match")
        expectEqual(r.state.candidates(matching: "token 0", in: AnyMentionable.self, for: r.owner, among: [r.plates[0]]).matches, [], "the token itself, not given")
        expectEqual(r.state.candidates(matching: "t", in: AnyMentionable.self, for: r.owner, among: []), MentionCandidates(), "none given, none listed")
        expectEqual(r.state.candidates(matching: "", in: AnyMentionable.self, for: r.owner, among: []), MentionCandidates())
    },

    test("among: an empty query lists the given shapes nearest first, as many as a query lists, and drops what the catalog lacks and the owner") {
        let r = try Row()
        let given = Array(r.plates.reversed()) + r.tokens + [r.owner, ShapeID()]
        let listed = r.state.candidates(matching: "", in: AnyMentionable.self, for: r.owner, among: given)
        expectEqual(listed.nearby.map(\.id), (0..<6).flatMap { [r.plates[$0], r.tokens[$0]] }, "all twelve, nearest first, not the four nearby lists: no owner, no stranger")
        r.state.didPick(r.tokens[5])
        r.state.didPick(r.plates[2])
        let recent = r.state.candidates(matching: "", in: AnyMentionable.self, for: r.owner, among: Array(r.plates)).recent.map(\.id)
        expectEqual(recent, [r.plates[2]], "a recent pick that isn't given isn't listed")
        expectEqual(r.state.candidates(matching: "", in: AnyMentionable.self, for: r.owner, among: [r.plates[0], r.plates[0]]).nearby.map(\.id), [r.plates[0]], "once")
    },

    test("among: an empty query lists on every board, the board shown's nearest first, then the others nearest board first, whatever the rule would reach") {
        let a = ShapeID(), b = ShapeID(), owner = ShapeID()
        let onRoot = ShapeID(), onA = ShapeID(), onB = ShapeID()
        @MainActor func plate(_ id: ShapeID, x: Double) -> AnyShapeRecord {
            var plate = ShapeRecord(id: id, Plate(CGRect(x: x, y: 0, width: 120, height: 80)))
            plate[TitleProperty.self] = "Plate"
            return AnyShapeRecord(plate)
        }
        @MainActor func pocket(_ id: ShapeID, x: Double) -> AnyShapeRecord {
            AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: 1200, width: 100, height: 100))))
        }
        let root = CanvasDocument(shapes: [pocket(a, x: 0), pocket(b, x: 200), plate(onRoot, x: 400)])
        let boardA = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: owner, Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))), plate(onA, x: 300)])
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                                  file: CanvasFile(root: root, children: [a: boardA, b: CanvasDocument(shapes: [plate(onB, x: 0)])]))
        expect(h.editor.showBoard(BoardID(owner: a)))
        let state = h.editor.mentionState
        expectEqual(state.candidates(matching: "", in: AnyMentionable.self, for: owner, among: [onB, onRoot, onA]).nearby.map(\.id), [onA, onRoot, onB],
                    "this board's, the root's one board away, B's two")
        expectEqual(state.candidates(matching: "", in: AnyMentionable.self, for: owner, among: [onB]).nearby.map(\.id), [onB], "a board the owner isn't inside, with nothing typed")
        expectEqual(state.candidates(matching: "plate", in: AnyMentionable.self, for: owner, among: [onB]).matches.map(\.id), [onB])
        // With kinds: the shapes of both.
        expectEqual(state.candidates(matching: "", in: AnyMentionable.self, for: owner, kinds: [Plate.kind], among: [onB, a]).nearby.map(\.id), [onB], "the pocket isn't a plate")
    },

    test("no among is what it was: every other call's answer is the same") {
        let r = try Row()
        r.state.didPick(r.tokens[2])
        for query in ["", "plate", "tok 3", "zzzzq"] {
            expectEqual(r.state.candidates(matching: query, in: AnyMentionable.self, for: r.owner, among: nil), r.candidates(query), "\"\(query)\"")
        }
    },
])
