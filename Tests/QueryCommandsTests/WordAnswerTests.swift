import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import Queries
import QueryCommands
import TestKit

// `canvas query`'s JSON when a word adds to it: `at` on every row that has a box, a word's members flat
// beside a row's own, and `absent` only when a word names something the file no longer holds. The fixture
// words are `:tagged("Alpha")` (a chore with that caption; absent: `gone-Alpha`) and `:boxed` (every chore).

private func wordsOfTheirOwn() -> Contributor {
    Contributor(id: "their-own") { registrar in
        registrar.queryPseudoClass("tagged", "its caption is the tag", example: #":tagged("Alpha")"#, argument: "tag", reads: .file,
                                   prepare: { (_: QueryFilePreparation, text: String) in text },
                                   matches: { shape, text in shape.record[Caption.self] == text ? .yes : .no },
                                   members: ["tag", "shout"],
                                   rowMembers: { _, text in ["tag": .string(text), "shout": .bool(true)] },
                                   absent: { text in [QueryAbsent(id: "gone-\(text)", members: ["tag": .string(text), "why": .string("deleted")])] })
        registrar.queryPseudoClass("boxed", "it is a chore", example: ":boxed", reads: .file,
                                   prepare: { (_: QueryFilePreparation) in () },
                                   matches: { shape, _ in shape.record.kind == Chore.kind ? .yes : .no })
    }
}

@MainActor let wordAnswerTests = Suite("query, with words that add to the answer", [
    test("a row says where the shape is, [[x, y], [width, height]], and an arrow, which has no box, doesn't") {
        let h = try shelfHarness()
        let rows = try require(try answered(["query", "*", "--brief"], on: h)["rows"]?.arrayValue)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"]?.stringValue ?? "", $0) })
        let chore = try require(byID[uuid(1)])
        expectEqual(chore["at"], .array([.array([0, 0]), .array([100, 60])]))
        expectEqual(try require(byID[uuid(3)])["at"], nil, "the link has none")
        expect(rows.filter { $0["kind"]?.stringValue != "link" }.allSatisfy { $0["at"] != nil }, "every other row has one")
        // After inside, whatever the row lists; for --fields and the full row too.
        let fields = try require(try answered(["query", "#\(uuid(1))", "--fields", "note"], on: h)["rows"]?.arrayValue?.first)
        expectEqual(fields["at"], chore["at"])
        expect(fields["properties"]?["note"] != nil)
        let full = try require(try answered(["query", "#\(uuid(1))"], on: h)["rows"]?.arrayValue?.first)
        expectEqual(full["at"], chore["at"])
        expect(full["properties"]?["frame"] == nil, "a place stays no attribute")
    },
    test("a word's members are flat on the rows it matched, kept by --brief and --fields, and its rows are the rows' own encoding") {
        let h = try shelfHarness(commandPlugins() + [wordsOfTheirOwn()])
        let answer = try answered(["query", #"chore:tagged("Alpha")"#], on: h)
        expectEqual(answer["query"], .string(#"chore:tagged("Alpha")"#))
        let rows = try require(answer["rows"]?.arrayValue)
        expectEqual(rows.count, 1)
        expectEqual(rows[0]["tag"], .string("Alpha"))
        expectEqual(rows[0]["shout"], .bool(true))
        expectEqual(rows[0]["at"], .array([.array([0, 0]), .array([100, 60])]))
        expect(rows[0]["properties"]?["note"] != nil, "the row lists its attributes still")
        for line in [["query", #"chore:tagged("Alpha")"#, "--brief"], ["query", #"chore:tagged("Alpha")"#, "--fields", "status"]] {
            let kept = try require(try answered(line, on: h)["rows"]?.arrayValue?.first)
            expectEqual(kept["tag"], .string("Alpha"), "\(line)")
            expectEqual(kept["shout"], .bool(true), "\(line)")
            expectEqual(kept["at"], rows[0]["at"], "\(line)")
        }
        let queries = try require(h.editor.queries)
        let result = try awaitResult { try await queries.run(QueryRequest(#"chore:tagged("Alpha")"#)) }
        for row in result.rows { expectEqual(QueryOutput.row(row), try JSON(encoding: row), "\(row.id)") }
        let other = try require(try answered(["query", "chore:boxed"], on: h)["rows"]?.arrayValue)
        expect(other.allSatisfy { $0["tag"] == nil }, "a word that adds none")
    },
    test("absent is written with the answer when a word names something the file no longer holds, as warnings are, and not otherwise; --count keeps it") {
        let h = try shelfHarness(commandPlugins() + [wordsOfTheirOwn()])
        let answer = try answered(["query", #"chore:tagged("Alpha")"#], on: h)
        expectEqual(answer["absent"], .array([.object(["id": .string("gone-Alpha"), "tag": .string("Alpha"), "why": .string("deleted")])]))
        expectEqual(answer["warnings"], nil)
        let counted = try answered(["query", #"chore:tagged("Alpha")"#, "--count"], on: h)
        expectEqual(counted["rows"], nil)
        expectEqual(counted["count"], 1)
        expectEqual(counted["absent"], answer["absent"])
        let two = try answered(["query", #":tagged("Beta"), :tagged("Alpha")"#], on: h)
        expectEqual(two["absent"]?.arrayValue?.map { $0["id"]?.stringValue }, ["gone-Alpha", "gone-Beta"], "in the order of the words' names")
        let none = try answered(["query", "chore:boxed"], on: h)
        expectEqual(none["absent"], nil, "no key at all when empty")
        expectEqual(try answered(["query", #"chore:tagged("Nobody")"#], on: h)["rows"]?.arrayValue?.count, 0)
    },
    test("query-vocabulary lists a word with a text as :word(\"…\") and its argument's name") {
        let h = try shelfHarness(commandPlugins() + [wordsOfTheirOwn()])
        let answer = try answered(["query-vocabulary"], on: h)
        let words = try require(answer["words"]?.arrayValue)
        let tagged = try require(words.first { $0["word"]?.stringValue == "tagged" })
        expectEqual(tagged["form"], nil)
        expectEqual(tagged["takes"], .string("tag"))
        expectEqual(tagged["example"], .string(#":tagged("Alpha")"#))
        expect(answer["vocabulary"]?.stringValue?.contains(#"- :tagged("…") — its caption is the tag. Example: :tagged("Alpha")"#) == true)
    },
])
