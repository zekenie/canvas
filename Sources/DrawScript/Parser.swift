import CoreGraphics
import FuzzyMatching

// Modified from reladraw's src/parser.ts (Apache-2.0; THIRD_PARTY_NOTICES.md).

extension Script {
    /// Reads a script: one statement a line, blank lines and `//` comments skipped. Every line that
    /// can't be read is an error, each line's first, collected in line order up to
    /// `ScriptErrors.limit`, since lines don't depend on one another. Styles are merged into the
    /// statements that name them once every line is read (a style may be defined after its use);
    /// naming one nobody defines, or defining one twice, is an error too. A style whose line can't
    /// be read is still defined, so the statements that use it aren't errors of their own.
    public init(parsing source: String) throws(ScriptErrors) {
        var errors: [ScriptError] = []
        var statements: [Statement] = []
        var styles: [StyleSource] = []
        var unread: Set<String> = []
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (offset, text) in lines.enumerated() {
            let number = offset + 1
            do throws(ScriptError) {
                let lexed = try Lexer.lex(String(text), number: number)
                guard !lexed.tokens.isEmpty else { continue }
                var parser = LineParser(tokens: lexed.tokens, line: number, text: lexed.text)
                switch try parser.statement() {
                case .statement(let body): statements.append(Statement(line: number, text: lexed.text, body: body))
                case .style(let style): styles.append(style)
                }
            } catch {
                if let name = LineParser.styleName(defining: text, number: number) { unread.insert(name) }
                errors.append(error)
                if errors.count == ScriptErrors.limit { throw ScriptErrors(errors) }
            }
        }

        // Styles, now every line is read.
        var defined: [String: Int] = [:]
        for (index, style) in styles.enumerated() {
            if let first = defined[style.definition.name] {
                let name = style.definition.name
                errors.append(ScriptError(line: style.definition.line, reason: .duplicate,
                                          "style \(name) is defined twice, here and on line \(styles[first].definition.line)",
                                          hint: "keep one, or give this one another name", statement: style.definition.text))
            } else {
                defined[style.definition.name] = index
            }
        }
        for (index, statement) in statements.enumerated() {
            guard case .shape(var shape) = statement.body, !shape.styles.isEmpty else { continue }
            var used: [StyleSource] = []
            for name in shape.styles where !unread.contains(name) || defined[name] != nil {
                if let at = defined[name] {
                    used.append(styles[at])
                } else {
                    let names = styles.map(\.definition.name)
                    let guess = Suggestions.closest(to: name, among: names, limit: 1).first
                    errors.append(ScriptError(line: statement.line, reason: .syntax, "style \(name) isn't defined",
                                              hint: guess.map { "did you mean \($0)?" } ?? "define it on a line of its own: style \(name) <attributes>",
                                              statement: statement.text))
                }
            }
            guard used.count == shape.styles.count else { continue }
            shape.merge(used)
            statements[index].body = .shape(shape)
        }

        guard errors.isEmpty else {
            let sorted = errors.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
            throw ScriptErrors(Array(sorted.prefix(ScriptErrors.limit)))
        }
        guard !statements.isEmpty else {
            throw ScriptErrors([ScriptError(line: 1, reason: .emptyScript, "the script says nothing to draw",
                                            hint: "write one statement a line, as <kind> \"A\" right of \"B\"")])
        }
        self.init(statements: statements, styles: styles.map(\.definition))
    }
}

/// A style as defined, and what it gives, read.
struct StyleSource {
    var definition: StyleDefinition
    var size: Size?
    var gap: Gap?
    var overlapAllowed: Bool
    /// What it gives but the language's keys.
    var attributes: [Attribute]
}

extension ShapeStatement {
    /// Takes what its styles give it: in the order named, a later style winning, the statement's own
    /// attributes beating every style; each attribute a style gave is tagged with the style's name.
    mutating func merge(_ styles: [StyleSource]) {
        let own = Set(attributes.map(\.key))
        let ownLanguage = ownLanguage
        var given: [Attribute] = []
        for style in styles {
            if let size = style.size, !ownLanguage.contains(.size) { self.size = size }
            if let gap = style.gap, !ownLanguage.contains(.gap) { self.gap = gap }
            if style.overlapAllowed { overlapAllowed = true }
            for attribute in style.attributes where !own.contains(attribute.key) {
                let tagged = Attribute(key: attribute.key, value: attribute.value, fromStyle: style.definition.name)
                if let at = given.firstIndex(where: { $0.key == attribute.key }) {
                    given[at] = tagged
                } else {
                    given.append(tagged)
                }
            }
        }
        attributes += given
    }

    /// The language keys the statement wrote itself (a style gives only what these don't).
    var ownLanguage: Set<LanguageKey> {
        var keys: Set<LanguageKey> = []
        if size != nil { keys.insert(.size) }
        if gap != nil { keys.insert(.gap) }
        return keys
    }
}

/// What a line said.
enum Parsed {
    case statement(Statement.Body)
    case style(StyleSource)
}

/// Reads one line's tokens. Its errors name the statement as written: `card "API": …`.
struct LineParser {
    let tokens: [Token]
    let line: Int
    let text: String
    var at = 0
    /// How messages name the statement, once it's known.
    var subject = ""

    /// What starts a comment in other languages, and here is an ordinary character: a statement
    /// that starts with it is refused as the comment it was meant to be.
    static let otherComment = "#"

    init(tokens: [Token], line: Int, text: String) {
        self.tokens = tokens
        self.line = line
        self.text = text
    }

    // MARK: Errors

    func error(_ reason: ScriptError.Reason, _ message: String, hint: String? = nil) -> ScriptError {
        ScriptError(line: line, reason: reason, subject.isEmpty ? message : "\(subject): \(message)", hint: hint, statement: text)
    }

    /// A `syntax` error.
    func error(_ message: String, hint: String? = nil) -> ScriptError { error(.syntax, message, hint: hint) }

    // MARK: Tokens

    func peek(_ ahead: Int = 0) -> Token? { at + ahead < tokens.count ? tokens[at + ahead] : nil }

    mutating func take() -> Token? {
        defer { at += 1 }
        return peek()
    }

    // MARK: Statements

    mutating func statement() throws(ScriptError) -> Parsed {
        let first = tokens[0]
        guard first.kind == .word else {
            let arrow = tokens.firstIndex(where: Self.isArrow)
            let hint = arrow.map(joinHint(arrowAt:))
                ?? (first.kind == .quoted ? "write the kind first: <kind> \(first.raw) (canvas kinds lists them)"
                : first.kind == .key ? "an attribute goes after the shape it's about: <kind> \"A\" \(first.raw) …"
                : nil)
            throw error("a statement starts with a kind, edge, delete, group, ungroup or style, not \(first.raw)", hint: hint)
        }
        if first.text.hasPrefix(Self.otherComment) {
            throw error("\(Self.otherComment) doesn't start a comment here", hint: "comments start with \(Lexer.comment)")
        }
        at = 1
        switch Keyword(rawValue: first.text) {
        case .edge?: return .statement(.edge(try edge()))
        case .delete?: return .statement(.delete(try delete()))
        case .group?: return .statement(.group(try group(.group)))
        case .ungroup?: return .statement(.ungroup(try group(.ungroup)))
        case .style?: return .style(try style())
        case nil: return .statement(.shape(try shape(first.text)))
        }
    }

