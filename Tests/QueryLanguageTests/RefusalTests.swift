import QueryLanguage
import TestKit

private let operators = "The operators: = != ^= $= *= ~= |= < <= > >=."
private let partStart = "A part starts with a kind, *, a title in quotes, an id, [ or :."
private let escapes = #"In quotes, write \" or \' for a quote, \\ for a backslash and \n for a line break."#
private let oneHead = "A part of a query names its shape once: a kind, *, a title or an id."
private let uuidShape = "An id is 32 hex digits in groups of 8, 4, 4, 4 and 12, as a row gives it."
private let bracketsTest = "can't be read here: a test of an attribute is in brackets"

@MainActor let refusalTests = Suite("Refusals", [
    test("an empty query: nothing but whitespace and comments") {
        expectRefused([
            Refused("", .emptyQuery, "The query is empty.", hint: "* is every shape."),
            Refused("  /* nothing */\n ", .emptyQuery, "The query is empty.", hint: "* is every shape."),
        ])
    },
    test("what isn't closed: a bracket, a parenthesis, a string, a comment") {
        expectRefused([
            Refused(#"[status*="x""#, .syntax, "[ isn't closed.", hint: #"[status*="x"]"#, at: 0, 12),
            Refused("card[rank=3  ", .syntax, "[ isn't closed.", hint: "card[rank=3]", at: 4, 9),
            Refused("card[rank", .syntax, "[ isn't closed.", hint: "card[rank]", at: 4, 5),
            Refused("[", .syntax, "[ isn't closed.", hint: "[]", at: 0, 1),
            Refused(":not(card", .syntax, ":not( isn't closed.", hint: ":not(card)", at: 0, 9),
            Refused(":not(", .syntax, ":not( isn't closed.", hint: ":not()", at: 0, 5),
            Refused(":glows(a", .syntax, ":glows( isn't closed.", hint: ":glows(a)", at: 0, 8),
            Refused(#":edge-to("A", "#, .syntax, ":edge-to( isn't closed.", hint: #":edge-to("A",)"#, at: 0, 14),
            Refused(#""Payments"#, .syntax, "\" isn't closed.", hint: #""Payments""#, at: 0, 9),
            Refused(#"'Pay  "#, .syntax, "' isn't closed.", hint: "'Pay  '", at: 0, 6),
            Refused("card /* open", .syntax, "/* isn't closed.", hint: "card /* open*/", at: 5, 7),
        ])
    },
    test("strings: escapes, line breaks") {
        expectRefused([
            Refused(#""a\q""#, .syntax, #"\q isn't an escape."#, hint: escapes, at: 2, 2, column: 3),
            Refused("\"Pay\nments\"", .syntax, "A string can't hold a line break.", hint: #"Close it before the line ends; \n is a line break inside it."#,
                    at: 0, 4),
            Refused("\"Pay\\\nments\"", .syntax, "A string can't hold a line break.", hint: #"Close it before the line ends; \n is a line break inside it."#,
                    at: 0, 5),
        ])
    },
    test("commas and combinators need something on both sides") {
        expectRefused([
            Refused("card,", .syntax, "A comma is followed by another shape.", hint: "card", at: 4, 1),
            Refused("card , ", .syntax, "A comma is followed by another shape.", hint: "card", at: 5, 1),
            Refused("card, ,box", .syntax, "A comma is followed by another shape.", at: 4, 1),
            Refused(":not(card,)", .syntax, "A comma is followed by another shape.", at: 9, 1),
            Refused(",card", .syntax, "A comma goes between two shapes.", at: 0, 1),
            Refused("card >", .syntax, "> is followed by the shapes it's about.", hint: "card > *", at: 5, 1),
            Refused("card > , box", .syntax, "> is followed by the shapes it's about.", at: 5, 1),
            Refused(":has(>)", .syntax, "> is followed by the shapes it's about.", at: 5, 1),
            Refused("box > > card", .syntax, "> is followed by the shapes it's about.", at: 4, 1),
            Refused(":has(> > card)", .syntax, "> is followed by the shapes it's about.", at: 5, 1),
            Refused("> card", .syntax, "> needs a shape before it: only :has(> …) starts with one.", at: 0, 1),
            Refused(":not(> card)", .syntax, "> needs a shape before it: only :has(> …) starts with one.", at: 5, 1),
        ])
    },
    test("one head, first; a kind and a title are one, the kind first") {
        expectRefused([
            // The two together, once the caller says the kind's shapes can have titles.
            Refused(#""Checkout"card"#, .syntax, oneHead, better: #"card"Checkout""#, at: 10, 4),
            Refused(#""Checkout"[rank]card"#, .syntax, oneHead, better: #"card"Checkout"[rank]"#, at: 16, 4),
            Refused(#"card[rank]"Checkout""#, .syntax, oneHead, better: #"card"Checkout"[rank]"#, at: 10, 10),
            Refused(#"card[rank]" ""#, .syntax, oneHead, at: 10, 3),
            Refused(#"card"Checkout""Auth""#, .syntax, oneHead, at: 14, 6),
            Refused(#"card"Checkout"*"#, .syntax, oneHead, hint: #"card"Checkout""#, at: 14, 1),
            Refused(#"*card"Checkout""#, .syntax, oneHead, hint: #"card"Checkout""#, at: 1, 14),
            Refused(#"card"""#, .syntax, #""" names no shape: a title isn't blank."#, at: 4, 2),
            Refused("card' '", .syntax, #"" " names no shape: a title isn't blank."#, at: 4, 3),
            Refused("card*", .syntax, oneHead, hint: "card", at: 4, 1),
            Refused("*box", .syntax, oneHead, hint: "box", at: 1, 3),
            Refused(#"#00000000-0000-4000-8000-000000000011"X""#, .syntax, oneHead, at: 37, 3),
            Refused("[rank]card", .syntax, "card comes first in its part, before [ and :.", hint: "card[rank]", at: 6, 4),
            Refused(#":glows"A""#, .syntax, #""A" comes first in its part, before [ and :."#, hint: #""A":glows"#, at: 6, 3),
            Refused(#""""#, .syntax, #""" names no shape: a title isn't blank."#, at: 0, 2),
            Refused(#"" ""#, .syntax, #"" " names no shape: a title isn't blank."#, at: 0, 3),
        ])
    },
    test("what can't start a part, or can't follow one") {
        expectRefused([
            Refused("3", .syntax, "3 can't start a part of a query.", hint: partStart, at: 0, 1),
            Refused("!card", .syntax, "! can't start a part of a query.", hint: ":not(…) leaves shapes out.", at: 0, 1),
            Refused("(card)", .syntax, "( only follows a pseudo-class's name: :is(…) groups shapes.", at: 0, 1),
            Refused("card(x)", .syntax, "( only follows a pseudo-class's name: :is(…) groups shapes.", at: 4, 1),
            Refused("card)", .syntax, ") closes nothing.", at: 4, 1),
            Refused("card]", .syntax, "] closes nothing.", at: 4, 1),
            Refused(":not(card]", .syntax, "] closes nothing.", at: 9, 1),
            Refused("card=3", .syntax, "= \(bracketsTest), [rank=3].", at: 4, 1),
            Refused("card!=3", .syntax, "! \(bracketsTest), [rank!=3].", at: 4, 1),
            Refused("card!", .syntax, "! can't be read here.", hint: ":not(…) leaves shapes out.", at: 4, 1),
            Refused("card { color: red }", .syntax, "{ can't be read here: a query is a selector alone, with no { } block.", at: 5, 1),
            Refused("card}", .syntax, "} can't be read here: a query is a selector alone, with no { } block.", at: 4, 1),
            Refused("card%", .syntax, "% can't be read here.", at: 4, 1),
            Refused("@Checkout", .syntax, "@Checkout isn't a shape: a title is in double quotes.", better: #""Checkout""#, at: 0, 9),
            Refused("@", .syntax, "@ doesn't start a shape: a title is in double quotes.", at: 0, 1),
            Refused("\u{201C}Checkout\u{201D}", .syntax, "Titles and text are in straight quotes.", hint: #""Checkout""#, at: 0, 10),
            Refused("\u{2018}API gateway", .syntax, "Titles and text are in straight quotes.", hint: #""API""#, at: 0, 4),
            Refused("\u{201C}\u{201D}", .syntax, "Titles and text are in straight quotes.", at: 0, 2),
        ])
    },
    test("attribute tests: a name, an operator, a value, a flag, ]") {
        expectRefused([
            Refused("[]", .syntax, "An attribute test starts with the attribute's name: [name] or [name=value].", at: 0, 2),
            Refused("[=3]", .syntax, "An attribute test starts with the attribute's name: [name] or [name=value].", at: 0, 2),
            Refused(#"[""]"#, .syntax, "An attribute's name isn't empty.", at: 1, 2),
            Refused("[rank 3]", .syntax, "An operator or ] follows rank.", hint: operators, at: 6, 1),
            Refused("[rank is 3]", .syntax, "An operator or ] follows rank.", hint: operators, at: 6, 2),
            Refused(#"["my attr" 3]"#, .syntax, #"An operator or ] follows "my attr"."#, hint: operators, at: 11, 1),
            Refused("[rank==3]", .syntax, "== isn't an operator.", hint: "Did you mean =?", at: 5, 2),
            Refused("[rank=>3]", .syntax, "=> isn't an operator.", hint: "Did you mean >=?", at: 5, 2),
            Refused("[rank=<3]", .syntax, "=< isn't an operator.", hint: "Did you mean <=?", at: 5, 2),
            Refused("[rank!==3]", .syntax, "!== isn't an operator.", hint: "Did you mean !=?", at: 5, 3),
            Refused("[rank<>3]", .syntax, "<> isn't an operator.", hint: "Did you mean !=?", at: 5, 2),
            Refused("[rank>=>3]", .syntax, ">=> isn't an operator.", at: 5, 3),
            Refused("[rank=]", .syntax, "= needs a value after it.", at: 5, 1),
            Refused("[rank>= ]", .syntax, ">= needs a value after it.", at: 5, 2),
            Refused("[rank= >3]", .syntax, "A value that starts with > is quoted.", at: 7, 1),
            Refused("[status=in review]", .syntax, "A value with spaces is quoted.", hint: #"[status="in review"]"#, at: 8, 9),
            Refused(#"["my attr"=a b  ]"#, .syntax, "A value with spaces is quoted.", hint: #"["my attr"="a b"]"#, at: 11, 3),
            Refused(#"[status="done" x]"#, .syntax, "x can't follow the value: the test ends with ].", at: 15, 1),
            Refused("[status=done i s]", .syntax, "s can't follow the value: the test ends with ].", at: 15, 1),
            Refused("[status=done is]", .syntax, "A value with spaces is quoted.", hint: #"[status="done is"]"#, at: 8, 7),
        ])
    },
    test("pseudo-classes: a name at once, and ( right after it") {
        expectRefused([
            Refused("card:", .syntax, ": is followed by a pseudo-class's name.", at: 4, 1),
            Refused("card:3", .syntax, ": is followed by a pseudo-class's name.", at: 4, 1),
            Refused("card: glows", .syntax, "A pseudo-class's name follows : with no space.", hint: ":glows", at: 4, 1),
            Refused("card: Glows", .syntax, "A pseudo-class's name follows : with no space.", hint: ":glows", at: 4, 1),
            Refused("card:glows (x)", .syntax, "A pseudo-class's ( follows its name with no space.", hint: ":glows(", at: 10, 2),
            Refused("card:not /* x */ (box)", .syntax, "A pseudo-class's ( follows its name with no space.", hint: ":not(", at: 8, 10),
        ])
    },
    test("edge types: joined by one |") {
        expectRefused([
            Refused(":dangling(wire|)", .syntax, "| is followed by another edge type.", at: 14, 1),
            Refused(":dangling(wire||pipe)", .syntax, "Edge types are joined by one |.", at: 14, 2),
            Refused(":dangling(wire, pipe)", .syntax, "Edge types are joined by |, not a comma.", at: 14, 1),
            Refused(#":edge-to("A", wire, pipe)"#, .syntax, "Edge types are joined by |, not a comma.", at: 18, 1),
            Refused(#":edge-to("A", wire|)"#, .syntax, "| is followed by another edge type.", at: 18, 1),
            Refused(":dangling(wire]", .syntax, "] closes nothing.", at: 14, 1),
        ])
    },
    test("a space before a part with no head is stray, in every position; a shape inside the part before it waits on its holding shapes") {
        func stray(_ query: String, before: String, _ after: String, at offset: Int, line: Int = 1, column: Int? = nil,
                   inside: String? = nil) -> Refused {
            Refused(query, .straySpace, "A space before \(after) asks for shapes inside the one before it.",
                    hint: "Write them together for one shape: \(before)\(after).",
                    better: "Write them together for one shape: \(before)\(after); for a shape inside it: \(inside ?? "\(before) *\(after)").",
                    holding: [before], at: offset, after.count, line: line, column: column)
        }
        expectRefused([
            stray("card :glows", before: "card", ":glows", at: 5),
            stray(#""Payments" :glows"#, before: #""Payments""#, ":glows", at: 11),
            stray("#00000000-0000-4000-8000-000000000011 :glows", before: "#00000000-0000-4000-8000-000000000011", ":glows", at: 38),
            stray("* :glows", before: "*", ":glows", at: 2),
            stray("card [rank]", before: "card", "[rank]", at: 5),
            stray("card[rank] :glows[due]", before: "card[rank]", ":glows[due]", at: 11),
            stray("box > card :glows", before: "card", ":glows", at: 11),
            stray("box, card :glows", before: "card", ":glows", at: 10),
            stray(":glows :stacked", before: ":glows", ":stacked", at: 7),
            stray(":not(card :glows)", before: "card", ":glows", at: 10),
            stray(":is(box, card [rank])", before: "card", "[rank]", at: 14),
            stray(":edge-to(card :glows)", before: "card", ":glows", at: 14),
            stray(":between(box, card :glows)", before: "card", ":glows", at: 19),
            // In :has(), where a combinator isn't read, a shape inside it is a :has of its own.
            stray(":has(card :glows)", before: "card", ":glows", at: 10, inside: "card:has(:glows)"),
            stray(":has(> box, card[rank] :glows[due])", before: "card[rank]", ":glows[due]", at: 23, inside: "card[rank]:has(:glows[due])"),
            stray(":not(:has(card :glows))", before: "card", ":glows", at: 15, inside: "card:has(:glows)"),
            stray(":has(:not(card :glows))", before: "card", ":glows", at: 15),
            stray("card\n:glows", before: "card", ":glows", at: 5, line: 2, column: 1),
            stray("card/* inside */:glows", before: "card", ":glows", at: 16),
        ])
        for allowed in ["card > :glows", "card>[rank]", ":not( :glows)", ":has(> :glows)", "  :glows", "card,\n:glows", "card:not(:glows)"] {
            expect(refusal(allowed) == nil, "\(allowed) reads: \(refusal(allowed).map(String.init(describing:)) ?? "")")
        }
    },
    test("CSS with no meaning here is unsupported") {
        expectRefused([
            Refused("card + box", .unsupported, "Shapes have no siblings here, so + has no meaning.", hint: #""Payments" > box lists those on one board."#,
                    at: 5, 1),
            Refused("card ~ box[rank]", .unsupported, "Shapes have no siblings here, so ~ has no meaning.",
                    hint: #""Payments" > box[rank] lists those on one board."#, at: 5, 1),
            Refused("card~", .unsupported, "Shapes have no siblings here, so ~ has no meaning.", hint: #""Payments" > * lists those on one board."#, at: 4, 1),
            Refused("card || box", .unsupported, "Shapes have no columns here, so || has no meaning.", at: 5, 2),
            Refused(":has(+ box)", .unsupported, "Shapes have no siblings here, so + has no meaning.", hint: #""Payments" > box lists those on one board."#,
                    at: 5, 1),
            Refused(":has(~box)", .unsupported, "Shapes have no siblings here, so ~ has no meaning.", hint: #""Payments" > box lists those on one board."#,
                    at: 5, 1),
            Refused("+ card", .unsupported, "Shapes have no siblings here, so + has no meaning.", hint: #""Payments" > card lists those on one board."#,
                    at: 0, 1),
            Refused("|| card", .unsupported, "Shapes have no columns here, so || has no meaning.", at: 0, 2),
            Refused(":not(||card)", .unsupported, "Shapes have no columns here, so || has no meaning.", at: 5, 2),
            Refused("card::before", .unsupported, "::before is a pseudo-element, and shapes have none.", at: 4, 8),
            Refused("ns|card", .unsupported, "Kinds have no namespaces here, so ns|card has no meaning.", hint: "card", at: 0, 7),
            Refused("*|card", .unsupported, "Kinds have no namespaces here, so *|card has no meaning.", hint: "card", at: 0, 6),
            Refused("|card", .unsupported, "Kinds have no namespaces here, so |card has no meaning.", hint: "card", at: 0, 5),
            Refused("card |*", .unsupported, "Kinds have no namespaces here, so |* has no meaning.", hint: "*", at: 5, 2),
            Refused("card|-2", .unsupported, "Kinds have no namespaces here, so | has no meaning.", at: 4, 1),
            Refused("[ns|rank]", .unsupported, "Attributes have no namespaces here, so ns|rank has no meaning.", hint: "[rank]", at: 1, 7),
            Refused("[*|rank]", .unsupported, "Attributes have no namespaces here, so *|rank has no meaning.", hint: "[rank]", at: 1, 6),
            Refused("& card", .unsupported, "& has no meaning here: a query is one selector, not a nested rule.", at: 0, 1),
            Refused("card$x", .unsupported, "$x has no meaning here: a query has no variables.", at: 4, 2),
            Refused("card:nth-child(2n+1)", .unsupported, ":nth-child has no meaning here: shapes on a board have no order a query can count.",
                    at: 4, 10),
            Refused(":NTH-of-type(1)", .unsupported, ":nth-of-type has no meaning here: shapes on a board have no order a query can count.", at: 0, 12),
            Refused(":nth-anything", .unsupported, ":nth-anything has no meaning here: shapes on a board have no order a query can count.", at: 0, 13),
            // Written as :has()s of their own, the parts before a combinator must hold shapes: that hint waits on them.
            Refused(":has(card box)", .unsupported, "Inside :has(), each part stands alone, or after > for what's directly on the board.",
                    better: ":has(card:has(box))", holding: ["card"], at: 5, 8),
            Refused(":has(> card > box)", .unsupported, "Inside :has(), each part stands alone, or after > for what's directly on the board.",
                    better: ":has(> card:has(> box))", holding: ["card"], at: 7, 10),
            Refused(#""P":has("A" > 'B' "C")"#, .unsupported, "Inside :has(), each part stands alone, or after > for what's directly on the board.",
                    better: #":has("A":has(> "B":has("C")))"#, holding: [#""A""#, #""B""#], at: 8, 13),
        ])
    },
    test("what's planned is not built: classes, attributes inside attributes") {
        expectRefused([
            Refused(".Task", .notBuilt, "Shapes aren't typed by schemas yet, so .Task names nothing.",
                    hint: #"Name a kind, or find the word: :contains("Task")."#, at: 0, 5),
            Refused("card.Task", .notBuilt, "Shapes aren't typed by schemas yet, so .Task names nothing.",
                    hint: #"Name a kind, or find the word: :contains("Task")."#, at: 4, 5),
            Refused(".", .syntax, ". can't start a part of a query.", at: 0, 1),
            Refused("[a.b]", .notBuilt, "a.b is an attribute inside an attribute, which a query can't read yet.", at: 1, 3),
            Refused("[a.b.c=1]", .notBuilt, "a.b.c is an attribute inside an attribute, which a query can't read yet.", at: 1, 5),
        ])
    },
    test("# takes an id") {
        expectRefused([
            // A title, once the caller finds a shape that has it.
            Refused("#Checkout", .notAnID, "# takes a shape's id.", better: #""Checkout" is the shape titled so."#, at: 0, 9),
            Refused("card #api-gateway", .notAnID, "# takes a shape's id.", better: #""api-gateway" is the shape titled so."#, at: 5, 12),
            Refused("#", .notAnID, "# takes a shape's id.", at: 0, 1),
            Refused("#[rank]", .notAnID, "# takes a shape's id.", at: 0, 1),
            Refused("#7C1E2A04-4B9E", .notAnID, "# takes a shape's id.", hint: uuidShape, at: 0, 14),
            Refused("#00000000-0000-4000-8000-0000000000111", .notAnID, "# takes a shape's id.", hint: uuidShape, at: 0, 38),
            Refused("#00000000_0000_4000_8000_000000000011", .notAnID, "# takes a shape's id.",
                    better: #""00000000_0000_4000_8000_000000000011" is the shape titled so."#, at: 0, 37),
        ])
    },
    test("the language's words refuse a missing, extra or wrong argument") {
        expectRefused([
            Refused(":not", .badArgument, ":not takes shapes.", hint: #":not("Payments" *)"#, at: 0, 4),
            Refused(":not()", .badArgument, ":not takes shapes.", hint: #":not("Payments" *)"#, at: 0, 6),
            Refused(":is( /* */ )", .badArgument, ":is takes shapes.", hint: #":is("Auth", "Checkout")"#, at: 0, 12),
            Refused("card:inside", .badArgument, ":inside takes shapes.", hint: #":inside("Payments")"#, at: 4, 7),
            Refused(":has()", .badArgument, ":has takes the shapes inside it.", hint: #":has("Refund policy")"#, at: 0, 6),
            Refused(":edge-to", .badArgument, ":edge-to takes a shape, then edge types if any.", hint: #":edge-to("Auth")"#, at: 0, 8),
            Refused(":upstream-of()", .badArgument, ":upstream-of takes a shape, then edge types if any.", hint: #":upstream-of("Auth")"#, at: 0, 14),
            Refused(":between", .badArgument, ":between takes two shapes, then edge types if any.", hint: #":between("Auth", "API gateway")"#, at: 0, 8),
            Refused(#":between("A")"#, .badArgument, ":between takes two shapes, then edge types if any.", hint: #":between("Auth", "API gateway")"#,
                    at: 0, 13),
            Refused(":contains", .badArgument, ":contains takes the text to find, in quotes.", hint: #":contains("retry")"#, at: 0, 9),
            Refused(":contains()", .badArgument, ":contains takes the text to find, in quotes.", hint: #":contains("retry")"#, at: 0, 11),
            Refused(":contains(API)", .badArgument, ":contains takes the text to find, in quotes.", hint: #":contains("API")"#, at: 10, 3),
            Refused(#":contains("a" b)"#, .badArgument, ":contains takes the text to find, in quotes.", hint: #":contains("a b")"#, at: 10, 5),
            Refused(#":contains("")"#, .badArgument, #":contains("") finds nothing: it takes the text to find."#, hint: #":contains("retry")"#, at: 10, 2),
            Refused(#":contains("a", 'b')"#, .badArgument, ":contains takes one text.", hint: #":is(:contains("a"), :contains("b"))"#, at: 10, 8),
            Refused(":top-level(x)", .badArgument, ":top-level takes no argument.", hint: ":top-level", at: 0, 13),
            Refused(":current-board()", .badArgument, ":current-board takes no argument.", hint: ":current-board", at: 0, 16),
            Refused(":dangling()", .badArgument, ":dangling() holds no edge types: leave out the parentheses for every type.", hint: ":dangling", at: 0, 11),
            Refused(#":dangling("x")"#, .badArgument, ":dangling takes edge types, or nothing.", hint: ":dangling", at: 10, 3),
            Refused(#":edge-to("Auth", "Checkout")"#, .badArgument, ":edge-to takes one shape, then edge types: a comma after the shape starts them.",
                    hint: #":edge-to(:is("Auth", "Checkout"))"#, at: 17, 10),
            Refused(#":edge-from("Auth", card[rank], box)"#, .badArgument,
                    ":edge-from takes one shape, then edge types: a comma after the shape starts them.",
                    hint: #":edge-from(:is("Auth", card[rank], box))"#, at: 19, 15),
            Refused(#":edge-to("A", wire pipe)"#, .badArgument, ":edge-to takes one shape, then edge types: a comma after the shape starts them.",
                    hint: #":edge-to(:is("A", wire pipe))"#, at: 14, 9),
            Refused(#":between("A", "B", "C")"#, .badArgument, ":between takes two shapes, then edge types: a comma after them starts the types.",
                    hint: #":between("A", :is("B", "C"))"#, at: 19, 3),
            Refused(#":edge-to("Auth", )"#, .badArgument, "A comma after the shape starts edge types, and none follow it.", hint: #":edge-to("Auth")"#,
                    at: 15, 1),
            Refused(#":between("A", "B",)"#, .badArgument, "A comma after the two shapes starts edge types, and none follow it.",
                    hint: #":between("A", "B")"#, at: 17, 1),
            Refused(#":edge-to("A", wire.Task)"#, .notBuilt, "Shapes aren't typed by schemas yet, so .Task names nothing.",
                    hint: #"Name a kind, or find the word: :contains("Task")."#, at: 18, 5),
        ])
    },
    test("a refusal says where it is: line and column in Characters, its length on that line, and the line") {
        let query = "card,\n  box :glows"
        let error = try require(refusal(query))
        let located = try require(error.located(in: query))
        expectEqual(located.line, 2)
        expectEqual(located.column, 7)
        expectEqual(located.length, 6)
        expectEqual(located.statement, "  box :glows")

        let crlf = "card,\r\n\"👍🏽\" box :x"
        let wide = try require(refusal(crlf).flatMap { $0.located(in: crlf) })
        expectEqual(wide.line, 2, "\r\n is one line break")
        expectEqual(wide.column, 9, "👍🏽 is one Character")
        expectEqual(wide.statement, "\"👍🏽\" box :x")

        let across = QueryError(.syntax, "x", span: at(2, 10)).located(in: "ab cd\nef gh")
        expectEqual(across?.line, 1)
        expectEqual(across?.column, 3)
        expectEqual(across?.length, 3, "a span past its line is cut at the line's end")
        expectEqual(across?.statement, "ab cd")
        expect(QueryError(.syntax, "x", span: at(40, 1)).located(in: "short") == nil, "a span past the text has no place")
        expect(QueryError(.cancelled, "x").located(in: "card") == nil)
    },
    test("a line longer than a refusal quotes is quoted in part, around where it's wrong, the column and length in what's quoted") {
        let long = String(repeating: "a", count: 8_193)
        let past = try require(refusal(long))
        expectEqual(past.reason, .tooLong)
        let whole = try require(past.located(in: long))
        expectEqual(whole.column, 8_193, "unbounded, the line is quoted whole")
        expectEqual(whole.statement.count, 8_193)
        let end = try require(past.located(in: long, quoting: 200))
        expectEqual(end.line, 1)
        expectEqual(end.statement, "…" + String(repeating: "a", count: 200), "its last 200: a quarter before would run past its end")
        expectEqual(end.column, 201, "the character past the limit, after … and the 199 before it")
        expectEqual(end.length, 1)

        let spaces = String(repeating: " ", count: 10_000)
        let blank = try require(refusal(spaces).flatMap { $0.located(in: spaces, quoting: 200) })
        expectEqual(blank.statement, "…" + String(repeating: " ", count: 200) + "…")
        expectEqual(blank.column, 52, "50 before it, after …")
        expectEqual(blank.length, 150, "carets under no more than what's quoted: 1,808 would reach past it")

        let line = String(repeating: "b", count: 300) + "XYZ" + String(repeating: "c", count: 300)
        let text = "card,\n" + line + "\nbox"
        let middle = try require(QueryError(.syntax, "x", span: at(6 + 300, 3)).located(in: text, quoting: 100))
        expectEqual(middle.line, 2)
        expectEqual(middle.statement, "…" + String(repeating: "b", count: 25) + "XYZ" + String(repeating: "c", count: 72) + "…")
        expectEqual(middle.column, 27)
        expectEqual(middle.length, 3)
        let caret = Array(middle.statement)[(middle.column - 1)..<(middle.column - 1 + middle.length)]
        expectEqual(String(caret), "XYZ", "a caret by the column lands on what's wrong")
        let near = try require(QueryError(.syntax, "x", span: at(6 + 10, 3)).located(in: text, quoting: 100))
        expectEqual(near.statement, String(repeating: "b", count: 100) + "…", "near its start: from its start")
        expectEqual(near.column, 11)
        let short = try require(QueryError(.syntax, "x", span: at(0, 4)).located(in: text, quoting: 100))
        expectEqual(short.statement, "card,", "a line no longer than it quotes, whole")
    },
    test("several problems at once: the first leads, and errors holds them all, to the limit") {
        let a = QueryError(.unknownKind, "a", span: at(0, 1)), b = QueryError(.unknownTitle, "b", span: at(2, 1))
        expectEqual(QueryError(collecting: [a]), a)
        let both = QueryError(collecting: [a, b])
        expectEqual(both.reason, .unknownKind)
        expectEqual(both.message, "a")
        expectEqual(both.errors, [a, b])
        expectEqual(QueryError(collecting: [both, QueryError(.noNames, "c")]).errors.map(\.message), ["a", "b", "c"], "flattened")
        let many = (0..<30).map { QueryError(.unknownKind, "\($0)") }
        expectEqual(QueryError(collecting: many).errors.count, QueryLimits.errors)
        expectEqual(String(describing: QueryError(.syntax, "It's wrong.", hint: "Do this.")), "syntax: It's wrong. (Do this.)")
    },
])
