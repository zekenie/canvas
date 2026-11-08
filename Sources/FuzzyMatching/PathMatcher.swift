import Foundation

/// What a path match is worth, and what it costs to skip. A path is segments from the outermost
/// container to the shape's own title (the leaf); the query's pieces (its words) go into the
/// segments in order, one group of neighboring pieces to a segment, the last group to the leaf.
///
///     score = leafWeight × (the leaf group's tier score)
///             + the sum of the ancestor groups' tier scores
///             − skipPenalty × (segments skipped)
///
/// A group's score is the matcher's tier for the group's pieces, as one query, in the segment's
/// label (`FuzzyRanking`: exact 1000 down to the typo's 100). A group in an ancestor may score
/// only the exact, prefix, word-prefix, substring or typo tier, never a bare subsequence: an
/// ancestor is named, not guessed at ("al" is Alpha, "apa" isn't), while the leaf, the thing
/// looked for, may be the matcher's loosest. A segment is skipped when it holds no group and a
/// piece has already gone into one before it: what the query leaves out between what it names.
/// What's above the first group isn't skipped, only unmentioned.
public enum PathRanking {
    /// How much more the leaf's group counts than an ancestor's.
    public static let leafWeight = 2
    /// What each skipped segment costs: less than a tier's step down from another (the least is
    /// 100), so a path never loses to another on its skips if its tiers are better.
    public static let skipPenalty = 25
    /// The most pieces a query is split in; the words after the last are part of it.
    public static let maximumPieces = 8
}

/// A query for paths, prepared once per keystroke: split on whitespace into pieces, each group of
/// neighboring pieces folded as one `FuzzyMatcher.Query`. Matching a path takes one of two forms:
///
/// - `match(path:)`, one path's score, with the characters to set in semibold in each segment;
/// - a row per container, for a caller that ranks thousands of shapes in a tree (Jump To): the
///   first container's row is `rootRow`, a container's is its parent's `advance`d through the
///   container's label, and a leaf's score is `leafScore` from its parent container's row. A row
///   holds, for each count of pieces placed so far, the best score of placing that many along the
///   chain from the root through the container, so what a container costs is memoized once for
///   every shape under it, and a leaf costs one match of each of its groups (as many as there are
///   pieces).
///
/// With one piece (no path to speak of) a path's score is only the leaf's, weighted: the caller
/// ranks that with `FuzzyMatcher.rank` over leaves. Pure, `Sendable`.
public struct PathMatcher: Sendable {
    /// The pieces, as typed.
    public let pieces: [String]
    /// The query of pieces `a..<b` (1 ≤ b ≤ count, a < b), joined by spaces, at `groups[a][b - 1]`.
    private let groups: [[FuzzyMatcher.Query]]