    mutating func shape(_ word: String) throws(ScriptError) -> ShapeStatement {
        var statement = ShapeStatement(word: word)
        // `API --> DB`, Mermaid's: two titles joined, with no kind.
        if let token = peek(), Self.isArrow(token) {
            throw error("\(token.raw) joins shapes only in an edge statement", hint: joinHint(arrowAt: at))
        }
        subject = word
        if let name = try name() {
            statement.name = name
            subject = "\(word) \(name.written)"
        } else if let token = peek(), token.kind == .word, !startsPlacement(token), !(peek(1)?.isWord(Word.of.rawValue) ?? false),
                  !Self.isBraced(token), equalsAttribute(at: at) == nil {
            throw error("\(token.raw) isn't quoted, and titles are in double quotes", hint: "write \(word) \(quote(token.text))")
        }
        var seen: [(key: String, written: String)] = []
        while let token = peek() {
            // An `and` or comma before a placement, after one that ended in brackets or a value.
            if let last = statement.clauses.last, token.kind == .comma || token.isWord(Word.and.rawValue) {
                let mark = at
                if joinsAnother(), let next = peek(), startsPlacement(next) { throw joined(after: last.written) }
                at = mark
            }
            if Self.isBraced(token) { throw braced(from: at) }
            if let written = equalsAttribute(at: at) { throw equals(written) }
            switch token.kind {
            case .key: try attribute(of: &statement, seen: &seen)
            case .word:
                if Self.isArrow(token) {
                    throw error("\(token.raw) joins shapes only in an edge statement", hint: joinHint(arrowAt: at))
                }
                if !startsPlacement(token), at >= 2, tokens[at - 2].kind == .key, tokens[at - 1].kind != .json {
                    let key = tokens[at - 2], value = tokens[at - 1]
                    throw error("\(token.raw) isn't a placement", hint: "a value with spaces is quoted: \(key.raw) \(quote(value.text + " " + token.text))")
                }
                if token.isWord(Word.in.rawValue) {
                    try container(&statement.container)
                    continue
                }
                statement.clauses.append(try clause())
            case .quoted:
                let joined = at > 2 && tokens[at - 1].kind == .quoted
                throw error("\(token.raw) is a title where none goes",
                            hint: joined ? "join several shapes with and: \(tokens[at - 1].raw) and \(token.raw)"
                                : statement.name == nil ? "a shape's title goes right after its kind: \(word) \(token.raw)"
                                : "a value with spaces is quoted after its key: text: \(token.raw)")
            case .comma: throw error("a \",\" here joins nothing", hint: "a comma separates the shapes a placement names: right of \"A\", \"B\" and \"C\"")
            case .open, .close, .json: throw error("\(token.raw) is out of place", hint: "brackets hold a placement's gap: right of \"A\" (gap: wide)")
            case .chevron: throw chevronOutOfPlace(token)
            }
        }
        // A path says where the shape is, as `in` does.
        if case .path(let path)? = statement.name, let container = statement.container {
            throw error("\(path.written) says what holds the shape, and so does in \(container.written)",
                        hint: "keep one: \(word) \(path.written), or \(word) \(quote(path.last)) in \(path.container?.written ?? container.written)")
        }
        return statement
    }

    /// A `>` where no path is being written.
    func chevronOutOfPlace(_ token: Token) -> ScriptError {
        error("\(token.raw) joins the parts of a path, and none is being written here",
              hint: "a path names a shape by the containers it is in: \"Payments\" > \"Checkout\"; it starts with a title, an id or board")
    }

    mutating func edge() throws(ScriptError) -> EdgeStatement {
        let example = "edge \"A\" -> \"B\""
        subject = Keyword.edge.rawValue
        let (first, firstRow) = try edgeEnd(example: example)
        guard let arrowToken = take(), arrowToken.kind == .word else {
            throw error("an edge's two titles are joined by an arrow", hint: "write \(example)")
        }
        guard let arrow = EdgeArrow(rawValue: arrowToken.text) else {
            throw error("\(arrowToken.raw) isn't an arrow", hint: "write ->, <- or <->, as \(example)")
        }
        let (second, secondRow) = try edgeEnd(example: example)
        let (from, to) = arrow == .backward ? (second, first) : (first, second)
        var statement = EdgeStatement(from: from, to: to, arrow: arrow)
        (statement.fromRow, statement.toRow) = arrow == .backward ? (secondRow, firstRow) : (firstRow, secondRow)
        subject = "\(Keyword.edge.rawValue) \(statement.written)"
        if let next = peek(), next.kind == .word, EdgeArrow(rawValue: next.text) != nil || Lexer.looksLikeArrow(next.text) {
            throw error(.unsupported, "an edge joins two shapes, and this one goes on to a third",
                        hint: "write each edge on a line of its own: edge \(to.written) -> …")
        }
        if let next = peek(), next.kind == .quoted {
            throw error("\(next.raw) is a title where none goes", hint: "what an edge says is written after a key: text: \(next.raw)")
        }
        var seen: [(key: String, written: String)] = []
        while let token = peek() {
            // An `and` or comma before a placement, after one that ended in brackets or a value.
            if let last = statement.clauses.last, token.kind == .comma || token.isWord(Word.and.rawValue) {
                let mark = at
                if joinsAnother(), let next = peek(), startsPlacement(next) { throw joined(after: last.written) }
                at = mark
            }
            if Self.isBraced(token) { throw braced(from: at, edge: true) }
            if let written = equalsAttribute(at: at) { throw equals(written) }
            // The edge goes where its ends are; a placement, and `in`, say where the reference it goes through goes.
            if token.kind == .word {
                if !startsPlacement(token), at >= 2, tokens[at - 2].kind == .key, tokens[at - 1].kind != .json {
                    let key = tokens[at - 2], value = tokens[at - 1]
                    throw error("\(token.raw) isn't a placement", hint: "a value with spaces is quoted: \(key.raw) \(quote(value.text + " " + token.text))")
                }
                if token.isWord(Word.in.rawValue) {
                    try container(&statement.container)
                } else {
                    statement.clauses.append(try clause())
                }
                continue
            }
            if token.kind == .chevron { throw chevronOutOfPlace(token) }
            guard token.kind == .key else {
                throw error("\(token.raw) isn't one of an edge's attributes", hint: "an attribute is written key: value, as from: right")
            }
            at += 1
            if token.text == LanguageKey.style.rawValue {
                throw error("an edge can't take a style", hint: "styles are for shapes; write the edge's attributes on it")
            }
            if token.text == EdgeKey.share.rawValue {
                statement.share = try share(token, in: &seen)
                continue
            }
            let value = try value(for: token)
            try note(token.text, value.written, in: &seen)
            if let key = EdgeKey(rawValue: token.text) {
                switch key {
                case .from, .to:
                    guard case .word(let word) = value, let side = EdgeSide(rawValue: word) else {
                        throw error(.invalidValue, "\(token.raw) \(value.written) isn't a side",
                                    hint: "\(token.raw) takes top, right, bottom or left")
                    }
                    if key == .from { statement.fromSide = side } else { statement.toSide = side }
                case .via:
                    // A kind, bare or quoted, as a title is: which kinds the caller knows.
                    var kind = ""
                    switch value {
                    case .word(let word): kind = word
                    case .quoted(let text): kind = text
                    case .json: break
                    }
                    guard kind.contains(where: { !$0.isWhitespace }) else {
                        throw error(.invalidValue, "\(token.raw) \(value.written) isn't a kind",
                                    hint: "\(token.raw) takes the kind of shape the edge goes through, as \(token.raw) <kind>")
                    }
                    statement.via = kind.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                case .share:
                    break
                }
            } else {
                statement.attributes.append(Attribute(key: token.text, value: value))
            }
        }
        // `share: "A"` goes into A's reference and never makes one, so it has none to put anywhere.
        if case .beside(let host)? = statement.share, let placed = statement.placementWritten {
            let key = EdgeKey.share.rawValue
            throw error(.invalidValue, "\(key): \(host.written) goes into the reference beside \(host.written), so it makes none for \(placed) to place",
                        hint: "leave \(placed) out, or write \(key): true, which makes one there when there's none to share")
        }
        return statement
    }

