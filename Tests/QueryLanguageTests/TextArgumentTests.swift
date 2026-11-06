import QueryLanguage
import TestKit

// A word the language doesn't know that a plugin declares with one quoted text (`:tagged("x")`, a fixture word):
// the parser keeps its argument raw, prints it as a string (a fixed point), and `PseudoClass.text(argument:example:)`
// reads it as exactly one string, refusing anything else `bad_argument`, where the argument is.

private let example = #"card:tagged("Plans")"#

/// The text of the last filter of the query's first compound, read as a text word's argument, or why not.
private func text(_ query: String) throws -> Result<String, QueryError> {
    let filters = try parse(query).selectors[0].compounds[0].filters
    guard case .pseudo(let pseudo) = filters.last else { throw QueryError(.syntax, "no pseudo-class") }
    do throws(QueryError) {
        return .success(try pseudo.text(argument: "name", example: example))
    } catch {
        return .failure(error)
    }
}

private func refusedText(_ query: String) throws -> QueryError? {
    if case .failure(let error) = try text(query) { error } else { nil }
}

@MainActor let textArgumentTests = Suite("A word with a text", [
    test("its canonical form is the text in double quotes, a fixed point, escaped as the language escapes strings") {
        expectCanonical(#":tagged("Plans")"#, #":tagged("Plans")"#)
        expectCanonical(#":tagged(   "Plans"  )"#, #":tagged("Plans")"#, sameTree: false)
        expectCanonical(":tagged('Plans')", #":tagged("Plans")"#, sameTree: false)
        expectCanonical(#"card:tagged("a \"b\" \\ c\nd")"#, #"card:tagged("a \"b\" \\ c\nd")"#)
        expectCanonical(#":tagged("it's")"#, #":tagged("it's")"#)
        expectCanonical(#":tagged("(a, b)") > card"#, #":tagged("(a, b)") > card"#)
        expectCanonical(#":not(:tagged("x")), :tagged("y"):tagged("z")"#, #":not(:tagged("x")), :tagged("y"):tagged("z")"#)
        expectCanonical(#":tagged("")"#, #":tagged("")"#)
    },
    test("the text is the one string, with its escapes read") {
        expectEqual(try text(#"card:tagged("Plans")"#), .success("Plans"))
        expectEqual(try text(#"card:tagged( 'Plans' /* c */ )"#), .success("Plans"))
        expectEqual(try text(#":tagged("a \"b\" \\ c\nd")"#), .success("a \"b\" \\ c\nd"))
        expectEqual(try text(#":tagged("a)b")"#), .success("a)b"), "a parenthesis in the string doesn't close the argument")
        expectEqual(try text(#":tagged("")"#), .success(""), "the empty string is a string")
    },
    test("none is refused, with the example") {
        for query in [":tagged", ":tagged()", ":tagged(  )"] {
            let error = try require(try refusedText(query), query)
            expectEqual(error.reason, .badArgument, query)
            expect(error.message.contains(":tagged takes one text in quotes, name"), error.message)
            expectEqual(error.hint, example, query)
        }
    },
    test("something that isn't a string is refused, with the string as the hint") {
        let bare = try require(try refusedText("card:tagged(Plans)"))
        expectEqual(bare.reason, .badArgument)
        expectEqual(bare.hint, #":tagged("Plans")"#)
        expectEqual(bare.span, at(12, 5), "where the argument is")
        let shapes = try require(try refusedText(#":tagged(card "Plans")"#))
        expectEqual(shapes.reason, .badArgument)
        let number = try require(try refusedText(":tagged(12)"))
        expectEqual(number.hint, #":tagged("12")"#)
        let trailing = try require(try refusedText(#":tagged("a" b)"#))
        expectEqual(trailing.reason, .badArgument)
        // a comma with no text after it, with or without a space, is refused alike, never read as the text before it
        for written in [#":tagged("a",)"#, #":tagged("a", )"#] {
            let comma = try require(try refusedText(written))
            expectEqual(comma.reason, .badArgument, written)
            expectEqual(comma.hint, #":tagged("a")"#, written)
        }
    },
    test("two are refused: one text, and :is for either") {
        let error = try require(try refusedText(#":tagged("a", "b")"#))
        expectEqual(error.reason, .badArgument)
        expect(error.message.contains(":tagged takes one text."), error.message)
        expectEqual(error.hint, #":is(:tagged("a"), :tagged("b"))"#)
    },
    test("a string that is not closed or holds a bad escape is the language's own syntax error") {
        expectEqual(refusal(#":tagged("a)"#)?.reason, .syntax)
        expectEqual(refusal(#":tagged("a\q")"#)?.reason, .syntax)
    },
    test("a word that was given no argument has none to read") {
        let error = try require(try refusedText(":tagged"))
        expectEqual(error.reason, .badArgument)
    },
])