    /// `splittingDots`: a dot followed by a letter splits a piece too, as whitespace does (`orders.cust` is `orders cust`), for a
    /// picker whose shapes' parts are listed under their shapes (a table's columns), where a dot is how a part is written after
    /// its shape; a dot followed by anything else (`v1.2`, a trailing `orders.`) stays in its piece.
    public init(_ text: String, splittingDots: Bool = false) {
        var pieces: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let splitsHere = splittingDots && character == "." && !current.isEmpty
                && characters.indices.contains(index + 1) && characters[index + 1].isLetter
            if character.isWhitespace || splitsHere {
                if !current.isEmpty { pieces.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        if pieces.count > PathRanking.maximumPieces {
            let tail = pieces[(PathRanking.maximumPieces - 1)...].joined(separator: " ")
            pieces = Array(pieces[..<(PathRanking.maximumPieces - 1)]) + [tail]
        }
        self.pieces = pieces
        groups = pieces.indices.map { a in
            (a..<pieces.count).map { b in FuzzyMatcher.Query(pieces[a...b].joined(separator: " ")) }
        }
    }

    public var isEmpty: Bool { pieces.isEmpty }
    public var pieceCount: Int { pieces.count }

    /// Pieces `a..<b` as one query.
    func group(_ a: Int, _ b: Int) -> FuzzyMatcher.Query { groups[a][b - a - 1] }

    // MARK: Rows

    /// What's been placed so far, best score for each count of pieces: `best[g]`, for `g` from 0
    /// to `pieceCount - 1` (the leaf always takes the last piece), or `Row.unreachable`.
    public struct Row: Sendable, Equatable {
        public static let unreachable = Int.min
        public let best: [Int]
        public init(best: [Int]) { self.best = best }
    }

    /// The row before any container: nothing placed, nothing lost.
    public var rootRow: Row {
        Row(best: [0] + [Int](repeating: Row.unreachable, count: max(pieces.count - 1, 0)))
    }

    /// The row after one more container on the chain, whose label is `label`: each count of
    /// pieces placed either skips the container (a skipped segment, once any piece is placed),
    /// or has the container take a group of the pieces after those the parent's row placed. Nil
    /// for a container with no name to match (an untitled one): skipped.
    public func advance(_ row: Row, through label: FuzzyMatcher.Label?) -> Row {
        let count = pieces.count
        guard count > 1 else { return row }
        var next = row.best
        for g in 1..<count where next[g] != Row.unreachable { next[g] -= PathRanking.skipPenalty }
        guard let label else { return Row(best: next) }
        // A group a..<b in this container, after the `a` pieces the parent's row placed.
        for a in 0..<(count - 1) where row.best[a] != Row.unreachable {
            for b in (a + 1)..<count {
                guard let score = FuzzyMatcher.score(group(a, b), in: label, allowSubsequence: false) else { continue }
                let candidate = row.best[a] + score
                if candidate > next[b] { next[b] = candidate }
            }
        }
        return Row(best: next)
    }

    /// The score of a shape whose own title is `label` (the leaf), under a container whose row
    /// is `row`: the leaf's group is the last piece and, as the parent's row allows, those before
    /// it. Nil if no way of placing the pieces works. With `placingAtLeast`, only the ways that put that
    /// many pieces in the containers before it (1: the shape is found by its path, not by its title alone).
    public func leafScore(after row: Row, label: FuzzyMatcher.Label, placingAtLeast minimum: Int = 0) -> Int? {
        leafScore(after: row, placingAtLeast: minimum) { FuzzyMatcher.score($0, in: label, allowSubsequence: true) }
    }

    /// The same for a title kept as keys in a list's buffer (`FuzzyMatcher.appendKeys`, rebased to start at 0: what
    /// `UnsafeBufferPointer(rebasing:)` makes), so a list that keeps its titles so makes no `Label` for each shape it scores.
    public func leafScore(after row: Row, keys: UnsafeBufferPointer<UInt32>, placingAtLeast minimum: Int = 0) -> Int? {
        leafScore(after: row, placingAtLeast: minimum) { FuzzyMatcher.score($0, keys: keys, allowSubsequence: true) }
    }

    private func leafScore(after row: Row, placingAtLeast minimum: Int, _ score: (FuzzyMatcher.Query) -> Int?) -> Int? {
        guard minimum < pieces.count else { return nil }
        var best: Int?
        for a in minimum..<pieces.count where row.best[a] != Row.unreachable {
            guard let score = score(group(a, pieces.count)) else { continue }
            let candidate = row.best[a] + PathRanking.leafWeight * score
            if best == nil || candidate > best! { best = candidate }
        }
        return best
    }

    // MARK: One path

    /// How a path matches: the score, and per segment (the path's order) what to set in
    /// semibold: ranges of `Character` offsets in the segment, empty for a segment skipped.
    public struct Match: Hashable, Sendable {
        public let score: Int
        public let matched: [[Range<Int>]]
        /// How many segments the query skipped.
        public let skipped: Int

        public init(score: Int, matched: [[Range<Int>]], skipped: Int) {
            self.score = score
            self.matched = matched
            self.skipped = skipped
        }
    }

    /// How `path` (the containers, the outermost first, then the shape's own title last) matches;
    /// nil if it doesn't. The same score the rows give, and the same `placingAtLeast`.
    public func match(path: [String], placingAtLeast minimum: Int = 0) -> Match? {
        guard minimum < pieces.count, let leaf = path.last else { return nil }
        let ancestors = path.dropLast().map(FuzzyMatcher.Label.init)
        var rows = [rootRow]
        for label in ancestors { rows.append(advance(rows[rows.count - 1], through: label)) }
        let leafLabel = FuzzyMatcher.Label(leaf)
        // The leaf's group, the best by the leaf's rule.
        var best: (score: Int, a: Int)?
        let parent = rows[rows.count - 1]
        for a in minimum..<pieces.count where parent.best[a] != Row.unreachable {
            guard let score = FuzzyMatcher.score(group(a, pieces.count), in: leafLabel, allowSubsequence: true) else { continue }
            let candidate = parent.best[a] + PathRanking.leafWeight * score
            if best == nil || candidate > best!.score { best = (candidate, a) }
        }
        guard let best else { return nil }
        var matched = [[Range<Int>]](repeating: [], count: path.count)
        matched[path.count - 1] = FuzzyMatcher.match(group(best.a, pieces.count), in: leafLabel, allowSubsequence: true)?.matched ?? []
        // Back along the containers: which took a group, which were skipped.
        var g = best.a, used = 0
        for i in stride(from: ancestors.count - 1, through: 0, by: -1) where g > 0 {
            let before = rows[i], after = rows[i + 1]
            if before.best[g] != Row.unreachable, after.best[g] == before.best[g] - PathRanking.skipPenalty { continue }
            var placed = false
            for a in 0..<g where before.best[a] != Row.unreachable {
                guard let m = FuzzyMatcher.match(group(a, g), in: ancestors[i], allowSubsequence: false),
                      before.best[a] + m.score == after.best[g] else { continue }
                matched[i] = m.matched
                g = a
                used += 1
                placed = true
                break
            }
            assert(placed, "a row's best came from neither a skip nor a group")
        }
        // Skipped: the containers between the first to take a group and the leaf that took none.
        let first = matched.indices.first { !matched[$0].isEmpty } ?? (path.count - 1)
        let skipped = (first..<(path.count - 1)).filter { matched[$0].isEmpty }.count
        return Match(score: best.score, matched: matched, skipped: skipped)
    }

    /// Ranges of `Character` offsets in `text` (a `FuzzyMatch`'s, a `PathMatcher.Match`'s) as ranges of its
    /// UTF-16 offsets, as an `NSRange` or an attributed string takes them.
    public static func utf16Ranges(_ ranges: [Range<Int>], in text: String) -> [Range<Int>] {
        guard !ranges.isEmpty else { return [] }
        var offsets: [Int] = [0]
        offsets.reserveCapacity(text.count + 1)
        for character in text { offsets.append(offsets[offsets.count - 1] + character.utf16.count) }
        return ranges.compactMap { range in
            guard range.lowerBound >= 0, range.upperBound < offsets.count, range.lowerBound < range.upperBound else { return nil }
            return offsets[range.lowerBound]..<offsets[range.upperBound]
        }
    }
}
