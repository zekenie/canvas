import Canvas
import Foundation

// The column grammar: a column written as a line, `name type [null] [unique] [default …] [pk] [→ table.column]`, read
// into the kit's model and printed back from it. One reader and one printer, pure, shared by everything that writes a
// column from text: a person typing a row (later), a pasted block, and `canvas draw`'s `columns:`. Words it can't
// place stay in the row (`unread`), shown plain, never marked; so does a key's `→ table.column` until keys land.
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
        let words = Self.words(of: line)
        guard let name = words.first else { return nil }
        var column = Column(id: id, name: name, type: TypeRef(""))
        var rest = words.dropFirst()
        if let type = rest.first, !isFlag(type) {
            rest = rest.dropFirst()
            if type.count > 1, type.hasSuffix("?") {
                column.type = TypeRef(String(type.dropLast()))
                column.nullable = true
            } else {
                column.type = TypeRef(type)
            }
        }
        var unread: [String] = []
        while let word = rest.first {
            rest = rest.dropFirst()
            switch word.lowercased() {
            case null: column.nullable = true
            case not where rest.first?.lowercased() == null:
                rest = rest.dropFirst()
                column.nullable = false
            case unique: column.unique = true
            case primaryKey: column.primaryKey = true
            case primary where rest.first?.lowercased() == key:
                rest = rest.dropFirst()
                column.primaryKey = true
            case Self.default where rest.first != nil:
                column.default = rest.first
                rest = rest.dropFirst()
            default:
                // A key's arrow, typed either way, and what follows it are kept whole: `→ customers.id`.
                unread.append(word == typedArrow ? arrow : word)
            }
        }
        column.unread = unread.joined(separator: " ")
        return column
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
    /// its type's words named, while they still say the same); a new name is added at the end, in the order written;
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
            if joined.type.words == old.type.words { joined.type.shape = old.type.shape }
            merged[at] = joined
        }
        return merged
    }

    /// Whether a word is one of the grammar's own (so it can't be a type: `id pk` is a column with no type).
    static func isFlag(_ word: String) -> Bool {
        [null, not, unique, primaryKey, primary, Self.default].contains(word.lowercased()) || word == arrow || word == typedArrow
    }

    /// A line's words: what whitespace separates, but a quoted run (`'a b'`, `"a b"`) and a parenthesized one
    /// (`numeric(10, 2)`) are one word with what's in them, as SQL writes a type and a default.
    static func words(of line: String) -> [String] {
        var words: [String] = [], word = ""
        var quote: Character?, depth = 0
        for character in line {
            if let open = quote {
                word.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                word.append(character)
            case "(":
                depth += 1
                word.append(character)
            case ")":
                depth = max(0, depth - 1)
                word.append(character)
            case _ where character.isWhitespace && depth == 0:
                if !word.isEmpty { words.append(word) }
                word = ""
            default:
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
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