    mutating func edgeEnd(example: String) throws(ScriptError) -> (ShapeName, String?) {
        guard let token = peek() else { throw error("an edge joins two shapes, by their titles", hint: "write \(example)") }
        if let named = try nameAndRow() { return named }
        at += 1
        if token.kind == .word { throw error("\(token.raw) isn't quoted, and titles are in double quotes", hint: "write \(example)") }
        throw error("an edge joins two shapes, by their titles", hint: "write \(example)")
    }

    /// What `share:` says: `true`, or the name of the shape whose reference it goes to (a title, an id or a path); the key is taken.
    mutating func share(_ key: Token, in seen: inout [(key: String, written: String)]) throws(ScriptError) -> EdgeShare {
        func refusal(_ written: String) -> ScriptError {
            error(.invalidValue, "\(key.raw) \(written) isn't true or the title of a shape",
                  hint: "write \(key.raw) true to reuse a reference to the same end, or \(key.raw) \"A\" for the one beside A; leave \(key.raw) out to make its own")
        }
        guard let next = peek() else { throw error("\(key.raw) has no value", hint: "write \(key.raw) <value>") }
        if next.isWord("true") {
            at += 1
            try note(key.text, next.raw, in: &seen)
            return .any
        }
        let blank = next.kind == .quoted && !next.text.contains(where: { !$0.isWhitespace })
        guard !blank, let name = try name() else { throw refusal(next.raw) }
        try note(key.text, name.written, in: &seen)
        return .beside(name)
    }

    /// Whether a token is a word that starts like an id (`#…`): where a name goes, it is meant as one.
    static func isIDWord(_ token: Token) -> Bool {
        token.kind == .word && token.text.hasPrefix(String(ShapeName.idMark))
    }

    /// The id a token `#…` names, as written (without the `#`), or why it isn't one.
    func id(_ token: Token) throws(ScriptError) -> String { try id(word: token.text) }

