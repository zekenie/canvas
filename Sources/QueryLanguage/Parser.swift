import Foundation

extension SelectorList {
    /// Reads a query. Leading and trailing whitespace and comments are ignored, and reading stops at
    /// the first thing that can't be read, which is the error thrown (`errors` empty). Besides
    /// syntax it refuses a compound after a descendant space that starts without a head
    /// (`card :x` is `stray_space`; `card > :x` is fine), a second head in a compound, the limits
    /// (`QueryLimits`), CSS with no meaning here (`unsupported`, `not_built`), `#` without a UUID,
    /// and the language's own words given a missing, extra or wrong argument (`bad_argument`).
    /// Kinds, titles, ids, attributes, values and edge types are left as written, for the caller.
    public init(parsing text: String) throws(QueryError) {
        let count = text.count
        guard count <= QueryLimits.characters else {
            throw QueryError(.tooLong, "The query is \(grouped(count)) characters long; a query is at most \(grouped(QueryLimits.characters)).",
                             hint: "Ask several shorter queries.",
                             span: QuerySpan(offset: QueryLimits.characters, length: count - QueryLimits.characters))
        }
        var parser = Parser(Lexer(text))
        self = try parser.query()
    }

    /// A pseudo-class's argument read as shapes, as `:not`'s is, for a word the language doesn't
    /// know that a plugin adds as a relation (`:x(S)`): its spans are the whole query's. The limits
    /// hold within it (its parentheses and compounds were counted as the query was read). Without an
    /// argument, or with a blank one, it's `bad_argument`.
    public init(argumentOf pseudo: PseudoClass) throws(QueryError) {
        switch pseudo.argument {
        case .selectors(let list):
            self = list
        case .raw(let text, let span):
            if let list = try SelectorList.reading(raw: text, at: span.offset) {
                self = list
                return
            }
            fallthrough
        default:
            throw QueryError(.badArgument, ":\(pseudo.name) takes shapes.", hint: #":\#(pseudo.name)("Auth")"#, span: pseudo.span)
        }
    }

    /// A raw argument read as a selector list, its spans from `offset`; nil when it's blank
    /// (whitespace and comments).
    static func reading(raw text: String, at offset: Int) throws(QueryError) -> SelectorList? {
        var parser = Parser(Lexer(text, at: offset))
        _ = try parser.lexer.skipSpace()
        guard !parser.lexer.atEnd else { return nil }
        let list = try parser.selectorList()
        try parser.finish()
        return list
    }
}

/// Reads the grammar over a `Lexer`, one character of lookahead at a time, spaces meaning what
/// they mean where they are: between compounds a descendant combinator, and elsewhere nothing.
struct Parser {
    var lexer: Lexer
    /// Parentheses open around the position.
    var depth = 0
    /// Compounds read so far.
    var compounds = 0
    /// Whether this reads only to find where an unknown word's argument ends (`shapesArgument`):
    /// what it reads is dropped, so it copies no argument's text.
    var probing = false

    init(_ lexer: Lexer) {
        self.lexer = lexer
    }

    var position: Int {
        get { lexer.position }
        set { lexer.position = newValue }
    }
    var current: Character? { lexer.current }
    var atEnd: Bool { lexer.atEnd }
    func peek(_ ahead: Int) -> Character? { lexer.peek(ahead) }
    func span(_ range: Range<Int>) -> QuerySpan { lexer.span(range) }
    /// What a span of the query says, as written.
    func written(_ span: QuerySpan) -> String { lexer.text((span.offset - lexer.base)..<(span.end - lexer.base)) }

    // MARK: Lists, complexes, compounds

    mutating func query() throws(QueryError) -> SelectorList {
        _ = try lexer.skipSpace()
        guard !atEnd else { throw QueryError(.emptyQuery, "The query is empty.", hint: "* is every shape.") }
        let list = try selectorList()
        try finish()
        return list
    }

    /// Nothing but whitespace and comments is left.
    mutating func finish() throws(QueryError) {
        _ = try lexer.skipSpace()
        if let character = current { throw stray(character) }
    }

    /// `complex ( , complex )*`, leaving the position past the whitespace after it.
    mutating func selectorList() throws(QueryError) -> SelectorList {
        var selectors = [try complex()]
        while current == "," {
            try comma()
            selectors.append(try complex())
        }
        return SelectorList(selectors)
    }

    /// Past a comma and the whitespace after it, to what must follow: another item.
    mutating func comma() throws(QueryError) {
        let at = position
        position += 1
        _ = try lexer.skipSpace()
        guard let next = current, next != ",", next != ")" else {
            let hint = atEnd && lexer.isWholeQuery ? lexer.text(0..<at).trimmingTrailingWhitespace : nil
            throw QueryError(.syntax, "A comma is followed by another shape.", hint: hint, span: span(at..<(at + 1)))
        }
    }

