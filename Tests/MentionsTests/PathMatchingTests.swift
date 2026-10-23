import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import TestKit
import TextEditing
import Titles

// The `@` picker finds a shape by its path: of several words, the ones before the last also name the containers it is
// inside (frames, and the shapes whose boards hold it), as Jump To ranks one. The order is the name's strong matches, then
// the shapes found by their path, then the loose matches of the name; one word ranks as ever; every filter holds for a
// shape found by its path; a longer query narrows a shorter one's only among queries of as many words; and the rows say
// where a shape is. Fixtures only: plates and endpoints named, corrals (they hold shapes, as frames do) and pockets (they
// own boards).

/// Corrals and pockets named by their titles.
@MainActor private var titledContainers: Contributor {
    Contributor(id: "titled-containers") {
        $0.title(Corral.self, contents: false)
        $0.title(Pocket.self, contents: false)
    }
}

@MainActor private func titled<P: ShapeProps>(_ props: P, _ title: String?, in container: ShapeID? = nil, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = ShapeRecord(id: id, props)
    record[TitleProperty.self] = title
    let any = AnyShapeRecord(record)
    return container.map { any.copy(as: id, container: $0) } ?? any
}

private func plate(_ x: Int) -> Plate { Plate(CGRect(x: x * 150, y: 0, width: 120, height: 80)) }
private func corral(_ x: Int) -> Corral { Corral(CGRect(x: x * 150, y: 400, width: 140, height: 140)) }

/// The shapes of a `Shop`.
private struct Shop {
    let alpha = ShapeID(), beta = ShapeID(), gamma = ShapeID(), pocket = ShapeID()
    let inAlpha = ShapeID(), inBeta = ShapeID(), inGamma = ShapeID(), notes = ShapeID(), loose = ShapeID(), endpoint = ShapeID()
    let inPocket = ShapeID()
}

/// Frames Alpha (holding Gamma) and Beta, and the pocket Annex, on the root; a "Checkout" in Alpha, in Beta, in Gamma and on
/// Annex's board; "Alpha checkout notes" on the root; "alp ha check" on the root, which holds the letters of "alpha check"; an
/// Endpoint called "Checkout" (by its path) in Alpha. The jot the text is on, "Plan", is at the origin.
@MainActor private final class Fixture {
    let h: EditorHarness
    let s = Shop()
    let owner = ShapeID()
    var state: MentionState { h.editor.mentionState }

    init(more: (Shop) -> [AnyShapeRecord] = { _ in [] }) throws {
        let root: [AnyShapeRecord] = [
            titled(Jot(CGRect(x: 0, y: -300, width: 200, height: 200)), "Plan", id: owner),
            titled(corral(0), "Alpha", id: s.alpha), titled(corral(1), "Beta", id: s.beta), titled(corral(2), "Gamma", in: s.alpha, id: s.gamma),
            titled(Pocket(CGRect(x: 1200, y: 400, width: 100, height: 100)), "Annex", id: s.pocket),
            titled(plate(0), "Checkout", in: s.alpha, id: s.inAlpha), titled(plate(1), "Checkout", in: s.beta, id: s.inBeta),
            titled(plate(2), "Checkout", in: s.gamma, id: s.inGamma), titled(plate(3), "Alpha checkout notes", id: s.notes),
            titled(plate(4), "alp ha check", id: s.loose),
            titled(Endpoint(CGRect(x: 600, y: 200, width: 100, height: 60), path: "Checkout"), "Route", in: s.alpha, id: s.endpoint),
        ] + more(s)
        h = try EditorHarness(plugins: mentionPlugins([CorralsPlugin(), PocketsPlugin(), titledContainers]),
                              file: CanvasFile(root: CanvasDocument(shapes: root),
                                               children: [s.pocket: CanvasDocument(shapes: [titled(plate(0), "Checkout", id: s.inPocket)])]))
    }

    func candidates<S: MentionScope>(_ query: String, in scope: S.Type = AnyMentionable.self, for owner: ShapeID? = nil, kinds: Set<ShapeKind>? = nil,
                                     among: [ShapeID]? = nil, listingUnnamed: Bool = false,
                                     admitting rule: (@MainActor (ShapeID) -> Bool)? = nil) -> MentionCandidates {
        state.candidates(matching: query, in: scope, for: owner, kinds: kinds, among: among, listingUnnamed: listingUnnamed, admitting: rule)
    }

    func ids(_ query: String, for owner: ShapeID? = nil) -> [ShapeID] { candidates(query, for: owner).matches.map(\.id) }

    /// The lines of the picker for `query` typed after an `@` in the text of the jot.
    func lines(_ query: String) -> [CaretListItem] {
        let picker = MentionPicker(at: 0, mentions: state, scope: AnyMentionable.self, owner: owner)
        let text = "@" + query
        expectEqual(picker.read(text as NSString, selection: NSRange(location: (text as NSString).length, length: 0), isEdit: true), nil)
        return picker.list.rows.compactMap(\.item)
    }
}

