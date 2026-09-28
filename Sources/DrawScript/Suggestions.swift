/// "Did you mean": the words among some that a mistyped one was probably meant as.
public enum Suggestions {
    /// Up to `limit` of `candidates` like `word`, best first, each once: the same but for case,
    /// spacing and × written as x; then one inside the other; then sharing a word; then a few
    /// letters off (a swapped pair counts as one). Within each, the fewest edits away first; ties
    /// keep the candidates' order.
    ///
    /// The edits are counted only where they decide something. The same is none away, and one
    /// inside the other as many as the letters left over; for a candidate that's neither and shares
    /// no word, the lengths come first: it takes at least their difference in edits, so one further
    /// off in length than a slip allows is passed over uncounted. A board's worth of titles costs
    /// their folding, not an edit table each.
    public static func closest(to word: String, among candidates: [String], limit: Int = 3) -> [String] {
        let wanted = folded(word)
        guard !wanted.isEmpty else { return [] }
        let wantedLength = wanted.count
        let wantedWords = Set(wanted.split(separator: " ").filter { $0.count > 1 })
        var scored: [(score: Int, distance: Int, index: Int, candidate: String)] = []
        var seen: Set<String> = []
        for (index, candidate) in candidates.enumerated() where seen.insert(candidate).inserted {
            let other = folded(candidate)
            guard !other.isEmpty else { continue }
            let length = other.count
            if other == wanted {
                scored.append((0, 0, index, candidate))
            } else if other.contains(wanted) || wanted.contains(other) {
                scored.append((1, abs(length - wantedLength), index, candidate))
            } else if !wantedWords.isDisjoint(with: other.split(separator: " ").filter { $0.count > 1 }) {
                scored.append((2, editDistance(wanted, other), index, candidate))
            } else {
                let allowed = allowance(min(wantedLength, length))
                guard abs(length - wantedLength) <= allowed else { continue }
                let distance = editDistance(wanted, other)
                guard distance <= allowed else { continue }
                scored.append((3, distance, index, candidate))
            }
        }
        scored.sort { ($0.score, $0.distance, $0.index) < ($1.score, $1.distance, $1.index) }
        return scored.prefix(limit).map(\.candidate)
    }

    /// Whether one title is a slip of the other, as a title typed wrong is: the same but for case,
    /// spacing and × written as x, or a letter off (two, in a title of 8 letters or more; none in
    /// one shorter than 4), but not the very same.
    public static func isNearMiss(_ word: String, _ other: String) -> Bool {
        guard word != other else { return false }
        let a = folded(word), b = folded(other)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let shorter = min(a.count, b.count)
        guard shorter >= 4 else { return false }
        let allowed = shorter >= 8 ? 2 : 1
        return abs(a.count - b.count) <= allowed && editDistance(a, b) <= allowed
    }

    /// Lowercased, runs of whitespace one space, trimmed, × as x.
    static func folded(_ word: String) -> String {
        word.lowercased().replacingAll("×", with: "x").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How many edits a word this long may be off by.
    static func allowance(_ length: Int) -> Int { length <= 3 ? 1 : max(2, length / 3) }

    /// Edits (insert, delete, change, or swap two neighbors) from one to the other.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let change = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + change)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}

extension String {
    /// With every `target` replaced (without Foundation).
    func replacingAll(_ target: Character, with replacement: Character) -> String {
        String(map { $0 == target ? replacement : $0 })
    }
}
