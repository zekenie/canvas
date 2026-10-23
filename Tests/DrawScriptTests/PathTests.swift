import DrawScript
import TestKit

// A shape is named by its title, or by a path when its title is not its alone: titles joined by `>`, each part the shape the next
// is directly inside, the first a container's title, a container's id (`#7C1E…`) or `board`, the top of the board the run draws on.
// A path stands wherever a name does: a shape statement's own name, an edge's ends, `delete`, `delete edge`, a placement's target,
// `in`, `group`, `ungroup` and `share:`'s host. DrawScript reads it and writes it back; whether it names a shape is Draw's.

private let one = "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11"
private let two = "b3d9f0e1-6a52-4c8d-a7e4-1f2b9c3d5e60"

private func path(_ head: ShapePath.Head, _ rest: String...) -> ShapeName { .path(ShapePath(head: head, rest: rest)) }

@MainActor let pathTests = Suite("Paths as names", [
    test("a shape statement may be named by a path, with its attributes and placements") {
        let note = try shape(#"sticky-note "Payments" > "Checkout" text: "x" right of "A""#)
        expectEqual(note.name, path(.title("Payments"), "Checkout"))
        expectEqual(note.title, nil, "a path is not a title")
        expectEqual(note.attributes, [Attribute(key: "text", value: .quoted("x"))])
        expectEqual(note.clauses.map(\.written), [#"right of "A""#])
        expectEqual(try shape(#"sticky-note "Billing" > "Payments" > "Checkout""#).name, path(.title("Billing"), "Payments", "Checkout"))
        expectEqual(try shape(#"sticky-note #\#(one) > "Checkout""#).name, path(.id(one), "Checkout"), "an untitled container is named by its id")
        expectEqual(try shape(#"sticky-note board > "Checkout""#).name, path(.board, "Checkout"), "board is the top of the board")
        expectEqual(try shape(#"sticky-note "Checkout""#).name, .title("Checkout"), "a lone title is still a title")
    },
    test("the spaces around > are optional, and the path is written back with one on each side") {
        for spelling in [#""A" > "B""#, #""A">"B""#, #""A" >"B""#, #""A"> "B""#] {
            expectEqual(try shape("card \(spelling)").name, path(.title("A"), "B"), spelling)
        }
        for spelling in ["board > \"B\"", "board>\"B\"", "board >\"B\"", "board> \"B\""] {
            expectEqual(try shape("card \(spelling)").name, path(.board, "B"), spelling)
        }
        for spelling in ["#\(one) > \"B\"", "#\(one)>\"B\"", "#\(one) >\"B\"", "#\(one)> \"B\""] {
            expectEqual(try shape("card \(spelling)").name, path(.id(one), "B"), spelling)
        }
        expectEqual(path(.title("A"), "B", "C").written, #""A" > "B" > "C""#)
        expectEqual(path(.board, "B").written, #"board > "B""#)
        expectEqual(path(.id(two), "B").written, #"#\#(two) > "B""#)
        expectEqual(path(.title(#"a "q""#), "B").written, #""a \"q\"" > "B""#, "a title is escaped as it is alone")
        expectEqual(ShapePath(head: .title("A"), rest: ["B", "C"]).last, "C")
    },
    test("a path's container is the path less its last part, and the top of the board for board > T") {
        expectEqual(ShapePath(head: .title("A"), rest: ["B"]).container, .title("A"))
        expectEqual(ShapePath(head: .title("A"), rest: ["B", "C"]).container, path(.title("A"), "B"))
        expectEqual(ShapePath(head: .id(one), rest: ["B"]).container, .id(one))
        expectEqual(ShapePath(head: .board, rest: ["B"]).container, nil)
        expectEqual(ShapePath(head: .board, rest: ["B", "C"]).container, path(.board, "B"))
    },
    test("an edge's ends may be paths, in any arrow's direction") {
        guard case .edge(let edge) = try parse(#"edge "Payments" > "Checkout" -> "Billing" > "Checkout" text: "x""#) else { return expect(false, "an edge") }
        expectEqual(edge.from, path(.title("Payments"), "Checkout"))
        expectEqual(edge.to, path(.title("Billing"), "Checkout"))
        expectEqual(edge.attributes, [Attribute(key: "text", value: .quoted("x"))])
        expectEqual(edge.written, #""Payments" > "Checkout" -> "Billing" > "Checkout""#, "written round-trips")
        guard case .edge(let back) = try parse(#"edge board > "A" <- "B" > "C""#) else { return expect(false, "an edge") }
        expectEqual(back.from, path(.title("B"), "C"), "<- writes the ends the other way round")
        expectEqual(back.to, path(.board, "A"))
        expectEqual(back.written, #"board > "A" <- "B" > "C""#)
        guard case .edge(let mixed) = try parse(#"edge "Lone" <-> #\#(one) > "C""#) else { return expect(false, "an edge") }
        expectEqual(mixed.from, .title("Lone"))
        expectEqual(mixed.to, path(.id(one), "C"))
        expectEqual(mixed.bothHeads, true)
    },
    test("delete and delete edge may name paths") {
        expectEqual(try parse(#"delete "Payments" > "Checkout""#), .delete(.shape(path(.title("Payments"), "Checkout"))))
        expectEqual(try parse(#"delete board > "Checkout""#), .delete(.shape(path(.board, "Checkout"))))
        expectEqual(try parse(#"delete edge "A" > "B" -> "C" > "B" is: "T""#),
                    .delete(.edges(from: path(.title("A"), "B"), to: path(.title("C"), "B"), eitherWay: false,
                                   attributes: [Attribute(key: "is", value: .quoted("T"))])))
        expectEqual(parseError(#"delete "A" > "B" "C""#)?.message, #"delete "A" > "B": delete takes one title, and nothing after it ("C")"#)
    },
    test("group and ungroup may name paths among titles and ids") {
        guard case .group(let group) = try parse(#"group "A" > "B" and "C", #\#(one) > "D" and board > "E""#) else { return expect(false, "a group") }
        expectEqual(group.shapes, [path(.title("A"), "B"), .title("C"), path(.id(one), "D"), path(.board, "E")])
        expectEqual(group.written, #""A" > "B", "C", #\#(one) > "D" and board > "E""#)
        guard case .ungroup(let ungroup) = try parse(#"ungroup "A" > "B""#) else { return expect(false, "an ungroup") }
        expectEqual(ungroup.shapes, [path(.title("A"), "B")])
    },
    test("a placement's targets may be paths, with a part, among titles and words") {
        let note = try shape(#"card "N" right of "A" > "B" top, "C" and board > "D""#)
        expectEqual(note.clauses[0].targets, [Target(.path(ShapePath(head: .title("A"), rest: ["B"])), part: .top), Target(.title("C")),
                                              Target(.path(ShapePath(head: .board, rest: ["D"])))])
        expectEqual(note.clauses[0].written, #"right of "A" > "B" top, "C" and board > "D""#)
        expectEqual(note.clauses[0].targets.map(\.isName), [true, true, true])
        expectEqual(try shape(#"card "N" inside "A" > "B" top-left"#).clauses[0].targets, [Target(.path(ShapePath(head: .title("A"), rest: ["B"])), part: .topLeft)])
        expectEqual(try shape(#"card "N" level with #\#(one) > "B""#).clauses.map(\.written), [#"level with #\#(one) > "B""#])
        expectEqual(try shape(#"card "N" on "A" > "B" > "C" above "X""#).clauses.map(\.written), [#"on "A" > "B" > "C""#, #"above "X""#])
    },
    test("board and origin stay the targets they are where no > follows") {
        expectEqual(try shape("card \"N\" below board").clauses[0].targets, [Target(.board)])
        expectEqual(try shape("card \"N\" right of origin").clauses[0].targets, [Target(.origin)])
        expectEqual(try shape("card \"N\" inside view top-left").clauses[0].targets, [Target(.view, part: .topLeft)])
        expectEqual(try shape("card \"N\" below board and \"A\" > \"B\"").clauses[0].targets, [Target(.board), Target(.path(ShapePath(head: .title("A"), rest: ["B"])))])
    },
    test("in may name its holder by a path, and share: its host") {
        expectEqual(try shape(#"card "N" in "Billing" > "Payments""#).container, path(.title("Billing"), "Payments"))
        expectEqual(try shape(#"card "N" in #\#(one) > "Payments""#).container, path(.id(one), "Payments"))
        guard case .edge(let edge) = try parse(#"edge "A" -> "B" via: reference share: "Payments" > "Checkout""#) else { return expect(false, "an edge") }
        expectEqual(edge.share, .beside(path(.title("Payments"), "Checkout")))
        guard case .edge(let boarded) = try parse(#"edge "A" -> "B" via: reference share: board > "Checkout""#) else { return expect(false, "an edge") }
        expectEqual(boarded.share, .beside(path(.board, "Checkout")))
        expectEqual(parseError(#"edge "A" -> "B" via: reference share: "Payments" > "Checkout" in "F""#)?.reason, .invalidValue,
                    "a host and a place are still refused together")
        guard case .edge(let any) = try parse(#"edge "A" -> "B" via: reference share: true"#) else { return expect(false, "an edge") }
        expectEqual(any.share, .any)
        expectEqual(parseError(#"edge "A" -> "B" via: reference share: "A" > "B" share: true"#)?.reason, .duplicate)
    },
    test("a malformed path is a syntax error with a hint") {
        let cases: [(source: String, message: String, hint: String)] = [
            (#"card "A" >"#, "card: > ends the path, and no title follows it", #"write "A" > "A": the title of a shape inside "A""#),
            (#"card "A" > "B" >"#, "card: > ends the path, and no title follows it", #"write "A" > "B" > "A": the title of a shape inside "B""#),
            (#"card board >"#, "card: > ends the path, and no title follows it", #"write board > "A": the title of a shape inside board"#),
            (#"edge "A" > -> "B""#, "edge: -> isn't quoted, and titles are in double quotes", #"write "A" > "A""#),
            (#"card > "A""#, #"card: > joins the parts of a path, and none is being written here"#,
             #"a path names a shape by the containers it is in: "Payments" > "Checkout"; it starts with a title, an id or board"#),
            (#"edge > "A" -> "B""#, #"edge: > joins the parts of a path, and none is being written here"#,
             #"a path names a shape by the containers it is in: "Payments" > "Checkout"; it starts with a title, an id or board"#),
            (#"card "A" > board"#, "card: board can only start a path", #"write board > "A": the top of the board, then the shape on it"#),
            (#"card "A" > "B" > board > "C""#, "card: board can only start a path", #"write board > "A": the top of the board, then the shape on it"#),
            (#"card "A" > #\#(one)"#, "card: an id can only start a path, and #\(one) comes after a >",
             #"write #\#(one) > "A", or name the shape by its title: "A" > "A""#),
            (#"card "A" > B"#, "card: B isn't quoted, and titles are in double quotes", #"write "A" > "A""#),
            (#"card "A" > "  ""#, "card: a title can't be blank", "leave it out for an untitled shape"),
            (#"card "N" right of view > "A""#, #"card "N": view can't start a path"#, #"a path starts with a title, an id or board: "Payments" > "Checkout""#),
            (#"card "N" right of origin > "A""#, #"card "N": origin can't start a path"#, #"a path starts with a title, an id or board: "Payments" > "Checkout""#),
        ]
        for (source, message, hint) in cases {
            let error = parseError(source)
            expectEqual(error?.reason, .syntax, source)
            expectEqual(error?.message, message, source)
            expectEqual(error?.hint, hint, source)
            expectEqual(error?.line, 1, source)
        }
        expectEqual(parseError(#"card "A" > #nope"#)?.reason, .syntax, "an id after the first part is refused before it is read")
        expectEqual(parseError(#"edge "A" -> "B" > "#)?.reason, .syntax, "a > ends the line")
        expectEqual(parseError(#"edge #nope > "A" -> "B""#)?.reason, .notAnID, "an id that heads a path is read as an id is")
    },
    test("a path is no value: title: takes one title, and other keys one value") {
        let rename = parseError(#"card "A" > "B" title: "C" > "D""#)
        expectEqual(rename?.reason, .syntax)
        expectEqual(rename?.message, #"card "A" > "B": title: takes one value, not a path"#)
        expectEqual(rename?.hint, "title: is the shape's new title: a path names where a shape is, and the shape keeps its place")
        let text = parseError(#"card "A" text: "x" > "y""#)
        expectEqual(text?.message, #"card "A": text: takes one value, not a path"#)
        expectEqual(text?.hint, "a path names a shape, and text: takes one value")
        expectEqual(parseError(#"style loud title: "x" > "y""#)?.reason, .syntax)
    },
    test("a path says where the shape is, so in beside it is refused") {
        let both = parseError(#"card "A" > "B" in "C""#)
        expectEqual(both?.reason, .syntax)
        expectEqual(both?.message, #"card "A" > "B": "A" > "B" says what holds the shape, and so does in "C""#)
        expectEqual(both?.hint, #"keep one: card "A" > "B", or card "B" in "A""#)
    },
    test("an arrow is still an arrow, and a > in a quoted title is a title") {
        guard case .edge(let edge) = try parse(#"edge "a>b" -> "c > d""#) else { return expect(false, "an edge") }
        expectEqual(edge.from, .title("a>b"))
        expectEqual(edge.to, .title("c > d"))
        expectEqual(parseError(#"API --> DB"#)?.message, "--> joins shapes only in an edge statement")
        expectEqual(try shape(#"card "A" text: "x>y""#).attributes, [Attribute(key: "text", value: .quoted("x>y"))])
        expectEqual(try shape("card \"N\" colour: a>b").attributes, [Attribute(key: "colour", value: .word("a>b"))], "a word with a > in it is a word")
    },
    test("a name outside a script is read with the same parser, and told from a bare title") {
        expectEqual(try ShapeName(parsing: #""Payments""#), .title("Payments"))
        expectEqual(try ShapeName(parsing: #" "Payments" > "Checkout" "#), path(.title("Payments"), "Checkout"))
        expectEqual(try ShapeName(parsing: #"board>"Checkout""#), path(.board, "Checkout"))
        expectEqual(try ShapeName(parsing: "#\(one)"), .id(one))
        expectEqual(try ShapeName(parsing: "#\(one) > \"Checkout\""), path(.id(one), "Checkout"))
        for text in [#""Payments" > "Checkout""#, #""Payments""#, "#\(one)", "#nope > \"A\"", #"board > "A""#, #"board>"A""#, #"  board  >"A""#, #"#\#(one)>"A""#] {
            expect(ShapeName.isScriptSpelling(text), text)
        }
        for text in ["Payments", "Payments > Checkout", "board", "boards > A", "a \"quoted\" word", "", "#", "#nope", "#1 task"] {
            expect(!ShapeName.isScriptSpelling(text), text)
        }
        var refused: [String: ScriptError] = [:]
        for text in [#""A" >"#, #""A" "B""#, "Payments", "", #""A" > board"#, "#nope"] {
            do throws(ScriptError) { _ = try ShapeName(parsing: text) } catch { refused[text] = error }
        }
        expectEqual(refused[#""A" >"#]?.reason, .syntax)
        expectEqual(refused[#""A" "B""#]?.message, #""B" comes after the name "A""#)
        expectEqual(refused["Payments"]?.message, "Payments isn't a name")
        expectEqual(refused["Payments"]?.hint, #"a name is a title in double quotes, an id (#…) or a path: "Payments" > "Checkout""#)
        expectEqual(refused[""]?.message, " isn't a name")
        expectEqual(refused[#""A" > board"#]?.message, "board can only start a path")
        expectEqual(refused["#nope"]?.reason, .notAnID)
    },
])
