import AppKit
import Canvas

/// A quote of mention text around a mention, as a list of what mentions a shape shows it under a
/// mentioner's name (`MentionState.quote(of:around:)`).
enum MentionQuote {
    /// The plain text of `runs` around the first mention of `target` (nil if there's none): each
    /// mention "@" and the name `name` gives, else the name it holds; every run of whitespace, line
    /// breaks included, one space; the mention whole, and as much of the text on either side as
    /// makes about `length` characters, half on each side where both have that much, cut between
    /// words where it can be and marked "…" where text is left out.
    static func quote(_ runs: [MentionRun], around target: ShapeID, length: Int, name: (ShapeID) -> String?) -> String? {
        var before = "", found: String?, after = ""
        for run in runs {
            let plain: String
            switch run {
            case .text(let text):
                plain = text
            case .mention(let id, let label):
                plain = "@" + (name(id) ?? label)
                if found == nil, id == target {
                    found = plain
                    continue
                }
            }
            if found == nil { before += plain } else { after += plain }
        }
        guard let found else { return nil }
        let mention = String(folded(found)), head = folded(before), tail = folded(after)
        let room = max(0, length - mention.count)
        var headTaken = min(head.count, room / 2)
        let tailTaken = min(tail.count, room - headTaken)
        headTaken = min(head.count, room - tailTaken)
        return lead(head, taking: headTaken) + mention + trail(tail, taking: tailTaken)
    }

    /// The last `count` characters of the text before the mention: from the start of a word, "…"
    /// first, where words are left out.
    private static func lead(_ head: [Character], taking count: Int) -> String {
        let start = head.count - count
        var kept = head[start...]
        let isCut = head[..<start].contains { !$0.isWhitespace }
        if isCut, !head[start - 1].isWhitespace, let space = kept.firstIndex(of: " ") {
            kept = kept[(space + 1)...]                          // not a word's end alone
        }
        while let first = kept.first, first.isWhitespace { kept = kept.dropFirst() }
        return (isCut ? "…" : "") + String(kept)
    }

    /// The first `count` characters of the text after the mention: to the end of a word, then "…",
    /// where words are left out.
    private static func trail(_ tail: [Character], taking count: Int) -> String {
        var kept = tail[..<count]
        let isCut = tail[count...].contains { !$0.isWhitespace }
        if isCut, !tail[count].isWhitespace, let space = kept.lastIndex(of: " ") {
            kept = kept[..<space]                                // not a word's start alone
        }
        while let last = kept.last, last.isWhitespace || (isCut && Self.pauses.contains(last)) { kept = kept.dropLast() }
        return String(kept) + (isCut ? "…" : "")
    }

    /// Punctuation a cut drops before its "…".
    private static let pauses: Set<Character> = [",", ";", ":"]

    /// The text's characters, each run of whitespace one space.
    private static func folded(_ text: String) -> [Character] {
        var characters: [Character] = []
        characters.reserveCapacity(text.utf8.count)
        for character in text {
            if character.isWhitespace {
                if characters.last != " " { characters.append(" ") }
            } else {
                characters.append(character)
            }
        }
        return characters
    }
}
