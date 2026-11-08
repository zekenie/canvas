import Foundation

// The SQL reader: Postgres-flavored DDL read into the kit's model, pure (Foundation and the kit's Model). A tokenizer (identifiers
// unquoted and folded to lower case, `"quoted"` and `backticked` kept as written, strings `'…'`, `E'…'` and `$tag$…$tag$`, comments
// `--` and nested `/* */`), so a body splits safely at `;`, then a recursive-descent reader of each statement: `CREATE TABLE` (its
// columns, their types as written, NOT NULL, NULL, UNIQUE, PRIMARY KEY, DEFAULT, REFERENCES … ON DELETE/UPDATE, each after an
// optional CONSTRAINT name, and the table's PRIMARY KEY, UNIQUE and FOREIGN KEY), `CREATE TYPE … AS ENUM` and `ALTER TABLE … ADD`
// a column or a key, as pg_dump writes keys. Everything else (CHECK, EXCLUDE, generated and identity clauses, COLLATE, a UNIQUE of
// several columns, indexes, views, functions, triggers, grants, SET, INSERT, ENGINE…) is skipped without a word, and a statement
// that doesn't read is skipped whole. It makes no shapes: the paste (`SQLPaste`) turns what it read into a draw program.

/// A name as SQL writes it: the schema, if one is written (`public`, the default, is none), and the name. Unquoted parts are folded
/// to lower case, as Postgres folds them; quoted parts are as written.
public struct SQLName: Hashable, Sendable, CustomStringConvertible {
    public var schema: String?
    public var name: String

    public init(_ name: String, schema: String? = nil) {
        self.name = name
        self.schema = schema == SQLReader.defaultSchema ? nil : schema
    }

    public var description: String { schema.map { "\($0).\(name)" } ?? name }
}

/// A table as SQL said it: its columns, in order (each the kit's `Column`: its type as written, lower-cased, one space; null when
/// no NOT NULL and no primary key says otherwise), the columns of its primary key in order, and its keys.
public struct SQLTable: Sendable, Equatable {
    public var name: SQLName
    public var columns: [Column]
    public var primaryKey: [String]
    public var keys: [SQLKey]
}

/// A key: a column, and the table and column it references (nil: that table's primary key's, the one at `place` for a key of
/// `width` columns).
public struct SQLKey: Hashable, Sendable {
    public var column: String
    public var table: SQLName
    public var targetColumn: String?
    /// Its column's place in a key of several (`FOREIGN KEY (a, b)`), and how many it has.
    public var place = 0
    public var width = 1

    public init(column: String, table: SQLName, targetColumn: String?, place: Int = 0, width: Int = 1) {
        self.column = column
        self.table = table
        self.targetColumn = targetColumn
        self.place = place
        self.width = width
    }

    /// The column it references among the columns of its table's primary key, `primaryKey`, when it names none: the one at its
    /// place, where the two have as many columns; nil otherwise.
    public func target(primaryKey: [String]) -> String? {
        if let targetColumn { return targetColumn }
        return primaryKey.count == width ? primaryKey[place] : nil
    }
}

/// An enum as SQL said it: its values, in order.
public struct SQLEnum: Sendable, Equatable {
    public var name: SQLName
    public var values: [String]
}

/// What a text of SQL says: its tables and enums, and the order they were made in.
public struct SQLSchema: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        case table(Int)
        case enumType(Int)
    }

    public var tables: [SQLTable] = []
    public var enums: [SQLEnum] = []
    public var order: [Item] = []

    /// Whether it read no table and no enum.
    public var isEmpty: Bool { order.isEmpty }
}

/// The reader.
public enum SQLReader {
    /// The schema a name with none is in, which a written one names as none.
    static let defaultSchema = "public"
    /// How much of a text the sniff looks at.
    static let sniffLimit = 65_536

