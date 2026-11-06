extension PseudoClass {
    /// A word the language doesn't know that a plugin declares with one text (`:drawn-by("Plans")`):
    /// its argument read as exactly one quoted string. `argument` is what the plugin calls it
    /// ("name") and `example` a query that uses it, for a refusal's hint. Refused `bad_argument`:
    /// no parentheses or none inside, something that isn't a string, or more than one string; a
    /// string that is unclosed or holds a bad escape is the language's own `syntax`. The empty
    /// string is a string.
    public func text(argument: String, example: String) throws(QueryError) -> String {
        let name = ":" + self.name
        guard case .raw(let raw, let rawSpan) = self.argument else {
            throw QueryError(.badArgument, "\(name) takes one text in quotes, \(argument).", hint: example, span: span)
        }
        var reader = Lexer(raw, at: rawSpan.offset)
        _ = try reader.skipSpace()
        guard !reader.atEnd else {
            throw QueryError(.badArgument, "\(name) takes one text in quotes, \(argument).", hint: example, span: span)
        }
        var strings: [String] = [], trailingComma = false
        while reader.atQuote {
            strings.append(try reader.string())
            _ = try reader.skipSpace()
            // A comma goes on to another string; with none after it (`"a",` or `"a", `), it is left where it is, so the argument is
            // refused as one that isn't one text, never read as the strings before it.
            guard reader.current == "," else { break }
            let comma = reader.position
            reader.position += 1
            _ = try reader.skipSpace()
            guard reader.atQuote else {
                trailingComma = reader.atEnd
                reader.position = comma
                break
            }
        }
        if reader.atEnd, strings.count == 1 { return strings[0] }
        if reader.atEnd || trailingComma, strings.count > 1 {
            throw QueryError(.badArgument, "\(name) takes one text.",
                             hint: ":is(\(strings.map { "\(name)(\(Printer.quoted($0)))" }.joined(separator: ", ")))", span: rawSpan)
        }
        if trailingComma, strings.count == 1 {
            throw QueryError(.badArgument, "\(name) takes one text in quotes, \(argument).", hint: "\(name)(\(Printer.quoted(strings[0])))", span: rawSpan)
        }
        let words = raw.trimmingWhitespace.filter { !Lexer.quotes.contains($0) }
        throw QueryError(.badArgument, "\(name) takes one text in quotes, \(argument).",
                         hint: words.isEmpty ? example : "\(name)(\(Printer.quoted(words)))", span: rawSpan)
    }
}
