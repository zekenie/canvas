import QueryLanguage
import TestKit

@MainActor let limitsTests = Suite("Limits", [
    test("the limits, pinned") {
        expectEqual(QueryLimits.characters, 8_192)
        expectEqual(QueryLimits.depth, 32)
        expectEqual(QueryLimits.compounds, 256)
        expectEqual(QueryLimits.errors, 20)
        expectEqual(QueryLimits.stringCharacters, 1_024)
    },
    test("a query of 8,192 characters reads; one more is too long") {
        expectEqual(stripped(try parse(String(repeating: "a", count: 8_192))), single(kind(String(repeating: "a", count: 8_192))))
        expectEqual(try parse(String(repeating: "e\u{301}", count: 8_192)).selectors.count, 1, "Characters, not scalars or bytes")
        expectRefused([
            Refused(String(repeating: "a", count: 8_193), .tooLong, "The query is 8,193 characters long; a query is at most 8,192.",
                    hint: "Ask several shorter queries.", at: 8_192, 1),
            Refused(String(repeating: " ", count: 10_000), .tooLong, "The query is 10,000 characters long; a query is at most 8,192.",
                    hint: "Ask several shorter queries.", at: 8_192, 1_808),
        ])
    },
    test("a string of 1,024 characters reads; one more is too long") {
        let most = String(repeating: "x", count: 1_024)
        expectEqual(stripped(try parse("\"\(most)\"")), single(titled(most)))
        expectEqual(stripped(try parse("\"\(String(repeating: #"\""#, count: 1_024))\"")), single(titled(String(repeating: "\"", count: 1_024))),
                    "escapes undone before counting")
        expectRefused([
            Refused("card[status=\"\(most)x\"]", .tooLong, "The string is 1,025 characters long; a string is at most 1,024.", at: 12, 1_027),
            Refused(":glows('\(most)x')", .tooLong, "The string is 1,025 characters long; a string is at most 1,024.", at: 7, 1_027),
        ])
    },
    test("32 levels of parentheses read; 33 are too complex, in a word the language doesn't know too") {
        func nested(_ levels: Int) -> String { String(repeating: ":not(", count: levels) + "card" + String(repeating: ")", count: levels) }
        expectEqual(try parse(nested(32)).canonical, nested(32))
        let deep = "The query nests more than 32 levels of parentheses."
        expectRefused([
            Refused(nested(33), .tooComplex, deep, hint: "Ask several shorter queries.", at: 32 * 5 + 4, 1),
            Refused(":glows(" + String(repeating: "(", count: 32) + String(repeating: ")", count: 33), .tooComplex, deep,
                    hint: "Ask several shorter queries.", at: 7 + 31, 1),
            Refused(String(repeating: ":not(", count: 31) + ":glows((x))" + String(repeating: ")", count: 31), .tooComplex, deep,
                    hint: "Ask several shorter queries.", at: 31 * 5 + 7, 1),
        ])
        expect(refusal(":glows(" + String(repeating: "(", count: 31) + String(repeating: ")", count: 32)) == nil)
    },
    test("256 compounds read; 257 are too complex, counted in arguments too, a plugin's word's too, and the compound an argument is in") {
        let most = Array(repeating: "card", count: 256).joined(separator: ", ")
        expectEqual(try parse(most).selectors.count, 256)
        expectRefused([
            Refused(most + ", box", .tooComplex, "The query has more than 256 parts.", hint: "Ask several shorter queries.", at: 256 * 6, 1),
            Refused(":not(" + Array(repeating: "card", count: 256).joined(separator: " ") + ")", .tooComplex, "The query has more than 256 parts.",
                    hint: "Ask several shorter queries.", at: 5 + 255 * 5, 1),
            Refused(":stacked(" + Array(repeating: "card", count: 256).joined(separator: " ") + ")", .tooComplex, "The query has more than 256 parts.",
                    hint: "Ask several shorter queries.", at: 9 + 255 * 5, 1),
        ])
        expectEqual(try parse(":stacked(" + Array(repeating: "card", count: 255).joined(separator: " ") + ")").selectors.count, 1,
                    "a word the language doesn't know counts the parts its argument reads as")
        expectEqual(try parse(":glows(" + Array(repeating: "2n+1", count: 300).joined(separator: " ") + ")").selectors.count, 1,
                    "and nothing for one that doesn't read as shapes")
    },
])
