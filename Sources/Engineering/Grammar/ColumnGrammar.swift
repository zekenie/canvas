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
    /// and its target among it, is kept as written, in order. A type is read as SQL writes it, several words where SQL's
    /// are (`timestamp with time zone`, `character varying(255)`, `double precision`: `SQLTypeWords`), and so is a default
    /// that casts to one (`''::character varying`); a name, a type or a default in double quotes is the words between them
    /// (`"order date"`, `"Order Status"`, a doubled `""` a quote), what a line prints a part in that wouldn't read back alone.
    public static func read(_ line: String, id: PartID = PartID()) -> Column? {
        scan(line, id: id).column
    }

    /// What each word of a column's line is: what the line's spans are drawn by.
    public enum WordRole: Hashable, Sendable {
        /// Its name.
        case name
        /// Its type (a `?` after it included): all its words, one run.
        case type
        /// A word of the grammar's own: `null`, `not`, `unique`, `pk`, `primary`, `key`, `default`.
        case keyword
        /// What follows `default`: all its words, one run.
        case defaultValue
        /// A key's arrow.
        case arrow
        /// Words nothing reads, kept as written (a key's target among them).
        case unread
    }

    /// A line read: the column it says (nil for a line with nothing on it), and each word's role and place in it (UTF-16);
    /// `typeRange`, where the type's words are without the quotes round them or the `?` after them (what stands for an
    /// enum the type names).
    public struct Scan: Sendable {
        public var column: Column?
        public var words: [(role: WordRole, range: NSRange, text: String)]
        public var typeRange: NSRange?
    }

    /// Reads a line as `read` does, saying too what each word is and where.
    public static func scan(_ line: String, id: PartID = PartID()) -> Scan {
        let words = Self.placedWords(of: line)
        guard let name = words.first else { return Scan(column: nil, words: []) }
        var roles: [(role: WordRole, range: NSRange, text: String)] = [(.name, name.range, name.text)]
        var column = Column(id: id, name: unquoted(name.text) ?? name.text, type: TypeRef(""))
        var rest = words.dropFirst()
        var typeRange: NSRange?
        if let type = typeRun(rest) {
            rest = rest.dropFirst(type.count)
            roles.append((.type, type.range, (line as NSString).substring(with: type.range)))
            column.type = TypeRef(type.words)
            column.nullable = type.nullable
            typeRange = type.inner
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
                let value = defaultRun(rest)
                roles.append((.defaultValue, value.range, (line as NSString).substring(with: value.range)))
                column.default = value.text
                rest = rest.dropFirst(value.count)
            default:
                // A key's arrow, typed either way, and what follows it are kept whole: `→ customers.id`.
                let isArrow = word.text == arrow || word.text == typedArrow
                roles.append((isArrow ? .arrow : .unread, word.range, word.text))
                unread.append(word.text == typedArrow ? arrow : word.text)
            }
        }
        column.unread = unread.joined(separator: " ")
        return Scan(column: column, words: roles, typeRange: typeRange)
    }

    /// A type's run at the head of `words`: its first word (nil where it's one of the grammar's own) and the words SQL's types of
    /// several words go on with (`SQLTypeWords`); a quoted name alone. Its words as the column holds them (one space between, the
    /// quotes and a `?` taken off), how many words it is, where it is, where its words are, and whether a `?` says null.
    static func typeRun(_ words: ArraySlice<(text: String, range: NSRange)>)
        -> (words: String, count: Int, range: NSRange, inner: NSRange, nullable: Bool)? {
        guard let head = words.first, !isFlag(head.text) else { return nil }
        func nulled(_ text: String) -> (text: String, nullable: Bool) {
            text.count > 1 && text.hasSuffix("?") ? (String(text.dropLast()), true) : (text, false)
        }
        let (headText, headNull) = nulled(head.text)
        if let inner = unquoted(headText) {
            return (inner, 1, head.range, NSRange(location: head.range.location + 1, length: (headText as NSString).length - 2), headNull)
        }
        var count = 1, nullable = headNull
        if !headNull {
            let more = SQLTypeWords.goesOn(after: headText, through: words.dropFirst().map(\.text))
            count += more
            nullable = more > 0 && nulled(words[words.startIndex + more].text).nullable
        }
        let run = words.prefix(count)
        let texts = run.enumerated().map { $0.offset == count - 1 && nullable ? nulled($0.element.text).text : $0.element.text }
        let last = run.last!.range
        let range = NSRange(location: head.range.location, length: NSMaxRange(last) - head.range.location)
        let inner = NSRange(location: range.location, length: range.length - (nullable ? 1 : 0))
        return (texts.joined(separator: " "), count, range, inner, nullable)
    }

    /// A default's run at the head of `words` (it has one): a quoted value alone, else its word and, where it casts to one of SQL's
    /// types of several words (`''::character varying`), the words the type goes on with.
    static func defaultRun(_ words: ArraySlice<(text: String, range: NSRange)>) -> (text: String, count: Int, range: NSRange) {
        let head = words.first!
        if let inner = unquoted(head.text) { return (inner, 1, head.range) }
        var count = 1
        if let cast = head.text.range(of: "::", options: .backwards) {
            count += SQLTypeWords.goesOn(after: String(head.text[cast.upperBound...]), through: words.dropFirst().map(\.text))
        }
        let run = words.prefix(count)
        let range = NSRange(location: head.range.location, length: NSMaxRange(run.last!.range) - head.range.location)
        return (run.map(\.text).joined(separator: " "), count, range)
    }

    /// The words between a word's double quotes, a doubled quote a quote: what a quoted name, type or default is. Nil for a
    /// word that isn't one quoted run.
    static func unquoted(_ word: String) -> String? {
        let characters = Array(word)
        guard characters.count >= 2, characters.first == "\"", characters.last == "\"" else { return nil }
        var inner = "", index = 1
        while index < characters.count - 1 {
            if characters[index] == "\"" {
                // Inside, a quote is only ever one doubled; one alone closes the run before the word ends.
                guard characters[index + 1] == "\"", index + 1 < characters.count - 1 else { return nil }
                index += 1
            }
            inner.append(characters[index])
            index += 1
        }
        return inner
    }

    /// `text` in double quotes, a quote in it doubled: one word that reads back as `text`.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The line a column is written as: its name, its type, then `null`, `unique`, `default …` and `pk` as it is,
    /// then the words it kept that nothing read. What `read` reads back as the same column: a name, a type or a default
    /// that wouldn't read back as itself (a name or an enum's of several words, a default of several words that no cast
    /// explains) is quoted, and nothing else is.
    public static func print(_ column: Column) -> String { print(column, key: nil).line }

    /// `column` printed with `key` (`→ customers.id`) after what it says and before the words it kept, so its line's first
    /// arrow is the key's; the line, and where the key's target is in it.
    public static func print(_ column: Column, key: String?) -> (line: String, key: NSRange?) {
        func line(quoting: Set<Part>) -> (line: String, key: NSRange?) {
            var words = [quoting.contains(.name) ? quoted(column.name) : column.name]
            if !column.type.words.isEmpty {
                words.append(quoting.contains(.type) ? quoted(column.type.words) : column.type.words)
            } else if key == nil, !column.nullable, !column.unique, column.default == nil, !column.primaryKey,
                      let next = Self.words(of: column.unread).first, !isFlag(next) {
                // No type, and a word kept that isn't the grammar's own would be read as one: an empty type says there is none.
                words.append(quoted(""))
            }
            if column.nullable { words.append(null) }
            if column.unique { words.append(unique) }
            if let value = column.default { words += [Self.default, quoting.contains(.default) ? quoted(value) : value] }
            if column.primaryKey { words.append(primaryKey) }
            var range: NSRange?
            if let key {
                words.append(arrow)
                let before = (words.joined(separator: " ") as NSString).length + 1
                range = NSRange(location: before, length: (key as NSString).length)
                words.append(key)
            }
            if !column.unread.isEmpty { words.append(column.unread) }
            return (words.joined(separator: " "), range)
        }
        func readsBack(_ line: String) -> Bool {
            guard let read = read(line, id: column.id) else { return false }
            return read.name == column.name && read.type.words == column.type.words && read.nullable == column.nullable
                && read.unique == column.unique && read.primaryKey == column.primaryKey && read.default == column.default
                && read.unread == [key.map { "\(arrow) \($0)" }, column.unread].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let plain = line(quoting: [])
        if readsBack(plain.line) { return plain }
        var quoting: Set<Part> = []
        if !reads(name: column.name) { quoting.insert(.name) }
        if !column.type.words.isEmpty, !reads(type: column.type.words) { quoting.insert(.type) }
        if let value = column.default, !reads(default: value) { quoting.insert(.default) }
        let some = line(quoting: quoting)
        return readsBack(some.line) ? some : line(quoting: [.name, .type, .default])
    }

    /// A part of a column's line a print may quote.
    private enum Part { case name, type, `default` }

    /// Whether `name` reads back as itself, alone as a line's first word.
    private static func reads(name: String) -> Bool {
        let words = placedWords(of: name)
        return words.count == 1 && words[0].text == name && unquoted(name) == nil
    }

    /// A type's words as a line writes them: quoted where they wouldn't read back as the type alone (an enum's name of several
    /// words), as they are where they would (`timestamp with time zone`).
    public static func written(type: String) -> String { type.isEmpty || reads(type: type) ? type : quoted(type) }

    /// Whether `type` reads back as itself, as a line's type.
    private static func reads(type: String) -> Bool {
        let words = placedWords(of: type)
        guard let run = typeRun(words[...]) else { return false }
        return run.count == words.count && !run.nullable && run.words == type
    }

    /// Whether `value` reads back as itself, as a line's default.
    private static func reads(default value: String) -> Bool {
        let words = placedWords(of: value)
        guard !words.isEmpty else { return false }
        let run = defaultRun(words[...])
        return run.count == words.count && run.text == value
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
    /// its type's words named, while they still say the same and the line binds none of its own); a new name goes after the
    /// nearest column written before it, else last, in the order written; a column `written` leaves out stays, where it was. A
    /// statement (or a paste) names only what it changes. `after`: the row a join written in pieces wrote before these.
    public static func merge(_ written: [Column], onto held: [Column], after: String? = nil) -> [Column] {
        var merged = held
        var previous = after
        for column in written {
            defer { previous = column.name }
            guard let at = merged.firstIndex(where: { $0.name == column.name }) else {
                merged.insert(column, at: Rows.after(previous, in: merged.map(\.name)))
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
            return (table, column.isEmpty ? nil : unquoted(column) ?? column)
        }
        // A column in quotes after the dot (`customers."first name"`): the table is what's before the first `."`, which a table
        // written plain never holds.
        if word.hasSuffix("\""), let quote = word.range(of: ".\""), let column = unquoted(String(word[word.index(after: quote.lowerBound)...])),
           !column.isEmpty, quote.lowerBound != word.startIndex {
            return (String(word[..<quote.lowerBound]), column)
        }
        guard let dot = word.lastIndex(of: ".") else { return word.isEmpty ? nil : (word, nil) }
        let table = String(word[..<dot]), column = String(word[word.index(after: dot)...])
        guard !table.isEmpty else { return nil }
        return (table, column.isEmpty ? nil : column)
    }

    /// A key's target written: `customers.id`; a table's name or a column's that holds a dot, a space or a quote in quotes
    /// (`"order lines".id`, `customers."first name"`), so the target reads back as one word naming the row.
    public static func written(table: String, column: String) -> String {
        let name = table.isEmpty || !plainTarget(table) ? "\"\(table.replacingOccurrences(of: "\"", with: ""))\"" : table
        return name + "." + written(column: column)
    }

    /// A column's name as a key's target says it after the dot: in quotes (a quote in it doubled) where it wouldn't read as one word
    /// there.
    public static func written(column: String) -> String { column.isEmpty || plainTarget(column) ? column : quoted(column) }

    /// Whether a name is a word of a key's target as it stands.
    private static func plainTarget(_ name: String) -> Bool {
        !name.contains(where: { $0 == "." || $0 == "\"" || $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "'" })
    }

    /// Whether a word is one of the grammar's own (so it can't be a type: `id pk` is a column with no type).
    static func isFlag(_ word: String) -> Bool {
        [null, not, unique, primaryKey, primary, Self.default].contains(word.lowercased()) || word == arrow || word == typedArrow
    }

    /// A line's words: what whitespace separates, but a quoted run (`'a b'`, `"a b"`) and a parenthesized one
    /// (`numeric(10, 2)`) are one word with what's in them, as SQL writes a type and a default.
    static func words(of line: String) -> [String] { placedWords(of: line).map(\.text) }

    /// The words of a line and where each is in it (UTF-16, as `NSRange` counts). A quote opens a quoted run only where
    /// a word starts (or inside parentheses, or a double quote right after a dot: a key's `customers."first name"`), as SQL's
    /// literals do, so an apostrophe in a name is a letter, and inside the run a
    /// quote doubled is one of its characters (`'it''s a test'`, `"say ""hi"""`); a quote or a parenthesis never closed is a
    /// letter too, and the line's other words stay words.
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
        let characters = Array(line)
        var escaped = false
        for (index, character) in characters.enumerated() {
            let width = character.utf16.count
            defer { offset += width }
            if let open = quote {
                word.append(character)
                // A quote doubled inside the run is one of its characters, as SQL writes one (`'it''s'`).
                if escaped {
                    escaped = false
                } else if character == open {
                    if index + 1 < characters.count, characters[index + 1] == open { escaped = true } else { quote = nil }
                }
                continue
            }
            if word.isEmpty { start = offset }
            switch character {
            case _ where (character == "'" || character == "\"") && (word.isEmpty || depth > 0 || (character == "\"" && word.hasSuffix("."))) && !plain.contains(offset):
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

    /// `written` joined onto `held` by text: a value `held` has keeps its id, a new one goes after the nearest value written
    /// before it, else last, in the order written, and one `written` leaves out stays. `after`: the value a join written in
    /// pieces wrote before these.
    public static func merge(_ written: [EnumValue], onto held: [EnumValue], after: String? = nil) -> [EnumValue] {
        var merged = held
        var previous = after
        for value in written {
            defer { previous = value.text }
            guard !merged.contains(where: { $0.text == value.text }) else { continue }
            merged.insert(value, at: Rows.after(previous, in: merged.map(\.text)))
        }
        return merged
    }
}

/// Where a row a join adds goes among the rows held: after the row the join wrote before it, else last.
enum Rows {
    /// The index after the row named `previous` among `names`, else the end.
    static func after(_ previous: String?, in names: [String]) -> Int {
        previous.flatMap { name in names.firstIndex(of: name).map { $0 + 1 } } ?? names.count
    }
}