@MainActor let pathMatchingTests = Suite("Picker: paths", [
    test("a query of several words is ranked in three bands: the name's strong matches, then the shapes found by their path, then the loose matches of the name") {
        let f = try Fixture(), s = f.s
        f.state.didPick(s.inAlpha)
        f.state.didPick(s.loose)
        // "Alpha checkout notes" has both words at a word's start; the Checkout in Alpha is found by its frame, the one in
        // Gamma by Alpha, skipping Gamma (a little less); "alp ha check" holds the letters only.
        expectEqual(f.ids("alpha check"), [s.notes, s.inAlpha, s.endpoint, s.inGamma, s.loose],
                    "a recent pick is lifted within its band, never across it: the loose one stays last")
        // A path match is the words along the path, in order.
        expectEqual(f.ids("beta check"), [s.inBeta])
        expectEqual(f.ids("check alpha"), [], "in order: the container comes first")
        expectEqual(f.ids("gamma check"), [s.inGamma])
        expectEqual(f.ids("alpha gamma checkout"), [s.inGamma], "any containers on the path, in order, any skipped")
        expectEqual(f.ids("annex check"), [s.inPocket], "the owner of the board a shape is on is a container too")
        // A container is named, not guessed at: a subsequence is no name ("apa" isn't Alpha), so these are only the names'.
        expectEqual(Set(f.ids("apa check")), [s.notes, s.loose])
    },

    test("the order within a band is the picker's: the recent pick, then nearness, as for one word") {
        let f = try Fixture(), s = f.s
        expectEqual(f.ids("alpha check"), [s.notes, s.endpoint, s.inAlpha, s.inGamma, s.loose], "no pick, no owner: the front-most of two alike")
        expectEqual(f.ids("alpha check", for: f.owner), [s.notes, s.inAlpha, s.endpoint, s.inGamma, s.loose], "the text's shape is nearer the first")
        f.state.didPick(s.inGamma)
        expectEqual(f.ids("alpha check"), [s.notes, s.inGamma, s.endpoint, s.inAlpha, s.loose],
                    "a pick is worth more than a skipped frame; the name's band is above both")
    },

    test("a path match carries the characters of its name and of its containers' the words took, and where it is") {
        let f = try Fixture(), s = f.s
        let found = f.candidates("alp che").matches
        let atGamma = try require(found.first { $0.id == s.inGamma })
        expectEqual(atGamma.matched, [0..<3], "of the shape's name")
        expectEqual(atGamma.place?.text, "Alpha › Gamma")
        expectEqual(atGamma.place?.matched, [0..<3], "of the containers': \"alp\" in Alpha")
        let atBeta = try require(f.candidates("bet che").matches.first { $0.id == s.inBeta })
        expectEqual(atBeta.place?.matched, [0..<3])
        let byName = try require(found.first { $0.id == s.notes })
        expectEqual(byName.place, nil, "a shape directly on the board shown is nowhere in particular")
    },

    test("one word ranks as ever, whatever the paths") {
        let f = try Fixture(), s = f.s
        expectEqual(f.ids("checkout"), [s.endpoint, s.inGamma, s.inBeta, s.inAlpha, s.inPocket, s.notes],
                    "the exact names, the front-most first, those on other boards after them; then the word prefix")
        expectEqual(f.ids("alpha"), [s.notes, s.loose], "a frame is no match for what it holds")
        expectEqual(f.candidates("alpha").words, 1)
        expectEqual(f.candidates("alpha ").words, 1, "a trailing space is no word")
        expectEqual(f.candidates("").words, 0)
        expectEqual(f.candidates("alpha check").words, 2)
    },

    test("every filter holds for a shape found by its path") {
        let f = try Fixture(), s = f.s
        expectEqual(f.candidates("alpha check", in: Only<Plate>.self).matches.map(\.id), [s.notes, s.inAlpha, s.inGamma, s.loose], "the scope: plates")
        expectEqual(f.candidates("alpha check", kinds: [Endpoint.kind]).matches.map(\.id), [s.endpoint], "the kinds a command takes")
        expectEqual(f.candidates("alpha check", among: [s.inGamma, s.inBeta, s.inPocket]).matches.map(\.id), [s.inGamma], "the shapes given")
        expectEqual(f.candidates("alpha check", admitting: { $0 != s.inAlpha }).matches.map(\.id), [s.notes, s.endpoint, s.inGamma, s.loose], "the rule")
        // The shape the text is on is left out while its name holds what is typed, whatever its containers.
        let jot = ShapeID()
        let g = try Fixture { s in [titled(Jot(CGRect(x: 900, y: 0, width: 200, height: 200)), "todo @alpha ch", in: s.alpha, id: jot)] }
        expectEqual(g.ids("alpha ch").contains(jot), true, "a path match like any other, from another shape's text")
        expectEqual(g.ids("alpha ch", for: jot).contains(jot), false, "not the shape the text is on")
        expectEqual(g.ids("alpha che", for: jot).contains(jot), true, "once its name no longer holds what's typed (a typo of it)")
    },

    test("a shape its kind gives no name is matched by its placeholder label alone, whatever its containers") {
        let token = ShapeID()
        let f = try Fixture { s in [titled(Token(CGRect(x: 800, y: 0, width: 60, height: 60)), nil, in: s.alpha, id: token)] }
        expectEqual(f.candidates("alpha untitled", among: [token], listingUnnamed: true).matches.map(\.id), [], "Alpha does not name it")
        expectEqual(f.candidates("untitled token", among: [token], listingUnnamed: true).matches.map(\.id), [token], "its label does, as before")
        expectEqual(f.ids("alpha untitled"), [], "unlisted but for a list that asks")
    },

    test("the typo's tier counts as run if either pass ran it") {
        // Eight shapes whose names have both words strongly: the whole query's typo pass doesn't run (it finds enough
        // without), but the last word's does, over the shapes the first didn't list.
        let many = try Fixture { _ in (0..<8).map { titled(plate(10 + $0), "Alpha checkout \($0)") } }
        expectEqual(many.candidates("alpha check").forgave, true)
        // And eight more whose names have the last word alone: neither does.
        let enough = try Fixture { _ in (0..<8).map { titled(plate(10 + $0), "Alpha checkout \($0)") } + (0..<8).map { titled(plate(20 + $0), "Check \($0)") } }
        expectEqual(enough.candidates("alpha check").forgave, false)
        // A typo in the last word is found by its path, and says it forgave.
        let f = try Fixture(), s = f.s
        let typo = f.candidates("alpha chekout")
        expectEqual(typo.forgave, true)
        expect(typo.matches.map(\.id).contains(s.inAlpha), "the typo's tier, along the path")
    },

    test("a longer query is among a shorter one's only with as many words: one word more is another query") {
        let f = try Fixture(), s = f.s
        let one = f.candidates("alpha"), two = f.candidates("alpha c")
        expectEqual(one.words, 1)
        expectEqual(two.words, 2)
        expect(!one.matches.map(\.id).contains(s.inAlpha), "alpha matches no Checkout")
        expect(two.matches.map(\.id).contains(s.inAlpha), "alpha c matches the Checkout in Alpha")
        expectEqual(MentionMatcher.words(in: "  alpha   c "), 2)
        expectEqual(MentionMatcher.words(in: "a b c d e f g h i j"), 8, "the words past the eighth are the eighth's")
        // Among as many words, the longer query's matches are among the shorter one's.
        let longer = Set(f.ids("alpha ch")), shorter = Set(two.matches.map(\.id))
        expect(longer.isSubset(of: shorter))
    },

    test("the rows say where a shape is: its containers' names, outermost first, or nothing for a shape directly on the board shown; spoken with it") {
        let f = try Fixture(), s = f.s
        let rows = f.lines("alp che")
        let byTitle = Dictionary(grouping: rows, by: \.title)
        expectEqual(byTitle["Alpha checkout notes"]?.first?.detail, "Plate", "directly on the board shown: its kind, as ever")
        let checkouts = rows.filter { $0.title == "Checkout" }
        expectEqual(checkouts.map(\.detail), ["Alpha", "Alpha", "Alpha › Gamma"])
        expectEqual(checkouts.last?.detailMatched, [0..<3])
        expectEqual(checkouts.last?.spoken, "Checkout, Plate, in Alpha › Gamma, 5 of 5")
        // Matched in the name of the container it is under, and set apart from one that is not a name.
        let plain = f.lines("beta che")
        expectEqual(plain.map(\.detail), ["Beta"])
        expectEqual(plain.map(\.detailMatched), [[0..<4]])
        _ = s
    },

    test("a container with no title is called by its kind, set fainter; what the board shown is inside is left out; a board's shapes in none say the board") {
        let blank = ShapeID(), inBlank = ShapeID(), onPocket = ShapeID()
        let f = try Fixture { _ in [titled(corral(8), nil, id: blank), titled(plate(8), "Checkout", in: blank, id: inBlank)] }
        let s = f.s
        let kind = f.h.editor.registry.label(of: Corral.kind).name
        let row = try require(f.lines("checkout").first { $0.title == "Checkout" && $0.detail == kind })
        expectEqual(row.detailDimmed, [0..<kind.count])
        // From the pocket's board: the pocket and what holds it are the board's own; a corral there says its name; the root's say the board.
        _ = onPocket
        expect(f.h.editor.showBoard(BoardID(owner: s.pocket)))
        let ring = ShapeID()
        f.h.editor.transact("Put") { $0.insert(titled(corral(3), "Ring", id: ring)); $0.insert(titled(plate(5), "Checkout", in: ring)) }
        let there = f.lines("checkout")
        expect(there.contains { $0.title == "Checkout" && $0.detail == "Ring" }, "inside a corral of the board shown: the corral")
        expect(there.contains { $0.title == "Checkout" && $0.detail == "Plate" }, "directly on the board shown")
        expect(there.contains { $0.title == "Checkout" && $0.detail == "Alpha" }, "a frame on the root: its name")
        expect(there.contains { $0.title == "Alpha checkout notes" && $0.detail == "Board" }, "on the root, in no frame: the board")
    },
])
