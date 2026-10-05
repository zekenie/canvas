import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// Edges, answered: which way each word reads, a type with those under it against the type alone,
// lists of types and a type nobody declares, edges from a shape to itself, when an anchor is part of
// its own answer, connections' own ends, and what dangles: an end that's gone, kept aside (which
// Topology calls live), or on a board the app can't show. And a compound that starts from few
// anchors reads their edges, never every shape.

/// Chores 1 to 6 on the top board, and links between them: a wire 11 from 1 to 2, a hot wire 12 from
/// 2 to 3, a loose link 13 (a tether) from 3 to 1, a wire 14 from 4 to 4 (itself), and a wire 15 from
/// 5 to 6. Chore 1 cites 4, chore 6 cites itself.
@MainActor func wiresHarness(more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let chores = (1...6).map { n in
        chore(id(n), caption: "C\(n)", Chore(unit, tags: n == 1 ? [uuid(4)] : n == 6 ? [uuid(6)] : []))
    }
    let links = [link(id(11), id(1), id(2)), link(id(12), id(2), id(3), grade: .hot), link(id(13), id(3), id(1), grade: .loose),
                 link(id(14), id(4), id(4)), link(id(15), id(5), id(6))]
    return try EditorHarness(plugins: queryPlugins(more: [citesPlugin()] + more), file: CanvasFile(root: CanvasDocument(shapes: chores + links)))
}

/// A file read from a board file, with chores that cite what the app can't show: chore 1 cites chore
/// 11 (on a board the app can't show, under gadget 10, which is kept aside), chore 2 cites gadget 10
/// (kept aside on the top board, which Topology calls live), chore 3 cites a shape that isn't in the
/// file, and chore 4 cites chore 1.
@MainActor func danglingHarness() throws -> EditorHarness {
    func frame() -> String { "\"frame\" : [[0, 0], [1, 1]]" }
    func chore(_ n: Int, cites: Int) -> String {
        #"{ "id" : "\#(uuid(n))", "kind" : "chore", "index" : "a\#(n)", "props" : { \#(frame()), "tags" : [ "\#(uuid(cites))" ] } }"#
    }
    let json = """
    { "format" : 4, "versions" : { "kinds" : { "chore" : 0 } },
      "shapes" : [ \(chore(1, cites: 11)), \(chore(2, cites: 10)), \(chore(3, cites: 99)), \(chore(4, cites: 1)),
                   { "id" : "\(uuid(10))", "kind" : "gadget", "index" : "a9", "props" : { } } ],
      "boards" : {
        "\(uuid(10))" : { "shapes" : [ { "id" : "\(uuid(11))", "kind" : "chore", "index" : "a0", "props" : { \(frame()) } } ] }
      } }
    """
    let plugins = queryPlugins(more: [citesPlugin()])
    let loaded = try BoardCodec(registry: Registry(plugins: plugins)).decode(Data(json.utf8))
    return try EditorHarness(plugins: plugins, file: loaded.file)
}

