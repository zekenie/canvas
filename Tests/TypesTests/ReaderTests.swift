import Foundation
import TestKit
import Types

/// The error reading `text` gives, or nil if it reads.
private func error(_ text: String) -> JSONSyntaxError? {
    do throws(JSONSyntaxError) {
        _ = try JSONReader.read(text)
        return nil
    } catch {
        return error
    }
}

/// "line:column message", which reads well in a failure.
private func where_(_ text: String) -> String? {
    error(text).map { "\($0.line):\($0.column) \($0.message)" }
}

@MainActor let readerTests = Suite("JSON reader", [
    test("an object's members come back in the order written, duplicates included; lookup takes the last") {
        let node = try JSONReader.read(#"{"zebra": 1, "apple": 2, "mango": {"b": true, "a": null}, "apple": 3}"#)
        expectEqual(node.members?.map(\.key), ["zebra", "apple", "mango", "apple"])
        expectEqual(node["mango"]?.members?.map(\.key), ["b", "a"])
        expectEqual(node["apple"]?.number, 3)
        expectEqual(node["mango"]?["b"]?.bool, true)
        expectEqual(node["mango"]?["a"]?.value, .null)
        expectEqual(node["nothing"]?.value, nil)
    },
    test("every value and key knows where it is, in UTF-8 offsets, quotes and brackets included") {
        let text = #"{ "name": "Ada", "tags": ["x", 12.5e1], "é": false }"#
        let node = try JSONReader.read(text)
        let utf8 = Array(text.utf8)
        func source(_ range: Range<Int>) -> String { String(decoding: utf8[range], as: UTF8.self) }
        expectEqual(source(node.range), text)
        let members = try require(node.members)
        expectEqual(members.map { source($0.keyRange) }, [#""name""#, #""tags""#, #""é""#])
        expectEqual(members.map { source($0.value.range) }, [#""Ada""#, #"["x", 12.5e1]"#, "false"])
        expectEqual(node["tags"]?.elements?.map { source($0.range) }, [#""x""#, "12.5e1"])
        expectEqual(node["tags"]?.elements?.last?.value, .number("12.5e1"))
        expectEqual(node["tags"]?.elements?.last?.number, 125)
    },
    test("strings decode their escapes: quotes, backslashes, control characters, \\u, surrogate pairs") {
        let node = try JSONReader.read(#"["a\"b\\c\/d", "\n\t\r\b\f", "é中", "😀", "\ud83d"]"#)
        expectEqual(node.elements?.map(\.string), ["a\"b\\c/d", "\n\t\r\u{08}\u{0C}", "é中", "😀", "\u{FFFD}"])
    },
    test("literal writes a string back as JSON, which reads as the same string") {
        for string in ["plain", "quote \" and \\ backslash", "line\nbreak\ttab", "\u{01}\u{1F}", "é 😀 中"] {
            expectEqual(try JSONReader.read(JSONReader.literal(string)).string, string)
        }
        expectEqual(JSONReader.literal("a\"b\n\u{01}"), #""a\"b\n\u0001""#)
    },
    test("errors say where, as a person counts: line and column from 1, columns in characters") {
        // The spec's invalid fixture: a trailing comma before "}" on line 6.
        expectEqual(where_(fixture(10)), "6:35 Expected a property name")
        expectEqual(where_("{\n  \"é\": [1, 2,,]\n}"), "2:14 Expected a value")
        expectEqual(where_("{\"a\" 1}"), "1:6 Expected “:”")
        expectEqual(where_("{\"a\": 1 \"b\": 2}"), "1:9 Expected “,” or “}”")
        expectEqual(where_("[1 2]"), "1:4 Expected “,” or “]”")
        expectEqual(where_("{\"a\": 1"), "1:8 Expected “,” or “}”")
        expectEqual(where_("{\"a\": \"open\n}"), "1:7 Unterminated string")
        expectEqual(where_("{\"a\": True}"), "1:7 Unexpected “True”")
        expectEqual(where_("{'a': 1}"), "1:2 Expected a property name")
        expectEqual(where_("[01]"), "1:2 Invalid number")
        expectEqual(where_("[1.]"), "1:2 Invalid number")
        expectEqual(where_("[-]"), "1:2 Invalid number")
        expectEqual(where_(#"["\x"]"#), "1:3 Invalid escape")
        expectEqual(where_("[\"a\tb\"]"), "1:4 Control character in a string")
        expectEqual(where_("{} {}"), "1:4 Unexpected text after the end")
        expectEqual(where_(""), "1:1 Expected a value")
        expectEqual(where_("   \n "), "2:2 Expected a value")
        expectEqual(where_("{\"a\": 1} // note"), "1:10 Unexpected text after the end")
    },
    test("an error keeps the root's members read whole before it") {
        let error = try require(error(fixture(10)))
        expectEqual(error.rootMembers.map(\.key), ["title", "type"])
        expectEqual(error.rootMembers.first?.value.string, "Invoice")
        expectEqual(error.description, "Line 6, column 35: Expected a property name")
    },
    test("odd, huge, deep or hostile input never crashes: every text reads or says why") {
        // Nesting past the limit is an error, not a stack overflow.
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        expectEqual(error(deep)?.message, "Nested more than \(JSONReader.maxDepth) deep")
        expectEqual(error(deep)?.column, JSONReader.maxDepth + 1)
        let deepObject = String(repeating: #"{"a":"#, count: 5_000) + "1" + String(repeating: "}", count: 5_000)
        expect(error(deepObject) != nil)
        let limit = String(repeating: "[", count: JSONReader.maxDepth) + String(repeating: "]", count: JSONReader.maxDepth)
        expectEqual(error(limit), nil, "exactly as deep as allowed")
        // Big, and wide.
        let long = String(repeating: "x", count: 2_000_000)
        expectEqual(try JSONReader.read("\"\(long)\"").string?.count, 2_000_000)
        let wide = "{" + (0..<20_000).map { "\"k\($0)\": \($0)" }.joined(separator: ",") + "}"
        expectEqual(try JSONReader.read(wide).members?.count, 20_000)
        // Scraps and junk: none crash, and each error is inside the text.
        let scraps = ["{", "}", "[", "]", ":", ",", "\"", "\\", "{\"", "{\"a", "{\"a\"", "{\"a\":", "{\"a\":\"", "[\"\\", "[\"\\u12",
                      "[\"\\ud83d\\u", "-", "1e", "1e+", "nul", "tru", "\u{0}", "\u{FEFF}{}", "{\"a\":1,}", "[,]", "😀", "{\"😀\":😀}",
                      String(repeating: "{\"a\":[", count: 300), String(repeating: "\"", count: 101)]
        for text in scraps {
            if let error = error(text) {
                expect(error.offset >= 0 && error.offset <= text.utf8.count, "\(text): \(error)")
                expect(error.line >= 1 && error.column >= 1, "\(text): \(error)")
            }
        }
        // Random bytes, deterministically.
        var seed: UInt64 = 42
        let alphabet = Array("{}[]:,\"\\ 0123456789-+.eEtrufalsn\n\té😀ab")
        for _ in 0..<500 {
            var text = ""
            for _ in 0..<40 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                text.append(alphabet[Int(seed >> 33) % alphabet.count])
            }
            if let error = error(text) { expect(error.offset <= text.utf8.count, text) }
        }
    },
    test("tokens: every token in order, with where it is, whether or not the text is JSON") {
        let text = "{\"a\": [1, true], \"b\" oops \"open\n}"
        let tokens = JSONReader.tokens(in: text)
        let utf8 = Array(text.utf8)
        expectEqual(tokens.map { "\($0.kind):\(String(decoding: utf8[$0.range], as: UTF8.self))" }, [
            "openBrace:{", "string:\"a\"", "colon::", "openBracket:[", "number:1", "comma:,", "literal:true", "closeBracket:]",
            "comma:,", "string:\"b\"", "invalid:oops", "invalid:\"open", "closeBrace:}",
        ])
    },
    test("line and column of any offset, for pointing into a text") {
        let text = "ab\ncdé\nf"
        expectEqual(JSONReader.position(of: 0, in: text).line, 1)
        expectEqual(JSONReader.position(of: 3, in: text).line, 2)
        expectEqual(JSONReader.position(of: 3, in: text).column, 1)
        // "é" is two UTF-8 bytes but one column.
        expectEqual(JSONReader.position(of: 7, in: text).column, 4)
        expectEqual(JSONReader.position(of: 8, in: text).line, 3)
        expectEqual(JSONReader.position(of: 999, in: text).column, 2)
    },
])