    /// `compound ( combinator compound )*`, leaving the position past the whitespace after it.
    /// `inHas`: it's an item of `:has()`, where a combinator isn't read (`hasItems`).
    mutating func complex(inHas: Bool = false) throws(QueryError) -> ComplexSelector {
        var compounds = [try compound()]
        var combinators: [Combinator] = []
        while true {
            let spaced = try lexer.skipSpace()
            guard let character = current else { break }
            if character == ">" {
                let at = position
                position += 1
                _ = try lexer.skipSpace()
                guard let next = current, next != ",", next != ")", next != ">" else {
                    throw QueryError(.syntax, "> is followed by the shapes it's about.", hint: atEnd ? lexer.closed(with: " *") : nil,
                                     span: span(at..<(at + 1)))
                }
                combinators.append(.child)
                compounds.append(try compound())
            } else if character == "+" || character == "~" {
                throw siblings(character)
            } else if character == "|", peek(1) == "|" {
                throw columns()
            } else if spaced, Self.startsCompound(character) {
                let before = compounds[compounds.count - 1]
                let next = try compound()
                guard next.head != nil else { throw straySpace(before, next, inHas: inHas) }
                combinators.append(.descendant)
                compounds.append(next)
            } else {
                break
            }
        }
        let first = compounds[0].span, last = compounds[compounds.count - 1].span
        return ComplexSelector(compounds: compounds, combinators: combinators, span: QuerySpan(offset: first.offset, length: last.end - first.offset))
    }

    /// Whether a character after a space starts a compound (or something refused as one), so the
    /// space is a descendant combinator.
    static func startsCompound(_ character: Character) -> Bool {
        Lexer.startsIdentifier(character) || Lexer.quotes.contains(character) || Lexer.curlyQuotes.contains(character)
            || "*#[:.&$@|(!".contains(character)
    }

    /// `head filter*` or `filter+`.
    mutating func compound() throws(QueryError) -> Compound {
        let start = position
        compounds += 1
        guard compounds <= QueryLimits.compounds else {
            throw QueryError(.tooComplex, "The query has more than \(grouped(QueryLimits.compounds)) parts.", hint: "Ask several shorter queries.",
                             span: span(start..<(start + 1)))
        }
        guard let character = current else {
            throw QueryError(.syntax, "The query ends where a shape should be.", span: span(max(start - 1, 0)..<start))
        }
        var head: Head?
        switch character {
        case "*":
            if peek(1) == "|", peek(2) != "|" { throw namespace(from: start) }
            position += 1
            head = .any
        case "\"", "'":
            head = .title(try title(), span(start..<position))
        case "#":
            head = try id()
        case "[", ":":
            head = nil
        default:
            guard Lexer.startsIdentifier(character) else { throw refusal(at: character) }
            let name = lexer.identifier()
            if current == "|", let next = peek(1), Lexer.startsIdentifier(next) || next == "*" { throw namespace(from: start) }
            let kind = span(start..<position)
            if lexer.atQuote {
                // A title right after the kind, with no space: `card"Payments"`, one head.
                let titleStart = position
                head = .kindTitle(name, kind, title: try title(), span(titleStart..<position))
            } else {
                head = .kind(name, kind)
            }
        }

        var filters: [Filter] = []
        while let character = current {
            if character == "[" {
                filters.append(.attribute(try attribute()))
            } else if character == ":" {
                filters.append(.pseudo(try pseudo()))
            } else if character == "|", peek(1) == "|" {
                break
            } else if character == "*" || character == "#" || Lexer.quotes.contains(character) || Lexer.startsIdentifier(character) {
                throw try secondHead(after: head, filters)
            } else if ".&$@|".contains(character) || Lexer.curlyQuotes.contains(character) {
                throw refusal(at: character)
            } else {
                break
            }
        }
        return Compound(head: head, filters: filters, span: span(start..<position))
    }

    /// A title at the position, `"…"` or `'…'`, refused when it's blank: it would name no shape.
    mutating func title() throws(QueryError) -> String {
        let start = position
        let title = try lexer.string()
        guard !title.allSatisfy(\.isWhitespace) else {
            throw QueryError(.syntax, "\(Printer.quoted(title)) names no shape: a title isn't blank.", span: span(start..<position))
        }
        return title
    }

