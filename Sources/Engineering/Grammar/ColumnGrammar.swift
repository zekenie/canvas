import Canvas
import Foundation

// The column grammar: a column written as a line, `name type [null] [unique] [default …] [pk] [→ table.column]`, read
// into the kit's model and printed back from it. One reader and one printer, pure, shared by everything that writes a
// column from text: a person typing a row, a pasted block, and `canvas draw`'s `columns:`. Words it can't place stay in
// the row (`unread`), shown plain, never marked. A key's `→ table.column` is read among them, and said apart by `key(in:)`:
// a key is its arrow, so what writes a column from a line draws the arrow and keeps the words only where they name nothing.
// Printing what was read loses no word.

/// The column grammar's reader and printer.
public enum ColumnGrammar {
    /// The words that say something of a column, as typed in any case.
    static let null = "null", not = "not", unique = "unique", primaryKey = "pk", primary = "primary", key = "key", `default` = "default"
    /// A key's arrow, and the two characters typed for it.
    public static let arrow = "→"
    static let typedArrow = "->"

    /// The column a line says, its id `id`; nil for a line with nothing on it. The first word is its name, the next
    /// its type (a `?` after it: it may be null), then any of `null` (`not null` says it mayn't), `unique`, `pk`
    /// (`primary key` too), `default` and the word after it, in any order and any case; everything else, a key's `→`
    /// and its target among it, is kept as written, in order.
    public static func read(_ line: String, id: PartID = PartID()) -> Column? {
        scan(line, id: id).column
    }

    /// What each word of a column's line is: what the line's spans are drawn by.
    public enum WordRole: Hashable, Sendable {
        /// Its name.
        case name
        /// Its type (a `?` after it included).
        case type
        /// A word of the grammar's own: `null`, `not`, `unique`, `pk`, `primary`, `key`, `default`.
        case keyword
        /// What follows `default`.
        case defaultValue
        /// A key's arrow.
        case arrow
        /// Words nothing reads, kept as written (a key's target among them).
        case unread
    }

    /// A line read: the column it says (nil for a line with nothing on it), and each word's role and place in it (UTF-16).
    public struct Scan: Sendable {
        public var column: Column?
        public var words: [(role: WordRole, range: NSRange, text: String)]
    }

    /// Reads a line as `read` does, saying too what each word is and where.
    public static func scan(_ line: String, id: PartID = PartID()) -> Scan {
        let words = Self.placedWords(of: line)
        guard let name = words.first else { return Scan(column: nil, words: []) }
        var roles: [(role: WordRole, range: NSRange, text: String)] = [(.name, name.range, name.text)]
        var column = Column(id: id, name: name.text, type: TypeRef(""))
        var rest = words.dropFirst()
        if let type = rest.first, !isFlag(type.text) {
            rest = rest.dropFirst()
            roles.append((.type, type.range, type.text))
            if type.text.count > 1, type.text.hasSuffix("?") {
                column.type = TypeRef(String(type.text.dropLast()))
                column.nullable = true
            } else {
                column.type = TypeRef(type.text)
            }
        }
        var unread: [String] = []
        // A word the grammar reads once: said again, it is kept as written with the rest, so printing loses none.
        var said: Set<String> = []
        func first(_ word: String) -> Bool { said.insert(word).inserted }
        while let word = rest.first {
            rest = rest.dropFirst()
            switch word.text.lowercased() {
            case null where !said.contains(null):
                said.insert(null)
                column.nullable = true
                roles.append((.keyword, word.range, word.text))
            case not where rest.first?.text.lowercased() == null && !said.contains(null):
                said.insert(null)
                roles.append((.keyword, word.range, word.text))
                roles.append((.keyword, rest.first!.range, rest.first!.text))
                rest = rest.dropFirst()
                column.nullable = false
            case unique where first(unique):
                column.unique = true
                roles.append((.keyword, word.range, word.text))
            case primaryKey where first(primaryKey):
                column.primaryKey = true
                roles.append((.keyword, word.range, word.text))
            case primary where rest.first?.text.lowercased() == key && !said.contains(primaryKey):
                said.insert(primaryKey)
                roles.append((.keyword, word.range, word.text))
                roles.append((.keyword, rest.first!.range, rest.first!.text))
                rest = rest.dropFirst()
                column.primaryKey = true
            case Self.default where rest.first != nil && first(Self.default):
                roles.append((.keyword, word.range, word.text))
                roles.append((.defaultValue, rest.first!.range, rest.first!.text))
                column.default = rest.first!.text
                rest = rest.dropFirst()
            default:
                // A key's arrow, typed either way, and what follows it are kept whole: `→ customers.id`.
                let isArrow = word.text == arrow || word.text == typedArrow
                roles.append((isArrow ? .arrow : .unread, word.range, word.text))
                unread.append(word.text == typedArrow ? arrow : word.text)
            }
        }
        column.unread = unread.joined(separator: " ")
        return Scan(column: column, words: roles)
    }

