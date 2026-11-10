import Foundation

extension SelectorList {
    /// The query as the language writes it, what an answer reports it ran: words lowercased, one
    /// space around `>`, `, ` between items, `|` between edge types, strings in double quotes
    /// (escaping only `"`, `\` and line breaks), a name in quotes only when it isn't an identifier,
    /// ids in capitals, flags after a space, and no comments. An unknown word's argument is
    /// printed canonically too when it reads as shapes, else as written, trimmed.
    ///
    /// It reads back to the same tree, once the tree is itself read from a canonical form (spans are
    /// where things are in the text, and the canonical text puts them where it puts them):
    /// `SelectorList(parsing: c).canonical == c` for any canonical `c`.
    public var canonical: String { Printer.list(self) }
}

// Each part of a tree printed as the whole query prints it, for a hint that quotes one.

extension ComplexSelector {
    public var canonical: String { Printer.complex(self) }
}

extension Compound {
    public var canonical: String { Printer.compound(self) }
}

extension Head {
    public var canonical: String { Printer.head(self) }
}

extension AttributeTest {
    public var canonical: String { Printer.attribute(self) }
}

extension PseudoClass {
    public var canonical: String { Printer.pseudo(self) }
}

/// Writes trees as text, canonically.
enum Printer {
    static func list(_ list: SelectorList) -> String {
        list.selectors.map(complex).joined(separator: ", ")
    }

    static func complex(_ complex: ComplexSelector) -> String {
        var out = ""
        for (index, compound) in complex.compounds.enumerated() {
            if index > 0 { out += index <= complex.combinators.count && complex.combinators[index - 1] == .child ? " > " : " " }
            out += Printer.compound(compound)
        }
        return out
    }

    static func compound(_ compound: Compound) -> String {
        (compound.head.map(head) ?? "") + compound.filters.map(filter).joined() + (compound.part.map(part) ?? "")
    }

    /// `::part(<row>)`, its id in capitals.
    static func part(_ part: PartSelector) -> String { "::part(" + part.id.uuidString + ")" }

    static func head(_ head: Head) -> String {
        switch head {
        case .kind(let name, _): name
        case .any: "*"
        case .title(let title, _): quoted(title)
        case .kindTitle(let name, _, let title, _): name + quoted(title)
        case .id(let id, _): "#" + id.uuidString
        }
    }

    static func filter(_ filter: Filter) -> String {
        switch filter {
        case .attribute(let test): attribute(test)
        case .pseudo(let pseudo): Printer.pseudo(pseudo)
        }
    }

    static func attribute(_ test: AttributeTest) -> String {
        var out = "[" + name(test.name) + test.path.map { "." + $0 }.joined()
        if let op = test.op, let value = test.value {
            switch value {
            case .bare(let text): out += op.rawValue + text
            case .quoted(let text): out += op.rawValue + quoted(text)
            }
            if let flag = test.flag { out += " " + flag.rawValue }
        }
        return out + "]"
    }

    static func pseudo(_ pseudo: PseudoClass) -> String {
        let name = ":" + pseudo.name
        switch pseudo.argument {
        case .none:
            return name
        case .selectors(let selectors):
            return name + "(" + list(selectors) + ")"
        case .has(let items):
            return name + "(" + items.map { ($0.child ? "> " : "") + compound($0.compound) }.joined(separator: ", ") + ")"
        case .anchored(let anchors, let types):
            return name + "(" + (anchors.map(complex) + (types.map { [typeList($0)] } ?? [])).joined(separator: ", ") + ")"
        case .types(let types):
            return name + "(" + typeList(types) + ")"
        case .text(let text):
            return name + "(" + quoted(text) + ")"
        case .raw(let text, let span):
            return name + "(" + raw(text, at: span) + ")"
        }
    }

    static func typeList(_ terms: [TypeTerm]) -> String {
        terms.map { ($0.only ? Keyword.only.rawValue + " " : "") + $0.name }.joined(separator: "|")
    }

    /// An unknown word's argument: canonical when it reads as shapes, nothing when it's blank, else
    /// as written, trimmed.
    static func raw(_ text: String, at span: QuerySpan) -> String {
        var lexer = Lexer(text, at: span.offset)
        if (try? lexer.skipSpace()) != nil, lexer.atEnd { return "" }
        if let list = try? SelectorList.reading(raw: text, at: span.offset) { return list.canonical }
        return text.trimmingWhitespace
    }

    /// In double quotes, with `"`, `\` and line breaks escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    /// An attribute's name: as it is when it's an identifier, else quoted.
    static func name(_ name: String) -> String {
        guard let first = name.first, Lexer.startsIdentifier(first), name.allSatisfy(Lexer.continuesIdentifier) else { return quoted(name) }
        return name
    }
}