    /// A head after the compound's head, or after its filters: a compound names its shape once,
    /// first. A kind and a title are one head written together, the kind first (`card"Checkout"`),
    /// which the hint writes wherever the two were.
    mutating func secondHead(after head: Head?, _ filters: [Filter]) throws(QueryError) -> QueryError {
        let start = position
        let second: Head
        switch current {
        case "*":
            position += 1
            second = .any
        case "\"", "'":
            second = .title(try lexer.string(), span(start..<position))
        case "#":
            second = try id()
        default:
            let name = lexer.identifier(), kind = span(start..<position)
            if lexer.atQuote {
                let titleStart = position
                second = .kindTitle(name, kind, title: try lexer.string(), span(titleStart..<position))
            } else {
                second = .kind(name, kind)
            }
        }
        let rest = filters.map(Printer.filter).joined()
        guard let head else {
            return QueryError(.syntax, "\(Printer.head(second)) comes first in its part, before [ and :.", hint: Printer.head(second) + rest,
                              span: span(start..<position))
        }
        let message = "A part of a query names its shape once: a kind, *, a title or an id."
        switch (head, second) {
        case (.kind(let kind, _), .title(let title, _)) where !title.allSatisfy(\.isWhitespace),
             (.title(let title, _), .kind(let kind, _)) where !title.allSatisfy(\.isWhitespace):
            // The two together, where the kind's shapes can have titles (the caller knows).
            return QueryError(.syntax, message, premise: HintPremise(.namedKind(kind), hint: kind + Printer.quoted(title) + rest),
                              span: span(start..<position))
        case (.any, let named), (let named, .any):
            return QueryError(.syntax, message, hint: Printer.head(named) + rest, span: span(start..<position))
        default:
            return QueryError(.syntax, message, span: span(start..<position))
        }
    }

    /// `#` and a UUID, 8-4-4-4-12 hex digits in any case.
    mutating func id() throws(QueryError) -> Head {
        let start = position
        position += 1
        let runStart = position
        while let character = current, Lexer.continuesIdentifier(character) { position += 1 }
        let run = lexer.text(runStart..<position)
        if Self.isUUID(run), let id = UUID(uuidString: run) { return .id(id, span(start..<position)) }
        let message = "# takes a shape's id."
        if run.isEmpty { throw QueryError(.notAnID, message, span: span(start..<position)) }
        if run.allSatisfy({ $0.isASCII && $0.isHexDigit || $0 == "-" }) {
            throw QueryError(.notAnID, message, hint: "An id is 32 hex digits in groups of 8, 4, 4, 4 and 12, as a row gives it.",
                             span: span(start..<position))
        }
        // A title, if some shape has it (the caller knows).
        throw QueryError(.notAnID, message, premise: HintPremise(.titled(run), hint: "\(Printer.quoted(run)) is the shape titled so."),
                         span: span(start..<position))
    }

    static func isUUID(_ text: String) -> Bool {
        guard text.count == 36 else { return false }
        return text.enumerated().allSatisfy { index, character in
            [8, 13, 18, 23].contains(index) ? character == "-" : character.isASCII && character.isHexDigit
        }
    }

    // MARK: Attributes