    /// The line a column is written as: its name, its type, then `null`, `unique`, `default …` and `pk` as it is,
    /// then the words it kept that nothing read. What `read` reads back as the same column.
    public static func print(_ column: Column) -> String {
        var words = [column.name]
        if !column.type.words.isEmpty { words.append(column.type.words) }
        if column.nullable { words.append(null) }
        if column.unique { words.append(unique) }
        if let value = column.default { words += [Self.default, value] }
        if column.primaryKey { words.append(primaryKey) }
        if !column.unread.isEmpty { words.append(column.unread) }
        return words.joined(separator: " ")
    }

    /// The columns a block of lines says, one a line, blank lines passed over, each a new id.
    public static func read(lines text: String) -> [Column] {
        text.split(whereSeparator: \.isNewline).compactMap { read(String($0)) }
    }

    /// `columns` as a block of lines, one a column.
    public static func print(lines columns: [Column]) -> String {
        columns.map(print).joined(separator: "\n")
    }

    /// `written` joined onto `held` by name: a column of a name `held` has takes what its line says (its type, null,
    /// unique, pk, default and unread words) and keeps its id and what no line says (on delete, on update, and the shape
    /// its type's words named, while they still say the same and the line binds none of its own); a new name is added at the end, in the order written;
    /// a column `written` leaves out stays, where it was. A statement names only what it changes.
    public static func merge(_ written: [Column], onto held: [Column]) -> [Column] {
        var merged = held
        var index: [String: Int] = [:]
        for (offset, column) in held.enumerated() where index[column.name] == nil { index[column.name] = offset }
        for column in written {
            guard let at = index[column.name] else {
                index[column.name] = merged.count
                merged.append(column)
                continue
            }
            let old = merged[at]
            var joined = column
            joined.id = old.id
            joined.onDelete = old.onDelete
            joined.onUpdate = old.onUpdate
            if joined.type.shape == nil, joined.type.words == old.type.words { joined.type.shape = old.type.shape }
            merged[at] = joined
        }
        return merged
    }

    /// A key's words in a column's unread words: `→` (or `->`) and the word after it, `table.column`, `table` alone (its primary
    /// key's) or `"a table".column`. Nil where there's no `→` with a word after it.
    public static func key(in unread: String) -> KeyWords? {
        let words = Self.words(of: unread)
        guard let at = words.firstIndex(where: { $0 == arrow || $0 == typedArrow }), words.indices.contains(at + 1) else { return nil }
        let target = words[at + 1]
        var rest = words
        rest.removeSubrange(at...(at + 1))
        guard let (table, column) = Self.target(target) else { return nil }
        return KeyWords(table: table, column: column, written: "\(arrow) \(target)", rest: rest.joined(separator: " "))
    }

    /// A key's target as written, `table.column`, `table`, `"a table".column`: the table's name and the column's (nil for none,
    /// the table's primary key). The column is after the last dot: a table's name may hold one (`v1.2`) only when quoted. Nil for
    /// a word that names no table.
    public static func target(_ word: String) -> (table: String, column: String?)? {
        if word.hasPrefix("\""), let close = word.dropFirst().firstIndex(of: "\"") {
            let table = String(word[word.index(after: word.startIndex)..<close])
            let after = word[word.index(after: close)...]
            guard !table.isEmpty else { return nil }
            if after.isEmpty { return (table, nil) }
            guard after.hasPrefix(".") else { return nil }
            let column = String(after.dropFirst())
            return (table, column.isEmpty ? nil : column)
        }
        guard let dot = word.lastIndex(of: ".") else { return word.isEmpty ? nil : (word, nil) }
        let table = String(word[..<dot]), column = String(word[word.index(after: dot)...])
        guard !table.isEmpty else { return nil }
        return (table, column.isEmpty ? nil : column)
    }

