import CoreGraphics
import DrawScript
import TestKit

@MainActor let lexingTests = Suite("Lexing", [
    test("one statement a line: blank lines, indentation and // comments are skipped; # is an ordinary character") {
        let script = try Script(parsing: """

              card "A"   // the first
            // a whole line of comment
            \tbox "B#2" colour: #ff0000 // hex, not a comment

            """)
        expectEqual(script.statements.count, 2)
        expectEqual(script.statements.map(\.line), [2, 4])
        expectEqual(script.statements.map(\.text), [#"card "A""#, #"box "B#2" colour: #ff0000"#])
        let second = try shape(#"box "B#2" colour: #ff0000"#)
        expectEqual(second.title, "B#2")
        expectEqual(second.attributes, [Attribute(key: "colour", value: .word("#ff0000"))])
    },
    test("a statement that starts with # is refused as the comment it was meant to be") {
        for line in ["# Services", "#Services", "## Heading"] {
            let error = parseError(line)
            expectEqual(error?.reason, .syntax)
            expectEqual(error?.message, "# doesn't start a comment here")
            expectEqual(error?.hint, "comments start with //")
        }
        expectEqual(try shape(##"card "#1" colour: #fff"##).title, "#1", "# anywhere else is a character")
    },
    test("Windows line endings count lines as any other") {
        let script = try Script(parsing: "card \"A\"\r\ncard \"B\" right of \"A\"\r\n")
        expectEqual(script.statements.map(\.line), [1, 2])
        expectEqual(script.statements.map(\.text), [#"card "A""#, #"card "B" right of "A""#])
    },
    test("a quoted string takes \\\" \\\\ \\n and \\t, and // inside it is text") {
        let card = try shape(#"card "say \"hi\" \\ now\n\tthen // not a comment" text: "a // b""#)
        expectEqual(card.title, "say \"hi\" \\ now\n\tthen // not a comment")
        expectEqual(card.attributes, [Attribute(key: "text", value: .quoted("a // b"))])
    },
    test("any other escape, or a string left open, is syntax") {
        let escape = parseError(#"card "a\q""#)
        expectEqual(escape?.reason, .syntax)
        expectEqual(escape?.message, #""\q" isn't an escape"#)
        let open = parseError(#"card "API right of "B""#)
        expectEqual(open?.reason, .syntax)
        expect(open?.message.contains("isn't closed on its line") == true, open?.message ?? "")
    },
    test("curly and single quotes are refused, naming the straight-quoted title") {
        expectEqual(parseError("card \u{201C}My API\u{201D} right of \"B\"")?.message, #"titles and text are in straight double quotes: "My API""#)
        expectEqual(parseError("card 'API'")?.message, #"titles and text are in straight double quotes: "API""#)
        expectEqual(parseError("card \u{2018}API\u{2019}")?.reason, .syntax)
    },
    test("after a key, a JSON value runs to its matching bracket, past strings, commas and //") {
        let card = try shape(#"card "A" items: [{"text": "Eggs, ham ] // x"}, {"text": "b"}] labels: {"a": [1, 2]} right of "B""#)
        expectEqual(card.attributes, [
            Attribute(key: "items", value: .json(#"[{"text": "Eggs, ham ] // x"}, {"text": "b"}]"#)),
            Attribute(key: "labels", value: .json(#"{"a": [1, 2]}"#)),
        ])
        expectEqual(card.clauses.map(\.written), [#"right of "B""#])
    },
    test("a JSON value left open on its line is syntax") {
        let error = parseError(#"card "A" items: [{"text": "Eggs"}"#)
        expectEqual(error?.reason, .syntax)
        expect(error?.message.contains("isn't closed on its line") == true, error?.message ?? "")
    },
    test("a trailing comma separates, as and does") {
        let card = try shape("card \"A\" right of \"B\", \"C\", and \"D\" style: urgent, quiet and loud\nstyle urgent a: 1\nstyle quiet b: 2\nstyle loud c: 3")
        expectEqual(card.clauses[0].targets.map(\.written), [#""B""#, #""C""#, #""D""#])
        expectEqual(card.styles, ["urgent", "quiet", "loud"])
    },
])

@MainActor let statementTests = Suite("Statements", [
    test("any first word but edge, delete and style is a kind word, left for the caller") {
        for word in ["card", "node", "box", "link", "whatever-kind"] {
            let statement = try shape("\(word) \"A\"")
            expectEqual(statement.word, word)
            expectEqual(statement.title, "A")
        }
        expectEqual(Keyword.allCases.map(\.rawValue), ["edge", "delete", "style"])
    },
    test("a shape statement: a kind, a title, then attributes and placements in any order") {
        let card = try shape(#"card "API" priority: high right of "Web" size: 300x120 notes: "a b" gap: wide below "Top" overlap: allow"#)
        expectEqual(card.word, "card")
        expectEqual(card.title, "API")
        expectEqual(card.size, CGSize(width: 300, height: 120))
        expectEqual(card.gap, .named(.wide))
        expectEqual(card.overlapAllowed, true)
        expectEqual(card.attributes, [Attribute(key: "priority", value: .word("high")), Attribute(key: "notes", value: .quoted("a b"))])
        expectEqual(card.clauses.map(\.written), [#"right of "Web""#, #"below "Top""#])
    },
    test("a shape needn't have a title, attributes or placements") {
        let card = try shape("card")
        expectEqual(card, ShapeStatement(word: "card"))
        expectEqual(try shape("card right of \"A\"").title, nil)
    },
    test("a title is quoted: an unquoted one is refused with the fix") {
        let error = parseError("card API right of \"B\"")
        expectEqual(error?.reason, .syntax)
        expectEqual(error?.message, "card: API isn't quoted, and titles are in double quotes")
        expectEqual(error?.hint, #"write card "API""#)
        expectEqual(error?.statement, #"card API right of "B""#)
        expectEqual(error?.line, 1)
    },
    test("a blank title is refused: leave it out for an untitled shape") {
        for source in [#"card """#, #"card "   ""#, #"card "A" right of " ""#, #"card "A" title: " ""#] {
            let error = parseError(source)
            expectEqual(error?.reason, .syntax, source)
            expect(error?.message.hasSuffix("a title can't be blank") == true, error?.message ?? source)
            expectEqual(error?.hint, "leave it out for an untitled shape")
        }
    },
    test("title: renames, and is quoted; a style can't give one") {
        expectEqual(try shape(#"card "Web" title: "Web app""#).newTitle, "Web app")
        expectEqual(parseError("card \"Web\" title: Web")?.hint, #"write title: "Web""#)
        expectEqual(parseError("style s title: \"X\"")?.message, "style s: a style can't give a title: a title names one shape")
    },
    test("a statement starts with a word; the hint depends on what came first") {
        let quoted = parseError(#""A" right of "B""#)
        expectEqual(quoted?.reason, .syntax)
        expectEqual(quoted?.message, #"a statement starts with a kind, edge, delete or style, not "A""#)
        expectEqual(quoted?.hint, #"write the kind first: <kind> "A" (canvas kinds lists them)"#)
        expectEqual(parseError(#""A" -> "B""#)?.hint, #"to join two shapes, write edge "A" -> "B""#)
        expectEqual(parseError(#""A" --> "B""#)?.hint, #"to join two shapes, write edge "A" -> "B""#)
        // A line of Mermaid's, or an arrow after a shape, is told the edge it means.
        let mermaid = parseError("API --> DB")
        expectEqual(mermaid?.reason, .syntax)
        expectEqual(mermaid?.message, "--> joins shapes only in an edge statement")
        expectEqual(mermaid?.hint, #"to join two shapes, write edge "API" -> "DB""#)
        expectEqual(parseError(#""Web" <-- "API""#)?.hint, #"to join two shapes, write edge "Web" <- "API""#)
        expectEqual(parseError("Web <--> API")?.hint, #"to join two shapes, write edge "Web" <-> "API""#)
        let after = parseError(#"card "Web" -> "API""#)
        expectEqual(after?.message, #"card "Web": -> joins shapes only in an edge statement"#)
        expectEqual(after?.hint, #"to join two shapes, write edge "Web" -> "API""#)
        expectEqual(parseError(#"card "Web" right of "API" -->"#)?.hint, #"to join two shapes, write edge "A" -> "B""#, "no title after it")
        expectEqual(parseError("size: 10x10")?.hint, "an attribute goes after the shape it's about: <kind> \"A\" size: …")
    },
    test("a key is written once a statement, the language's too") {
        let error = parseError(#"card "A" priority: high priority: low"#)
        expectEqual(error?.reason, .duplicate)
        expectEqual(error?.message, #"card "A": "priority" is written twice (high, low)"#)
        expectEqual(error?.hint, "keep one")
        expectEqual(parseError(#"card "A" gap: wide gap: tight"#)?.reason, .duplicate)
        expectEqual(parseError(#"card "A" style: s style: t"#)?.reason, .duplicate)
        expectEqual(parseError("card \"A\" style: s, s\nstyle s x: 1")?.message, #"card "A": style s is named twice"#)
    },
    test("a key needs a value") {
        let error = parseError(#"card "A" priority:"#)
        expectEqual(error?.message, #"card "A": priority: has no value"#)
        expectEqual(parseError(#"card "A" priority: notes: x"#)?.reason, .syntax)
        expectEqual(parseError(#"card "A" priority: (gap: wide)"#)?.reason, .syntax)
    },
    test("values: a word, a quoted string, JSON, and null is just a word for the caller") {
        let card = try shape(#"card "A" a: high b: "two words" c: 12.5 d: true e: null f: [1, 2]"#)
        expectEqual(card.attributes.map(\.value), [.word("high"), .quoted("two words"), .word("12.5"), .word("true"), .word("null"), .json("[1, 2]")])
        expectEqual(card.attributes.map(\.written), ["a: high", #"b: "two words""#, "c: 12.5", "d: true", "e: null", "f: [1, 2]"])
    },
    test("a word after a value that's neither a placement nor a key is refused, with the fix") {
        let error = parseError(#"card "A" text: hello world"#)
        expectEqual(error?.message, #"card "A": world isn't a placement"#)
        expectEqual(error?.hint, #"a value with spaces is quoted: text: "hello world""#)
        let key = parseError(#"card "A" size:200x100"#)
        expectEqual(key?.message, #"card "A": size:200x100 isn't a placement or an attribute"#)
        expectEqual(key?.hint, "an attribute is written key: value, with a space after the colon: size: 200x100")
    },
    test("size: w x h, with x or ×, or [w, h]; both finite and more than 0") {
        expectEqual(try shape(#"card size: 200x120"#).size, CGSize(width: 200, height: 120))
        expectEqual(try shape("card size: 200×120.5").size, CGSize(width: 200, height: 120.5))
        expectEqual(try shape(#"card size: [80, 40]"#).size, CGSize(width: 80, height: 40))
        for bad in ["0x10", "10x-1", "10", "10x10x10", "wide", "[1]", "[1, 2, 3]", #""10x10""#, "infx10"] {
            let error = parseError("card size: \(bad)")
            expectEqual(error?.reason, .invalidValue, bad)
            expectEqual(error?.hint, "write size: <width>x<height>, as size: 200x120 (world units)")
        }
    },
    test("gap: none, tight, normal, wide, or a number at least 0") {
        expectEqual(try shape("card gap: none").gap, .named(.none))
        expectEqual(try shape("card gap: tight").gap?.value, 40)
        expectEqual(try shape("card gap: normal").gap?.value, 80)
        expectEqual(try shape("card gap: wide").gap?.value, 160)
        expectEqual(try shape("card gap: 12.5").gap, .units(12.5))
        expectEqual(parseError("card gap: -3")?.hint, "a gap is a distance, at least 0; overlap: allow is what lets two shapes meet")
        expectEqual(parseError("card gap: 12px")?.hint, "write gap: 12: a gap's number is already in world units")
        let typo = parseError("card gap: wdie")
        expectEqual(typo?.reason, .invalidValue)
        expectEqual(typo?.message, "card: gap: wdie isn't a gap")
        expectEqual(typo?.hint, "did you mean wide? a gap is none, tight, normal, wide, or a number of world units")
    },
    test("a size's sides and a gap's number are at most 100000 world units") {
        expectEqual(try shape("card size: 100000x100000").size, CGSize(width: 100_000, height: 100_000))
        for bad in ["100001x10", "10x1e300", "1e300x1e300", "[5, 1e7]"] {
            let error = parseError("card size: \(bad)")
            expectEqual(error?.reason, .invalidValue, bad)
            expectEqual(error?.message, "card: size: \(bad) is too big: a side is at most 100000 world units")
            expectEqual(error?.hint, "write size: <width>x<height>, each at most 100000")
        }
        expectEqual(parseError("style huge size: 1e300x5\ncard style: huge")?.message, "style huge: size: 1e300x5 is too big: a side is at most 100000 world units")
        expectEqual(try shape("card gap: 100000").gap, .units(100_000))
        let far = parseError("card gap: 1e300")
        expectEqual(far?.reason, .invalidValue)
        expectEqual(far?.message, "card: gap: 1e300 is too far: a gap is at most 100000 world units")
        expectEqual(far?.hint, "write gap: wide, or a number up to 100000")
        expectEqual(parseError(#"card right of "A" (gap: 100001)"#)?.reason, .invalidValue)
        expectEqual(try shape(#"card right of "A" (gap: 100000)"#).clauses[0].gap, .units(100_000))
    },
    test("overlap: takes allow and nothing else") {
        expectEqual(try shape("card overlap: allow").overlapAllowed, true)
        expectEqual(parseError("card overlap: yes")?.reason, .invalidValue)
        expectEqual(parseError("card overlap: yes")?.hint, "write overlap: allow, or leave it out")
    },
    test("attributes in braces, or written with =, are refused with the line written as it's meant") {
        let braces = parseError(#"card "Web" right of "API" {text: "braces"}"#)
        expectEqual(braces?.reason, .syntax)
        expectEqual(braces?.message, #"card "Web": attributes are written key: value, without braces"#)
        expectEqual(braces?.hint, #"write text: "braces""#)
        expectEqual(parseError(#"card "Web" { text: "braces" }"#)?.hint, #"write text: "braces""#)
        expectEqual(parseError(#"card { text: "braces" }"#)?.message, "card: attributes are written key: value, without braces")
        // JSON quotes a word the language's own keys take bare, so the hint writes it bare; text,
        // a title and a plugin's attributes keep their quotes.
        expectEqual(parseError(#"card "Web" {"text": "braces", "size": "200x100"}"#)?.hint, #"write text: "braces" size: 200x100"#)
        expectEqual(parseError(#"card "Web" {"size": "200x100"}"#)?.hint, "write size: 200x100")
        expectEqual(parseError(#"card "Web" {"gap": "wide"}"#)?.hint, "write gap: wide")
        expectEqual(parseError(#"card "Web" {"overlap": "allow", "style": "urgent"}"#)?.hint, "write overlap: allow style: urgent")
        expectEqual(parseError(#"card "Web" {"status": "doing", "title": "Web2", "text": "two words"}"#)?.hint,
                    #"write status: "doing" title: "Web2" text: "two words""#)
        expectEqual(parseError(#"card "Web" {"from": "right"}"#)?.hint, #"write from: "right""#, "a shape's from is a plugin's")
        expectEqual(parseError(#"edge "A" -> "B" {from: right}"#)?.hint, "write from: right")
        expectEqual(parseError(#"edge "A" -> "B" {"from": "right", "to": "left", "tone": "warm"}"#)?.hint, #"write from: right to: left tone: "warm""#)
        for hint in [parseError(#"card "Web" {"size": "200x100"}"#)?.hint, parseError(#"edge "A" -> "B" {"from": "right"}"#)?.hint] {
            let line = String(try require(hint).dropFirst("write ".count))
            let script = line.hasPrefix("from") ? #"edge "A" -> "B" "# + line : #"card "Web" "# + line
            expectEqual(parseError(script), nil, "the line the hint writes reads: \(script)")
        }
        let equals = parseError(#"card "Web" right of "API" text = "equals""#)
        expectEqual(equals?.reason, .syntax)
        expectEqual(equals?.message, #"card "Web": an attribute is written key: value, not key = value"#)
        expectEqual(equals?.hint, #"write text: "equals""#)
        expectEqual(parseError(#"card "Web" text="equals""#)?.hint, #"write text: "equals""#)
        expectEqual(parseError(#"card "Web" size=200x100"#)?.hint, "write size: 200x100")
        expectEqual(parseError(#"card text = "equals""#)?.message, "card: an attribute is written key: value, not key = value")
        expectEqual(parseError(#"edge "A" -> "B" from = right"#)?.hint, "write from: right")
        // An arrow written without spaces isn't one.
        expectEqual(parseError(#"card "Web" right of "API" A==>B"#)?.message, #"card "Web": A==>B isn't a placement"#)
    },
    test("title: null (or none, or nil) is refused, never told to be quoted: a script renames a shape, and can't take its title away") {
        let error = parseError(#"card "Alpha 3" title: null"#)
        expectEqual(error?.reason, .unsupported)
        expectEqual(error?.message, #"card "Alpha 3": title: null would take the shape's title away, and a script only renames"#)
        expectEqual(error?.hint, #"rename it with title: "…", or leave title: out"#)
        // The other words for nothing are refused alike: told to quote them, the title would be "none".
        for word in ["none", "nil"] {
            let other = parseError(#"card "Alpha 3" title: "# + word)
            expectEqual(other?.reason, .unsupported, word)
            expectEqual(other?.message, #"card "Alpha 3": title: "# + word + " would take the shape's title away, and a script only renames")
            expectEqual(other?.hint, #"rename it with title: "…", or leave title: out"#)
        }
        expectEqual(parseError(#"card "Alpha 3" title: "none""#), nil, "a title that is none is quoted")
        expectEqual(parseError(#"card "Alpha 3" title: Beta"#)?.hint, #"write title: "Beta""#)
    },
    test("a stray title, comma or bracket is refused with what it probably meant") {
        expectEqual(parseError(#"card "A" "B""#)?.hint, "a value with spaces is quoted after its key: text: \"B\"")
        expectEqual(parseError(#"card "A" right of "B" "C""#)?.hint, #"join several shapes with and: "B" and "C""#)
        expectEqual(parseError(#"card , "A""#)?.reason, .syntax)
        expectEqual(parseError(#"card "A" (gap: wide)"#)?.hint, #"brackets hold a placement's gap: right of "A" (gap: wide)"#)
    },
])

@MainActor let placementTests = Suite("Placements", [
    test("the eight directions, of optional after each, quoted back in one form") {
        expectEqual(try written(#"card above "A""#), [#"above "A""#])
        expectEqual(try written(#"card below of "A""#), [#"below "A""#])
        expectEqual(try written(#"card left of "A""#), [#"left of "A""#])
        expectEqual(try written(#"card right "A""#), [#"right of "A""#])
        expectEqual(try written(#"card above-left of "A" below-right "B""#), [#"above-left of "A""#, #"below-right of "B""#])
        expectEqual(try written(#"card above-right "A" below-left of "B""#), [#"above-right of "A""#, #"below-left of "B""#])
        let clause = try shape(#"card above-right of "A""#).clauses[0]
        expectEqual(clause.relation, .direction(.aboveRight))
        expectEqual(clause.targets, [Target(.title("A"))])
        expectEqual(clause.direction, .aboveRight)
    },
    test("level with, and a side level with; an alignment takes no gap") {
        let card = try shape(#"card level with "A" top level with "B" bottom level with "C" left level with "D" right level with "E""#)
        expectEqual(card.clauses.map(\.relation), [.level(.center), .level(.top), .level(.bottom), .level(.left), .level(.right)])
        expectEqual(card.clauses.map(\.written), [#"level with "A""#, #"top level with "B""#, #"bottom level with "C""#, #"left level with "D""#, #"right level with "E""#])
        expectEqual(parseError(#"card level "A""#)?.message, #"card: an alignment reads level with "A""#)
        expectEqual(parseError(#"card top level "A""#)?.hint, #"write top level with "A""#)
        expectEqual(parseError(#"card level with "A" (gap: wide)"#)?.message, #"card: level with "A" shares a line rather than leaving a space, so it takes no gap"#)
    },
    test("in names the one shape that holds it, quoted, with no part, anywhere among the placements") {
        let card = try shape(#"card "A" right of "B" in "Box""#)
        expectEqual(card.container, "Box")
        expectEqual(card.clauses.map(\.written), [#"right of "B""#])
        expectEqual(try shape(#"card in "Box""#).container, "Box", "an untitled shape")
        expectEqual(try shape(#"card "A" in "Box" right of "B" top level with "C""#).clauses.map(\.written), [#"right of "B""#, #"top level with "C""#],
                    "words parts share, opening placements")
        expectEqual(try shape(#"card "A" in "Box" inside view top-left"#).clauses.map(\.written), ["inside view top-left"])
        expectEqual(parseError(#"card "A" in Box"#)?.hint, #"write in "Box""#)
        expectEqual(parseError(#"card "A" in"#)?.message, "card \"A\": in names no shape")
        expectEqual(parseError(#"card "A" in "Box" in "Crate""#)?.message, #"card "A": in is written twice, in "Box" and in "Crate""#)
        expectEqual(parseError(#"card "A" in "Box" top-left"#)?.hint, #"say where with a placement too: in "Box" inside view top-left"#)
        expectEqual(parseError(#"card "A" in "Box" and "Crate""#)?.message, #"card "A": in "Box" names one shape, and a shape is in one"#)
    },
    test("inside and outside take one shape and a part on its edge, and derive a direction") {
        let card = try shape(#"card inside "Z" top-left outside "Y" right inside view bottom (gap: wide)"#)
        expectEqual(card.clauses.map(\.relation), [.inside, .outside, .inside])
        expectEqual(card.clauses.map(\.direction), [.belowRight, .right, .above])
        expectEqual(card.clauses.map(\.written), [#"inside "Z" top-left"#, #"outside "Y" right"#, "inside view bottom (gap: wide)"])
        expectEqual(card.clauses[2].gap, .named(.wide))
        let none = parseError(#"card inside "Z""#)
        expectEqual(none?.message, #"card: inside "Z" names no part of "Z""#)
        expectEqual(none?.hint, "inside takes a side or a point of the box: top, bottom, left, right, top-left, top-center, top-right, left-center, right-center, bottom-left, bottom-center, bottom-right")
        expectEqual(parseError(#"card outside "Z" center"#)?.message, #"card: outside "Z" center reads no direction from center, which isn't on the edge"#)
        expectEqual(parseError(#"card inside "Z" and "Y" top"#)?.message, #"card: inside "Z" and "Y" top names 2 shapes, and inside reads its direction off one part of one"#)
    },
    test("on takes one shape, a part or its middle, and no gap") {
        let card = try shape(#"card on "Hub" on "Hub" top-right"#)
        expectEqual(card.clauses.map(\.relation), [.on, .on])
        expectEqual(card.clauses.map(\.written), [#"on "Hub""#, #"on "Hub" top-right"#])
        expectEqual(card.clauses[1].targets, [Target(.title("Hub"), part: .topRight)])
        expectEqual(parseError(#"card on "A" and "B""#)?.message, #"card: on "A" and "B" names 2 shapes, and a shape sits on one"#)
        expectEqual(parseError(#"card on "A" (gap: tight)"#)?.message, #"card: on "A" puts its middle on that point rather than leaving a space, so it takes no gap"#)
    },
    test("several targets, joined by , and and; board and view are boxes too") {
        let clause = try shape(#"card right of "A", "B" top and board and view top-right"#).clauses[0]
        expectEqual(clause.targets, [Target(.title("A")), Target(.title("B"), part: .top), Target(.board), Target(.view, part: .topRight)])
        expectEqual(clause.written, #"right of "A", "B" top, board and view top-right"#)
    },
    test("a part word after a target is its part, unless the word after makes it the next placement") {
        let next = try shape(#"card right of "A" left of "B" below "C" top level with "D""#)
        expectEqual(next.clauses.map(\.written), [#"right of "A""#, #"left of "B""#, #"below "C""#, #"top level with "D""#])
        expectEqual(try shape(#"card below "A" right "B""#).clauses.map(\.written), [#"below "A""#, #"right of "B""#])
        expectEqual(try shape(#"card right of "A" top"#).clauses[0].targets, [Target(.title("A"), part: .top)])
        expectEqual(try shape(#"card below "A" left"#).clauses[0].targets, [Target(.title("A"), part: .left)])
        // After inside, outside and on, a side before level is the part.
        let inside = try shape(#"card inside "Z" right level with "Q""#)
        expectEqual(inside.clauses.map(\.written), [#"inside "Z" right"#, #"level with "Q""#])
    },
    test("text isn't a part here") {
        let error = parseError(#"card right of "A" text"#)
        expectEqual(error?.message, #"card: text isn't a part of a shape here"#)
        expectEqual(parseError(#"card "A" below "B" text "hello""#)?.hint, #"to set its text, write text: "hello""#)
    },
    test("a bracketed gap on a placement: a name or a number; only gap goes there") {
        let clause = try shape(#"card right of "A" (gap: 24)"#).clauses[0]
        expectEqual(clause.gap, .units(24))
        expectEqual(clause.written, #"right of "A" (gap: 24)"#)
        expectEqual(parseError(#"card right of "A" (size: 3)"#)?.message, #"card: a placement's brackets hold its gap, not size:"#)
        expectEqual(parseError(#"card right of "A" (gap: wide"#)?.message, #"card: right of "A" opens a ( and never closes it"#)
        expectEqual(parseError(#"card right of "A" (gap: wide, gap: tight)"#)?.reason, .duplicate)
        expectEqual(parseError(#"card right of "A" (gap: -1)"#)?.reason, .invalidValue)
        expectEqual(parseError(#"card right of "A" ()"#)?.message, #"card: right of "A" has empty brackets"#)
    },
    test("what isn't a placement is refused, with a guess") {
        let typo = parseError(#"card "A" rigth of "B""#)
        expectEqual(typo?.message, #"card "A": rigth isn't a placement"#)
        expectEqual(typo?.hint, "did you mean right?")
        let position = parseError(#"card "A" top-right "B""#)
        expectEqual(position?.message, #"card "A": top-right is a point of a shape, not a direction from one"#)
        expectEqual(position?.hint, #"write inside "A" top-right to put this in that corner, on "A" top-right to straddle it, or a direction, as above-right of "A""#)
        expectEqual(parseError(#"card "A" of "B""#)?.message, #"card "A": of is out of place"#)
        expectEqual(parseError(#"card "A" sideways "B""#)?.hint,
                    "a placement is above, below, left of, right of (and the corners, as above-left of), level with, inside, outside or on; an attribute is written key: value")
    },
    test("a placement names something, in quotes") {
        expectEqual(parseError(#"card "A" right of"#)?.message, #"card "A": right of names nothing"#)
        expectEqual(parseError(#"card "A" right of"#)?.hint, #"write right of "A""#)
        let unquoted = parseError(#"card "A" right of Hub"#)
        expectEqual(unquoted?.message, #"card "A": Hub isn't quoted, and titles are in double quotes"#)
        expectEqual(unquoted?.hint, #"write right of "Hub""#)
        expectEqual(parseError(#"card "A" right of "B" and"#)?.message, #"card "A": right of names nothing"#)
    },
    test("placements follow one another: an and or a comma between two is refused, with them written so") {
        let and = parseError(#"card "N" right of "A" and below "B""#)
        expectEqual(and?.reason, .syntax)
        expectEqual(and?.message, #"card "N": placements follow one another without and"#)
        expectEqual(and?.hint, #"write right of "A" below "B""#)
        let comma = parseError(#"card "N" right of "A", below "B" priority: high"#)
        expectEqual(comma?.message, #"card "N": placements follow one another without a comma"#)
        expectEqual(comma?.hint, #"write right of "A" below "B""#)
        expectEqual(parseError(#"card "N" right of "A" and "C" and top level with "B" left of "D""#)?.hint,
                    #"write right of "A" and "C" top level with "B" left of "D""#)
        expectEqual(parseError(#"card "N" inside "Z" top-left and below "B""#)?.hint, #"write inside "Z" top-left below "B""#)
        // After a placement's brackets, or a value, the same.
        expectEqual(parseError(#"card "N" right of "A" (gap: wide) and below "B""#)?.hint, #"write right of "A" (gap: wide) below "B""#)
        expectEqual(parseError(#"card "N" right of "A" priority: high and level with "B""#)?.hint, #"write right of "A" level with "B""#)
        // Several shapes a placement names are still joined so.
        expectEqual(try written(#"card right of "A", "B" and board below "C""#), [#"right of "A", "B" and board"#, #"below "C""#])
    },
])

@MainActor let edgeTests = Suite("Edges and deletes", [
    test("an edge: from, to, the arrow, and <- written the other way round") {
        guard case .edge(let forward) = try parse(#"edge "A" -> "B""#) else { throw RequireFailed() }
        expectEqual(forward, EdgeStatement(from: "A", to: "B", arrow: .forward))
        expectEqual(forward.bothHeads, false)
        guard case .edge(let backward) = try parse(#"edge "B" <- "A""#) else { throw RequireFailed() }
        expectEqual(backward.from, "A")
        expectEqual(backward.to, "B")
        expectEqual(backward.written, #""B" <- "A""#)
        guard case .edge(let both) = try parse(#"edge "A" <-> "B""#) else { throw RequireFailed() }
        expectEqual(both.bothHeads, true)
        expectEqual(both.written, #""A" <-> "B""#)
    },
    test("from: and to: are sides; every other key is the caller's, as written") {
        guard case .edge(let edge) = try parse(#"edge "A" -> "B" from: right to: top via: wire weight: 2"#) else { throw RequireFailed() }
        expectEqual(edge.fromSide, .right)
        expectEqual(edge.toSide, .top)
        expectEqual(edge.attributes, [Attribute(key: "via", value: .word("wire")), Attribute(key: "weight", value: .word("2"))])
        let side = parseError(#"edge "A" -> "B" from: middle"#)
        expectEqual(side?.reason, .invalidValue)
        expectEqual(side?.message, #"edge "A" -> "B": from: middle isn't a side"#)
        expectEqual(side?.hint, "from: takes top, right, bottom or left")
        expectEqual(parseError(#"edge "A" -> "B" via: a via: b"#)?.reason, .duplicate)
    },
    test("an edge takes no style, placement, text or third shape") {
        expectEqual(parseError(#"edge "A" -> "B" style: s"#)?.message, #"edge "A" -> "B": an edge can't take a style"#)
        expectEqual(parseError(#"edge "A" -> "B" right of "C""#)?.message, #"edge "A" -> "B": an edge goes where its ends are, so it takes no placement (right)"#)
        let chain = parseError(#"edge "A" -> "B" -> "C""#)
        expectEqual(chain?.reason, .unsupported)
        expectEqual(chain?.message, #"edge "A" -> "B": an edge joins two shapes, and this one goes on to a third"#)
        let text = parseError(#"edge "A" -> "B" "calls""#)
        expectEqual(text?.reason, .unsupported)
        expectEqual(text?.message, #"edge "A" -> "B": edges can't carry text yet: arrows here have no labels"#)
    },
    test("an edge's ends are quoted titles joined by ->, <- or <->") {
        expectEqual(parseError(#"edge A -> "B""#)?.message, "edge: A isn't quoted, and titles are in double quotes")
        let mermaid = parseError(#"edge "A" --> "B""#)
        expectEqual(mermaid?.message, #"edge: --> isn't an arrow"#)
        expectEqual(mermaid?.hint, #"write ->, <- or <->, as edge "A" -> "B""#)
        expectEqual(parseError(#"edge "A""#)?.message, "edge: an edge's two titles are joined by an arrow")
        expectEqual(parseError("edge")?.message, "edge: an edge joins two shapes, by their titles")
    },
    test("delete a shape by its title, or the edges from one to another") {
        expectEqual(try parse(#"delete "Old""#), .delete(.shape(title: "Old")))
        expectEqual(try parse(#"delete edge "A" -> "B""#), .delete(.edges(from: "A", to: "B", eitherWay: false)))
        expectEqual(try parse(#"delete edge "B" <- "A""#), .delete(.edges(from: "A", to: "B", eitherWay: false)))
        expectEqual(try parse(#"delete edge "A" <-> "B""#), .delete(.edges(from: "A", to: "B", eitherWay: true)))
    },
    test("delete takes one quoted title and nothing more") {
        expectEqual(parseError("delete")?.hint, #"write delete "A", or delete edge "A" -> "B""#)
        expectEqual(parseError("delete Old")?.hint, #"write delete "Old""#)
        expectEqual(parseError(#"delete "A" "B""#)?.message, #"delete "A": delete takes one title, and nothing after it ("B")"#)
        expectEqual(parseError(#"delete edge "A" -> "B" from: left"#)?.message, #"edge "A" -> "B": deleting takes no attributes"#)
    },
])

@MainActor let styleTests = Suite("Styles", [
    test("a style's attributes merge into the shapes that name it, tagged with its name") {
        let script = try Script(parsing: """
            style urgent priority: high status: doing
            card "A" style: urgent
            """)
        expectEqual(script.styles, [StyleDefinition(name: "urgent", line: 1, text: "style urgent priority: high status: doing",
                                                    attributes: [Attribute(key: "priority", value: .word("high")), Attribute(key: "status", value: .word("doing"))])])
        guard case .shape(let card) = script.statements[0].body else { throw RequireFailed() }
        expectEqual(script.statements.count, 1)
        expectEqual(card.styles, ["urgent"])
        expectEqual(card.attributes, [Attribute(key: "priority", value: .word("high"), fromStyle: "urgent"),
                                      Attribute(key: "status", value: .word("doing"), fromStyle: "urgent")])
    },
    test("the statement's own attributes beat every style; of several styles, a later one wins") {
        let script = try Script(parsing: """
            card "A" priority: low style: urgent, calm
            style urgent priority: high status: doing owner: "Ann"
            style calm status: todo
            """)
        guard case .shape(let card) = script.statements[0].body else { throw RequireFailed() }
        expectEqual(card.attributes, [Attribute(key: "priority", value: .word("low")),
                                      Attribute(key: "status", value: .word("todo"), fromStyle: "calm"),
                                      Attribute(key: "owner", value: .quoted("Ann"), fromStyle: "urgent")])
    },
    test("size, gap and overlap merge too; the statement's own win") {
        let script = try Script(parsing: """
            style big size: 400x300 gap: wide overlap: allow
            style small size: 50x50
            card "A" style: big
            card "B" style: big, small gap: tight
            """)
        guard case .shape(let a) = script.statements[0].body, case .shape(let b) = script.statements[1].body else { throw RequireFailed() }
        expectEqual(a.size, CGSize(width: 400, height: 300))
        expectEqual(a.gap, .named(.wide))
        expectEqual(a.overlapAllowed, true)
        expectEqual(a.attributes, [])
        expectEqual(b.size, CGSize(width: 50, height: 50))
        expectEqual(b.gap, .named(.tight))
        expectEqual(script.styles[0].attributes.map(\.key), ["size", "gap", "overlap"])
    },
    test("a style's values are checked where it's defined") {
        let error = parseError("style big size: huge\ncard style: big")
        expectEqual(error?.reason, .invalidValue)
        expectEqual(error?.line, 1)
        expectEqual(error?.message, "style big: size: huge isn't a size")
    },
    test("a style holds attributes: at least one, no style:, no title:, no placement") {
        expectEqual(parseError("style empty")?.message, "style empty: a style gives something")
        expectEqual(parseError("style s style: t")?.message, "style s: a style can't take another style")
        expectEqual(parseError(#"style s right of "A""#)?.message, "style s: a style holds attributes, and right isn't one")
        expectEqual(parseError(#"style "s" a: 1"#)?.message, "a style is written style <name> <attributes>")
        expectEqual(parseError("style s a: 1 a: 2")?.reason, .duplicate)
    },
    test("a style used but not defined, or defined twice, is refused") {
        let undefined = parseError("style urgent a: 1\ncard style: urgnet")
        expectEqual(undefined?.reason, .syntax)
        expectEqual(undefined?.line, 2)
        expectEqual(undefined?.message, "style urgnet isn't defined")
        expectEqual(undefined?.hint, "did you mean urgent?")
        expectEqual(parseError("card style: quiet")?.hint, "define it on a line of its own: style quiet <attributes>")
        let twice = parseError("style s a: 1\nstyle s b: 2\ncard style: s")
        expectEqual(twice?.reason, .duplicate)
        expectEqual(twice?.line, 2)
        expectEqual(twice?.message, "style s is defined twice, here and on line 1")
    },
    test("a style whose line can't be read is still defined: the shapes that use it aren't errors too") {
        let errors = parseErrors("""
            style urgent size: 0x5
            card "A" style: urgent right of "X"
            card "B" style: urgent right of "A"
            """)
        expectEqual(errors.map(\.line), [1])
        expectEqual(errors.map(\.reason), [.invalidValue])
        // Refused by the lexer past its name, the same.
        expectEqual(parseErrors("style quiet owner: 'Ann'\ncard style: quiet").map(\.line), [1])
        // A style nobody defines is still one.
        expectEqual(parseErrors("style urgent size: 0x5\ncard style: urgent, quiet").map(\.line), [1, 2])
        expectEqual(parseErrors("style urgent size: 0x5\ncard style: urgent, quiet").last?.message, "style quiet isn't defined")
    },
])

@MainActor let collectedErrorTests = Suite("Collected errors", [
    test("every line that can't be read is reported, each once, in line order") {
        let errors = parseErrors("""
            card "A" rigth of "B"
            card "B"
            edge "A" --> "B"
            card "C" style: nope
            card "D" gap: -1
            """)
        expectEqual(errors.map(\.line), [1, 3, 4, 5])
        expectEqual(errors.map(\.reason), [.syntax, .syntax, .syntax, .invalidValue])
        expectEqual(errors.map(\.statement), [#"card "A" rigth of "B""#, #"edge "A" --> "B""#, #"card "C" style: nope"#, #"card "D" gap: -1"#])
    },
    test("at most twenty are collected, the first leading") {
        let source = (1...30).map { "card \"\($0)\" sideways \"X\"" }.joined(separator: "\n")
        do throws(ScriptErrors) {
            _ = try Script(parsing: source)
            expect(false, "expected errors")
        } catch {
            expectEqual(error.errors.count, ScriptErrors.limit)
            expectEqual(error.errors.map(\.line), Array(1...20))
            expectEqual(error.first.line, 1)
        }
    },
    test("a script with nothing to draw is empty_script; one of only styles too") {
        expectEqual(parseError("")?.reason, .emptyScript)
        expectEqual(parseError("// nothing\n\n")?.reason, .emptyScript)
        expectEqual(parseError("style s a: 1")?.reason, .emptyScript)
    },
    test("errors read as a line and a message") {
        let error = ScriptError(line: 3, reason: .syntax, "bad", hint: "fix it")
        expectEqual(error.description, "line 3: bad (fix it)")
        expectEqual(ScriptError.Reason.noRoom.rawValue, "no_room")
        expectEqual(ScriptError.Reason.allCases.count, 31)
    },
])

@MainActor let vocabularyTests = Suite("Vocabulary", [
    test("a part is a side (a segment) or a point, read off a box's bounds") {
        let size = CGSize(width: 200, height: 100)
        expectEqual(Part.top.rect(in: size), CGRect(x: 0, y: 0, width: 200, height: 0))
        expectEqual(Part.right.rect(in: size), CGRect(x: 200, y: 0, width: 0, height: 100))
        expectEqual(Part.bottom.rect(in: size), CGRect(x: 0, y: 100, width: 200, height: 0))
        expectEqual(Part.left.rect(in: size), CGRect(x: 0, y: 0, width: 0, height: 100))
        expectEqual(Part.center.rect(in: size), CGRect(x: 100, y: 50, width: 0, height: 0))
        expectEqual(Part.topRight.rect(in: size), CGRect(x: 200, y: 0, width: 0, height: 0))
        expectEqual(Part.bottomCenter.rect(in: size), CGRect(x: 100, y: 100, width: 0, height: 0))
        expectEqual(Part.leftCenter.rect(in: size), CGRect(x: 0, y: 50, width: 0, height: 0))
        expectEqual(Part.allCases.filter(\.isCorner), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        expectEqual(Part.allCases.filter(\.isSide), [.top, .bottom, .left, .right])
    },
    test("inside points from a part toward the middle; outside is the opposite") {
        expectEqual(Part.top.inward, .below)
        expectEqual(Part.right.inward, .left)
        expectEqual(Part.topLeft.inward, .belowRight)
        expectEqual(Part.bottomRight.inward, .aboveLeft)
        expectEqual(Part.leftCenter.inward, .right)
        expectEqual(Part.center.inward, nil)
        expectEqual(Direction.aboveLeft.opposite, .belowRight)
        expectEqual(Direction.below.opposite, .above)
        expectEqual(Direction.belowLeft.horizontal, -1)
        expectEqual(Direction.belowLeft.vertical, 1)
    },
    test("gaps in world units") {
        expectEqual(GapName.allCases.map(\.value), [0, 40, 80, 160])
        expectEqual(Gap.units(12).written, "12")
        expectEqual(Gap.units(12.5).written, "12.5")
        expectEqual(Gap.named(.wide).written, "wide")
    },
    test("did you mean: case, spacing and × first, then containing, sharing a word, a few letters off") {
        expectEqual(Suggestions.closest(to: "deploy", among: ["Deploy", "Deploy now", "Depot", "Other"]), ["Deploy", "Deploy now", "Depot"])
        expectEqual(Suggestions.closest(to: "Tile, 120 x 80", among: ["Tile, 120 × 80", "Box"]), ["Tile, 120 × 80"])
        expectEqual(Suggestions.closest(to: "rigth", among: Direction.allCases.map(\.rawValue), limit: 1), ["right"])
        expectEqual(Suggestions.closest(to: "Web tier", among: ["Tier two", "API"]), ["Tier two"])
        expectEqual(Suggestions.closest(to: "zzz", among: ["right", "left"]), [])
    },
    test("did you mean: the fewest edits first within each; one further off in length than a slip allows is passed over, uncounted") {
        // One inside the other: as many edits as the letters left over.
        expectEqual(Suggestions.closest(to: "deploy", among: ["Deploy the plan now", "Deploy now", "Redeploy"]),
                    ["Redeploy", "Deploy now", "Deploy the plan now"])
        // Sharing a word: the edits, not the lengths (both are 9 letters).
        expectEqual(Suggestions.closest(to: "red cache", among: ["cache red", "rod cache"]), ["rod cache", "cache red"])
        // A slip: 3 edits in 10 letters, so a length 4 off is too far however it's spelled.
        expectEqual(Suggestions.closest(to: "Deploymnet", among: ["Deploymentplan", "Deployment"]), ["Deployment"])
        // Titles far longer than the word, none near: they're folded, and none is given an edit
        // table (60 × 600 each, seconds for them all in debug).
        let wanted = String(repeating: "q", count: 60)
        let titles = (0..<300).map { "Title \($0) " + String(repeating: "x", count: 600) }
        var found = ["not asked"]
        let took = threadCPUTime { found = Suggestions.closest(to: wanted, among: titles) }
        expectEqual(found, [])
        expect(took < .milliseconds(500), "300 titles of 600 letters took \(took)")
    },
    test("a near miss: the same title but for case, spacing and ×, or a letter off (two in a long one), never itself") {
        expect(Suggestions.isNearMiss("deploy", "Deploy"))
        expect(Suggestions.isNearMiss("Tile, 120 x 80", "Tile,  120 × 80"))
        expect(Suggestions.isNearMiss("Ship it", "Shop it"))
        expect(Suggestions.isNearMiss("Checkout flow", "Chekout flwo"))
        expect(!Suggestions.isNearMiss("Deploy", "Deploy"), "the same title is no miss")
        expect(!Suggestions.isNearMiss("A", "B"), "short titles only by case")
        expect(!Suggestions.isNearMiss("API", "APP"))
        expect(!Suggestions.isNearMiss("Ship", "Shape"))
        expect(!Suggestions.isNearMiss("Deploy", "Deploy now"))
    },
])