    /// `[ name ( op value flag? )? ]`.
    mutating func attribute() throws(QueryError) -> AttributeTest {
        let start = position
        position += 1
        _ = try lexer.skipSpace()
        let name: String
        if lexer.atQuote {
            let nameStart = position
            name = try lexer.string()
            guard !name.isEmpty else { throw QueryError(.syntax, "An attribute's name isn't empty.", span: span(nameStart..<position)) }
        } else if current == "*" && peek(1) == "|" || current == "|" {
            throw namespace(from: position, attribute: true)
        } else if lexer.atIdentifier {
            let nameStart = position
            name = lexer.identifier()
            if current == "|", let next = peek(1), Lexer.startsIdentifier(next) || next == "*" {
                throw namespace(from: nameStart, attribute: true)
            }
            if current == ".", let next = peek(1), Lexer.startsIdentifier(next) {
                while current == ".", let next = peek(1), Lexer.startsIdentifier(next) {
                    position += 1
                    _ = lexer.identifier()
                }
                let path = lexer.text(nameStart..<position)
                throw QueryError(.notBuilt, "\(path) is an attribute inside an attribute, which a query can't read yet.", span: span(nameStart..<position))
            }
        } else if atEnd {
            throw unclosedBracket(start)
        } else {
            throw QueryError(.syntax, "An attribute test starts with the attribute's name: [name] or [name=value].", span: span(start..<(position + 1)))
        }

        _ = try lexer.skipSpace()
        if current == "]" {
            position += 1
            return AttributeTest(name: name, span: span(start..<position))
        }
        guard !atEnd else { throw unclosedBracket(start) }
        let opStart = position
        guard let op = readOperator() else {
            let end = lexer.atIdentifier ? position + lexer.identifierLength : position + 1
            throw QueryError(.syntax, "An operator or ] follows \(Printer.name(name)).", hint: "The operators: = != ^= $= *= ~= |= < <= > >=.",
                             span: span(position..<end))
        }
        if let next = current, Self.operatorCharacters.contains(next) {
            var end = position
            while end < lexer.characters.count, Self.operatorCharacters.contains(lexer.characters[end]) { end += 1 }
            let written = lexer.text(opStart..<end)
            let meant = ["==": "=", "===": "=", "=>": ">=", "=<": "<=", "!==": "!=", "<>": "!="][written]
            throw QueryError(.syntax, "\(written) isn't an operator.", hint: meant.map { "Did you mean \($0)?" }, span: span(opStart..<end))
        }
        _ = try lexer.skipSpace()
        guard let first = current else { throw unclosedBracket(start) }
        guard first != "]" else { throw QueryError(.syntax, "\(op.rawValue) needs a value after it.", span: span(opStart..<(opStart + op.rawValue.count))) }
        let valueStart = position
        let value: Literal
        if lexer.atQuote {
            value = .quoted(try lexer.string())
        } else if Self.operatorCharacters.contains(first) {
            throw QueryError(.syntax, "A value that starts with \(first) is quoted.", span: span(valueStart..<(valueStart + 1)))
        } else {
            value = .bare(lexer.bare())
        }

        let spaced = try lexer.skipSpace()
        var flag: CaseFlag?
        if spaced || value.isQuoted, let letter = current, let caseFlag = CaseFlag(rawValue: asciiLowercased(String(letter))),
           peek(1).map(Lexer.continuesIdentifier) != true {
            flag = caseFlag
            position += 1
            _ = try lexer.skipSpace()
        }
        guard current == "]" else {
            guard let character = current else { throw unclosedBracket(start) }
            if case .bare = value, flag == nil, let close = closingBracket() {
                let words = lexer.text(valueStart..<close).trimmingTrailingWhitespace
                throw QueryError(.syntax, "A value with spaces is quoted.",
                                 hint: "[\(Printer.name(name))\(op.rawValue)\(Printer.quoted(words))]", span: span(valueStart..<(valueStart + words.count)))
            }
            throw QueryError(.syntax, "\(character) can't follow the value: the test ends with ].", span: span(position..<(position + 1)))
        }
        position += 1
        return AttributeTest(name: name, op: op, value: value, flag: flag, span: span(start..<position))
    }

    static let operatorCharacters: Set<Character> = ["=", "<", ">", "!"]

    /// The operator at the position, the longest first; nil for none.
    mutating func readOperator() -> Operator? {
        if let first = current, let second = peek(1), let op = Operator(rawValue: String([first, second])) {
            position += 2
            return op
        }
        if let first = current, let op = Operator(rawValue: String(first)) {
            position += 1
            return op
        }
        return nil
    }

    /// The `]` a bare value with spaces runs to, if one comes before a quote or a line break.
    func closingBracket() -> Int? {
        var index = position
        while index < lexer.characters.count {
            let character = lexer.characters[index]
            if character == "]" { return index }
            if Lexer.quotes.contains(character) || character.isNewline || character == "[" { return nil }
            index += 1
        }
        return nil
    }

    func unclosedBracket(_ start: Int) -> QueryError {
        QueryError(.syntax, "[ isn't closed.", hint: lexer.closed(with: "]"), span: span(start..<lexer.characters.count))
    }

    // MARK: Pseudo-classes