    func id(word: String) throws(ScriptError) -> String {
        let text = String(word.dropFirst())
        if ShapeName.isID(text) { return text }
        let message = "\(ShapeName.idMark) takes a shape's id, and \(word) isn't one"
        if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isHexDigit || $0 == "-" }) {
            throw error(.notAnID, message, hint: "an id is 32 hex digits in groups of 8, 4, 4, 4 and 12, as a query's row gives it")
        }
        throw error(.notAnID, message, hint: text.isEmpty || text.contains(where: \.isWhitespace) ? "a shape is named by its title in double quotes, or by an id a query gave"
                    : "a title is in double quotes: write \(quote(text)); an id is what a query's row gives")
    }

    /// The name at the next token, if one starts there: a title, an id, or a path (`"Payments" > "Checkout"`, `#7C1E… > "Checkout"`,
    /// `board > "Checkout"`), whose first part is a title, an id or `board` and whose others are titles. Nil when the token starts
    /// none (the caller says what it wanted instead). A `>` that ends a path with nothing after it, or starts nothing, is
    /// refused here, since only a path has one.
    mutating func name() throws(ScriptError) -> ShapeName? {
        guard let first = peek() else { return nil }
        let head: ShapePath.Head
        switch first.kind {
        case .quoted: head = .title(try title(first))
        case .word where Self.isIDWord(first): head = .id(try id(first))
        case .word where first.isWord(PlaceWord.board.rawValue) && peek(1)?.kind == .chevron: head = .board
        case .chevron: throw chevronOutOfPlace(first)
        default: return nil
        }
        at += 1
        guard peek()?.kind == .chevron else {
            switch head {
            case .title(let title): return .title(title)
            case .id(let id): return .id(id)
            case .board: throw error("board names the top of the board, and a path says what is on it", hint: "write board > \"A\"")
            }
        }
        var rest: [String] = []
        let example = "\(head.written) \(ShapePath.joiner) \"A\""
        while let chevron = peek(), chevron.kind == .chevron {
            at += 1
            guard let next = peek() else {
                throw error("\(chevron.raw) ends the path, and no title follows it", hint: "write \(([head.written] + rest.map(quote) + ["\"A\""]).joined(separator: " \(ShapePath.joiner) ")): the title of a shape inside \(rest.last.map(quote) ?? head.written)")
            }
            switch next.kind {
            case .quoted:
                at += 1
                rest.append(try title(next))
            case .word where next.isWord(PlaceWord.board.rawValue):
                throw error("board can only start a path", hint: "write board > \"A\": the top of the board, then the shape on it")
            case .word where Self.isIDWord(next):
                throw error("an id can only start a path, and \(next.raw) comes after a >", hint: "write \(next.raw) > \"A\", or name the shape by its title: \(example)")
            case .word:
                throw error("\(next.raw) isn't quoted, and titles are in double quotes", hint: "write \(example)")
            default:
                throw error("\(chevron.raw) ends the path, and no title follows it", hint: "write \(example)")
            }
        }
        return .path(ShapePath(head: head, rest: rest))
    }

    /// A name, and a row of it after a dot outside the quotes (`"orders".customer_id`, `"orders"."POST /x"`,
    /// `#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11.id`, `"shop" > "orders".id`), if one starts at the next token; nil otherwise.
    mutating func nameAndRow() throws(ScriptError) -> (ShapeName, String?)? {
        // An id and a row are one word: `#…-…​.id`.
        if let first = peek(), Self.isIDWord(first), let dot = first.text.dropFirst().firstIndex(of: ShapeName.rowMark) {
            let id = String(first.text[first.text.index(after: first.text.startIndex)..<dot])
            if ShapeName.isID(id) {
                at += 1
                let row = String(first.text[first.text.index(after: dot)...])
                guard !row.isEmpty else {
                    throw error("\(first.raw) ends in a dot, and a row's name follows it", hint: "write \(ShapeName.id(id).written)\(ShapeName.writtenRow("id"))")
                }
                return (.id(id), row)
            }
        }
        guard let name = try name() else { return nil }
        return (name, try row(of: name))
    }

    /// The row after a name, written `.customer_id` or `."POST /orders"` right after it; nil when no dot follows.
    mutating func row(of name: ShapeName) throws(ScriptError) -> String? {
        guard let next = peek(), next.kind == .word, next.text.first == ShapeName.rowMark else { return nil }
        at += 1
        guard next.text.count == 1 else { return String(next.text.dropFirst()) }
        guard let quoted = peek(), quoted.kind == .quoted else {
            throw error("\(name.written)\(next.raw) ends in a dot, and a row's name follows it", hint: "write \(name.written)\(ShapeName.writtenRow("id"))")
        }
        at += 1
        return try title(quoted)
    }

    mutating func delete() throws(ScriptError) -> DeleteStatement {
        subject = Keyword.delete.rawValue
        let example = "write delete \"A\", or delete edge \"A\" -> \"B\""
        guard let token = peek() else { throw error("delete names what it removes", hint: example) }
        let statement: DeleteStatement
        if token.isWord(Keyword.edge.rawValue) {
            at += 1
            let edge = try edge()
            guard edge.fromSide == nil, edge.toSide == nil, edge.via == nil, edge.share == nil else {
                throw error("deleting takes no from:, to:, via: or share:", hint: "write delete edge \(edge.written)")
            }
            if let placed = edge.placementWritten {
                throw error("deleting takes no placement (\(placed))", hint: "write delete edge \(edge.written)")
            }
            if edge.fromRow != nil || edge.toRow != nil {
                let whole = EdgeStatement(from: edge.from, to: edge.to, arrow: edge.arrow).written
                throw error(.unsupported, "delete edge names the shapes an edge joins, not their rows",
                            hint: "write delete edge \(whole), which takes every edge between them, keys too")
            }
            subject = "\(Keyword.delete.rawValue) \(Keyword.edge.rawValue) \(edge.written)"
            statement = .edges(from: edge.from, to: edge.to, eitherWay: edge.arrow == .both, attributes: edge.attributes)
        } else if let (name, row) = try nameAndRow() {
            statement = row.map { .row(name, row: $0) } ?? .shape(name)
            subject = "\(Keyword.delete.rawValue) \(name.written)\(row.map(ShapeName.writtenRow) ?? "")"
        } else if token.kind == .word {
            throw error("\(token.raw) isn't quoted, and titles are in double quotes", hint: "write delete \(quote(token.text))")
        } else {
            throw error("delete names what it removes", hint: example)
        }
        if let extra = peek() {
            throw error("delete takes one title, and nothing after it (\(extra.raw))", hint: "delete each shape on a line of its own")
        }
        return statement
    }

    /// `group "A" and "B"` and `ungroup "A"`: the shapes a statement names, each a title in quotes or an id, joined by `and` (or by
    /// commas, as a placement's targets are). A group is two shapes or more, `ungroup` takes one or more, and nothing follows the
    /// names: the shapes' own lines say where they go and what they hold.
    mutating func group(_ keyword: Keyword) throws(ScriptError) -> GroupStatement {
        let word = keyword.rawValue
        let example = keyword == .group ? "\(word) \"A\" \(Word.and.rawValue) \"B\"" : "\(word) \"A\""
        var statement = GroupStatement(shapes: [])
        repeat {
            guard let token = peek() else {
                if statement.shapes.isEmpty {
                    throw error(keyword == .group ? "\(word) names the shapes it puts in one group" : "\(word) names the shapes it takes out of their groups",
                                hint: "write \(example)")
                }
                let joiner = tokens[at - 1].kind == .comma ? "a comma" : Word.and.rawValue
                throw error("\(joiner) joins a shape, and none follows it", hint: "write \(example)")
            }
            if let name = try name() {
                statement.shapes.append(name)
            } else if token.kind == .word, !token.isWord(Word.and.rawValue) {
                // The names as they should have been written: every bare word that stands where a name goes, quoted.
                var fixed = statement.shapes.map(\.written)
                for rest in tokens[at...] {
                    if rest.kind == .quoted || Self.isIDWord(rest) {
                        fixed.append(rest.raw)
                    } else if rest.kind == .word, !rest.isWord(Word.and.rawValue) {
                        fixed.append(quote(rest.text))
                    } else if rest.kind == .comma || rest.isWord(Word.and.rawValue) {
                        continue
                    } else {
                        break
                    }
                }
                throw error("\(token.raw) isn't quoted, and titles are in double quotes", hint: "write \(word) \(listed(fixed))")
            } else {
                throw error("\(token.raw) is out of place: \(word) names shapes by their titles", hint: "write \(example)")
            }
            subject = "\(word) \(statement.written)"
        } while joinsAnother()
        if let extra = peek() {
            if extra.kind == .quoted || Self.isIDWord(extra) {
                throw error("\(extra.raw) is \(extra.kind == .quoted ? "a title" : "an id") where none goes",
                            hint: "join the shapes with \(Word.and.rawValue): \(statement.shapes.last?.written ?? "\"A\"") \(Word.and.rawValue) \(extra.raw)")
            }
            throw error("\(word) takes the shapes and nothing after them (\(extra.raw))",
                        hint: "a placement or an attribute goes on a shape's own line; write \(example)")
        }
        if keyword == .group, statement.shapes.count < 2 {
            throw error("a group is two shapes or more, and this names one", hint: "join another with \(Word.and.rawValue): \(example)")
        }
        return statement
    }

    mutating func style() throws(ScriptError) -> StyleSource {
        let example = "style urgent priority: high"
        guard let name = take(), name.kind == .word, Word(rawValue: name.text) == nil else {
            throw error("a style is written style <name> <attributes>", hint: "as \(example)")
        }
        subject = "\(Keyword.style.rawValue) \(name.text)"
        var source = StyleSource(definition: StyleDefinition(name: name.text, line: line, text: text, attributes: []),
                                 overlapAllowed: false, attributes: [])
        var seen: [(key: String, written: String)] = []
        while let token = peek() {
            if token.kind == .chevron { throw chevronOutOfPlace(token) }
            guard token.kind == .key else {
                throw error("a style holds attributes, and \(token.raw) isn't one", hint: "placements go on the shape: <kind> \"A\" style: \(name.text) right of \"B\"")
            }
            at += 1
            switch LanguageKey(rawValue: token.text) {
            case .style?: throw error("a style can't take another style", hint: "name both on the shape: style: \(name.text), other")
            case .title?: throw error("a style can't give a title: a title names one shape")
            default: break
            }
            let value = try value(for: token)
            try note(token.text, value.written, in: &seen)
            source.definition.attributes.append(Attribute(key: token.text, value: value))
            switch LanguageKey(rawValue: token.text) {
            case .size?: source.size = try size(value, key: token.raw)
            case .gap?: source.gap = try gap(value, key: token.raw)
            case .overlap?: source.overlapAllowed = try overlap(value, key: token.raw)
            default: source.attributes.append(Attribute(key: token.text, value: value))
            }
        }
        guard !source.definition.attributes.isEmpty else {
            throw error("a style gives something", hint: "write its attributes after its name: \(example)")
        }
        return source
    }

    /// The style a line that couldn't be read defines, if it reads as one as far as its name:
    /// `style urgent size: 0x5`, or a line the lexer refused past its first two words.
    static func styleName(defining line: Substring, number: Int) -> String? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(2)
        guard let lexed = try? Lexer.lex(words.joined(separator: " "), number: number), lexed.tokens.count >= 2,
              lexed.tokens[0].isWord(Keyword.style.rawValue), lexed.tokens[1].kind == .word, Word(rawValue: lexed.tokens[1].text) == nil
        else { return nil }
        return lexed.tokens[1].text
    }

    // MARK: Attributes

    mutating func attribute(of statement: inout ShapeStatement, seen: inout [(key: String, written: String)]) throws(ScriptError) {
        guard let key = take() else { return }
        if key.text == LanguageKey.style.rawValue {
            var names: [String] = []
            repeat {
                guard let name = peek(), name.kind == .word, !name.isWord(Word.and.rawValue) else {
                    throw error("\(key.raw) names the styles it takes, as \(key.raw) urgent", hint: "a style's name is a bare word")
                }
                at += 1
                if names.contains(name.text) {
                    throw error(.duplicate, "style \(name.text) is named twice", hint: "name it once")
                }
                names.append(name.text)
            } while joinsAnother()
            try note(key.text, names.joined(separator: ", "), in: &seen)
            statement.styles = names
            return
        }
        let value = try value(for: key)
        try note(key.text, value.written, in: &seen)
        switch LanguageKey(rawValue: key.text) {
        case .size?: statement.size = try size(value, key: key.raw)
        case .gap?: statement.gap = try gap(value, key: key.raw)
        case .overlap?: statement.overlapAllowed = try overlap(value, key: key.raw)
        case .title?:
            guard case .quoted = value else {
                // `null`, as a property's default is written, and the other words for nothing an
                // agent reaches for: `none`, as a gap or a channel says it, and `nil`.
                if [Word.null.rawValue, "none", "nil"].contains(where: { value == .word($0) }) {
                    throw error(.unsupported, "\(key.raw) \(value.written) would take the shape's title away, and a script only renames",
                                hint: "rename it with \(key.raw) \"…\", or leave \(key.raw) out")
                }
                throw error("\(value.written) isn't quoted, and titles are in double quotes", hint: "write \(key.raw) \(quote(value.written))")
            }
            statement.newTitle = try title(Token(kind: .quoted, text: value.text, raw: value.written))
        case .style?, nil:
            statement.attributes.append(Attribute(key: key.text, value: value))
        }
    }

    /// The one token after a key.
    mutating func value(for key: Token) throws(ScriptError) -> Attribute.Value {
        guard let token = peek() else { throw error("\(key.raw) has no value", hint: "write \(key.raw) <value>") }
        let value: Attribute.Value
        switch token.kind {
        case .word where !token.isWord(Word.and.rawValue):
            value = .word(token.text)
        case .quoted:
            value = .quoted(token.text)
        case .json:
            value = .json(token.text)
        default:
            throw error("\(key.raw) has no value", hint: "write \(key.raw) <value>")
        }
        at += 1
        // A path names a shape; a value is one token.
        if peek()?.kind == .chevron {
            throw error("\(key.raw) takes one value, not a path",
                        hint: key.text == LanguageKey.title.rawValue ? "\(key.raw) is the shape's new title: a path names where a shape is, and the shape keeps its place" : "a path names a shape, and \(key.raw) takes one value")
        }
        return value
    }

    /// Records a key, refusing one written twice.
    func note(_ key: String, _ written: String, in seen: inout [(key: String, written: String)]) throws(ScriptError) {
        if let earlier = seen.first(where: { $0.key == key }) {
            throw error(.duplicate, "\"\(key)\" is written twice (\(earlier.written), \(written))", hint: "keep one")
        }
        seen.append((key, written))
    }

    /// `<width>x<height>` (or `×`), `[w, h]`, or a width alone, `<width>x`: each side finite, more
    /// than 0, and at most `largest`.
    func size(_ value: Attribute.Value, key: String) throws(ScriptError) -> Size {
        let refusal = error(.invalidValue, "\(key) \(value.written) isn't a size",
                            hint: "write \(key) <width>x<height>, as \(key) 200x120, or a width alone, as \(key) 200x (world units)")
        let numbers: [Double]
        switch value {
        case .word(let word):
            let parts = String(word.map { $0 == "×" ? "x" : $0 }).split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw refusal }
            // A width alone (`300x`): the height is the kind's.
            let sides = parts[1].isEmpty ? [parts[0]] : parts
            numbers = sides.compactMap { Double($0) }
            guard numbers.count == sides.count else { throw refusal }
        case .json(let json):
            let inner = json.trimmingSpaces
            guard inner.hasPrefix("["), inner.hasSuffix("]") else { throw refusal }
            // Both sides: JSON has no width alone.
            let parts = inner.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            numbers = parts.compactMap { Double(String($0).trimmingSpaces) }
            guard parts.count == 2, numbers.count == 2 else { throw refusal }
        case .quoted: throw refusal
        }
        guard numbers.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw refusal }
        guard numbers.allSatisfy({ $0 <= Self.largest }) else {
            throw error(.invalidValue, "\(key) \(value.written) is too big: a side is at most \(Self.written(Self.largest)) world units",
                        hint: "write \(key) <width>x<height>, each at most \(Self.written(Self.largest))")
        }
        return Size(width: numbers[0], height: numbers.count == 2 ? numbers[1] : nil)
    }

    /// The most a `size:` side or a gap's number may be, in world units: more than any board needs,
    /// and small enough that placing never meets a number too big to work with.
    static let largest: Double = 100_000

    /// A number as a message writes it: `100000`.
    static func written(_ number: Double) -> String { Gap.units(number).written }

    func gap(_ value: Attribute.Value, key: String) throws(ScriptError) -> Gap {
        guard case .word(let word) = value else {
            throw error(.invalidValue, "\(key) \(value.written) isn't a gap", hint: "a gap is none, tight, normal, wide, or a number of world units")
        }
        return try Self.gap(word, key: key, error: { error(.invalidValue, $0, hint: $1) })
    }

    /// A gap's word: a name, or a number from 0 to `largest`.
    static func gap(_ word: String, key: String, error: (String, String?) -> ScriptError) throws(ScriptError) -> Gap {
        if let name = GapName(rawValue: word) { return .named(name) }
        if let number = Double(word), number.isFinite {
            guard number >= 0 else {
                throw error("\(key) \(word) is less than nothing", "a gap is a distance, at least 0; overlap: allow is what lets two shapes meet")
            }
            guard number <= largest else {
                throw error("\(key) \(word) is too far: a gap is at most \(written(largest)) world units", "write \(key) wide, or a number up to \(written(largest))")
            }
            return .units(number)
        }
        let names = GapName.allCases.map(\.rawValue)
        if word.hasSuffix("px"), let number = Double(word.dropLast(2)), number >= 0 {
            throw error("\(key) \(word) isn't a gap", "write \(key) \(word.dropLast(2)): a gap's number is already in world units")
        }
        let guess = Suggestions.closest(to: word, among: names, limit: 1).first
        throw error("\(key) \(word) isn't a gap", (guess.map { "did you mean \($0)? " } ?? "") + "a gap is none, tight, normal, wide, or a number of world units")
    }

    func overlap(_ value: Attribute.Value, key: String) throws(ScriptError) -> Bool {
        guard case .word(let word) = value, word == Word.allow.rawValue else {
            throw error(.invalidValue, "\(key) \(value.written) isn't something overlap takes", hint: "write \(key) allow, or leave it out")
        }
        return true
    }

    /// A quoted title, never blank.
    func title(_ token: Token) throws(ScriptError) -> String {
        guard token.text.contains(where: { !$0.isWhitespace }) else {
            throw error("a title can't be blank", hint: "leave it out for an untitled shape")
        }
        return token.text
    }

    // MARK: Placements

    /// Whether a token opens a placement (or is a word that nearly does: a part used as a
    /// direction), as against a forgotten pair of quotes.
    func startsPlacement(_ token: Token) -> Bool {
        guard token.kind == .word else { return false }
        return Direction(rawValue: token.text) != nil || Part(rawValue: token.text) != nil || AlignSide(rawValue: token.text) != nil
            || [Word.level, .inside, .outside, .on, .in].contains { $0.rawValue == token.text }
    }

    /// `in "X"`: the shape that holds it (a shape statement's shape, or an edge's reference), once.
    mutating func container(_ held: inout ShapeName?) throws(ScriptError) {
        at += 1
        let opening = Word.in.rawValue
        let start = at
        guard let name = try name() else {
            if let token = peek(), token.kind == .word, PlaceWord(rawValue: token.text) == nil {
                throw error("\(token.raw) isn't quoted, and titles are in double quotes", hint: "write \(opening) \(quote(token.text))")
            }
            throw error("\(opening) names no shape", hint: "write \(opening) \"A\": the shape that holds it")
        }
        let raw = tokens[start..<at].map(\.raw).joined(separator: " ")
        if let earlier = held {
            throw error("\(opening) is written twice, \(opening) \(earlier.written) and \(opening) \(raw)",
                        hint: "a shape is in one shape: keep one")
        }
        // A part (`top-left`), but not a placement starting with a word parts share (`right of`,
        // `top level with`).
        if let next = peek(), next.kind == .word, Part(rawValue: next.text) != nil, Direction(rawValue: next.text) == nil,
           peek(1)?.isWord(Word.level.rawValue) != true {
            throw error("\(opening) \(raw) takes no part: it says what holds the shape, not where in it",
                        hint: "say where with a placement too: \(opening) \(raw) inside view \(next.text)")
        }
        if let next = peek(), next.kind == .comma || next.isWord(Word.and.rawValue) {
            throw error("\(opening) \(raw) names one shape, and a shape is in one", hint: "name the one that holds it")
        }
        held = name
    }

    mutating func clause() throws(ScriptError) -> Clause {
        guard let word = take() else { throw error("a placement is missing") }
        if word.isWord(Word.on.rawValue) { return try on() }
        if word.isWord(Word.inside.rawValue) || word.isWord(Word.outside.rawValue) { return try tucked(inside: word.text == Word.inside.rawValue) }
        if let side = AlignSide(rawValue: word.text), side != .center, peek()?.isWord(Word.level.rawValue) == true {
            at += 1
            return try level(side)
        }
        if word.isWord(Word.level.rawValue) { return try level(.center) }
        guard let direction = Direction(rawValue: word.text) else { throw notAPlacement(word) }
        var opening = direction.rawValue
        if peek()?.isWord(Word.of.rawValue) == true {
            at += 1
            opening += " \(Word.of.rawValue)"
        }
        let targets = try targets(after: opening, partFirst: false)
        let gap = try bracketedGap(after: Clause.write(.direction(direction), targets, gap: nil))
        return Clause(relation: .direction(direction), targets: targets, gap: gap)
    }

    mutating func level(_ side: AlignSide) throws(ScriptError) -> Clause {
        let opening = "\(side == .center ? "" : side.rawValue + " ")\(Word.level.rawValue) \(Word.with.rawValue)"
        guard peek()?.isWord(Word.with.rawValue) == true else {
            throw error("an alignment reads \(opening) \"A\"", hint: "write \(opening) \"A\"")
        }
        at += 1
        let targets = try targets(after: opening, partFirst: false)
        let clause = Clause(relation: .level(side), targets: targets)
        if try bracketedGap(after: clause.written) != nil {
            throw error("\(clause.written) shares a line rather than leaving a space, so it takes no gap")
        }
        return clause
    }

    mutating func on() throws(ScriptError) -> Clause {
        let targets = try targets(after: Word.on.rawValue, partFirst: true)
        let clause = Clause(relation: .on, targets: targets)
        guard targets.count == 1 else {
            throw error("\(clause.written) names \(targets.count) shapes, and a shape sits on one", hint: "name the one it sits on")
        }
        if try bracketedGap(after: clause.written) != nil {
            throw error("\(clause.written) puts its middle on that point rather than leaving a space, so it takes no gap")
        }
        return clause
    }

    mutating func tucked(inside: Bool) throws(ScriptError) -> Clause {
        let word = inside ? Word.inside.rawValue : Word.outside.rawValue
        let targets = try targets(after: word, partFirst: true)
        let relation: Relation = inside ? .inside : .outside
        let written = Clause.write(relation, targets, gap: nil)
        guard targets.count == 1 else {
            throw error("\(written) names \(targets.count) shapes, and \(word) reads its direction off one part of one", hint: "name one shape and its part")
        }
        let boundary = Part.allCases.filter { $0 != .center }.map(\.rawValue).joined(separator: ", ")
        guard let part = targets[0].part, part.inward != nil else {
            let named = targets[0].part == nil ? "\(written) names no part of \(Target(targets[0].box).written)"
                : "\(written) reads no direction from center, which isn't on the edge"
            throw error(named, hint: "\(word) takes a side or a point of the box: \(boundary)")
        }
        let gap = try bracketedGap(after: written)
        return Clause(relation: relation, targets: targets, gap: gap)
    }

    /// One target, or several joined by `,` or `and`: `"A"`, `"A" top`, `board`, `view top-right`.
    mutating func targets(after opening: String, partFirst: Bool) throws(ScriptError) -> [Target] {
        var targets: [Target] = []
        repeat {
            let box: Target.Box
            if let name = try name() {
                switch name {
                case .title(let title): box = .title(title)
                case .id(let id): box = .id(id)
                case .path(let path): box = .path(path)
                }
            } else if let token = peek(), token.kind == .word, let word = PlaceWord(rawValue: token.text) {
                if peek(1)?.kind == .chevron {
                    throw error("\(token.raw) can't start a path", hint: "a path starts with a title, an id or board: \"Payments\" > \"Checkout\"")
                }
                at += 1
                box = .word(word)
            } else {
                if let token = peek(), token.kind == .word, !token.isWord(Word.and.rawValue) {
                    throw error("\(token.raw) isn't quoted, and titles are in double quotes", hint: "write \(opening) \(quote(token.text))")
                }
                throw error("\(opening) names nothing", hint: "write \(opening) \"A\"")
            }
            targets.append(Target(box, part: try part(partFirst: partFirst)))
            guard joinsAnother() else { break }
            if let next = peek(), startsPlacement(next) { throw joined(after: "\(opening) \(listed(targets.map(\.written)))") }
        } while true
        return targets
    }

    /// `right of "A" and below "B"`: the `and` (or comma) just taken joins two placements, which
    /// follow one another with nothing between them. The hint writes them so, from the placement
    /// written before it.
    func joined(after written: String) -> ScriptError {
        let joiner = tokens[at - 1].kind == .comma ? "a comma" : Word.and.rawValue
        var rest: [String] = []
        for token in tokens[at...] {
            if token.kind == .key || token.kind == .open || token.kind == .comma || token.isWord(Word.and.rawValue) { break }
            rest.append(token.raw)
        }
        return error("placements follow one another without \(joiner)", hint: "write \(written) \(rest.joined(separator: " "))")
    }

    /// Steps past a `,` or `and` (or both) and says whether one was there.
    mutating func joinsAnother() -> Bool {
        var joined = false
        if peek()?.kind == .comma {
            at += 1
            joined = true
        }
        if peek()?.isWord(Word.and.rawValue) == true {
            at += 1
            joined = true
        }
        return joined
    }

    /// The part word after a target, if there is one. `left` and `right` also open a direction and
    /// `top`, `bottom`, `left` and `right` an alignment, so the word after decides: `of` or `level`,
    /// or (for `left` and `right`) a title, and it's the next placement's. After `inside`,
    /// `outside` and `on`, which need or take a part, only `of` does.
    mutating func part(partFirst: Bool) throws(ScriptError) -> Part? {
        guard let token = peek(), token.kind == .word else { return nil }
        if let written = equalsAttribute(at: at) { throw equals(written) }
        if token.text == Word.text.rawValue {
            let parts = Part.allCases.map(\.rawValue).joined(separator: ", ")
            throw error("text isn't a part of a shape here", hint: peek(1)?.kind == .quoted ? "to set its text, write text: \(peek(1)!.raw)" : "the parts are \(parts)")
        }
        guard let part = Part(rawValue: token.text) else { return nil }
        let next = peek(1)
        if next?.isWord(Word.of.rawValue) == true { return nil }
        if !partFirst {
            if next?.isWord(Word.level.rawValue) == true { return nil }
            if Direction(rawValue: token.text) != nil, let next, next.kind == .quoted || next.kind == .word && PlaceWord(rawValue: next.text) != nil { return nil }
        }
        at += 1
        return part
    }

    /// `(gap: wide)` after a placement, if it's there.
    mutating func bracketedGap(after written: String) throws(ScriptError) -> Gap? {
        guard peek()?.kind == .open else { return nil }
        at += 1
        var gap: Gap?
        while true {
            guard let token = take() else { throw error("\(written) opens a ( and never closes it", hint: "write \(written) (gap: wide)") }
            if token.kind == .close { break }
            if token.kind == .comma { continue }
            guard token.kind == .key, token.text == LanguageKey.gap.rawValue else {
                throw error("a placement's brackets hold its gap, not \(token.raw)", hint: "write \(written) (gap: wide)")
            }
            guard let value = take(), value.kind == .word else {
                throw error("\(token.raw) has no value", hint: "write \(written) (gap: wide)")
            }
            let read = try Self.gap(value.text, key: token.raw, error: { error(.invalidValue, $0, hint: $1) })
            if let gap {
                throw error(.duplicate, "\"\(token.text)\" is written twice in the brackets after \(written) (\(gap.written), \(value.text))", hint: "keep one")
            }
            gap = read
        }
        guard let gap else { throw error("\(written) has empty brackets", hint: "write \(written) (gap: wide), or leave them out") }
        return gap
    }

    /// Whether a word or a key opens or closes braces, as JSON and object literals write
    /// attributes: `{text: "x"}` is the key `{text`, `"x"`, and the word `}`.
    static func isBraced(_ token: Token) -> Bool {
        (token.kind == .word || token.kind == .key) && (token.raw.hasPrefix("{") || token.raw.hasPrefix("}"))
    }

    /// Attributes written in braces (`{text: "x"}`, `{"text": "x"}`), refused with the line from
    /// the brace on written without them. JSON quotes every string, but the language's own keys
    /// that take a word (`size`, `gap`, `overlap`, `style`, and an edge's `from` and `to`) refuse a
    /// quoted one, so a quoted value of theirs that reads as one word is written bare; text, a
    /// title and a plugin's attributes keep their quotes.
    func braced(from start: Int, edge: Bool = false) -> ScriptError {
        let bare = Set(LanguageKey.allCases.filter { $0 != .title }.map(\.rawValue) + (edge ? EdgeKey.allCases.map(\.rawValue) : []))
        var parts: [String] = []
        for token in tokens[start...] where token.kind != .comma {
            var raw = Substring(token.raw)
            while raw.first == "{" { raw.removeFirst() }
            while raw.last == "}" { raw.removeLast() }
            // JSON's key: a quoted word, then a colon.
            if raw == ":", let last = parts.last, last.count > 2, last.hasPrefix("\""), last.hasSuffix("\"") {
                parts[parts.count - 1] = "\(last.dropFirst().dropLast()):"
                continue
            }
            if token.kind == .quoted, let key = parts.last, key.hasSuffix(":"), bare.contains(String(key.dropLast())),
               !token.text.isEmpty, token.text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) {
                parts.append(token.text)
                continue
            }
            if !raw.isEmpty { parts.append(String(raw)) }
        }
        return error("attributes are written key: value, without braces", hint: parts.isEmpty ? nil : "write \(parts.joined(separator: " "))")
    }

    /// `text = "x"`, `text="x"` or `text=x` from the token at `index`: an attribute written with
    /// `=`, as its key and value, if the tokens there read so.
    func equalsAttribute(at index: Int) -> (key: String, value: String)? {
        guard index < tokens.count, tokens[index].kind == .word else { return nil }
        let word = tokens[index].text, next = index + 1 < tokens.count ? tokens[index + 1] : nil
        func isKey(_ key: some StringProtocol) -> Bool { !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
        if next?.isWord("=") == true, isKey(word), index + 2 < tokens.count { return (word, tokens[index + 2].raw) }
        guard let equals = word.firstIndex(of: "="), isKey(word[..<equals]) else { return nil }
        let rest = word[word.index(after: equals)...]
        // `A==>B` is an arrow's, not an attribute's.
        guard rest.first != "=", rest.first != ">" else { return nil }
        if !rest.isEmpty { return (String(word[..<equals]), String(rest)) }
        return next.map { (String(word[..<equals]), $0.raw) }
    }

    /// An attribute written with `=`, refused with how it's written.
    func equals(_ written: (key: String, value: String)) -> ScriptError {
        error("an attribute is written key: value, not key = value", hint: "write \(written.key): \(written.value)")
    }

    /// Why a word that opens no placement doesn't.
    func notAPlacement(_ word: Token) -> ScriptError {
        if let part = Part(rawValue: word.text) {
            let direction = part.inward?.opposite.rawValue ?? Direction.above.rawValue
            return error("\(word.raw) is a point of a shape, not a direction from one",
                         hint: "write inside \"A\" \(part.rawValue) to put this in that corner, on \"A\" \(part.rawValue) to straddle it, or a direction, as \(direction) of \"A\"")
        }
        if word.isWord(Word.of.rawValue) || word.isWord(Word.with.rawValue) || word.isWord(Word.and.rawValue) {
            return error("\(word.raw) is out of place", hint: "a placement reads right of \"A\", level with \"A\", inside \"A\" top-left or on \"A\"")
        }
        if let colon = word.text.firstIndex(of: ":"), colon != word.text.startIndex {
            let key = word.text[..<colon]
            return error("\(word.raw) isn't a placement or an attribute", hint: "an attribute is written key: value, with a space after the colon: \(key): \(word.text[word.text.index(after: colon)...])")
        }
        let words = Direction.allCases.map(\.rawValue) + [Word.level.rawValue, Word.inside.rawValue, Word.outside.rawValue, Word.on.rawValue]
        let guess = Suggestions.closest(to: word.text, among: words, limit: 1).first
        return error("\(word.raw) isn't a placement",
                     hint: guess.map { "did you mean \($0)?" }
                        ?? "a placement is above, below, left of, right of (and the corners, as above-left of), level with, inside, outside or on; an attribute is written key: value")
    }
}

