import DrawScript
import TestKit

// A shape the file has is named by its title, or, for a shape with none, by its id, in the query language's spelling
// (`#7C1E2A04-…`), at every place a statement names one: an edge's ends, `delete` and `delete edge`, a placement's target,
// `in`, a shape statement's own name and `share:`'s host. DrawScript keeps the id as text and checks only its shape.

private let one = "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11"
private let two = "b3d9f0e1-6a52-4c8d-a7e4-1f2b9c3d5e60"

@MainActor let idTests = Suite("Ids as names", [
    test("an edge's ends, either of them, in any arrow's direction") {
        guard case .edge(let edge) = try parse(#"edge "Checkout" -> #\#(one) text: "x""#) else { return expect(false, "an edge") }
        expectEqual(edge.from, .title("Checkout"))
        expectEqual(edge.to, .id(one))
        expectEqual(edge.attributes, [Attribute(key: "text", value: .quoted("x"))])
        expectEqual(edge.written, #""Checkout" -> #\#(one)"#)
        guard case .edge(let both) = try parse("edge #\(one) <- #\(two)") else { return expect(false, "an edge") }
        expectEqual(both.from, .id(two), "<- writes the ends the other way round")
        expectEqual(both.to, .id(one))
        expectEqual(both.written, "#\(one) <- #\(two)", "written round-trips")
        guard case .edge(let reading) = try parse(#"edge "A" <-> #\#(one)"#) else { return expect(false, "an edge") }
        expectEqual(reading.bothHeads, true)
    },
    test("delete a shape by its id, or the edges between ends named by id or title") {
        expectEqual(try parse("delete #\(one)"), .delete(.shape(.id(one))))
        expectEqual(try parse(#"delete edge #\#(one) -> "B" is: "T""#),
                    .delete(.edges(from: .id(one), to: "B", eitherWay: false, attributes: [Attribute(key: "is", value: .quoted("T"))])))
        expectEqual(try parse("delete edge \"A\" <-> #\(two)"), .delete(.edges(from: "A", to: .id(two), eitherWay: true)))
        expectEqual(parseError("delete #\(one) #\(two)")?.message, "delete #\(one): delete takes one title, and nothing after it (#\(two))")
    },
    test("a shape statement may name the shape it restates by its id, with its attributes and placements") {
        let note = try shape(#"sticky-note #\#(one) text: "x" right of "A""#)
        expectEqual(note.name, .id(one))
        expectEqual(note.title, nil, "an id is not a title")
        expectEqual(note.attributes, [Attribute(key: "text", value: .quoted("x"))])
        expectEqual(note.clauses.map(\.written), [#"right of "A""#])
        let titled = try shape(#"sticky-note "A" text: "x""#)
        expectEqual(titled.name, .title("A"))
        expectEqual(titled.title, "A")
        expectEqual(try shape("card").name, nil, "untitled")
    },
    test("a placement's targets may be ids, with a part, among titles and words") {
        let note = try shape("card \"N\" right of #\(one) top, \"B\" and #\(two)")
        expectEqual(note.clauses[0].targets, [Target(.id(one), part: .top), Target(.title("B")), Target(.id(two))])
        expectEqual(note.clauses[0].written, "right of #\(one) top, \"B\" and #\(two)")
        expectEqual(note.clauses[0].targets.map(\.isName), [true, true, true])
        expectEqual(Target(.board).isName, false)
        expectEqual(try shape("card \"N\" inside #\(one) top-left").clauses[0].targets, [Target(.id(one), part: .topLeft)])
        expectEqual(try shape("card \"N\" level with #\(one)").clauses.map(\.written), ["level with #\(one)"])
        expectEqual(try shape("card \"N\" above view").clauses[0].targets, [Target(.view)])
    },
    test("in may name its holder by id, and share: its host") {
        expectEqual(try shape("card \"N\" in #\(one)").container, .id(one))
        expectEqual(try shape(#"card "N" in "Hub""#).container, .title("Hub"))
        guard case .edge(let edge) = try parse(#"edge "A" -> "B" via: reference share: #\#(one)"#) else { return expect(false, "an edge") }
        expectEqual(edge.share, .beside(.id(one)))
        guard case .edge(let titled) = try parse(#"edge "A" -> "B" via: reference share: "Ledger""#) else { return expect(false, "an edge") }
        expectEqual(titled.share, .beside(.title("Ledger")))
        expectEqual(parseError("card \"N\" in #\(one) in #\(two)")?.message, "card \"N\": in is written twice, in #\(one) and in #\(two)")
    },
    test("an id is its 36 characters, hex digits in any case; any other word after a # is not_an_id") {
        for source in ["card #7C1E2A04", "card #7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C1", "card #7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C1G",
                       "card #Services", "card #", "edge \"A\" -> #nope", "edge #nope -> \"A\"", "delete #nope", "delete edge \"A\" -> #12",
                       "card \"N\" right of #nope", "card \"N\" in #nope", "edge \"A\" -> \"B\" via: reference share: #nope"] {
            let error = parseError(source)
            expectEqual(error?.reason, .notAnID, source)
            expectEqual(error?.line, 1, source)
        }
        let hex = parseError("card #7C1E2A04-4B9E")
        expectEqual(hex?.hint, "an id is 32 hex digits in groups of 8, 4, 4, 4 and 12, as a query's row gives it")
        expectEqual(parseError("card #Services")?.hint, #"a title is in double quotes: write "Services"; an id is what a query's row gives"#)
        expectEqual(ScriptError.Reason.notAnID.rawValue, "not_an_id")
        expectEqual(ScriptError.Reason.unknownID.rawValue, "unknown_id")
    },
    test("a statement that starts with # is still the comment's refusal, and a title that has one is a title") {
        for line in ["# Services", "#Services", "#\(one)"] {
            expectEqual(parseError(line)?.message, "# doesn't start a comment here", line)
        }
        expectEqual(try shape("card \"#\(one)\"").name, .title("#\(one)"), "a quoted title is a title whatever it holds")
        expectEqual(try shape(##"card "#1" colour: #fff"##).name, .title("#1"))
    },
    test("an id lasts as written, upper or lower case, and an id is no attribute value") {
        expectEqual(try shape("card #\(two)").name, .id(two))
        expectEqual(ShapeName.id(two).written, "#\(two)")
        expectEqual(ShapeName.title("a \"b\"").written, #""a \"b\"""#)
        let colour = try shape("card \"A\" colour: #\(one)")
        expectEqual(colour.attributes, [Attribute(key: "colour", value: .word("#\(one)"))], "a value is a value")
    },
])