    /// `:name` or `:name(argument)`, the argument read by the word's signature.
    mutating func pseudo() throws(QueryError) -> PseudoClass {
        let start = position
        position += 1
        if current == ":" {
            position += 1
            let name = lexer.identifier()
            throw QueryError(.unsupported, "::\(name) is a pseudo-element, and shapes have none.", span: span(start..<position))
        }
        guard lexer.atIdentifier else {
            let colon = span(start..<(start + 1))
            if try lexer.skipSpace(), lexer.atIdentifier {
                throw QueryError(.syntax, "A pseudo-class's name follows : with no space.", hint: ":" + asciiLowercased(lexer.identifier()), span: colon)
            }
            throw QueryError(.syntax, ": is followed by a pseudo-class's name.", span: colon)
        }
        let name = asciiLowercased(lexer.identifier())
        let nameSpan = span(start..<position)
        if name.hasPrefix("nth-"), let invention = KnownInventions.invention(for: name) {
            throw QueryError(invention.reason, invention.message, hint: invention.hint(argument: nil), span: nameSpan)
        }
        let word = Word(rawValue: name)
        if current?.isWhitespace == true || lexer.atComment {
            let after = position
            _ = try lexer.skipSpace()
            if current == "(" {
                throw QueryError(.syntax, "A pseudo-class's ( follows its name with no space.", hint: ":\(name)(", span: span(after..<(position + 1)))
            }
            position = after
        }
        guard current == "(" else {
            if let word, word.needsArgument { throw missingArgument(word, span: nameSpan) }
            return PseudoClass(name: name, span: nameSpan, nameSpan: nameSpan)
        }

        let open = position
        depth += 1
        defer { depth -= 1 }
        guard depth <= QueryLimits.depth else { throw tooDeep(open) }
        position += 1
        guard let word else {
            let range = if let shapes = try shapesArgument(open: open) { shapes } else { try rawArgument(open: open, start: start, name: name) }
            return PseudoClass(name: name, argument: .raw(probing ? "" : lexer.text(range), span(range)), span: span(start..<position),
                               nameSpan: nameSpan)
        }
        let argument: PseudoArgument
        switch word.signature {
        case .none:
            _ = try rawArgument(open: open, start: start, name: name)
            throw QueryError(.badArgument, ":\(name) takes no argument.", hint: ":\(name)", span: span(start..<position))
        case .selectors:
            try openArgument(word, start: start)
            argument = .selectors(try selectorList())
            try close(start: start, name: name)
        case .has:
            try openArgument(word, start: start)
            argument = .has(try hasItems())
            try close(start: start, name: name)
        case .anchor, .twoAnchors:
            try openArgument(word, start: start)
            argument = try anchored(word, start: start)
            try close(start: start, name: name)
        case .types:
            _ = try lexer.skipSpace()
            if current == ")" {
                position += 1
                throw QueryError(.badArgument, ":\(name)() holds no edge types: leave out the parentheses for every type.", hint: ":\(name)",
                                 span: span(start..<position))
            }
            guard !atEnd else { throw unclosedParenthesis(start: start, name: name) }
            guard lexer.atIdentifier else {
                let range = try rawArgument(open: open, start: start, name: name)
                throw QueryError(.badArgument, ":\(name) takes \(word.takes).", hint: ":\(name)", span: span(range))
            }
            argument = .types(try typeList())
            if current == "," { throw commaBetweenTypes() }
            try close(start: start, name: name)
        case .text:
            let range = try rawArgument(open: open, start: start, name: name)
            argument = .text(try text(of: range, word: word, span: span(start..<position)))
        }
        return PseudoClass(name: name, argument: argument, span: span(start..<position), nameSpan: nameSpan)
    }

    /// Past the whitespace after an argument's `(`, refusing an empty argument.
    mutating func openArgument(_ word: Word, start: Int) throws(QueryError) {
        _ = try lexer.skipSpace()
        if current == ")" {
            position += 1
            throw missingArgument(word, span: span(start..<position))
        }
        guard !atEnd else { throw unclosedParenthesis(start: start, name: word.rawValue) }
    }

    /// Past an argument's `)`, after the whitespace before it.
    mutating func close(start: Int, name: String) throws(QueryError) {
        _ = try lexer.skipSpace()
        guard let character = current else { throw unclosedParenthesis(start: start, name: name) }
        guard character == ")" else { throw stray(character) }
        position += 1
    }

    /// `:has`'s items: `> compound` or `compound`, commas OR.
    mutating func hasItems() throws(QueryError) -> [HasItem] {
        var items: [HasItem] = []
        while true {
            var child = false
            if current == ">" {
                let at = position
                child = true
                position += 1
                _ = try lexer.skipSpace()
                guard let next = current, next != ",", next != ")", next != ">" else {
                    throw QueryError(.syntax, "> is followed by the shapes it's about.", span: span(at..<(at + 1)))
                }
            }
            let complex = try complex(inHas: true)
            guard complex.compounds.count == 1 else {
                // `:has(A > B)` is `:has(A:has(> B))`: each combinator becomes a `:has` on the compound before it,
                // which must then hold shapes, so the hint waits for the caller to say they can.
                var rewritten = Printer.compound(complex.compounds[complex.compounds.count - 1])
                for index in stride(from: complex.compounds.count - 2, through: 0, by: -1) {
                    let child = complex.combinators[index] == .child ? "> " : ""
                    rewritten = "\(Printer.compound(complex.compounds[index])):has(\(child)\(rewritten))"
                }
                throw QueryError(.unsupported, "Inside :has(), each part stands alone, or after > for what's directly inside.",
                                 premise: HintPremise(.holdShapes(Array(complex.compounds.dropLast())), hint: ":has(\(child ? "> " : "")\(rewritten))"),
                                 span: complex.span)
            }
            items.append(HasItem(child: child, compound: complex.compounds[0]))
            guard current == "," else { return items }
            try comma()
        }
    }

