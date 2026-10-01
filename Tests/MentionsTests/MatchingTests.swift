import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import TestKit

// Fuzzy matching (Amendment 1's tiers) and what the picker lists: ranking, Recent and Nearby,
// caps and exclusions.

private func plateFrame(_ i: Int) -> CGRect { CGRect(x: i * 150, y: 0, width: 120, height: 80) }

@MainActor let matchingTests = Suite("Matching", [
    test("each tier: exact, prefix, word prefixes, substring, subsequence, typo, with the characters matched") {
        let label = "Grocery List"
        func match(_ query: String) -> MentionMatch? { MentionMatcher.match(query, in: label) }
        expectEqual(match("grocery list"), MentionMatch(score: 1000, matched: [0..<12]))
        expectEqual(match("  GROCERY   list "), MentionMatch(score: 1000, matched: [0..<12]), "case and spaces")
        expectEqual(match("groc"), MentionMatch(score: 800, matched: [0..<4]))
        expectEqual(match("gro li"), MentionMatch(score: 600, matched: [0..<3, 8..<10]))
        expectEqual(match("list"), MentionMatch(score: 600, matched: [8..<12]))
        expectEqual(match("cery"), MentionMatch(score: 400, matched: [3..<7]))
        let grcy = try require(match("grcy"))
        expect(grcy.score > 100 && grcy.score <= 300, "\(grcy.score)")
        expectEqual(grcy.matched, [0..<2, 3..<4, 6..<7])
        let gl = try require(match("gl"))
        expect(gl.score > 100 && gl.score <= 300, "\(gl.score)")
        expectEqual(gl.matched, [0..<1, 8..<9])
        expect(try require(match("grlist")).score <= 300)
        // A letter left out is a subsequence already; the typos are what isn't.
        expect(try require(match("grocey")).score > 100)
        expect(try require(match("grocry")).score > 100)
        expectEqual(match("grocexy"), MentionMatch(score: 100, matched: [0..<7]), "a letter changed")
        expectEqual(match("gorcery"), MentionMatch(score: 100, matched: [0..<7]), "two swapped")
        expectEqual(match("grocerry"), MentionMatch(score: 100, matched: [0..<7]), "a letter added")
        expectEqual(match("lsit"), MentionMatch(score: 100, matched: [8..<12]), "at a later word's start")
        expectEqual(match("grx"), nil, "no typo for a query under four characters")
        expectEqual(match("gorcey"), nil, "two typos")
        expectEqual(match("zebra"), nil)
        expectEqual(match(""), nil)
        expectEqual(match("   "), nil)
    },

    test("a subsequence scores more at word starts and in runs, and never reaches a substring's tier") {
        let starts = try require(MentionMatcher.match("gl", in: "Grocery List")).score
        let inside = try require(MentionMatcher.match("gl", in: "Bagel")).score
        expect(starts > inside, "\(starts) vs \(inside)")
        let run = try require(MentionMatcher.match("abd", in: "xabcd")).score
        let gap = try require(MentionMatcher.match("abd", in: "xaxbxxd")).score
        expect(run > gap, "\(run) vs \(gap)")
        for (query, label) in [("abc", "a b c"), ("gl", "Grocery List"), ("xyzw", "x y z w and more")] {
            let score = try require(MentionMatcher.match(query, in: label), "\(query) in \(label)").score
            expect(score <= MentionRanking.subsequence && score > MentionRanking.typo)
        }
    },

    test("case and diacritics are ignored; matched ranges count characters, emoji and all") {
        expectEqual(MentionMatcher.match("cafe", in: "Café")?.score, 1000)
        expectEqual(MentionMatcher.match("CAFÉ", in: "cafe")?.score, 1000)
        expectEqual(MentionMatcher.match("naive", in: "Naïve plan")?.score, 800)
        expectEqual(MentionMatcher.match("plan", in: "👍🏽 Plan"), MentionMatch(score: 600, matched: [2..<6]))
        expectEqual(MentionMatcher.match("über", in: "Das Überlied")?.matched, [4..<8])
        expectEqual(MentionMatcher.match("q3-p", in: "Q3-plan review")?.score, 800)
        expectEqual(MentionMatcher.match("plan", in: "Q3-plan review")?.score, 600, "a word after punctuation")
    },

    test("a subsequence never outranks a prefix, whatever the adjustments") {
        // Every tier's floor and ceiling, with the largest bonuses a subsequence could get.
        let subsequenceBest = MentionRanking.subsequence + MentionRanking.recentBonus + MentionRanking.nearnessBonus
        expect(subsequenceBest < MentionRanking.prefix)
        let h = try mentionHarness()
        let owner = h.editor.add(Plate(plateFrame(0)), titled: "Owner")
        let prefix = h.add(Token(plateFrame(20), caption: "Unto the hills"))  // far away
        let subsequence = h.add(Token(plateFrame(1), caption: "Under a nice tree"))  // right beside the owner
        let state = h.editor.mentionState
        state.didPick(subsequence)
        let listed = state.candidates(matching: "unt", in: AnyMentionable.self, for: owner).matches.map(\.id)
        expectEqual(listed, [prefix, subsequence])
    },

    test("one ranked list: tiers first, then shorter labels, then the front-most shape") {
        let h = try mentionHarness()
        let longer = h.editor.add(Plate(plateFrame(0)), titled: "Grocery list for the week")
        let exact = h.editor.add(Plate(plateFrame(1)), titled: "Grocery")
        let substring = h.editor.add(Plate(plateFrame(2)), titled: "Supergrocery run")
        let back = h.editor.add(Plate(plateFrame(3)), titled: "Grocery list")
        let front = h.editor.add(Plate(plateFrame(4)), titled: "Grocery list")
        let subsequence = h.editor.add(Plate(plateFrame(5)), titled: "Gear, rope, oars, crampons")
        let words = h.editor.add(Plate(plateFrame(6)), titled: "Old Grocery notes")
        _ = h.add(Box(plateFrame(7)))
        let listed = h.editor.mentionState.candidates(matching: "grocery", in: AnyMentionable.self, for: nil).matches.map(\.id)
        expectEqual(listed, [exact, front, back, longer, words, substring])
        let fuzzy = h.editor.mentionState.candidates(matching: "grcy", in: AnyMentionable.self, for: nil).matches.map(\.id)
        expect(fuzzy.contains(subsequence) == false, "no y after its r, c")
        expectEqual(fuzzy.first, exact)
    },

    test("the typo pass runs only when the other tiers found fewer than eight") {
        let h = try mentionHarness()
        let target = h.editor.add(Plate(plateFrame(0)), titled: "Grocery List")
        let state = h.editor.mentionState
        let exact = (1...7).map { h.editor.add(Plate(plateFrame($0)), titled: "Grocexy \($0)") }
        var listed = state.candidates(matching: "grocexy", in: AnyMentionable.self, for: nil).matches.map(\.id)
        expectEqual(Set(listed), Set(exact + [target]))
        expectEqual(listed.last, target, "a typo ranks last")
        _ = h.editor.add(Plate(plateFrame(8)), titled: "Grocexy 8")
        listed = state.candidates(matching: "grocexy", in: AnyMentionable.self, for: nil).matches.map(\.id)
        expectEqual(listed.count, 8)
        expect(!listed.contains(target))
    },

    test("at most 50 matches, however many match") {
        let h = try mentionHarness()
        for i in 0..<120 { h.editor.add(Plate(plateFrame(i)), titled: "Item \(i)") }
        let candidates = h.editor.mentionState.candidates(matching: "item", in: AnyMentionable.self, for: nil)
        expectEqual(candidates.matches.count, 50)
        expectEqual(candidates.recent, [])
        expectEqual(candidates.nearby, [])
        expectEqual(candidates.matches.first?.appearance.label, "Item 9", "shorter labels first, then the front-most")
    },

    test("a shape its kind gives no name, called by the \"Untitled …\" placeholder, isn't listed until it has one; a mention of it stays live") {
        let h = try mentionHarness()
        let owner = h.editor.add(Plate(plateFrame(0)), titled: "Owner")
        let token = h.add(Token(plateFrame(1)))                              // "Untitled Token"
        let state = h.editor.mentionState
        expectEqual(state.resolve(token).appearance?.isPlaceholder, true)
        expectEqual(state.candidates(matching: "untitled", in: AnyMentionable.self, for: owner).matches.map(\.id), [])
        expect(!state.candidates(matching: "", in: AnyMentionable.self, for: owner).all.map(\.id).contains(token), "nor nearby")
        h.editor.transact { $0.update(token, as: Token.self) { $0.props.caption = "Milk" } }
        expectEqual(state.candidates(matching: "milk", in: AnyMentionable.self, for: owner).matches.map(\.id), [token])
        expect(state.candidates(matching: "", in: AnyMentionable.self, for: owner).nearby.map(\.id).contains(token))
        h.editor.transact { $0.update(token, as: Token.self) { $0.props.caption = "" } }
        expectEqual(state.candidates(matching: "milk", in: AnyMentionable.self, for: owner).matches.map(\.id), [], "out again once it has none")
        expect(state.resolve(token).isLive, "a mention of it shows it, by the placeholder")
    },

    test("the text's own shape can be listed (not nearby, nor while its name holds what's typed), never a shape kept aside or one that can't be mentioned") {
        let h = try mentionHarness()
        let owner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Alpha jot"))
        let plate = h.editor.add(Plate(plateFrame(3)), titled: "Alpha plate")
        _ = h.add(Box(plateFrame(4)))
        append([try keptAside(Plate.kind, id: idC, in: h.editor.registry)], to: h.editor)
        let state = h.editor.mentionState
        expectEqual(Set(state.candidates(matching: "alpha", in: AnyMentionable.self, for: owner).matches.map(\.id)), [owner, plate],
                    "the text's own shape too, named by its text")
        expectEqual(state.candidates(matching: "alpha j", in: AnyMentionable.self, for: owner).matches.first?.id, owner)
        h.editor.transact { $0.update(owner, as: Jot.self) { $0.props.text = "Alpha jot @alpha" } }
        expectEqual(state.candidates(matching: "alpha", in: AnyMentionable.self, for: owner).matches.map(\.id), [plate],
                    "not while its name holds the @alpha being typed")
        h.editor.transact { $0.update(owner, as: Jot.self) { $0.props.text = "Alpha jot" } }
        expectEqual(Set(state.candidates(matching: "alpha", in: AnyMentionable.self, for: nil).matches.map(\.id)), [owner, plate])
        expectEqual(Set(state.candidates(matching: "untitled", in: AnyMentionable.self, for: nil).matches.map(\.id)), [])
        let empty = state.candidates(matching: "", in: AnyMentionable.self, for: owner)
        expectEqual(empty.nearby.map(\.id), [plate])
    },

    test("an empty query: up to four recent picks, then up to four of the nearest other shapes") {
        let h = try mentionHarness()
        let owner = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: "Mine"))
        let plates = (1...8).map { h.editor.add(Plate(plateFrame($0)), titled: "Plate \($0)") }
        let state = h.editor.mentionState
        var empty = state.candidates(matching: "", in: AnyMentionable.self, for: owner)
        expectEqual(empty.recent, [])
        expectEqual(empty.nearby.map(\.id), Array(plates.prefix(4)), "nearest first")
        expectEqual(empty.matches, [])
        state.didPick(plates[0])
        state.didPick(plates[6])
        state.didPick(owner)
        empty = state.candidates(matching: "", in: AnyMentionable.self, for: owner)
        expectEqual(empty.recent.map(\.id), [owner, plates[6], plates[0]], "the latest first, the owner's own pick too")
        expectEqual(empty.nearby.map(\.id), [plates[1], plates[2], plates[3], plates[4]], "not what's recent")
        expectEqual(state.candidates(matching: "", in: AnyMentionable.self, for: nil).nearby, [], "no owner, nothing is near")
        expectEqual(empty.all.count, 7)
    },

    test("a candidate says how its shape shows, whether it's read-only, and what matched") {
        let h = try mentionHarness([FreezingPlugin()])
        let plate = h.editor.add(Plate(plateFrame(0)), titled: "Frozen plate")
        h.editor.freeze([plate])
        let candidate = try require(h.editor.mentionState.candidates(matching: "frz", in: AnyMentionable.self, for: nil).matches.first)
        expectEqual(candidate.id, plate)
        expect(candidate.isReadOnly)
        expectEqual(candidate.appearance.label, "Frozen plate")
        expectEqual(candidate.matched, [0..<2, 3..<4])
    },

    test("the catalog follows the board: a rename is found by its new name, a deleted shape isn't found, one whose deletion is undone is, and a rename undone is found by its old name") {
        let h = try mentionHarness()
        let plate = h.editor.add(Plate(plateFrame(0)), titled: "Groceries")
        let state = h.editor.mentionState
        @MainActor func found(_ query: String) -> [ShapeID] { state.candidates(matching: query, in: AnyMentionable.self, for: nil).matches.map(\.id) }
        expectEqual(found("groc"), [plate])
        h.editor.rename(plate, "Food")
        expectEqual(found("groc"), [])
        expectEqual(found("food"), [plate])
        h.editor.delete(plate)
        expectEqual(found("food"), [])
        h.editor.undo()
        expectEqual(found("food"), [plate])
        h.editor.undo()
        expectEqual(found("food"), [])
        expectEqual(found("groc"), [plate])
        h.editor.redo()
        expectEqual(found("food"), [plate])
        #if DEBUG
        let read = state.entriesRead
        h.editor.transact { $0.translate([plate], by: CGPoint(x: 40, y: 0)) }
        _ = found("food")
        expectEqual(state.entriesRead, read, "a drag makes nothing stale")
        h.editor.rename(plate, "Supplies")
        h.editor.rename(plate, "Stock")
        _ = found("stock")
        expectEqual(state.entriesRead, read + 1, "read again once, at the next query")
        #endif
    },
])