@MainActor let edgeTests = Suite("Edges", [
    test("direction: what the result does, to the anchor or from it, either way") {
        let h = try wiresHarness()
        expectMatches([
            #":edge-to("C2")"#: [1],
            #"chore:edge-to("C2")"#: [1],
            #"chore:edge-from("C2")"#: [3],
            #"chore:edge-from("C1")"#: [2, 4],
            #"chore:connected-to("C2")"#: [1, 3],
            #"chore:connected-to("C1")"#: [2, 3, 4],
            // Links carry edges; they aren't their ends.
            ":edge-to(*)": [1, 2, 3, 4, 5, 6],
            "chore:edge-to(*)": [1, 2, 3, 4, 5, 6],
            "chore:edge-from(*)": [1, 2, 3, 4, 6],
            #"chore:wired-to("C2")"#: [1],
            #"chore:cites("C4")"#: [1],
            #"chore:cited-by("C1")"#: [4],
            #"chore:cited-by(*)"#: [4, 6],
        ], on: h)
    },
    test("types: one and those under it, only one, lists, and a type nobody declares") {
        let h = try wiresHarness()
        expectMatches([
            "chore:edge-to(*, wire)": [1, 2, 4, 5],
            "chore:edge-to(*, only wire)": [1, 4, 5],
            "chore:edge-to(*, hot-wire)": [2],
            "chore:edge-to(*, tether)": [3],
            "chore:edge-to(*, cite)": [1, 6],
            "chore:edge-to(*, only wire|hot-wire)": [1, 2, 4, 5],
            "chore:edge-to(*, tether|cite)": [1, 3, 6],
            "chore:dangling(tether)": [],
            #"chore:downstream-of("C1", wire)"#: [2, 3],
            #"chore:downstream-of("C1", only wire)"#: [2],
            #"chore:upstream-of("C1", tether)"#: [3],
            #"chore:component-of("C1", only wire)"#: [2],
        ], on: h)
    },
    test("a shape and itself: one-step words through its own edge, transitive words through a cycle") {
        let h = try wiresHarness()
        expectMatches([
            #"chore:edge-to("C4")"#: [1, 4],
            #"chore:edge-from("C4")"#: [4],
            #"chore:connected-to("C4")"#: [1, 4],
            #"chore:cites("C6")"#: [6],
            #"chore:edge-to("C6", cite)"#: [6],
            // Downstream of C1: C1 again, round the cycle 1 → 2 → 3 → 1, and C4.
            #"chore:downstream-of("C1")"#: [1, 2, 3, 4],
            #"chore:downstream-of("C4")"#: [4],
            #"chore:downstream-of("C5")"#: [6],
            #"chore:upstream-of("C5")"#: [],
            #"chore:upstream-of("C3")"#: [1, 2, 3],
            #"chore:downstream-of("C1", only wire)"#: [2],
            // A component never pairs a shape with itself, but pairs two anchors joined.
            #"chore:component-of("C4")"#: [1, 2, 3],
            #"chore:component-of("C5")"#: [6],
            #"chore:component-of("C6")"#: [5],
            #"chore:component-of(:is("C5", "C6"))"#: [5, 6],
            #"chore:component-of(:is("C5", "C1"))"#: [2, 3, 4, 6],
            #"chore:component-of("C1", cite)"#: [4],
        ], on: h)
    },
    test("connections: where they start, where they end, and between, either way; a text's edges don't count") {
        let h = try wiresHarness()
        expectMatches([
            #"link:starts-at("C1")"#: [11],
            #"link:ends-at("C1")"#: [13],
            #":starts-at("C4")"#: [14],
            #":ends-at("C4")"#: [14],
            #"link:between("C1", "C2")"#: [11],
            #"link:between("C2", "C1")"#: [11],
            #"link:between("C1", *)"#: [11, 13],
            #"link:between(chore, chore, hot-wire)"#: [12],
            #"link:between("C4", "C4")"#: [14],
            // A chore's citations are in its tags, not its own: it's no connection.
            #":starts-at("C1", cite)"#: [],
            #":starts-at(*, cite)"#: [],
            "link:starts-at(*)": [11, 12, 13, 14, 15],
        ], on: h)
        let row = try require(answer(#"link:ends-at("C1")"#, on: h).rows.first)
        expectEqual(row.connection, QueryConnection(type: tether, from: QueryEnd(id: id(3), title: "C3"), to: QueryEnd(id: id(1), title: "C1")))
        expectEqual(try answer("#\(uuid(1))", on: h).rows.first?.connection, nil, "a chore is no connection, citing or not")
    },
    test("dangling: an end that's gone, kept aside, or on a board the app can't show; never a live one") {
        let h = try danglingHarness()
        expectMatches([
            ":dangling": [1, 2, 3],
            ":dangling(cite)": [1, 2, 3],
            ":dangling(wire)": [],
            "#\(uuid(1)):dangling": [1],
            "#\(uuid(4)):dangling": [],
            // Ends outside the range match no anchor and are reached by nothing.
            "chore:cites(*)": [4],
            ":edge-to(*)": [4],
            ":edge-from(*)": [1],
            ":connected-to(*)": [1, 4],
            #":downstream-of(#\#(uuid(4)))"#: [1],
        ], on: h)
    },
    test("few anchors: the compound starts from their edges, and walks no shape but theirs") {
        let h = try wiresHarness()
        let queries = try require(h.editor.queries)
        @MainActor func walks(_ text: String, _ expected: [Int], walked: Int, seeded: Int, line: UInt = #line) throws {
            let (walks, seeds) = (queries.universeWalks, queries.seededFromAnchors)
            expectEqual(try matched(text, on: h), expected.map(id), text, line: line)
            expectEqual(queries.universeWalks - walks, walked, "\(text): walks of every shape", line: line)
            expectEqual(queries.seededFromAnchors - seeds, seeded, "\(text): compounds started from anchors", line: line)
        }
        // An anchor named by its id: its edges' far ends, each looked up, in file order.
        try walks("chore:edge-to(#\(uuid(2)))", [1], walked: 0, seeded: 1)
        try walks("chore:edge-from(#\(uuid(1)))", [2, 4], walked: 0, seeded: 1)
        try walks("link:starts-at(#\(uuid(1)))", [11], walked: 0, seeded: 1)
        try walks("link:between(#\(uuid(1)), #\(uuid(2)))", [11], walked: 0, seeded: 1)
        try walks("chore:wired-to(#\(uuid(2)))", [1], walked: 0, seeded: 1)
        try walks("chore[caption=C1]:connected-to(#\(uuid(2)))", [1], walked: 0, seeded: 1)
        // An anchor named by a name is found among every name: a walk, then the seed.
        try walks(#"chore:edge-to("C2")"#, [1], walked: 1, seeded: 1)
        // A compound with an id of its own starts there.
        try walks("#\(uuid(1)):edge-to(#\(uuid(2)))", [1], walked: 0, seeded: 0)
        // Transitive words don't seed: the compound walks.
        try walks("chore:downstream-of(#\(uuid(5)))", [6], walked: 1, seeded: 0)
        let encoded = queries.recordsEncoded
        _ = try matched("chore[status=todo]:edge-to(#\(uuid(2)))", on: h)
        expectEqual(queries.recordsEncoded - encoded, 1, "only the far end's properties were read")
    },
])
