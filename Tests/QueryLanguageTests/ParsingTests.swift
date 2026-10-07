import Foundation
import QueryLanguage
import TestKit

@MainActor let parsingTests = Suite("Parsing", [
    test("a compound starts with a kind, *, a title in either quotes or an id, in any case") {
        expectEqual(stripped(try parse("card")), single(kind("card")))
        expectEqual(stripped(try parse("*")), single(.any))
        expectEqual(stripped(try parse(#""Payments""#)), single(titled("Payments")))
        expectEqual(stripped(try parse("'Payments'")), single(titled("Payments")))
        expectEqual(stripped(try parse("#00000000-0000-4000-8000-00000000001a")), single(id("00000000-0000-4000-8000-00000000001A")))
        expectEqual(stripped(try parse("#7c1e2a04-4b9e-4e0c-9d8c-5b0e7f3a2c11")), single(id("7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11")))
        expectEqual(stripped(try parse("Card")), single(kind("Card")), "a kind is an id: its case is kept")
        expectEqual(stripped(try parse("wide_card-2")), single(kind("wide_card-2")))
        expectEqual(stripped(try parse("_card")), single(kind("_card")))
        expectEqual(stripped(try parse("é-card")), single(kind("é-card")), "letters are Unicode's")
    },
    test("a kind with a title right after it, no space between, is one head: the kind's shapes with that title") {
        expectEqual(stripped(try parse(#"card"Payments""#)), single(kind("card", titled: "Payments")))
        expectEqual(stripped(try parse("card'Payments'")), single(kind("card", titled: "Payments")))
        expectEqual(stripped(try parse(#"wide_card-2"it's \"it\"""#)), single(kind("wide_card-2", titled: #"it's "it""#)))
        expectEqual(stripped(try parse(#"card"Payments"[rank>3]:glows"#)),
                    single(kind("card", titled: "Payments"), attribute("rank", .greater, .bare("3")), pseudo("glows")))
        let read = try parse(#"card"👍🏽 Pay" > box"#)
        expectEqual(read.selectors[0].compounds[0].head, .kindTitle("card", at(0, 4), title: "👍🏽 Pay", at(4, 7)), "each where it is")
        expectEqual(read.selectors[0].compounds[0].span, at(0, 11))
        expectEqual(stripped(try parse(#"card "Payments""#)), list(complex(compound(kind("card")), (.descendant, compound(titled("Payments"))))),
                    "with a space, the title is inside the kind's shapes")
        expectEqual(stripped(try parse(#":edge-to(card"Auth")"#)),
                    single(nil, pseudo("edge-to", .anchored([complex(compound(kind("card", titled: "Auth")))], types: nil))))
    },
    test("filters follow the head, or stand alone") {
        expectEqual(stripped(try parse(#"card[rank>3]:inside("Payments")"#)),
                    single(kind("card"), attribute("rank", .greater, .bare("3")), pseudo("inside", .selectors(single(titled("Payments"))))))
        expectEqual(stripped(try parse("[rank]:glows")), single(nil, attribute("rank"), pseudo("glows")))
        expectEqual(stripped(try parse(":glows[rank]")), single(nil, pseudo("glows"), attribute("rank")))
    },
    test("a comma is OR, a space is inside, and > is directly on") {
        expectEqual(stripped(try parse("box, card")), list(complex(compound(kind("box"))), complex(compound(kind("card")))))
        expectEqual(stripped(try parse("box ,card")), list(complex(compound(kind("box"))), complex(compound(kind("card")))))
        expectEqual(stripped(try parse(#""Payments" card"#)), list(complex(compound(titled("Payments")), (.descendant, compound(kind("card"))))))
        for text in [#""Payments" > card"#, #""Payments">card"#, "\"Payments\"\n>\tcard", #""Payments" >card"#] {
            expectEqual(stripped(try parse(text)), list(complex(compound(titled("Payments")), (.child, compound(kind("card"))))), text)
        }
        expectEqual(stripped(try parse("* > box card, disc")),
                    list(complex(compound(.any), (.child, compound(kind("box"))), (.descendant, compound(kind("card")))), complex(compound(kind("disc")))))
    },
    test("after >, a compound may start without a head: the > says what the space would only seem to") {
        expectEqual(stripped(try parse("card > :glows")), list(complex(compound(kind("card")), (.child, compound(nil, pseudo("glows"))))))
        expectEqual(stripped(try parse("card>[rank]")), list(complex(compound(kind("card")), (.child, compound(nil, attribute("rank"))))))
        expectEqual(stripped(try parse("card,\n:glows")), list(complex(compound(kind("card"))), complex(compound(nil, pseudo("glows")))),
                    "after a comma, a new selector starts")
    },
    test("attribute tests take every operator, a value bare or quoted, a flag, and a quoted name") {
        for op in Operator.allCases {
            expectEqual(stripped(try parse("[rank\(op.rawValue)3]")), single(nil, attribute("rank", op, .bare("3"))), op.rawValue)
        }
        expectEqual(stripped(try parse("[ rank = 3 ]")), single(nil, attribute("rank", .equals, .bare("3"))))
        expectEqual(stripped(try parse(#"[status="in review" i]"#)), single(nil, attribute("status", .equals, .quoted("in review"), .insensitive)))
        expectEqual(stripped(try parse("[status=done I]")), single(nil, attribute("status", .equals, .bare("done"), .insensitive)))
        expectEqual(stripped(try parse("[status=done s ]")), single(nil, attribute("status", .equals, .bare("done"), .sensitive)))
        expectEqual(stripped(try parse("[status='done'i]")), single(nil, attribute("status", .equals, .quoted("done"), .insensitive)),
                    "a flag may follow a quoted value at once, as in CSS")
        expectEqual(stripped(try parse("[status=i i]")), single(nil, attribute("status", .equals, .bare("i"), .insensitive)))
        expectEqual(stripped(try parse(#"["my attr"]"#)), single(nil, attribute("my attr")))
        expectEqual(stripped(try parse(#"['a.b'^="x"]"#)), single(nil, attribute("a.b", .startsWith, .quoted("x"))), "a quoted name is any text")
        expectEqual(stripped(try parse("[due<2026-10-01]")), single(nil, attribute("due", .less, .bare("2026-10-01"))))
        expectEqual(stripped(try parse("[rank=-2.5]")), single(nil, attribute("rank", .equals, .bare("-2.5"))))
        expectEqual(stripped(try parse("[status=a(b),c)]")), single(nil, attribute("status", .equals, .bare("a(b),c)"))),
                    "a bare value runs to whitespace, ] or a quote")
        expectEqual(stripped(try parse("[rank=3/* three */]")), single(nil, attribute("rank", .equals, .bare("3"))), "and to a comment")
        expectEqual(stripped(try parse(#"[status=""]"#)), single(nil, attribute("status", .equals, .quoted(""))))
        expectEqual(stripped(try parse("[rank=+3]")), single(nil, attribute("rank", .equals, .bare("+3"))))
    },
    test("the language's words read their arguments by their signatures") {
        expectEqual(stripped(try parse("card:not(box, disc)")),
                    single(kind("card"), pseudo("not", .selectors(list(complex(compound(kind("box"))), complex(compound(kind("disc"))))))))
        expectEqual(stripped(try parse(#":is("A"):where(*)"#)),
                    single(nil, pseudo("is", .selectors(single(titled("A")))), pseudo("where", .selectors(single(.any)))))
        expectEqual(stripped(try parse(#":inside("Payments" > card)"#)),
                    single(nil, pseudo("inside", .selectors(list(complex(compound(titled("Payments")), (.child, compound(kind("card")))))))))
        expectEqual(stripped(try parse(#":has(> "B", card[rank])"#)),
                    single(nil, pseudo("has", .has([HasItem(child: true, compound: compound(titled("B"))),
                                                    HasItem(compound: compound(kind("card"), attribute("rank")))]))))
        expectEqual(stripped(try parse(":has(>:glows)")), single(nil, pseudo("has", .has([HasItem(child: true, compound: compound(nil, pseudo("glows")))]))))
        expectEqual(stripped(try parse(":top-level:current-board")), single(nil, pseudo("top-level"), pseudo("current-board")))
        for word in [Word.edgeTo, .edgeFrom, .connectedTo, .downstreamOf, .upstreamOf, .componentOf, .startsAt, .endsAt, .startOf, .endOf] {
            expectEqual(stripped(try parse(#":\#(word.rawValue)("Auth")"#)),
                        single(nil, pseudo(word.rawValue, .anchored([complex(compound(titled("Auth")))], types: nil))), word.rawValue)
        }
        expectEqual(stripped(try parse(":edge-from(*, wire)")), single(nil, pseudo("edge-from", .anchored([complex(compound(.any))], types: [type("wire")]))))
        expectEqual(stripped(try parse(":connected-to(card, only wire | hot-wire|pipe)")),
                    single(nil, pseudo("connected-to", .anchored([complex(compound(kind("card")))],
                                                                 types: [type("wire", only: true), type("hot-wire"), type("pipe")]))))
        expectEqual(stripped(try parse(#":edge-to("Payments" > card)"#)),
                    single(nil, pseudo("edge-to", .anchored([complex(compound(titled("Payments")), (.child, compound(kind("card"))))], types: nil))))
        expectEqual(stripped(try parse(#":edge-to(:is("Auth", "Checkout"))"#)),
                    single(nil, pseudo("edge-to", .anchored([complex(compound(nil, pseudo("is", .selectors(list(complex(compound(titled("Auth"))),
                                                                                                                complex(compound(titled("Checkout"))))))))],
                                                            types: nil))))
        // The ends of a connection: its anchor is a connection, any query that finds one, edge types after a comma.
        expectEqual(stripped(try parse(#":end-of(:starts-at("Warehouse"))"#)),
                    single(nil, pseudo("end-of", .anchored([complex(compound(nil, pseudo("starts-at", .anchored([complex(compound(titled("Warehouse")))],
                                                                                                                types: nil))))], types: nil))))
        expectEqual(stripped(try parse(":start-of(link, only wire|pipe)")),
                    single(nil, pseudo("start-of", .anchored([complex(compound(kind("link")))], types: [type("wire", only: true), type("pipe")]))))
        expectEqual(stripped(try parse(#":between("A", "B")"#)),
                    single(nil, pseudo("between", .anchored([complex(compound(titled("A"))), complex(compound(titled("B")))], types: nil))))
        expectEqual(stripped(try parse(#":between("A", "B", pipe)"#)),
                    single(nil, pseudo("between", .anchored([complex(compound(titled("A"))), complex(compound(titled("B")))], types: [type("pipe")]))))
        expectEqual(stripped(try parse(":dangling")), single(nil, pseudo("dangling")))
        expectEqual(stripped(try parse(":dangling(wire|only pipe)")), single(nil, pseudo("dangling", .types([type("wire"), type("pipe", only: true)]))))
        expectEqual(stripped(try parse(#":contains("retry")"#)), single(nil, pseudo("contains", .text("retry"))))
        expectEqual(stripped(try parse(#":contains( 'it\'s' )"#)), single(nil, pseudo("contains", .text("it's"))))
        expectEqual(stripped(try parse(":not(:has(*))")), single(nil, pseudo("not", .selectors(single(nil, pseudo("has", .has([HasItem(compound: compound(.any))])))))))
    },
    test("only is a word before a type; alone, it's a type named so") {
        expectEqual(stripped(try parse(":dangling(only)")), single(nil, pseudo("dangling", .types([type("only")]))))
        expectEqual(stripped(try parse(":dangling(only|wire)")), single(nil, pseudo("dangling", .types([type("only"), type("wire")]))))
        expectEqual(stripped(try parse(":dangling(only only)")), single(nil, pseudo("dangling", .types([type("only", only: true)]))))
        expectEqual(stripped(try parse(":dangling(ONLY /* x */ Wire)")), single(nil, pseudo("dangling", .types([type("Wire", only: true)]))))
    },
    test("the language's words ignore ASCII case; kinds and edge types keep theirs") {
        expectEqual(stripped(try parse(":NOT(Card)")), single(nil, pseudo("not", .selectors(single(kind("Card"))))))
        expectEqual(stripped(try parse(":Edge-To(*, ONLY Wire)")), single(nil, pseudo("edge-to", .anchored([complex(compound(.any))], types: [type("Wire", only: true)]))))
        expectEqual(stripped(try parse(":GLOWS")), single(nil, pseudo("glows")))
        expectEqual(stripped(try parse(":ÉLAN")), single(nil, pseudo("Élan")), "only ASCII letters are lowercased")
        expectEqual(try parse(":Top-Level").selectors[0].compounds[0].filters, [.pseudo(PseudoClass(name: "top-level", span: at(0, 10), nameSpan: at(0, 10)))])
    },
    test("a word the language doesn't know keeps its argument's text as written, and where it is") {
        expectEqual(try parse(":glows"), SelectorList([ComplexSelector(compounds: [Compound(filters: [
            .pseudo(PseudoClass(name: "glows", span: at(0, 6), nameSpan: at(0, 6)))], span: at(0, 6))], span: at(0, 6))]))
        let empty = try parse(":glows()").selectors[0].compounds[0].filters[0]
        expectEqual(empty, .pseudo(PseudoClass(name: "glows", argument: .raw("", at(7, 0)), span: at(0, 8), nameSpan: at(0, 6))))
        let text = #":glows( 2n + 1 )"#
        expectEqual(try parse(text).selectors[0].compounds[0].filters[0],
                    .pseudo(PseudoClass(name: "glows", argument: .raw(" 2n + 1 ", at(7, 8)), span: at(0, 16), nameSpan: at(0, 6))))
        let nested = #":stacked(a (b) "c)" /* ) */ d)"#
        expectEqual(stripped(try parse(nested)), single(nil, pseudo("stacked", .raw(#"a (b) "c)" /* ) */ d"#, nowhere))),
                    "parentheses, strings and comments inside it are passed over")
        expectEqual(stripped(try parse(":glows(anything: [at all] ~ + ||)")), single(nil, pseudo("glows", .raw("anything: [at all] ~ + ||", nowhere))),
                    "what's inside isn't read")
        expectEqual(stripped(try parse("card:stacked(box[status*=:)])")), single(kind("card"), pseudo("stacked", .raw("box[status*=:)]", nowhere))),
                    "an argument that reads as shapes ends where the grammar says: a parenthesis in a value closes nothing, as in :not's")
        expectEqual(stripped(try parse(#":glows(box[status^="]" /* ] */ i][rank*=(])"#)),
                    single(nil, pseudo("glows", .raw(#"box[status^="]" /* ] */ i][rank*=(]"#, nowhere))))
        expectEqual(stripped(try parse(":glows(a[b), box[rank]")), list(complex(compound(nil, pseudo("glows", .raw("a[b", nowhere)))),
                                                                         complex(compound(kind("box"), attribute("rank")))),
                    "one that doesn't runs to the parenthesis that balances its own")
    },
    test("a plugin's relation reads its argument as shapes, spans in the whole query") {
        let query = #"card:stacked("A", 'B')"#
        guard case .pseudo(let stacked) = try parse(query).selectors[0].compounds[0].filters[0] else { throw RequireFailed() }
        expectEqual(stacked.argument, .raw(#""A", 'B'"#, at(13, 8)))
        let argument = try SelectorList(argumentOf: stacked)
        expectEqual(argument, SelectorList([
            ComplexSelector(compounds: [Compound(head: .title("A", at(13, 3)), span: at(13, 3))], span: at(13, 3)),
            ComplexSelector(compounds: [Compound(head: .title("B", at(18, 3)), span: at(18, 3))], span: at(18, 3)),
        ]))
        expectEqual(argument.canonical, #""A", "B""#)

        guard case .pseudo(let stray) = try parse("card:stacked(card :x)").selectors[0].compounds[0].filters[0] else { throw RequireFailed() }
        do throws(QueryError) {
            _ = try SelectorList(argumentOf: stray)
            expect(false, "a stray space inside is refused")
        } catch {
            expectEqual(error.reason, .straySpace)
            expectEqual(error.span, at(18, 2))
        }
        for text in [":stacked", ":stacked()", ":stacked( /* none */ )"] {
            guard case .pseudo(let bare) = try parse(text).selectors[0].compounds[0].filters[0] else { throw RequireFailed() }
            do throws(QueryError) {
                _ = try SelectorList(argumentOf: bare)
                expect(false, "\(text) has no shapes")
            } catch {
                expectEqual(error, QueryError(.badArgument, ":stacked takes shapes.", hint: #":stacked("Auth")"#, span: bare.span), text)
            }
        }
        guard case .pseudo(let smile) = try parse("card:stacked(box[status*=:)])").selectors[0].compounds[0].filters[0] else { throw RequireFailed() }
        expectEqual(try SelectorList(argumentOf: smile), SelectorList([ComplexSelector(compounds: [
            Compound(head: .kind("box", at(13, 3)), filters: [.attribute(AttributeTest(name: "status", op: .contains, value: .bare(":)"), span: at(16, 12)))],
                     span: at(13, 15)),
        ], span: at(13, 15))]))
        guard case .pseudo(let not) = try parse(":not(card)").selectors[0].compounds[0].filters[0] else { throw RequireFailed() }
        expectEqual(try SelectorList(argumentOf: not),
                    SelectorList([ComplexSelector(compounds: [Compound(head: .kind("card", at(5, 4)), span: at(5, 4))], span: at(5, 4))]),
                    "a word's own selectors are themselves")
    },
    test("comments go wherever whitespace may, and count as whitespace") {
        expectEqual(stripped(try parse("/* board: story */ card")), single(kind("card")))
        expectEqual(stripped(try parse("card/* a */,/* b */box")), list(complex(compound(kind("card"))), complex(compound(kind("box")))))
        expectEqual(stripped(try parse(#""Payments"/* inside */card"#)), list(complex(compound(titled("Payments")), (.descendant, compound(kind("card"))))))
        expectEqual(stripped(try parse("[ /* x */ rank /* y */ = /* z */ 3 /* w */ ]")), single(nil, attribute("rank", .equals, .bare("3"))))
        expectEqual(stripped(try parse(":not( /* a */ card /* b */ )")), single(nil, pseudo("not", .selectors(single(kind("card"))))))
        expectEqual(stripped(try parse(#""a /* b */""#)), single(titled("a /* b */")), "in a string, it's text")
        expectEqual(stripped(try parse("card /* ✓ */\n")), single(kind("card")))
        expectEqual(stripped(try parse("card /*/ still a comment */")), single(kind("card")), "/*/ opens and doesn't close")
    },
    test("a string takes \\\" \\' \\\\ and \\n, in either quote") {
        expectEqual(stripped(try parse(#""say \"hi\"""#)), single(titled(#"say "hi""#)))
        expectEqual(stripped(try parse(#"'it\'s'"#)), single(titled("it's")))
        expectEqual(stripped(try parse(#""it's""#)), single(titled("it's")))
        expectEqual(stripped(try parse(#"'say "hi"'"#)), single(titled(#"say "hi""#)))
        expectEqual(stripped(try parse(#""a\\b""#)), single(titled(#"a\b"#)))
        expectEqual(stripped(try parse(#""line\nbreak""#)), single(titled("line\nbreak")))
        expectEqual(stripped(try parse(#""\"""#)), single(titled("\"")))
        expectEqual(stripped(try parse("\"👍🏽 café\t)\"")), single(titled("👍🏽 café\t)")), "a tab and a parenthesis are text")
    },
    test("a query may span lines, and positions count Characters") {
        let text = "card,\n  \"👍🏽 Payments\" > box[rank>3]"
        let read = try parse(text)
        expectEqual(read.selectors[0].span, at(0, 4))
        let second = read.selectors[1]
        expectEqual(second.compounds[0].head, .title("👍🏽 Payments", at(8, 12)))
        expectEqual(second.compounds[1].head, .kind("box", at(23, 3)))
        expectEqual(second.compounds[1].filters, [.attribute(AttributeTest(name: "rank", op: .greater, value: .bare("3"), span: at(26, 8)))])
        expectEqual(second.span, at(8, 26))
    },
    test("every node knows where it is") {
        let star = Compound(head: .any, span: at(29, 1))
        let edge = PseudoClass(name: "edge-to", argument: .anchored([ComplexSelector(compounds: [star], span: at(29, 1))],
                                                                     types: [TypeTerm(name: "wire", only: true, span: at(32, 9))]),
                               span: at(20, 22), nameSpan: at(20, 8))
        let card = Compound(head: .kind("card", at(8, 4)),
                            filters: [.attribute(AttributeTest(name: "rank", op: .greater, value: .bare("3"), span: at(12, 8))), .pseudo(edge)],
                            span: at(8, 34))
        expectEqual(try parse(#""Pay" > card[rank>3]:edge-to(*, only wire)"#), SelectorList([
            ComplexSelector(compounds: [Compound(head: .title("Pay", at(0, 5)), span: at(0, 5)), card], combinators: [.child], span: at(0, 42)),
        ]))

        let has = PseudoClass(name: "has", argument: .has([HasItem(child: true, compound: Compound(head: .kind("box", at(7, 3)), span: at(7, 3)))]),
                              span: at(0, 11), nameSpan: at(0, 4))
        let glows = PseudoClass(name: "glows", argument: .raw("x", at(18, 1)), span: at(11, 9), nameSpan: at(11, 6))
        let dangling = PseudoClass(name: "dangling", argument: .types([TypeTerm(name: "pipe", span: at(30, 4))]), span: at(20, 15), nameSpan: at(20, 9))
        let contains = PseudoClass(name: "contains", argument: .text("r"), span: at(35, 14), nameSpan: at(35, 9))
        let filters: [Filter] = [.pseudo(has), .pseudo(glows), .pseudo(dangling), .pseudo(contains)]
        expectEqual(try parse(#":has(> box):glows(x):dangling(pipe):contains("r")"#),
                    SelectorList([ComplexSelector(compounds: [Compound(filters: filters, span: at(0, 49))], span: at(0, 49))]))

        let padded = try parse("  box ,  #00000000-0000-4000-8000-000000000011[rank]  ")
        expectEqual(padded.selectors.map(\.span), [at(2, 3), at(9, 43)])
        expectEqual(padded.selectors[1].compounds[0].head, .id(UUID(uuidString: "00000000-0000-4000-8000-000000000011")!, at(9, 37)))
    },
])
