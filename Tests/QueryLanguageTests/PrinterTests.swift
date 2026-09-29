import Foundation
import QueryLanguage
import TestKit

@MainActor let canonicalTests = Suite("Canonical form", [
    test("spacing: one space around >, a comma and a space between items, none inside brackets or parentheses") {
        expectCanonical("  card  ,box  ", "card, box")
        expectCanonical(#""A">card"#, #""A" > card"#)
        expectCanonical("\"A\"\n\n  card", #""A" card"#)
        expectCanonical("card /* one */ box", "card box")
        expectCanonical("[ rank = 3 ]", "[rank=3]")
        expectCanonical(":not( card , box )", ":not(card, box)")
        expectCanonical(":has(>card,box)", ":has(> card, box)")
        expectCanonical(":edge-to( * , wire | hot-wire )", ":edge-to(*, wire|hot-wire)")
        expectCanonical(#":between( "A","B" ,pipe )"#, #":between("A", "B", pipe)"#)
    },
    test("words lowercased, data words as written") {
        expectCanonical(":NOT(Card):Top-Level", ":not(Card):top-level")
        expectCanonical(":dangling(ONLY Wire|only pipe)", ":dangling(only Wire|only pipe)")
        expectCanonical("[rank=\"3\" I]", #"[rank="3" i]"#)
        expectCanonical("[status=Done S]", "[status=Done s]")
        expectCanonical(":GLOWS", ":glows")
    },
    test("strings in double quotes, escaping only what needs it") {
        expectCanonical("'Payments'", #""Payments""#)
        expectCanonical(#"'it\'s'"#, #""it's""#)
        expectCanonical(#"'say "hi"'"#, #""say \"hi\"""#)
        expectCanonical(#""a\\b\nc""#, #""a\\b\nc""#)
        expectCanonical(#":contains('x')"#, #":contains("x")"#)
        expectCanonical("card'it\\'s'", #"card"it's""#)
        expectCanonical(#"card"Pay" > box"#, #"card"Pay" > box"#)
        expectCanonical(#"card  "Pay""#, #"card "Pay""#)
        expectCanonical(#"[status='done']"#, #"[status="done"]"#)
        expectCanonical(#"[status="done"i]"#, #"[status="done" i]"#)
        expectCanonical("\"👍🏽 /* not a comment */\"", "\"👍🏽 /* not a comment */\"")
    },
    test("a name in quotes only when it isn't an identifier; a bare value as written") {
        expectCanonical(#"["rank"=3]"#, "[rank=3]")
        expectCanonical(#"['my attr'^=x]"#, #"["my attr"^=x]"#)
        expectCanonical(#"["a.b"]"#, #"["a.b"]"#)
        expectCanonical("[due>=2026-10-01]", "[due>=2026-10-01]")
        expectCanonical("[status=a(b),c)]", "[status=a(b),c)]")
    },
    test("ids in capitals") {
        expectCanonical("#7c1e2a04-4b9e-4e0c-9d8c-5b0e7f3a2c11", "#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11")
    },
    test("an unknown word's argument is canonical when it reads as shapes, else as written, trimmed") {
        expectCanonical(#":stacked( "A" , 'B' )"#, #":stacked("A", "B")"#, sameTree: false)
        expectCanonical(":stacked( card   >box )", ":stacked(card > box)", sameTree: false)
        expectCanonical(":glows( 2n + 1 )", ":glows(2n + 1)", sameTree: false)
        expectCanonical(":glows( /* nothing */ )", ":glows()", sameTree: false)
        expectCanonical(":glows()", ":glows()")
        expectCanonical(":glows(a (b) /* ) */ c)", ":glows(a (b) /* ) */ c)")
        expectCanonical(":glows(:stacked( 'x' ))", #":glows(:stacked("x"))"#, sameTree: false)
    },
    test("every construct of the language, printed as the language writes it") {
        let written = [
            "card", "*", #""Checkout""#, #"card"Checkout""#, "#00000000-0000-4000-8000-000000000011",
            "box, card", #""Payments" > *"#, #""Payments" card"#,
            "[rank]", "[rank=3]", "[rank!=3]", #"[status^="in"]"#, "[status$=x]", "[status*=x]", "[status~=x]", "[status|=x]",
            "[rank<3]", "[rank<=3]", "[rank>3]", "[rank>=3]", #"[status="x" i]"#, "[status=x s]",
            ":not(card)", #":is("A", "B")"#, ":where(*)", #":inside("Payments")"#, #":has("B")"#, #":has(> "B", card)"#,
            ":top-level", ":current-board",
            #":edge-to("Auth")"#, #":edge-from("A", wire)"#, ":connected-to(card, only wire|pipe)", ":downstream-of(*)", ":upstream-of(*)",
            ":component-of(*)", ":starts-at(*)", ":ends-at(*)", #":between("A", "B")"#, #":between("A", "B", wire)"#,
            ":dangling", ":dangling(wire)", #":contains("retry")"#, ":glows", #":stacked("A")"#,
            #""Payments" card[rank>3]:not(:has(*)):edge-to(:is("A", "B"), only wire)"#,
        ]
        for text in written { expectCanonical(text, text) }
    },
    test("each part prints as the whole query prints it") {
        let read = try parse(#"'Pay' > card[ status = 'x' I ]:stacked( 'A' ), box"#)
        let complex = read.selectors[0], compound = complex.compounds[1]
        expectEqual(complex.canonical, #""Pay" > card[status="x" i]:stacked("A")"#)
        expectEqual(compound.canonical, #"card[status="x" i]:stacked("A")"#)
        expectEqual(complex.compounds[0].head?.canonical, #""Pay""#)
        expectEqual(Head.id(UUID(uuidString: "00000000-0000-4000-8000-00000000001a")!, nowhere).canonical, "#00000000-0000-4000-8000-00000000001A")
        expectEqual(kind("card", titled: #"say "hi""#).canonical, #"card"say \"hi\"""#)
        guard case .attribute(let test) = compound.filters[0], case .pseudo(let stacked) = compound.filters[1] else { throw RequireFailed() }
        expectEqual(test.canonical, #"[status="x" i]"#)
        expectEqual(stacked.canonical, #":stacked("A")"#)
    },
    test("a tree built by hand prints what reads back to it") {
        let built = list(
            complex(compound(titled("Pay \"ments\""), attribute("my attr", .hasWord, .quoted("x y"), .insensitive)), (.child, compound(nil, pseudo("glows")))),
            complex(compound(kind("card"), pseudo("between", .anchored([complex(compound(.any)), complex(compound(id("00000000-0000-4000-8000-000000000011")))],
                                                                      types: [type("wire", only: true), type("pipe")])))))
        let text = built.canonical
        expectEqual(text, #""Pay \"ments\""["my attr"~="x y" i] > :glows, card:between(*, #00000000-0000-4000-8000-000000000011, only wire|pipe)"#)
        expectEqual(stripped(try parse(text)), built)
    },
])