    /// A key's target written: `customers.id`, a table's name that holds a dot, a space or a quote in quotes.
    public static func written(table: String, column: String) -> String {
        let plain = !table.isEmpty && !table.contains(where: { $0 == "." || $0 == "\"" || $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "'" })
        return (plain ? table : "\"\(table.replacingOccurrences(of: "\"", with: ""))\"") + "." + column
    }

    /// Whether a word is one of the grammar's own (so it can't be a type: `id pk` is a column with no type).
    static func isFlag(_ word: String) -> Bool {
        [null, not, unique, primaryKey, primary, Self.default].contains(word.lowercased()) || word == arrow || word == typedArrow
    }

    /// A line's words: what whitespace separates, but a quoted run (`'a b'`, `"a b"`) and a parenthesized one
    /// (`numeric(10, 2)`) are one word with what's in them, as SQL writes a type and a default.
    static func words(of line: String) -> [String] { placedWords(of: line).map(\.text) }

    /// The words of a line and where each is in it (UTF-16, as `NSRange` counts). A quote opens a quoted run only where
    /// a word starts (or inside parentheses), as SQL's literals do, so an apostrophe in a name is a letter; a quote or
    /// a parenthesis never closed is a letter too, and the line's other words stay words.
    public static func placedWords(of line: String) -> [(text: String, range: NSRange)] {
        var plain: Set<Int> = []
        while true {
            let (words, unclosed) = scannedWords(of: line, plain: plain)
            guard let unclosed else { return words }
            plain.insert(unclosed)
        }
    }

    /// The words of a line, and where the quote or parenthesis left open begins, if one is; those `plain` mark are letters.
    private static func scannedWords(of line: String, plain: Set<Int>) -> (words: [(text: String, range: NSRange)], unclosed: Int?) {
        var words: [(text: String, range: NSRange)] = [], word = "", start = 0, offset = 0
        var quote: Character?, quoteAt = 0, depth = 0, groupAt = 0
        func flush() {
            if !word.isEmpty { words.append((word, NSRange(location: start, length: offset - start))) }
            word = ""
        }
        for character in line {
            let width = character.utf16.count
            defer { offset += width }
            if let open = quote {
                word.append(character)
                if character == open { quote = nil }
                continue
            }
            if word.isEmpty { start = offset }
            switch character {
            case _ where (character == "'" || character == "\"") && (word.isEmpty || depth > 0) && !plain.contains(offset):
                quote = character
                quoteAt = offset
                word.append(character)
            case "(" where !plain.contains(offset):
                if depth == 0 { groupAt = offset }
                depth += 1
                word.append(character)
            case ")":
                depth = max(0, depth - 1)
                word.append(character)
            case _ where character.isWhitespace && depth == 0:
                flush()
            default:
                word.append(character)
            }
        }
        flush()
        return (words, quote != nil ? quoteAt : depth > 0 ? groupAt : nil)
    }
}

/// A key as a column's line writes it: `→ customers.id`.
public struct KeyWords: Equatable, Sendable {
    /// The table it names, as written (its quotes taken off).
    public var table: String
    /// The column it names; nil for the table's primary key.
    public var column: String?
    /// Its words as written: `→ customers.id`.
    public var written: String
    /// The unread words without them.
    public var rest: String
}

/// The enum grammar: one value a line, as typed, trimmed.
public enum EnumGrammar {
    /// The values a block of lines says, one a line, blank lines passed over, each a new id.
    public static func read(lines text: String) -> [EnumValue] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : EnumValue(text: text)
        }
    }

    /// `values` as a block of lines, one a value.
    public static func print(lines values: [EnumValue]) -> String {
        values.map(\.text).joined(separator: "\n")
    }

    /// `written` joined onto `held` by text: a value `held` has keeps its id, a new one is added at the end in the order
    /// written, and one `written` leaves out stays.
    public static func merge(_ written: [EnumValue], onto held: [EnumValue]) -> [EnumValue] {
        var merged = held
        var known = Set(held.map(\.text))
        for value in written where known.insert(value.text).inserted { merged.append(value) }
        return merged
    }
}
