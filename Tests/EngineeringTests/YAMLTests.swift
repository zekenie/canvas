import Engineering
import TestKit
import Types

// The kit's YAML subset (`YAMLReader`), pure: block mappings and sequences in the order written (a sequence at its key's indent),
// the core schema's scalars, keys always strings, quoted strings over lines, block scalars and their chomping, one-line flow
// collections, comments, a leading `---`, plain scalars folded over lines; and what it refuses whole: anchors, aliases, tags, `?`
// keys, flow over several lines, a tab in an indent, a second document, a line where none belongs.

private func read(_ text: String) throws -> SchemaValue? { try YAMLReader.read(text) }

private func keys(_ value: SchemaValue?) -> [String] { value?.members?.map(\.key) ?? [] }

@MainActor private func refuses(_ text: String, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
    do {
        let value = try YAMLReader.read(text)
        expect(false, "\(what): read as \(String(describing: value))", file: file, line: line)
    } catch {
        expect(!error.message.isEmpty, what, file: file, line: line)
    }
}

@MainActor let yamlTests = Suite("YAML, the kit's subset", [
    test("block mappings keep the order written, nest by indent, and a sequence may sit at its key's indent or past it") {
        let value = try read("""
            openapi: 3.1.0
            info:
              title: billing API
              version: 1.0.0
            tags:
            - one
            - two
            servers:
              - url: https://billing.shop.dev
                description: live
              - url: http://localhost
            zebra: last
            alpha: after
            """)
        expectEqual(keys(value), ["openapi", "info", "tags", "servers", "zebra", "alpha"], "written order, not sorted")
        expectEqual(value?["info"]?["title"], .string("billing API"))
        expectEqual(value?["tags"], .array([.string("one"), .string("two")]), "a sequence at its key's indent")
        expectEqual(value?["servers"]?.elements?.count, 2)
        expectEqual(keys(value?["servers"]?.elements?.first), ["url", "description"], "a mapping in an item: its keys at the first key's column")
        expectEqual(value?["servers"]?.elements?.last?["url"], .string("http://localhost"))
        expectEqual(value?["openapi"], .string("3.1.0"), "two dots: a string")
    },
    test("the core schema's scalars: null, booleans, integers in decimal, octal and hex, floats, infinities; anything else a string") {
        let value = try read("""
            a: ~
            b: null
            c:
            d: true
            e: False
            f: 42
            g: -7
            h: 0o17
            i: 0x1F
            j: 1.5
            k: 6.02e23
            l: .inf
            m: yes
            n: 3.1
            o: 1.2.3
            p: 007
            """)
        expectEqual(value?["a"], .null)
        expectEqual(value?["b"], .null)
        expectEqual(value?["c"], .null, "nothing after the colon")
        expectEqual(value?["d"], .bool(true))
        expectEqual(value?["e"], .bool(false))
        expectEqual(value?["f"], .number(42))
        expectEqual(value?["g"], .number(-7))
        expectEqual(value?["h"], .number(15))
        expectEqual(value?["i"], .number(31))
        expectEqual(value?["j"], .number(1.5))
        expectEqual(value?["k"], .number(6.02e23))
        expectEqual(value?["l"], .number(.infinity))
        expectEqual(value?["m"], .string("yes"), "YAML 1.2: yes is a string")
        expectEqual(value?["n"], .number(3.1))
        expectEqual(value?["o"], .string("1.2.3"))
        expectEqual(value?["p"], .number(7))
    },
    test("keys are strings, a number-like one too (200:), quoted ones unquoted; a key written twice keeps its first place and its last value") {
        let value = try read("""
            responses:
              200:
                description: ok
              "404":
                description: gone
              'default': {}
              3.0: x
            b: 1
            a: 2
            b: 3
            """)
        expectEqual(keys(value?["responses"]), ["200", "404", "default", "3.0"])
        expectEqual(keys(value), ["responses", "b", "a"])
        expectEqual(value?["b"], .number(3))
    },
    test("quoted strings: single with '' for a quote, double with escapes; over several lines, folded") {
        let value = try read(#"""
            a: 'it''s # not a comment'
            b: "tab\there \"q\" \u00e9 \x41"
            c: "first
              second

              third"
            d: 'one
              two'
            e: "joined\
              up"
            """#)
        expectEqual(value?["a"], .string("it's # not a comment"))
        expectEqual(value?["b"], .string("tab\there \"q\" é A"))
        expectEqual(value?["c"], .string("first second\nthird"), "a line break a space, a blank line a line break")
        expectEqual(value?["d"], .string("one two"))
        expectEqual(value?["e"], .string("joinedup"), "an escaped line break joins with nothing")
    },
    test("block scalars: | keeps line breaks, > folds them; - strips the last, + keeps them all, none keeps one; an indentation digit") {
        let value = try read("""
            literal: |
              line one
                indented
              line three
            folded: >
              a long
              sentence

              new paragraph
            strip: |-
              no break
            keep: |+
              kept

            digit: |2
                four spaces
            after: here
            """)
        expectEqual(value?["literal"], .string("line one\n  indented\nline three\n"))
        expectEqual(value?["folded"], .string("a long sentence\nnew paragraph\n"))
        expectEqual(value?["strip"], .string("no break"))
        expectEqual(value?["keep"], .string("kept\n\n"))
        expectEqual(value?["digit"], .string("  four spaces\n"), "content at two past its key: two spaces are the text's")
        expectEqual(value?["after"], .string("here"), "the block ends where the indent does")
    },
    test("flow collections on one line, nested; comments anywhere a line or a value allows; a leading --- and directives before it") {
        let value = try read("""
            %YAML 1.2
            ---
            # a comment line
            list: [a, "b, c", 3, {k: v, n: [1, 2]}]   # trailing
            empty: []
            map: {a: 1, 'b': two}
            url: http://x.dev/#frag
            note: plain # cut here
            """)
        expectEqual(value?["list"], .array([.string("a"), .string("b, c"), .number(3),
                                            .object([SchemaMember(key: "k", value: .string("v")), SchemaMember(key: "n", value: .array([.number(1), .number(2)]))])]))
        expectEqual(value?["empty"], .array([]))
        expectEqual(keys(value?["map"]), ["a", "b"])
        expectEqual(value?["url"], .string("http://x.dev/#frag"), "a # with no space before it is the text's")
        expectEqual(value?["note"], .string("plain"))
    },
    test("plain scalars folded over the lines indented past their key; sequences of sequences; an empty document is nothing") {
        let value = try read("""
            description: This endpoint returns
              the statements of a customer,

              newest first.
            matrix:
              - - 1
                - 2
              - - 3
            next: 1
            """)
        expectEqual(value?["description"], .string("This endpoint returns the statements of a customer,\nnewest first."))
        expectEqual(value?["matrix"], .array([.array([.number(1), .number(2)]), .array([.number(3)])]))
        expectEqual(value?["next"], .number(1))
        expectEqual(try read("# nothing\n\n"), nil)
        expectEqual(try read("---\n...\n"), nil)
    },
    test("refused whole: anchors, aliases, tags, ? keys, flow over several lines, a tab in an indent, a second document, a line where none belongs") {
        refuses("base: &base\n  a: 1\n", "an anchor")
        refuses("copy: *base\n", "an alias")
        refuses("a: !!str 1\n", "a tag")
        refuses("? complex\n: value\n", "a ? key")
        refuses("list: [a,\n  b]\n", "a flow sequence over two lines")
        refuses("map: {a: 1,\n  b: 2}\n", "a flow mapping over two lines")
        refuses("a:\n\tb: 1\n", "a tab in an indent")
        refuses("a: 1\n---\nb: 2\n", "a second document")
        refuses("a: 1\n  b: 2\n", "a line indented past a scalar")
        refuses("a: 1\n- b\n", "an item among a mapping's keys")
        refuses("a: \"open\n", "a string left open")
        refuses("a: [1] trailing\n", "words after a flow collection")
    },
])
