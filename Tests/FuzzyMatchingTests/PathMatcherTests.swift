import FuzzyMatching
import TestKit

// Jump To's matcher: a query's pieces placed along a path, one group of neighbors to a segment, the
// last to the leaf; the score's formula; and the rows a caller memoizes per container, against the
// one path's match, on seeded random trees.

private let skip = PathRanking.skipPenalty, leafWeight = PathRanking.leafWeight

@MainActor let pathMatcherTests = Suite("Path matcher", [
    // MARK: Placing pieces

    test("pieces name segments in order, and a segment between may be skipped") {
        let match = try require(PathMatcher("alpha gamma checkout").match(path: ["Alpha", "Beta", "Gamma", "Checkout"]))
        expectEqual(match.matched, [[0..<5], [], [0..<5], [0..<8]])
        expectEqual(match.skipped, 1)
        expectEqual(match.score, leafWeight * FuzzyRanking.exact + 2 * FuzzyRanking.exact - skip)
        expectEqual(PathMatcher("gamma alpha").match(path: ["Alpha", "Beta", "Gamma"]), nil, "in order")
        expectEqual(PathMatcher("alpha alpha").match(path: ["Alpha", "Alpha"])?.matched, [[0..<5], [0..<5]])
        expectEqual(PathMatcher("alpha alpha").match(path: ["Alpha"]), nil, "one segment can't hold a piece twice over")
    },

    test("splitting dots: a dot before a letter splits a piece, as `orders.cust` is `orders cust`; any other dot stays, and none splits without it") {
        expectEqual(PathMatcher("orders.cust", splittingDots: true).pieces, ["orders", "cust"])
        expectEqual(PathMatcher("shop orders.cust", splittingDots: true).pieces, ["shop", "orders", "cust"])
        expectEqual(PathMatcher("v1.2 orders.", splittingDots: true).pieces, ["v1.2", "orders."], "a digit after it, or nothing")
        expectEqual(PathMatcher(".cust", splittingDots: true).pieces, [".cust"], "nothing before it")
        expectEqual(PathMatcher("orders.cust").pieces, ["orders.cust"])
        let match = try require(PathMatcher("orders.cust", splittingDots: true).match(path: ["orders", "customer_id"]))
        expectEqual(match.matched, [[0..<6], [0..<4]])
    },

    test("what's above the first piece isn't skipped, only unmentioned") {
        let match = try require(PathMatcher("beta gamma").match(path: ["Root", "Alpha", "Beta", "Gamma"]))
        expectEqual(match.matched, [[], [], [0..<4], [0..<5]])
        expectEqual(match.skipped, 0)
        expectEqual(match.score, leafWeight * FuzzyRanking.exact + FuzzyRanking.exact)
    },

    test("several pieces may be one segment's: a group matched as one query") {
        let two = try require(PathMatcher("alpha gamma checkout").match(path: ["Alpha Gamma", "Checkout"]))
        expectEqual(two.matched, [[0..<11], [0..<8]], "the whole label: exact")
        expectEqual(two.skipped, 0)
        let wordPrefixes = try require(PathMatcher("al ga checkout").match(path: ["Alpha Beta Gamma", "Checkout"]))
        expectEqual(wordPrefixes.matched, [[0..<2, 11..<13], [0..<8]], "each piece starts a word of the label, in order")
        let all = try require(PathMatcher("gamma check").match(path: ["Alpha", "Gamma Checkout"]))
        expectEqual(all.matched, [[], [0..<11]], "all in the leaf: as one query, a prefix of it")
        expectEqual(all.skipped, 0)
    },

    test("the last piece is in the leaf") {
        expectEqual(PathMatcher("alpha beta").match(path: ["Alpha Beta", "Gamma"]), nil, "both pieces name the container, none the leaf")
        let match = try require(PathMatcher("alpha beta").match(path: ["Alpha", "Beta"]))
        expectEqual(match.matched, [[0..<5], [0..<4]])
        expectEqual(PathMatcher("alpha").match(path: ["Alpha", "Beta"]), nil, "one piece is the leaf's alone")
        expectEqual(PathMatcher("beta").match(path: ["Alpha", "Beta"])?.matched, [[], [0..<4]])
    },

    test("an ancestor is matched by the exact, prefix, word-prefix, substring and typo tiers, the leaf by any") {
        // `ac` is `Alpha Checkout` only as a bare subsequence.
        expectEqual(PathMatcher("ac check").match(path: ["Alpha Checkout", "Check"]), nil)
        expect(PathMatcher("zz ac").match(path: ["zz", "Alpha Checkout"]) != nil, "but it is for the leaf")
        let tiers: [(String, String)] = [("alpha", "Alpha"), ("alp", "Alpha"), ("al ch", "Alpha Checkout"), ("heck", "Alpha Checkout"),
                                         ("alhpa", "Alpha")]
        for (piece, label) in tiers {
            expect(PathMatcher("\(piece) leaf").match(path: [label, "Leaf"]) != nil, "\(piece) in \(label)")
        }
        // A query that's a subsequence of a label and a typo of one of its words: the typo's tier.
        let scored = try require(PathMatcher("grocry list").match(path: ["Grocery", "List"]))
        expectEqual(scored.matched[0], [0..<7])
    },

    test("a single piece is the leaf's alone") {
        let one = PathMatcher("check")
        expectEqual(one.pieceCount, 1)
        expectEqual(one.rootRow.best, [0])
        let match = try require(one.match(path: ["Alpha", "Check"]))
        expectEqual(match.score, leafWeight * FuzzyRanking.exact)
        expectEqual(match.matched, [[], [0..<5]])
        expectEqual(match.skipped, 0)
        expectEqual(one.advance(one.rootRow, through: FuzzyMatcher.Label("Anything")), one.rootRow)
        expectEqual(one.leafScore(after: one.rootRow, label: FuzzyMatcher.Label("Check")), leafWeight * FuzzyRanking.exact)
        expectEqual(one.leafScore(after: one.rootRow, label: FuzzyMatcher.Label("Zebra")), nil)
    },

    test("an empty query, an empty path, and a long query") {
        expect(PathMatcher("").isEmpty)
        expectEqual(PathMatcher("  ").match(path: ["A"]), nil)
        expectEqual(PathMatcher("a").match(path: []), nil)
        expectEqual(PathMatcher("a").leafScore(after: PathMatcher("a").rootRow, label: FuzzyMatcher.Label("a")), leafWeight * FuzzyRanking.exact)
        let long = PathMatcher("a b c d e f g h i j k")
        expectEqual(long.pieceCount, PathRanking.maximumPieces)
        expectEqual(long.pieces.last, "h i j k", "the words after the last piece are its")
    },

    // MARK: Ranking

    test("a small story: alpha gamma check") {
        let paths: [(String, [String])] = [
            ("deep, exact leaf", ["Alpha", "Beta", "Gamma", "Check"]),
            ("direct, leaf prefix", ["Alpha", "Gamma", "Checkout"]),
            ("a skip, leaf prefix", ["Alpha", "Beta", "Gamma", "Checkout"]),
            ("a prefix ancestor", ["Alpha", "Gamma Ray", "Check Out"]),
            ("two pieces in one segment", ["Alpha Gamma", "Checkout"]),
            ("no alpha", ["Gamma", "Checkout"]),
            ("no gamma", ["Alpha", "Checkout Flow"]),
            ("leaf a typo's tier", ["Alpha", "Gamma", "Chec"]),
        ]
        let query = PathMatcher("alpha gamma check")
        let scores = paths.map { query.match(path: $0.1)?.score }
        let exact = FuzzyRanking.exact, prefix = FuzzyRanking.prefix
        expectEqual(scores[0], leafWeight * exact + 2 * exact - skip)
        expectEqual(scores[1], leafWeight * prefix + 2 * exact)
        expectEqual(scores[2], leafWeight * prefix + 2 * exact - skip)
        expectEqual(scores[3], leafWeight * prefix + exact + prefix)
        expectEqual(scores[4], leafWeight * prefix + exact)
        expectEqual(scores[5], nil)
        expectEqual(scores[6], nil)
        expectEqual(scores[7], leafWeight * FuzzyRanking.typo + 2 * exact, "`check` is `chec` with a letter added")
        let ranked = paths.indices.filter { scores[$0] != nil }.sorted { scores[$0]! > scores[$1]! }
        expectEqual(ranked, [0, 1, 2, 3, 4, 7])
    },

    test("skipping costs less than a tier, so better tiers win, and a path without skips beats one with") {
        expect(PathRanking.skipPenalty < 100)
        let query = PathMatcher("a b c")
        let direct = try require(query.match(path: ["A", "B", "C"]))
        let skipped = try require(query.match(path: ["A", "x", "B", "C"]))
        let twice = try require(query.match(path: ["A", "x", "y", "B", "C"]))
        expect(direct.score > skipped.score && skipped.score > twice.score)
        expectEqual(direct.score - skipped.score, skip)
        expectEqual(twice.skipped, 2)
        // A segment after the leaf's container is never in the way, and an untitled one costs a skip.
        let untitled = try require(query.match(path: ["A", "", "B", "C"]))
        expectEqual(untitled.score, skipped.score)
        expectEqual(untitled.matched[1], [])
    },

    test("matched ranges convert to UTF-16 offsets") {
        expectEqual(PathMatcher.utf16Ranges([1..<3], in: "a🙂b"), [1..<4])
        expectEqual(PathMatcher.utf16Ranges([0..<1, 2..<3], in: "e\u{301}xé"), [0..<2, 3..<4])
        expectEqual(PathMatcher.utf16Ranges([], in: "abc"), [])
        expectEqual(PathMatcher.utf16Ranges([2..<9], in: "abc"), [], "out of range is left out")
        let match = try require(PathMatcher("cafe noir").match(path: ["Café", "Noir"]))
        expectEqual(PathMatcher.utf16Ranges(match.matched[0], in: "Café"), [0..<4])
    },

    // MARK: Rows

    test("a container's row is its parent's, advanced; an untitled one is a skip") {
        let query = PathMatcher("alpha gamma checkout")
        let root = query.rootRow
        expectEqual(root.best, [0, PathMatcher.Row.unreachable, PathMatcher.Row.unreachable])
        let alpha = query.advance(root, through: FuzzyMatcher.Label("Alpha"))
        expectEqual(alpha.best, [0, FuzzyRanking.exact, PathMatcher.Row.unreachable], "alpha placed; nothing yet for two pieces")
        let beta = query.advance(alpha, through: FuzzyMatcher.Label("Beta"))
        expectEqual(beta.best, [0, FuzzyRanking.exact - skip, PathMatcher.Row.unreachable], "a skip once a piece is placed")
        let untitled = query.advance(alpha, through: nil)
        expectEqual(untitled, beta)
        let gamma = query.advance(beta, through: FuzzyMatcher.Label("Gamma"))
        expectEqual(gamma.best[2], 2 * FuzzyRanking.exact - skip)
        expectEqual(gamma.best[1], FuzzyRanking.exact - 2 * skip, "gamma isn't a word of alpha's piece, so it's skipped, as was beta")
        expectEqual(query.leafScore(after: gamma, label: FuzzyMatcher.Label("Checkout")), leafWeight * FuzzyRanking.exact + 2 * FuzzyRanking.exact - skip)
        expectEqual(query.leafScore(after: gamma, label: FuzzyMatcher.Label("Zebra")), nil)
        // The first container may be the first to take a piece, and nothing above it is skipped.
        let first = query.advance(root, through: FuzzyMatcher.Label("Gamma"))
        expectEqual(first.best[0], 0)
        expectEqual(first.best[1], PathMatcher.Row.unreachable, "alpha, the first piece, isn't gamma")
    },

    test("placingAtLeast keeps only the placements that put pieces in the containers: a shape found by its path, not its title alone") {
        let query = PathMatcher("alpha checkout")
        let alpha = query.advance(query.rootRow, through: FuzzyMatcher.Label("Alpha"))
        let checkout = FuzzyMatcher.Label("Checkout"), both = FuzzyMatcher.Label("Alpha Checkout")
        expectEqual(query.leafScore(after: alpha, label: checkout, placingAtLeast: 1), leafWeight * FuzzyRanking.exact + FuzzyRanking.exact)
        expectEqual(query.leafScore(after: query.rootRow, label: both), leafWeight * FuzzyRanking.exact, "a title that holds every piece, on the root")
        expectEqual(query.leafScore(after: query.rootRow, label: both, placingAtLeast: 1), nil, "has no container to put one in")
        expectEqual(query.leafScore(after: alpha, label: both, placingAtLeast: 1) != nil, true, "the last piece alone, found in a longer title")
        expectEqual(query.leafScore(after: alpha, label: checkout, placingAtLeast: 2), nil, "the leaf always takes the last piece")
        expectEqual(query.match(path: ["Alpha", "Checkout"], placingAtLeast: 1)?.matched, [[0..<5], [0..<8]])
        expectEqual(query.match(path: ["Beta", "Alpha Checkout"], placingAtLeast: 1), nil)
        expectEqual(query.match(path: ["Beta", "Alpha Checkout"])?.matched.last, [0..<14])
    },

    test("rows and match(path:) over seeded random trees agree with a brute force over every placement") {
        var random = SplitMix(seed: 20_261_006)
        let vocabulary = ["Alpha", "Beta", "Gamma", "Checkout", "Delta Flow", "Orders", "Alpha Gamma", "Check Out Flow", "Gamma Ray", "Zeta"]
        let fragments = ["al", "alp", "ga", "gamm", "check", "chekc", "ord", "del", "fl", "z", "be", "beta", "orders", "alhpa", "xx"]
        struct Node {
            var label: String
            var parent: Int?
            var isContainer: Bool
        }
        var checked = 0, matches = 0, withSkips = 0, withGroups = 0
        for tree in 0..<60 {
            var nodes: [Node] = []
            func grow(parent: Int?, depth: Int) {
                for _ in 0..<Int.random(in: 1...3, using: &random) {
                    let container = depth < 4 && Int.random(in: 0..<3, using: &random) > 0
                    let untitled = Int.random(in: 0..<6, using: &random) == 0
                    nodes.append(Node(label: untitled ? "" : vocabulary.randomElement(using: &random)!, parent: parent, isContainer: container))
                    if container { grow(parent: nodes.count - 1, depth: depth + 1) }
                }
            }
            grow(parent: nil, depth: 0)
            for _ in 0..<6 {
                let pieces = (0..<Int.random(in: 1...4, using: &random)).map { _ in fragments.randomElement(using: &random)! }
                let query = PathMatcher(pieces.joined(separator: " "))
                // One row per container, once.
                var rows: [Int: PathMatcher.Row] = [:]
                func row(of index: Int?) -> PathMatcher.Row {
                    guard let index else { return query.rootRow }
                    if let known = rows[index] { return known }
                    let label = nodes[index].label.isEmpty ? nil : FuzzyMatcher.Label(nodes[index].label)
                    let made = query.advance(row(of: nodes[index].parent), through: label)
                    rows[index] = made
                    return made
                }
                for node in nodes {
                    var path = [node.label], at = node.parent
                    while let parent = at {
                        path.insert(nodes[parent].label, at: 0)
                        at = nodes[parent].parent
                    }
                    let reference = bruteForce(pieces, path)
                    let context = "tree \(tree), \(path) for \(pieces)"
                    expectEqual(query.leafScore(after: row(of: node.parent), label: FuzzyMatcher.Label(node.label)), reference?.score, context)
                    let match = query.match(path: path)
                    expectEqual(match?.score, reference?.score, context)
                    if let match, let reference {
                        expect(reference.placements.contains { $0.matched == match.matched && $0.skipped == match.skipped },
                               "\(context): ranges \(match.matched), skipped \(match.skipped), not one of the best placements \(reference.placements)")
                        if match.skipped > 0 { withSkips += 1 }
                        if match.matched.dropLast().contains(where: { !$0.isEmpty }) { withGroups += 1 }
                    }
                    checked += 1
                    if reference != nil { matches += 1 }
                }
            }
        }
        expect(checked > 1000 && matches > 100, "checked \(checked), matched \(matches): the trees and queries should meet")
        expect(withSkips > 20 && withGroups > 50, "skips \(withSkips), ancestors named \(withGroups): the matches should vary")
    },
])