extension Attribute.Value {
    /// Its text, whatever its kind.
    var text: String {
        switch self {
        case .word(let text), .quoted(let text), .json(let text): text
        }
    }
}

extension LineParser {
    /// An arrow, or a word written like one.
    static func isArrow(_ token: Token) -> Bool {
        token.kind == .word && (EdgeArrow(rawValue: token.text) != nil || Lexer.looksLikeArrow(token.text))
    }

    /// The hint for an arrow outside an edge statement: the edge the line means, when the arrow
    /// stands between two titles, quoted or not (`API --> DB` is `edge "API" -> "DB"`, with the
    /// nearest arrow there is); else an example.
    func joinHint(arrowAt index: Int) -> String {
        let written = tokens[index].text
        guard index > 0, index + 1 < tokens.count, [tokens[index - 1], tokens[index + 1]].allSatisfy({ end in
            end.kind == .quoted || (end.kind == .word && !Self.isArrow(end))
        }) else {
            return "to join two shapes, write \(Keyword.edge.rawValue) \"A\" \(EdgeArrow.forward.rawValue) \"B\""
        }
        let arrow = EdgeArrow(rawValue: written)
            ?? (written.hasPrefix("<") ? (written.hasSuffix(">") ? .both : .backward) : .forward)
        return "to join two shapes, write \(Keyword.edge.rawValue) \(quote(tokens[index - 1].text)) \(arrow.rawValue) \(quote(tokens[index + 1].text))"
    }
}

