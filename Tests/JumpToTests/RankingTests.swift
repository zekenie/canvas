import Canvas
import CanvasTesting
import CoreGraphics
import JumpTo
import Selection
import TestKit
import TextEditing

// What a query lists: the titles alone for a word; for several, the pieces placed in order along a
// shape's path (VS Code's file switcher), over the story file: four Checkouts, in Alpha (12), in
// Alpha › Beta › Gamma (22), in Alpha › Beta › Gamma › Epsilon (31), and in Delta (41).

@MainActor let rankingTests = Suite("Jump To's ranking", [
    test("one word names titles alone: every Checkout, the shallower first, then the file's order; a container isn't listed for what's in it") {
        let h = try storyHarness()
        expectEqual(h.listing("checkout"), ["12", "41", "22", "31"])
        expectEqual(h.listing("alpha"), ["1"], "Alpha, not what's inside it: contents are Find's")
        expectEqual(h.listing("cardamom"), ["51"])
    },
    test("a row's symbol and tint are what the plugin's appearance says, the kind's label's name and symbol otherwise, untinted") {
        let h = try storyHarness()
        let box = try require(h.candidates("plan note one").first)
        expectEqual(box.systemImage, "shippingbox")
        expect(box.tint == boxTint, "the injected tint")
        expectEqual(box.kindName, "box")
        let pocket = try require(h.candidates("alpha").first)
        expectEqual(pocket.systemImage, "square.dashed", "no label symbol, none injected: the placeholder")
        expect(pocket.tint == nil, "nothing injected for a pocket")
        // No appearance given: every row untinted, and the same names.
        let blind = try EditorHarness(plugins: jumpPlugins().map { $0.id == .jumpTo ? JumpToPlugin() : $0 }, file: storyFile())
        let plain = try require(blind.candidates("plan note one").first)
        expect(plain.tint == nil)
        expectEqual(plain.kindName, "box")
    },
    test("several pieces go in order along the path, names skipped as they like, the last in the shape's own title") {
        let h = try storyHarness()
        expectEqual(h.listing("alpha gamma checkout"), ["22", "31"], "one name skipped, then two")
        expectEqual(h.listing("alpha checkout"), ["12", "22", "31"], "none skipped, then the fewer")
        expectEqual(h.listing("beta checkout"), ["22", "31"])
        expectEqual(h.listing("delta check"), ["41"])
        expectEqual(h.listing("gamma epsilon checkout"), ["31"])
        expectEqual(h.listing("epsilon gamma checkout"), ["(No matches)"], "in order: Gamma is outside Epsilon")
        expectEqual(h.listing("delta gamma checkout"), ["(No matches)"], "Delta's Checkout isn't in Gamma")
        expectEqual(h.listing("alpha delta checkout"), ["(No matches)"])
        expectEqual(h.listing("gamma alpha"), ["(No matches)"], "the last piece goes in the shape itself: Alpha's titled Alpha, inside nothing")
    },
    test("two names that don't skip one: the fewer skipped first, whatever the file's order") {
        let h = try storyHarness()
        expectEqual(h.listing("a c"), ["12", "22", "31", "41"], "every Checkout; the one in Alpha has nothing between")
        expectEqual(h.listing("beta gamma checkout"), ["22", "31"])
        let rows = h.candidates("beta gamma checkout")
        expectEqual(rows.map(\.pathText), ["Alpha › Beta › Gamma", "Alpha › Beta › Gamma › Epsilon"])
    },
    test("several pieces may be one title's words: the title that starts with them first") {
        let h = try storyHarness()
        expectEqual(h.listing("plan note"), ["3", "4"], "Plan note one (a prefix) before Planned notes (a word each starts)")
        expectEqual(h.listing("pn").prefix(2), ["3", "4"], "one piece, loosely: its letters in Plan note, Planned notes, and (later) Epsilon")
        let rows = h.candidates("plan note")
        expectEqual(rows[0].titleMatched, [0..<9], "Plan note")
        expectEqual(rows[1].titleMatched, [0..<4, 8..<12], "Plan, note")
    },
    test("the path is built for what's shown: names of the containers, outermost first, the root never one, and what the query matched in each") {
        let h = try storyHarness()
        let rows = h.candidates("alpha gamma checkout")
        expectEqual(rows.map(\.pathText), ["Alpha › Beta › Gamma", "Alpha › Beta › Gamma › Epsilon"])
        expectEqual(rows[0].path.map(\.matched), [[0..<5], [], [0..<5]], "Alpha and Gamma, not Beta, which was skipped")
        expectEqual(rows[0].titleMatched, [0..<8])
        expectEqual(rows[1].path.map(\.matched), [[0..<5], [], [0..<5], []])
        expectEqual(h.candidates("alpha")[0].pathText, "", "a shape on the root has no path")
        expectEqual(h.candidates("beta")[0].pathText, "Alpha")
        _ = h.candidates("alpha gamma checkout")
        let item = try require(h.jump.list.rows[0].item)
        expectEqual(item.title, "Checkout")
        expectEqual(item.detail, "Alpha › Beta › Gamma")
        expectEqual(item.detailMatched, [0..<5, 15..<20], "Alpha, and Gamma after \"Alpha › Beta › \"")
        expectEqual(item.matched, [0..<8])
        expect(item.spoken.hasPrefix("Checkout, "), item.spoken)
        expect(item.spoken.hasSuffix("in Alpha › Beta › Gamma, 1 of 2"), item.spoken)
    },
    test("a container nobody titled is on the path by its kind's name, dimmed, and is never matched") {
        let h = try storyHarness()
        let row = try require(h.candidates("cardamom").first)
        expectEqual(row.path.map(\.text), ["Untitled Pocket"])
        expectEqual(row.path.map(\.isPlaceholder), [true])
        expectEqual(row.pathText, "Untitled Pocket")
        _ = h.candidates("cardamom")
        let item = try require(h.jump.list.rows[0].item)
        expectEqual(item.detailDimmed, [0..<15])
        expectEqual(item.detailMatched, [])
        expectEqual(h.listing("untitled cardamom"), ["(No matches)"], "its placeholder isn't its name: it can't be matched")
        expectEqual(h.listing("pocket cardamom"), ["(No matches)"])
        // Named, it is one.
        h.editor.rename(id(5), "Spices", on: .root)
        expectEqual(h.listing("spices cardamom"), ["51"])
        expectEqual(h.candidates("cardamom")[0].path.map(\.isPlaceholder), [false])
    },
    test("typos: a title with one typo is found, so is a container; a short word is exact") {
        let h = try storyHarness()
        expectEqual(h.listing("chekout"), ["12", "41", "22", "31"])
        expectEqual(h.listing("alpha gama checkout"), ["22", "31"], "Gamma, mistyped")
        expectEqual(h.listing("alpha gamma chekout"), ["22", "31"])
        expectEqual(h.listing("ab c"), ["(No matches)"], "two letters aren't typed with a typo")
    },
    test("a container's name must be a name, never a loose scatter of its letters: a bare subsequence matches only the shape's own title") {
        let h = try storyHarness()
        expectEqual(h.listing("apa checkout"), ["(No matches)"], "\"apa\" is scattered through Alpha")
        expectEqual(h.listing("apha"), ["1"], "the shape's own title may be matched loosely")
    },
    test("ties: shallower, then a recent pick, then the file's order") {
        let h = try storyHarness()
        h.jump.pick(id(41))
        expectEqual(h.listing("checkout"), ["41", "12", "22", "31"], "as deep as 12, which comes first in the file, but picked")
        h.jump.pick(id(31))
        expectEqual(h.listing("checkout"), ["41", "12", "22", "31"], "a pick doesn't beat a shallower path")
        h.jump.pick(id(12))
        expectEqual(h.listing("checkout"), ["12", "41", "22", "31"], "the latest first")
    },
    test("it lists at most fifty, the best") {
        let file = CanvasFile(root: CanvasDocument(shapes: (0..<200).map { shape(1000 + $0, Box(frame(CGFloat($0) * 10, 0)), titled: $0 == 150 ? "item" : "item \($0)") }))
        let h = try storyHarness(file: file)
        let rows = h.listing("item")
        expectEqual(rows.count, 50)
        expectEqual(rows[0], "1150", "the exact title first")
    },
    test("an empty query lists recent picks, then the shapes in view on the board shown nearest its center, each under its header") {
        let h = try storyHarness()
        // The root in a 1000 × 700 view, its center (500, 350): Delta (500, 175) is nearest, then Planned notes (200, 475),
        // Plan note one (800, 175) and Alpha (190, 175). The untitled pocket and box aren't listed, and the box far off isn't in view.
        expectEqual(h.listing(""), ["# Nearby", "2", "4", "3", "1"])
        h.jump.pick(id(41))
        h.openJumpTo()
        h.editor.goBack()
        h.openJumpTo()
        expectEqual(h.listing(""), ["# Recent", "41", "# Nearby", "2", "4", "3", "1"])
        h.jump.setQuery("")
        h.jump.pick(id(2))
        h.editor.goBack()
        h.wait(500)
        expectEqual(h.listing(""), ["# Recent", "2", "41", "# Nearby", "4", "3", "1"], "a shape isn't listed twice: Delta, recent, isn't nearby")
    },
    test("an empty query lists at most five recent picks and five nearby, looking only around the view's middle; with no view, nothing is nearby") {
        let file = CanvasFile(root: CanvasDocument(shapes: (0..<12).map { shape(1000 + $0, Box(frame(CGFloat($0) * 60, 300)), titled: "Box \($0)") }))
        let h = try storyHarness(file: file)
        // The middle of the view is (500, 350): the boxes' centers are 50 + 60n, nearest n = 7, 8, 6, 9, 5 (distances 30, 30...).
        let nearby = h.listing("").dropFirst().map { Int($0)! - 1000 }
        expectEqual(nearby.count, 5)
        expectEqual(Set(nearby), [5, 6, 7, 8, 9])
        for n in 0..<8 { h.jump.pick(id(1000 + n)); h.openJumpTo() }
        let rows = h.listing("")
        expectEqual(rows.prefix(6).map { $0 }, ["# Recent", "1007", "1006", "1005", "1004", "1003"])
        let blind = try EditorHarness(plugins: jumpPlugins(), file: file)
        expectEqual(blind.listing(""), ["(Nothing to jump to)"], "no view yet: nothing is in view")
    },
    test("what Nearby looks at is the board shown: its shapes, nearest the middle of the view as the camera left it") {
        let h = try storyHarness()
        expect(h.enter(id(1)))
        h.wait(500)
        let alpha = h.listing("")
        expectEqual(alpha.first, "# Nearby")
        expectEqual(Set(alpha.dropFirst()), ["11", "12"])
        expect(h.enter(id(11)))
        h.wait(500)
        // The corral fills the view's middle; the shapes it holds are around it.
        expectEqual(h.listing(""), ["# Nearby", "21", "23", "22"])
    },
])
