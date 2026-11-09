import Foundation

// SQL's types of several words, as SQL writes them: `double precision`, `character varying(255)`, `timestamp(3) with time zone`,
// `interval day to second`, MySQL's `int unsigned`. What the SQL reader stores whole (it reads a type up to the first word of a
// constraint) and what a column's line reads as one type, so a line printed from a pasted column reads back as it, and a person
// types them as SQL does.

/// The words SQL's types of several words go on with after their first.
enum SQLTypeWords {
    /// The fields an interval may be limited to: `interval day`, `interval year to month`.
    static let intervalFields: Set<String> = ["year", "month", "day", "hour", "minute", "second"]
    /// What follows a numeric type in MySQL, any of them, in any order.
    static let numericModifiers: Set<String> = ["unsigned", "signed", "zerofill"]

    /// How many of `following` go on with the type whose first word is `head`: none for a type of one word. A word's
    /// length, its array brackets and a `?` after it don't count (`varying(255)`, `zone[]`, `zone?`), and a word with a `?` ends
    /// the type.
    static func goesOn(after head: String, through following: [String]) -> Int {
        let words = following.map(bare)
        var at = 0
        // A word with a `?` after it is the type's last: nothing after it goes on with it.
        func ended() -> Bool { at > 0 && following[at - 1].hasSuffix("?") }
        func take(_ word: String) -> Bool {
            guard !ended(), at < words.count, words[at] == word else { return false }
            at += 1
            return true
        }
        func takeAny(_ set: Set<String>) -> Bool {
            guard !ended(), at < words.count, set.contains(words[at]) else { return false }
            at += 1
            return true
        }
        guard !head.hasSuffix("?") else { return 0 }
        switch bare(head) {
        case "double":
            _ = take("precision")
        case "character", "char", "nchar", "bit", "varbit":
            _ = take("varying")
        case "national":
            if take("character") || take("char") { _ = take("varying") }
        case "time", "timestamp":
            // `with time zone`, `with local time zone` (Oracle's), `without time zone`: whole or not at all.
            let start = at
            if take("with") { _ = take("local") } else if !take("without") { break }
            if !(take("time") && take("zone")) { at = start }
        case "interval":
            if takeAny(intervalFields) {
                let start = at
                if !(take("to") && takeAny(intervalFields)) { at = start }
            }
        default:
            break
        }
        while takeAny(numericModifiers) {}
        return at
    }

    /// A word as a type's word is matched: lower-cased, without a `?` after it, its array brackets or its length.
    static func bare(_ word: String) -> String {
        var text = word.lowercased()
        if text.count > 1, text.hasSuffix("?") { text.removeLast() }
        while text.hasSuffix("[]") { text.removeLast(2) }
        if let open = text.firstIndex(of: "("), text.hasSuffix(")") { text = String(text[..<open]) }
        return text
    }
}