    /// An edge word's anchor, or `:between`'s two, then the edge types after a comma.
    mutating func anchored(_ word: Word, start: Int) throws(QueryError) -> PseudoArgument {
        var anchors = [try complex()]
        if word == .between {
            if current == ")" {
                position += 1
                throw QueryError(.badArgument, ":between takes two shapes, then edge types if any.", hint: word.example, span: span(start..<position))
            }
            guard current == "," else { throw current.map(stray) ?? unclosedParenthesis(start: start, name: word.rawValue) }
            try comma()
            anchors.append(try complex())
        }
        guard current == "," else { return .anchored(anchors, types: nil) }
        let at = position
        position += 1
        _ = try lexer.skipSpace()
        guard !atEnd else { throw unclosedParenthesis(start: start, name: word.rawValue) }
        guard current != ")" else {
            throw QueryError(.badArgument, "A comma after \(word == .between ? "the two shapes" : "the shape") starts edge types, and none follow it.",
                             hint: ":\(word.rawValue)(\(anchors.map(Printer.complex).joined(separator: ", ")))", span: span(at..<(at + 1)))
        }

        // Edge types; else shapes, which the comma doesn't take here.
        let afterComma = position
        var typesProblem: QueryError?
        if lexer.atIdentifier {
            var types: [TypeTerm]?
            do throws(QueryError) {
                types = try typeList()
            } catch {
                typesProblem = error
            }
            if let types, current == ")" { return .anchored(anchors, types: types) }
            if types != nil, current == "," { throw commaBetweenTypes() }
        }
        position = afterComma
        let rest: SelectorList
        do throws(QueryError) {
            rest = try selectorList()
        } catch {
            throw typesProblem ?? error
        }
        guard let character = current else { throw typesProblem ?? unclosedParenthesis(start: start, name: word.rawValue) }
        guard character == ")" else { throw typesProblem ?? stray(character) }
        var rewritten = anchors.map(Printer.complex)
        let last = rewritten.removeLast()
        rewritten.append(":is(\(last), \(Printer.list(rest)))")
        let takes = word == .between ? "two shapes, then edge types: a comma after them starts the types."
            : "one shape, then edge types: a comma after the shape starts them."
        let restStart = lexer.base + afterComma
        throw QueryError(.badArgument, ":\(word.rawValue) takes \(takes)", hint: ":\(word.rawValue)(\(rewritten.joined(separator: ", ")))",
                         span: QuerySpan(offset: restStart, length: rest.selectors[rest.selectors.count - 1].span.end - restStart))
    }

    /// `type-term ( | type-term )*`, leaving the position past the whitespace after it.
    mutating func typeList() throws(QueryError) -> [TypeTerm] {
        var terms = [typeTerm()]
        while true {
            _ = try lexer.skipSpace()
            guard current == "|" else { return terms }
            let bar = position
            guard peek(1) != "|" else { throw QueryError(.syntax, "Edge types are joined by one |.", span: span(bar..<(bar + 2))) }
            position += 1
            _ = try lexer.skipSpace()
            guard lexer.atIdentifier else { throw QueryError(.syntax, "| is followed by another edge type.", span: span(bar..<(bar + 1))) }
            terms.append(typeTerm())
        }
    }

    /// `T` or `only T`, at an identifier. `only` with no type after it is a type named so.
    mutating func typeTerm() -> TypeTerm {
        let start = position
        let word = lexer.identifier()
        if asciiLowercased(word) == Keyword.only.rawValue {
            let after = position
            if (try? lexer.skipSpace()) == true, lexer.atIdentifier {
                return TypeTerm(name: lexer.identifier(), only: true, span: span(start..<position))
            }
            position = after
        }
        return TypeTerm(name: word, span: span(start..<position))
    }