extension Lexer {
    /// A word someone may have meant as an arrow: Mermaid's `-->` and `---`, `=>`, `--`.
    static func looksLikeArrow(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy { "-<>=".contains($0) }
    }
}

extension ShapeName {
    /// Whether `text` is written as a script writes a name rather than being a bare title: it starts with a quote, with `#` (an id
    /// alone, or the head of a path: a `#` that is neither is a title that starts with one), or with `board` and a `>`. What a
    /// command that takes a name outside a script (`canvas show`, `canvas capture`) reads with `init(parsing:)`; anything else it
    /// takes as a title as it is.
    public static func isScriptSpelling(_ text: String) -> Bool {
        let trimmed = text.trimmingSpaces
        if trimmed.hasPrefix("\"") { return true }
        if trimmed.hasPrefix(String(idMark)) { return isID(trimmed.dropFirst()) || trimmed.contains(ShapePath.joiner) }
        guard trimmed.hasPrefix(PlaceWord.board.rawValue) else { return false }
        return trimmed.dropFirst(PlaceWord.board.rawValue.count).drop(while: \.isWhitespace).hasPrefix(ShapePath.joiner)
    }

    /// Reads `text` as the one name a script writes: a title in quotes, an id, or a path. Refused, as a script's line is, with a
    /// message that says what is wrong (`syntax`, `not_an_id`) for text that is none, or has anything after the name.
    public init(parsing text: String) throws(ScriptError) {
        let lexed = try Lexer.lex(text, number: 1)
        var parser = LineParser(tokens: lexed.tokens, line: 1, text: lexed.text)
        guard let name = try parser.name() else {
            throw parser.error("\(lexed.text) isn't a name", hint: "a name is a title in double quotes, an id (#…) or a path: \"Payments\" > \"Checkout\"")
        }
        if let extra = parser.peek() {
            throw parser.error("\(extra.raw) comes after the name \(name.written)", hint: "a name is a title in double quotes, an id (#…) or a path: \"Payments\" > \"Checkout\"")
        }
        self = name
    }
}