// MARK: The brute force

/// Every way to place a query's pieces along a path, scored by the stated formula, written the
/// plain way: each container takes no pieces or the next few, the leaf takes the rest (at least
/// the last piece), a group scored as one query in the label (an ancestor's never a bare
/// subsequence), a container with no group, after the first to have one, a skip. The best score,
/// and what each placement that gets it shows (ranges, skips); nil if no placement works.
private func bruteForce(_ pieces: [String], _ path: [String]) -> (score: Int, placements: [(matched: [[Range<Int>]], skipped: Int)])? {
    guard let leaf = path.last, !pieces.isEmpty else { return nil }
    let ancestors = Array(path.dropLast())
    let k = pieces.count
    var best: Int?
    var placements: [(matched: [[Range<Int>]], skipped: Int)] = []
    /// `taken[i]`: how many pieces container `i` takes.
    func consider(_ taken: [Int]) {
        var a = 0, score = 0, matched = [[Range<Int>]](repeating: [], count: path.count), skipped = 0, started = false
        for (i, count) in taken.enumerated() {
            if count == 0 {
                if started { score -= PathRanking.skipPenalty; skipped += 1 }
                continue
            }
            started = true
            let query = FuzzyMatcher.Query(pieces[a..<(a + count)].joined(separator: " "))
            guard let m = FuzzyMatcher.match(query, in: FuzzyMatcher.Label(ancestors[i]), allowSubsequence: false) else { return }
            score += m.score
            matched[i] = m.matched
            a += count
        }
        let query = FuzzyMatcher.Query(pieces[a...].joined(separator: " "))
        guard let m = FuzzyMatcher.match(query, in: FuzzyMatcher.Label(leaf), allowSubsequence: true) else { return }
        score += PathRanking.leafWeight * m.score
        matched[path.count - 1] = m.matched
        if best == nil || score > best! {
            best = score
            placements = []
        }
        if score == best! { placements.append((matched, skipped)) }
    }
    func place(_ taken: [Int], _ used: Int) {
        if taken.count == ancestors.count { consider(taken); return }
        for count in 0...(k - 1 - used) { place(taken + [count], used + count) }
    }
    place([], 0)
    guard let best else { return nil }
    return (best, placements)
}