    /// `:contains`'s argument: one string, not empty.
    func text(of range: Range<Int>, word: Word, span whole: QuerySpan) throws(QueryError) -> String {
        var reader = Lexer(lexer.text(range), at: lexer.base + range.lowerBound)
        var strings: [String] = []
        _ = try reader.skipSpace()
        while reader.atQuote {
            strings.append(try reader.string())
            _ = try reader.skipSpace()
            guard reader.current == ",", reader.peek(1) != nil else { break }
            reader.position += 1
            _ = try reader.skipSpace()
        }
        let argument = range.isEmpty ? whole : span(range)
        let name = ":" + word.rawValue
        if reader.atEnd, strings.count == 1 {
            guard !strings[0].isEmpty else {
                throw QueryError(.badArgument, #"\#(name)("") finds nothing: it takes the text to find."#, hint: word.example, span: argument)
            }
            return strings[0]
        }
        if reader.atEnd, strings.count > 1 {
            throw QueryError(.badArgument, "\(name) takes one text.",
                             hint: ":is(\(strings.map { "\(name)(\(Printer.quoted($0)))" }.joined(separator: ", ")))", span: argument)
        }
        let words = lexer.text(range).trimmingWhitespace.filter { !Lexer.quotes.contains($0) }
        throw QueryError(.badArgument, "\(name) takes \(word.takes).", hint: words.isEmpty ? word.example : "\(name)(\(Printer.quoted(words)))",
                         span: argument)
    }

    /// An unknown word's argument read as shapes, as a plugin's relation reads it
    /// (`SelectorList(argumentOf:)`), so where it ends is the grammar's (a test's value may hold a
    /// parenthesis, `[text*=:)]`) and its compounds count toward the limit: the position past its
    /// `)`, and where it is; nil, moving nothing, when it doesn't read as shapes. Past a limit it's
    /// too complex whatever it was meant to be.
    mutating func shapesArgument(open: Int) throws(QueryError) -> Range<Int>? {
        var probe = self
        probe.position = open + 1
        probe.probing = true
        do throws(QueryError) {
            _ = try probe.lexer.skipSpace()
            guard !probe.atEnd, probe.current != ")" else { return nil }
            _ = try probe.selectorList()
        } catch {
            if error.reason == .tooComplex { throw error }
            return nil
        }
        guard probe.current == ")" else { return nil }
        let range = (open + 1)..<probe.position
        position = probe.position + 1
        compounds = probe.compounds
        return range
    }

    /// The text between an argument's parentheses as written, to the `)` that closes it (past
    /// strings, comments and the parentheses inside it), leaving the position past it.
    mutating func rawArgument(open: Int, start: Int, name: String) throws(QueryError) -> Range<Int> {
        position = open + 1
        let textStart = position
        var level = 0
        while let character = current {
            if lexer.atQuote {
                _ = try lexer.string()
            } else if lexer.atComment {
                _ = try lexer.skipSpace()
            } else if character == "(" {
                level += 1
                guard depth + level <= QueryLimits.depth else { throw tooDeep(position) }
                position += 1
            } else if character == ")" {
                guard level > 0 else {
                    position += 1
                    return textStart..<(position - 1)
                }
                level -= 1
                position += 1
            } else {
                position += 1
            }
        }
        throw unclosedParenthesis(start: start, name: name)
    }

    // MARK: Refusals

    func commaBetweenTypes() -> QueryError {
        QueryError(.syntax, "Edge types are joined by |, not a comma.", span: span(position..<(position + 1)))
    }

    func missingArgument(_ word: Word, span: QuerySpan) -> QueryError {
        QueryError(.badArgument, ":\(word.rawValue) takes \(word.takes).", hint: word.example, span: span)
    }

    func unclosedParenthesis(start: Int, name: String) -> QueryError {
        QueryError(.syntax, ":\(name)( isn't closed.", hint: lexer.closed(with: ")"), span: span(start..<lexer.characters.count))
    }

    func tooDeep(_ open: Int) -> QueryError {
        QueryError(.tooComplex, "The query nests more than \(QueryLimits.depth) levels of parentheses.", hint: "Ask several shorter queries.",
                   span: span(open..<(open + 1)))
    }

    /// A compound after a descendant space with no head: the space asks for shapes inside the
    /// compound before it, which is rarely what's meant. The hint writes them together; and, once
    /// the caller says the compound before can hold shapes, a shape inside it too: with a head
    /// after the space, or in `:has()`, where a combinator isn't read, as a `:has` of its own.
    func straySpace(_ before: Compound, _ next: Compound, inHas: Bool) -> QueryError {
        let first = written(before.span), second = written(next.span)
        let together = "Write them together for one shape: \(first)\(second)"
        let inside = inHas ? "\(first):has(\(second))" : "\(first) *\(second)"
        return QueryError(.straySpace, "A space before \(second) asks for shapes inside the one before it.", hint: together + ".",
                          premise: HintPremise(.holdShapes([before]), hint: "\(together); for a shape inside it: \(inside)."), span: next.span)
    }

    /// `+` or `~` at the position, between compounds or where one starts (`:has(+ x)`, CSS's next sibling).
    func siblings(_ combinator: Character) -> QueryError {
        var probe = self
        probe.position += 1
        _ = try? probe.lexer.skipSpace()
        let next = (try? probe.compound()).map { written($0.span) } ?? "*"
        return QueryError(.unsupported, "Shapes have no siblings here, so \(combinator) has no meaning.",
                          hint: "\"Payments\" > \(next) lists those directly inside one shape.", span: span(position..<(position + 1)))
    }

    /// `||` at the position.
    func columns() -> QueryError {
        QueryError(.unsupported, "Shapes have no columns here, so || has no meaning.", span: span(position..<(position + 2)))
    }

    /// `ns|x`, `*|x` or `|x`, from the namespace's start: the refusal, having read the name after the bar.
    mutating func namespace(from start: Int, attribute: Bool = false) -> QueryError {
        while let character = current, character != "|" { position += 1 }
        if !atEnd { position += 1 }
        let local: String
        if current == "*" {
            position += 1
            local = "*"
        } else {
            local = lexer.atIdentifier ? lexer.identifier() : ""
        }
        let written = lexer.text(start..<position)
        return QueryError(.unsupported, "\(attribute ? "Attributes" : "Kinds") have no namespaces here, so \(written) has no meaning.",
                          hint: local.isEmpty ? nil : attribute ? "[\(local)]" : local, span: span(start..<position))
    }

    /// What can't start a compound, at the position: the refusal, having read what it names.
    mutating func refusal(at character: Character) -> QueryError {
        let start = position
        position += 1
        switch character {
        case ".":
            guard lexer.atIdentifier else { return QueryError(.syntax, ". can't start a part of a query.", span: span(start..<position)) }
            let name = lexer.identifier()
            return QueryError(.notBuilt, "Shapes aren't typed by schemas yet, so .\(name) names nothing.",
                              hint: "Name a kind, or find the word: :contains(\(Printer.quoted(name))).", span: span(start..<position))
        case "&":
            return QueryError(.unsupported, "& has no meaning here: a query is one selector, not a nested rule.", span: span(start..<position))
        case "$":
            let name = lexer.identifier()
            return QueryError(.unsupported, "$\(name) has no meaning here: a query has no variables.", span: span(start..<position))
        case "@":
            guard lexer.atIdentifier else {
                return QueryError(.syntax, "@ doesn't start a shape: a title is in double quotes.", span: span(start..<position))
            }
            let name = lexer.identifier()
            // The title in quotes, if some shape has it (the caller knows).
            return QueryError(.syntax, "@\(name) isn't a shape: a title is in double quotes.",
                              premise: HintPremise(.titled(name), hint: Printer.quoted(name)), span: span(start..<position))
        case "+", "~":
            position = start
            return siblings(character)
        case "|":
            position = start
            return peek(1) == "|" ? columns() : namespace(from: start)
        case "(":
            return QueryError(.syntax, "( only follows a pseudo-class's name: :is(…) groups shapes.", span: span(start..<position))
        case ">":
            return QueryError(.syntax, "> needs a shape before it: only :has(> …) starts with one.", span: span(start..<position))
        case ",":
            return QueryError(.syntax, "A comma goes between two shapes.", span: span(start..<position))
        case "!":
            return QueryError(.syntax, "! can't start a part of a query.", hint: ":not(…) leaves shapes out.", span: span(start..<position))
        default:
            if Lexer.curlyQuotes.contains(character) {
                var end = position
                while end < lexer.characters.count, !Lexer.curlyQuotes.contains(lexer.characters[end]), !lexer.characters[end].isNewline { end += 1 }
                let closed = end < lexer.characters.count && Lexer.curlyQuotes.contains(lexer.characters[end])
                let inside = closed ? lexer.text(position..<end) : String(lexer.text(position..<end).prefix { !$0.isWhitespace })
                position = closed ? end + 1 : position + inside.count
                return QueryError(.syntax, "Titles and text are in straight quotes.",
                                  hint: inside.allSatisfy(\.isWhitespace) ? nil : Printer.quoted(inside), span: span(start..<position))
            }
            return QueryError(.syntax, "\(character) can't start a part of a query.",
                              hint: "A part starts with a kind, *, a title in quotes, an id, [ or :.", span: span(start..<position))
        }
    }

    /// A character where the query, or an argument, should have ended.
    func stray(_ character: Character) -> QueryError {
        let at = span(position..<(position + 1))
        switch character {
        case ")", "]":
            return QueryError(.syntax, "\(character) closes nothing.", span: at)
        case "(":
            return QueryError(.syntax, "( only follows a pseudo-class's name: :is(…) groups shapes.", span: at)
        case "=", "<", "^":
            return QueryError(.syntax, "\(character) can't be read here: a test of an attribute is in brackets, [rank=3].", span: at)
        case "!" where peek(1) == "=":
            return QueryError(.syntax, "! can't be read here: a test of an attribute is in brackets, [rank!=3].", span: at)
        case "!":
            return QueryError(.syntax, "! can't be read here.", hint: ":not(…) leaves shapes out.", span: at)
        case "{", "}":
            return QueryError(.syntax, "\(character) can't be read here: a query is a selector alone, with no { } block.", span: at)
        default:
            return QueryError(.syntax, "\(character) can't be read here.", span: at)
        }
    }
}

extension Word {
    /// Whether the word must have parentheses.
    var needsArgument: Bool {
        switch signature {
        case .none: false
        case .types(let optional): !optional
        case .selectors, .has, .anchor, .twoAnchors, .text: true
        }
    }
}

extension Literal {
    var isQuoted: Bool {
        if case .quoted = self { true } else { false }
    }
}