    /// Whether a text may be SQL this reads, cheaply: `CREATE TABLE` (temporary or unlogged too) or `AS ENUM`, in any case and
    /// spacing, in its first 64 KB.
    public static func sniffs(_ text: String) -> Bool {
        let head = text.utf8.count > sniffLimit ? String(decoding: text.utf8.prefix(sniffLimit), as: UTF8.self) : text
        return head.range(of: #"\bcreate\s+(?:(?:global|local|temp|temporary|unlogged)\s+)*table\b|\bas\s+enum\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What `text` says: every statement that reads, in order; the rest skipped.
    public static func read(_ text: String) -> SQLSchema {
        var reading = Reading()
        for statement in SQLTokens.statements(of: text) {
            var cursor = Cursor(statement, source: text)
            reading.read(&cursor)
        }
        return reading.schema
    }
}

// MARK: Tokens

/// A token of SQL text.
struct SQLToken: Equatable {
    enum Kind: Equatable {
        /// An unquoted identifier or keyword, as written.
        case word
        /// A `"quoted"` or `backticked` identifier, its quotes off and its doubled quotes undone.
        case quoted
        /// A string, `'…'`, `E'…'` or `$tag$…$tag$`, its contents.
        case string
        case number
        /// A punctuation mark or an operator, a character each (`::` one).
        case symbol
    }

    var kind: Kind
    var text: String
    /// Where it is in the source, for a default's text as written.
    var range: Range<String.Index>

    /// Whether it is the keyword `word` (written in any case).
    func `is`(_ word: String) -> Bool { kind == .word && text.caseInsensitiveCompare(word) == .orderedSame }
    func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }

    /// The identifier it is: a word folded to lower case, a quoted one as written; nil for anything else.
    var identifier: String? {
        switch kind {
        case .word: text.lowercased()
        case .quoted: text
        default: nil
        }
    }
}

enum SQLTokens {
    /// The statements of a text, each its tokens, split at the `;`s outside strings, quotes and comments; empty ones left out.
    static func statements(of text: String) -> [[SQLToken]] {
        var statements: [[SQLToken]] = [], current: [SQLToken] = []
        for token in tokens(of: text) {
            if token.isSymbol(";") {
                if !current.isEmpty { statements.append(current) }
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { statements.append(current) }
        return statements
    }

    /// A text's tokens, its comments and whitespace passed over. A string, a quote or a comment left open runs to the end.
    static func tokens(of text: String) -> [SQLToken] {
        var tokens: [SQLToken] = []
        var at = text.startIndex
        let end = text.endIndex
        func char(_ offset: Int = 0) -> Character? {
            var index = at
            for _ in 0..<offset {
                guard index < end else { return nil }
                index = text.index(after: index)
            }
            return index < end ? text[index] : nil
        }
        func advance(_ count: Int = 1) {
            for _ in 0..<count where at < end { at = text.index(after: at) }
        }
        while at < end {
            let start = at
            let c = text[at]
            if c.isWhitespace {
                advance()
                continue
            }
            // Comments: `--` to the line's end, `/* … */` nested.
            if c == "-", char(1) == "-" {
                while at < end, !text[at].isNewline { advance() }
                continue
            }
            if c == "/", char(1) == "*" {
                advance(2)
                var depth = 1
                while at < end, depth > 0 {
                    if text[at] == "/", char(1) == "*" {
                        depth += 1
                        advance(2)
                    } else if text[at] == "*", char(1) == "/" {
                        depth -= 1
                        advance(2)
                    } else {
                        advance()
                    }
                }
                continue
            }
            // Strings: `'…'` (`''` a quote), and with a letter before them (`E'…'` reads backslash escapes; `N`, `B`, `X`, `U&`).
            if c == "'" {
                tokens.append(SQLToken(kind: .string, text: quotedRun(closing: "'", escapes: false), range: start..<at))
                continue
            }
            if "eEnNbBxX".contains(c), char(1) == "'" {
                advance()
                tokens.append(SQLToken(kind: .string, text: quotedRun(closing: "'", escapes: c == "e" || c == "E"), range: start..<at))
                continue
            }
            // A dollar-quoted string: `$$…$$` or `$tag$…$tag$`.
            if c == "$", let tag = dollarTag() {
                advance(tag.count)
                let body = at
                if let close = text.range(of: tag, range: at..<end) {
                    tokens.append(SQLToken(kind: .string, text: String(text[body..<close.lowerBound]), range: start..<close.upperBound))
                    at = close.upperBound
                } else {
                    tokens.append(SQLToken(kind: .string, text: String(text[body..<end]), range: start..<end))
                    at = end
                }
                continue
            }
            // Quoted identifiers: `"…"` (`""` a quote) and MySQL's backticks.
            if c == "\"" || c == "`" {
                tokens.append(SQLToken(kind: .quoted, text: quotedRun(closing: c, escapes: false), range: start..<at))
                continue
            }
            if c.isLetter || c == "_" {
                while at < end, text[at].isLetter || text[at].isNumber || text[at] == "_" || text[at] == "$" { advance() }
                tokens.append(SQLToken(kind: .word, text: String(text[start..<at]), range: start..<at))
                continue
            }
            if c.isNumber || (c == "." && char(1)?.isNumber == true) {
                while at < end, text[at].isNumber || text[at] == "." { advance() }
                if at < end, text[at] == "e" || text[at] == "E", let next = char(1), next.isNumber || ((next == "+" || next == "-") && char(2)?.isNumber == true) {
                    advance(2)
                    while at < end, text[at].isNumber { advance() }
                }
                tokens.append(SQLToken(kind: .number, text: String(text[start..<at]), range: start..<at))
                continue
            }
            if c == ":", char(1) == ":" {
                advance(2)
                tokens.append(SQLToken(kind: .symbol, text: "::", range: start..<at))
                continue
            }
            advance()
            tokens.append(SQLToken(kind: .symbol, text: String(c), range: start..<at))
            // `COPY t (…) FROM stdin;` is followed by the table's rows as raw lines to one that is `\.`, which no quote or comment in
            // them opens (pg_dump writes its keys after them).
            if c == ";", copiesFromInput(tokens.dropLast()) { skipRows() }
        }
        return tokens

        /// Whether the statement these tokens (up to the `;`) end is `COPY … FROM STDIN`.
        func copiesFromInput(_ ended: ArraySlice<SQLToken>) -> Bool {
            let statement = ended.reversed().prefix { !$0.isSymbol(";") }.reversed()
            guard statement.first?.is("COPY") == true else { return false }
            let words = Array(statement)
            return words.indices.dropLast().contains { words[$0].is("FROM") && words[$0 + 1].is("STDIN") }
        }

        /// Passes over the lines after the statement's end, through the one that is `\.` (to the end of the text where none is).
        func skipRows() {
            while at < end, !text[at].isNewline { advance() }
            while at < end {
                advance()
                let lineStart = at
                while at < end, !text[at].isNewline { advance() }
                if text[lineStart..<at].trimmingCharacters(in: .whitespaces) == "\\." {
                    return
                }
            }
        }

        /// The run from a quote at `at` to its closing quote, the quotes off: a doubled closing quote is one, and with `escapes` a
        /// backslash takes the character after it.
        func quotedRun(closing: Character, escapes: Bool) -> String {
            advance()
            var value = ""
            while at < end {
                let c = text[at]
                if escapes, c == "\\", let next = char(1) {
                    value.append(next)
                    advance(2)
                    continue
                }
                if c == closing {
                    if char(1) == closing {
                        value.append(closing)
                        advance(2)
                        continue
                    }
                    advance()
                    return value
                }
                value.append(c)
                advance()
            }
            return value
        }

        /// The tag a dollar quote at `at` opens, `$` to `$` (an identifier's letters between, or none), nil where there's none
        /// (`$1` is a parameter).
        func dollarTag() -> String? {
            var tag = "$", index = text.index(after: at)
            while index < end {
                let c = text[index]
                if c == "$" { return tag + "$" }
                guard c.isLetter || c == "_" || (c.isNumber && tag.count > 1) else { return nil }
                tag.append(c)
                index = text.index(after: index)
            }
            return nil
        }
    }
}

// MARK: Reading

/// A statement's tokens being read, left to right.
struct Cursor {
    let tokens: [SQLToken]
    let source: String
    var at = 0

    init(_ tokens: [SQLToken], source: String) {
        self.tokens = tokens
        self.source = source
    }

    var isAtEnd: Bool { at >= tokens.count }
    func peek(_ offset: Int = 0) -> SQLToken? { tokens.indices.contains(at + offset) ? tokens[at + offset] : nil }

    /// Whether the next tokens are these keywords, in order.
    func sees(_ words: String...) -> Bool { sees(words) }
    func sees(_ words: [String]) -> Bool {
        words.enumerated().allSatisfy { peek($0.offset)?.is($0.element) == true }
    }

    /// Takes these keywords if they come next, in order.
    @discardableResult
    mutating func take(_ words: String...) -> Bool {
        guard sees(words) else { return false }
        at += words.count
        return true
    }

    mutating func takeSymbol(_ symbol: String) -> Bool {
        guard peek()?.isSymbol(symbol) == true else { return false }
        at += 1
        return true
    }

    /// Takes the next token.
    @discardableResult
    mutating func next() -> SQLToken? {
        defer { at += 1 }
        return peek()
    }

    /// Takes an identifier.
    mutating func identifier() -> String? {
        guard let name = peek()?.identifier else { return nil }
        at += 1
        return name
    }

    /// Takes a name: `name`, `schema.name`, or `catalog.schema.name` (the last two kept).
    mutating func name() -> SQLName? {
        guard var parts = identifier().map({ [$0] }) else { return nil }
        while peek()?.isSymbol(".") == true, let part = peek(1)?.identifier {
            at += 2
            parts.append(part)
        }
        return SQLName(parts[parts.count - 1], schema: parts.count > 1 ? parts[parts.count - 2] : nil)
    }

    /// Takes a parenthesized group, from its `(` to the one that closes it, if one comes next.
    @discardableResult
    mutating func skipGroup() -> Bool {
        guard peek()?.isSymbol("(") == true else { return false }
        var depth = 0
        while let token = next() {
            if token.isSymbol("(") { depth += 1 }
            if token.isSymbol(")") {
                depth -= 1
                if depth == 0 { return true }
            }
        }
        return true
    }

    /// Takes `( a, b )`, a list of identifiers (each maybe with `ASC`, `DESC` or a length after it, as an index writes one); nil
    /// where none comes next or it holds something else.
    mutating func names() -> [String]? {
        guard peek()?.isSymbol("(") == true else { return nil }
        let start = at
        at += 1
        var names: [String] = []
        while !isAtEnd {
            guard let name = identifier() else { at = start; return nil }
            names.append(name)
            // What may follow a column in a key's list: a length, an order, a collation, an operator class.
            while let token = peek(), !token.isSymbol(","), !token.isSymbol(")") {
                if token.isSymbol("(") { skipGroup() } else { at += 1 }
            }
            if takeSymbol(")") { return names }
            _ = takeSymbol(",")
        }
        at = start
        return nil
    }

    /// The parts of a parenthesized list from its `(` (taken) to its `)` (taken), split at its commas at depth 0: each part its
    /// tokens. Nil where no `(` comes next.
    mutating func parts() -> [[SQLToken]]? {
        guard takeSymbol("(") else { return nil }
        var parts: [[SQLToken]] = [], part: [SQLToken] = [], depth = 0
        while let token = next() {
            if token.isSymbol("(") || token.isSymbol("[") { depth += 1 }
            if token.isSymbol("]") { depth = max(0, depth - 1) }
            if token.isSymbol(")") {
                if depth == 0 { break }
                depth -= 1
            }
            if token.isSymbol(","), depth == 0 {
                parts.append(part)
                part = []
                continue
            }
            part.append(token)
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }

    /// The rest of the statement split at its commas at depth 0 (an `ALTER TABLE`'s actions).
    mutating func rest() -> [[SQLToken]] {
        var parts: [[SQLToken]] = [], part: [SQLToken] = [], depth = 0
        while let token = next() {
            if token.isSymbol("(") || token.isSymbol("[") { depth += 1 }
            if token.isSymbol(")") || token.isSymbol("]") { depth = max(0, depth - 1) }
            if token.isSymbol(","), depth == 0 {
                parts.append(part)
                part = []
                continue
            }
            part.append(token)
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }

    /// The source text from one token's start to another's end, its whitespace runs one space: a default as written.
    func written(_ first: Int, through last: Int) -> String {
        let text = source[tokens[first].range.lowerBound..<tokens[last].range.upperBound]
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The words a column's type runs up to: what starts a constraint, or another clause a column may have. SQL's keywords are written
/// in upper case here, as SQL is, and read in any case.
private let constraintWords: Set<String> = ["CONSTRAINT", "NOT", "NULL", "PRIMARY", "UNIQUE", "DEFAULT", "REFERENCES", "CHECK", "COLLATE",
                                            "GENERATED", "AUTO_INCREMENT", "AUTOINCREMENT", "COMMENT", "IDENTITY", "DEFERRABLE", "INITIALLY",
                                            "CHARSET", "ON", "ENCODE", "STORAGE", "COMPRESSION"]

/// What's being read: the tables and enums so far.
private struct Reading {
    var schema = SQLSchema()
    /// The tables being made, by name: what an `ALTER TABLE` adds to.
    private var tableIndex: [SQLName: Int] = [:]
    /// Each table's columns that NOT NULL says may not be null (a primary key's may not either, once it's read).
    private var notNull: [Int: Set<String>] = [:]

    mutating func read(_ cursor: inout Cursor) {
        if cursor.take("CREATE") {
            _ = cursor.take("OR", "REPLACE")
            _ = cursor.take("GLOBAL") || cursor.take("LOCAL")
            _ = cursor.take("TEMPORARY") || cursor.take("TEMP") || cursor.take("UNLOGGED")
            if cursor.take("TABLE") { createTable(&cursor) } else if cursor.take("TYPE") { createType(&cursor) }
        } else if cursor.take("ALTER", "TABLE") {
            alterTable(&cursor)
        }
    }

    // MARK: CREATE TABLE

    private mutating func createTable(_ cursor: inout Cursor) {
        _ = cursor.take("IF", "NOT", "EXISTS")
        guard let name = cursor.name(), tableIndex[name] == nil, let elements = cursor.parts() else { return }
        let index = schema.tables.count
        schema.tables.append(SQLTable(name: name, columns: [], primaryKey: [], keys: []))
        schema.order.append(.table(index))
        tableIndex[name] = index
        for element in elements where !element.isEmpty {
            var part = Cursor(element, source: cursor.source)
            readElement(&part, table: index)
        }
        settle(index)
    }

    /// A table's element: a constraint of the table, or a column.
    private mutating func readElement(_ cursor: inout Cursor, table: Int) {
        if readTableConstraint(&cursor, table: table) { return }
        guard let first = cursor.peek() else { return }
        // A table's index (MySQL's `KEY name (a)`, `INDEX (a)`), and what copies or excludes (`LIKE t`, `EXCLUDE USING …`).
        if first.is("KEY") || first.is("INDEX") || first.is("FULLTEXT") || first.is("SPATIAL") {
            if cursor.peek(1)?.isSymbol("(") == true { return }
            if cursor.peek(2)?.isSymbol("(") == true, cursor.peek(3)?.kind != .number { return }
        }
        if first.is("LIKE") || (first.is("EXCLUDE") && (cursor.peek(1)?.is("USING") == true || cursor.peek(1)?.isSymbol("(") == true)) { return }
        readColumn(&cursor, table: table)
    }

    /// A constraint of a table, in its element or an `ALTER TABLE … ADD`: `[CONSTRAINT n] PRIMARY KEY (a, b)`, `UNIQUE (a)`,
    /// `FOREIGN KEY (a, b) REFERENCES t (x, y) [ON DELETE …]`; `CHECK` and `EXCLUDE` read and dropped. False where it isn't one.
    private mutating func readTableConstraint(_ cursor: inout Cursor, table: Int) -> Bool {
        let start = cursor.at
        if cursor.take("CONSTRAINT") { _ = cursor.identifier() }
        if cursor.take("PRIMARY", "KEY") {
            if let columns = cursor.names() {
                for column in columns where !schema.tables[table].primaryKey.contains(column) { schema.tables[table].primaryKey.append(column) }
            }
            return true
        }
        if cursor.take("UNIQUE") {
            // Postgres's `NULLS NOT DISTINCT`, MySQL's `KEY name`: whatever comes before the columns.
            while let token = cursor.peek(), !token.isSymbol("(") { cursor.next() }
            if let columns = cursor.names(), columns.count == 1 { mark(columns[0], in: table) { $0.unique = true } }
            return true
        }
        if cursor.take("FOREIGN", "KEY") {
            if cursor.peek()?.identifier != nil, cursor.peek(1)?.isSymbol("(") == true { cursor.next() }
            guard let columns = cursor.names(), cursor.take("REFERENCES"), let target = cursor.name() else { return true }
            let targets = cursor.names()
            let actions = readActions(&cursor)
            for (offset, column) in columns.enumerated() {
                let targetColumn = targets.flatMap { $0.indices.contains(offset) ? $0[offset] : nil }
                key(column, in: table, to: SQLKey(column: column, table: target, targetColumn: targetColumn, place: offset, width: columns.count), actions: actions)
            }
            return true
        }
        if cursor.take("CHECK") || cursor.take("EXCLUDE") { return true }
        cursor.at = start
        return false
    }

    /// A column: its name, its type to the first word of a constraint, then its constraints.
    private mutating func readColumn(_ cursor: inout Cursor, table: Int) {
        guard let name = cursor.identifier(), !schema.tables[table].columns.contains(where: { $0.name == name }) else { return }
        var column = Column(name: name, type: TypeRef(typeWords(&cursor)), nullable: true)
        var notNull = false
        var key: SQLKey?
        var actions: (onDelete: String?, onUpdate: String?) = (nil, nil)
        while let token = cursor.peek() {
            if cursor.take("CONSTRAINT") {
                _ = cursor.identifier()
            } else if cursor.take("NOT", "NULL") {
                notNull = true
            } else if cursor.take("NULL") {
                notNull = false
            } else if cursor.take("PRIMARY", "KEY") {
                column.primaryKey = true
                _ = cursor.take("ASC") || cursor.take("DESC")
            } else if cursor.take("UNIQUE") {
                _ = cursor.take("KEY")
                _ = cursor.take("NULLS", "NOT", "DISTINCT") || cursor.take("NULLS", "DISTINCT")
                column.unique = true
            } else if cursor.take("DEFAULT") {
                column.default = defaultText(&cursor)
            } else if cursor.take("REFERENCES") {
                guard let target = cursor.name() else { return }
                let targets = cursor.names()
                key = SQLKey(column: name, table: target, targetColumn: targets?.first)
                actions = readActions(&cursor)
            } else if cursor.take("GENERATED") {
                // `GENERATED ALWAYS AS (expr) STORED`, `GENERATED {ALWAYS | BY DEFAULT} AS IDENTITY [(options)]`.
                _ = cursor.take("ALWAYS") || cursor.take("BY", "DEFAULT")
                _ = cursor.take("AS")
                _ = cursor.take("IDENTITY")
                cursor.skipGroup()
                _ = cursor.take("STORED") || cursor.take("VIRTUAL")
            } else if cursor.take("COLLATE") || cursor.take("COMMENT") || cursor.take("CHARSET") || cursor.take("CHARACTER", "SET") {
                cursor.next()
            } else if cursor.take("ON", "UPDATE") {
                // MySQL's `ON UPDATE CURRENT_TIMESTAMP`.
                cursor.next()
                cursor.skipGroup()
            } else if token.isSymbol("(") {
                cursor.skipGroup()
            } else {
                cursor.next()
            }
        }
        column.onDelete = actions.onDelete
        column.onUpdate = actions.onUpdate
        schema.tables[table].columns.append(column)
        if notNull { self.notNull[table, default: []].insert(name) }
        if column.primaryKey, !schema.tables[table].primaryKey.contains(name) { schema.tables[table].primaryKey.append(name) }
        if let key { self.key(name, in: table, to: key, actions: actions) }
    }

    /// A column's type as written, lower-cased but for a quoted name, one space between words and none inside brackets:
    /// `varchar(255)`, `numeric(10,2)`, `text[]`, `timestamp with time zone`.
    private func typeWords(_ cursor: inout Cursor) -> String {
        var text = "", depth = 0, last: SQLToken?
        while let token = cursor.peek() {
            if depth == 0 {
                if token.kind == .word, constraintWords.contains(token.text.uppercased()) { break }
                // `CHARACTER SET` is MySQL's clause; `character varying` a type.
                if token.is("CHARACTER"), cursor.peek(1)?.is("SET") == true { break }
            }
            if token.isSymbol("(") || token.isSymbol("[") { depth += 1 }
            if token.isSymbol(")") || token.isSymbol("]") { depth = max(0, depth - 1) }
            let tight = [")", ",", "]", "(", "[", "."].contains(token.text) && token.kind == .symbol
            let afterTight = last.map { $0.kind == .symbol && ["(", "[", ",", ".", "::"].contains($0.text) } ?? true
            if !text.isEmpty, !tight, !afterTight { text += " " }
            switch token.kind {
            case .word: text += token.text.lowercased()
            case .string: text += "'" + token.text.replacingOccurrences(of: "'", with: "''") + "'"
            default: text += token.text
            }
            last = token
            cursor.next()
        }
        return text
    }

    /// A default's text as written, to the next word that starts a constraint (its first token always taken: `DEFAULT NULL`).
    private func defaultText(_ cursor: inout Cursor) -> String? {
        let first = cursor.at
        var depth = 0
        while let token = cursor.peek() {
            if depth == 0, cursor.at > first {
                if token.kind == .word, constraintWords.contains(token.text.uppercased()) { break }
                if token.isSymbol(",") { break }
            }
            if token.isSymbol("(") || token.isSymbol("[") { depth += 1 }
            if token.isSymbol(")") || token.isSymbol("]") { depth -= 1 }
            if depth < 0 { break }
            cursor.next()
        }
        guard cursor.at > first else { return nil }
        return cursor.written(first, through: cursor.at - 1)
    }

    /// What a key does on delete and on update: `ON DELETE CASCADE`, `ON UPDATE SET NULL`, … in either order; `MATCH …` and
    /// `DEFERRABLE …` passed over.
    private func readActions(_ cursor: inout Cursor) -> (onDelete: String?, onUpdate: String?) {
        var actions: (onDelete: String?, onUpdate: String?) = (nil, nil)
        while !cursor.isAtEnd {
            if cursor.take("MATCH") {
                cursor.next()
            } else if cursor.take("ON", "DELETE") {
                actions.onDelete = action(&cursor)
            } else if cursor.take("ON", "UPDATE") {
                actions.onUpdate = action(&cursor)
            } else {
                break
            }
        }
        return actions
    }

    /// `CASCADE`, `RESTRICT`, `NO ACTION`, `SET NULL [(a)]`, `SET DEFAULT [(a)]`, lower-cased.
    private func action(_ cursor: inout Cursor) -> String? {
        for words in [["CASCADE"], ["RESTRICT"], ["NO", "ACTION"], ["SET", "NULL"], ["SET", "DEFAULT"]] where cursor.sees(words) {
            cursor.at += words.count
            cursor.skipGroup()
            return words.joined(separator: " ").lowercased()
        }
        return cursor.next()?.identifier
    }

    /// Marks a column of a table, if it has it.
    private mutating func mark(_ column: String, in table: Int, _ change: (inout Column) -> Void) {
        guard let at = schema.tables[table].columns.firstIndex(where: { $0.name == column }) else { return }
        change(&schema.tables[table].columns[at])
    }

    /// A column's key, its actions on the column: the last a column is given wins.
    private mutating func key(_ column: String, in table: Int, to key: SQLKey, actions: (onDelete: String?, onUpdate: String?)) {
        schema.tables[table].keys.removeAll { $0.column == column }
        schema.tables[table].keys.append(key)
        mark(column, in: table) {
            if let onDelete = actions.onDelete { $0.onDelete = onDelete }
            if let onUpdate = actions.onUpdate { $0.onUpdate = onUpdate }
        }
    }

    /// A table read whole: a primary key's columns and those NOT NULL says may not be null; every other may.
    private mutating func settle(_ table: Int) {
        let primaryKey = Set(schema.tables[table].primaryKey), notNull = notNull[table] ?? []
        for index in schema.tables[table].columns.indices {
            let name = schema.tables[table].columns[index].name
            if primaryKey.contains(name) { schema.tables[table].columns[index].primaryKey = true }
            schema.tables[table].columns[index].nullable = !(primaryKey.contains(name) || notNull.contains(name))
        }
    }

    // MARK: CREATE TYPE … AS ENUM

    private mutating func createType(_ cursor: inout Cursor) {
        guard let name = cursor.name(), cursor.take("AS", "ENUM"), cursor.takeSymbol("(") else { return }
        guard !schema.enums.contains(where: { $0.name == name }) else { return }
        var values: [String] = []
        while let token = cursor.next(), !token.isSymbol(")") {
            if token.kind == .string, !values.contains(token.text) { values.append(token.text) }
        }
        schema.order.append(.enumType(schema.enums.count))
        schema.enums.append(SQLEnum(name: name, values: values))
    }

    // MARK: ALTER TABLE … ADD

    /// `ALTER TABLE [IF EXISTS] [ONLY] t ADD [COLUMN] …` and `ADD [CONSTRAINT n] {PRIMARY KEY | UNIQUE | FOREIGN KEY} …`, for a
    /// table the same text makes; any other action passed over.
    private mutating func alterTable(_ cursor: inout Cursor) {
        _ = cursor.take("IF", "EXISTS")
        _ = cursor.take("ONLY")
        guard let name = cursor.name(), let table = tableIndex[name] else { return }
        _ = cursor.takeSymbol("*")
        for action in cursor.rest() {
            var part = Cursor(action, source: cursor.source)
            guard part.take("ADD") else { continue }
            if readTableConstraint(&part, table: table) { continue }
            _ = part.take("COLUMN")
            _ = part.take("IF", "NOT", "EXISTS")
            readColumn(&part, table: table)
        }
        settle(table)
    }
}
