import Canvas
import CanvasTesting
import Foundation
import Queries
import TestKit
import Topology
import os

// What the engine does with stand-ins it knows nothing of: the edges a query reads in the view its
// request names (`QueryRequest.edges`), and a connection's row, which says what it went through
// (`QueryConnection.via`, `more`). Over the relay of StandIns.swift: a proxy for chore 1, a lens
// answered with chore 2, and wires into them.

/// A query's answer on `h`'s editor in the edge view, as a query is asked (every row, no attributes).
@MainActor func ran(_ text: String, edges: EdgeView = .resolved, on h: EditorHarness, file: StaticString = #fileID,
                    line: UInt = #line) throws -> QueryResult {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryBudget.maxRows, properties: .none, edges: edges))
    }
}

/// The relay with the lens answered "q" with chore 2.
@MainActor func answeredRelay() throws -> EditorHarness {
    let h = try relay()
    try require(h.editor.topology).provide([id(6): provided("q", [id(2)])])
    return h
}

@MainActor let edgeViewTests = Suite("Edge views", [
    test("a request reads the resolved view unless it says otherwise") {
        expectEqual(QueryRequest("*").edges, .resolved)
        expectEqual(QueryRequest("*").settle, nil)
        expectEqual(QueryRequest("*", edges: .literal, settle: .seconds(1)).edges, .literal)
        expectEqual(QueryMatchRequest("*").edges, .resolved)
    },
    test("resolved: an arrow into a stand-in is an arrow into what it stands for; recorded: only for what its record names; literal: as drawn") {
        let h = try answeredRelay()
        let lens = "#\(uuid(6))", proxy = "#\(uuid(5))"
        let cases: [(query: String, resolved: [Int], recorded: [Int], literal: [Int])] = [
            // The lens's answer is Beta: the wire 8 from Gamma reads 3 to Beta, and the wire 10 from the proxy (Alpha) 1 to Beta;
            // the recorded view leaves the lens's end where it is.
            (#"chore:connected-to("Beta")"#, [1, 3], [], []),
            // The lens itself: nothing is left at it resolved; recorded, the wire 8 from Gamma and the wire 10 from what the
            // proxy stands for; as drawn, the wire 8 (the wire 10 is from the proxy, which isn't a chore).
            ("chore:connected-to(\(lens), wire)", [], [1, 3], [3]),
            // The proxy's record names Alpha: every view but the literal sees through it.
            ("chore:connected-to(\(proxy), wire)", [], [], [3]),
            (#"chore:connected-to("Alpha")"#, [2, 3], [3], [3]),
            // The standing edges, resolved, and recorded for what a stand-in's record names; never as drawn.
            (#"proxy:edge-to("Alpha", stands-for)"#, [5], [5], []),
            (#"lens:edge-to("Beta", stands-for)"#, [6], [], []),
            // Where a connection ends or starts is read the same way: the wire 7 from Gamma ends at what the proxy stands for, or
            // at the proxy as drawn; the wire 8 at what the lens was answered with, resolved only; the wire 10 runs from the
            // proxy's Alpha, or the proxy, to the lens's Beta, or the lens.
            (":end-of(#\(uuid(7)))", [1], [1], [5]),
            (":start-of(#\(uuid(7)))", [3], [3], [3]),
            (":end-of(#\(uuid(8)))", [2], [6], [6]),
            (":start-of(#\(uuid(10)))", [1], [1], [5]),
            (":end-of(#\(uuid(10)))", [2], [6], [6]),
            (":end-of(link)", [1, 2], [1, 6], [1, 5, 6]),
            (":start-of(link)", [1, 3], [1, 3], [3, 5]),
            ("chore:end-of(link)", [1, 2], [1], [1]),
        ]
        for (query, resolved, recorded, literal) in cases {
            expectEqual(try ran(query, on: h).rows.map(\.id), resolved.map(id), "\(query), resolved")
            expectEqual(try ran(query, edges: .resolved, on: h).rows.map(\.id), resolved.map(id), "\(query), asked for the resolved view")
            expectEqual(try ran(query, edges: .recorded, on: h).rows.map(\.id), recorded.map(id), "\(query), recorded")
            expectEqual(try ran(query, edges: .literal, on: h).rows.map(\.id), literal.map(id), "\(query), literal")
        }
    },
    test("a stand-in with nothing to stand for leaves its arrows where they are: the lens, before an answer, and what is forwarded from the proxy") {
        let h = try relay()
        // The wire 8 stays at the lens in every view; the wire 10 runs from the proxy's Alpha to the lens, but as drawn from the proxy.
        for (view, found) in [(EdgeView.resolved, [1, 3]), (.recorded, [1, 3]), (.literal, [3])] {
            expectEqual(try ran("chore:connected-to(#\(uuid(6)), wire)", edges: view, on: h).rows.map(\.id), found.map(id), "pending lens, \(view)")
            expectEqual(try ran(#"chore:connected-to("Beta")"#, edges: view, on: h).rows.map(\.id), [], "\(view)")
            // The connections that end there end at the lens, in every view.
            expectEqual(try ran(":end-of(#\(uuid(8)))", edges: view, on: h).rows.map(\.id), [id(6)], "the wire 8 ends at the pending lens, \(view)")
        }
    },
])

@MainActor let connectionViaTests = Suite("A connection that went through a stand-in", [
    test("as drawn, a connection has no via and no more") {
        let h = try answeredRelay()
        let rows = try ran("link", edges: .literal, on: h).rows
        expectEqual(rows.count, 4)
        for row in rows {
            expectEqual(row.connection?.via, nil, "\(row.id)")
            expectEqual(row.connection?.more, nil, "\(row.id)")
        }
        let direct = try require(try ran("#\(uuid(9))", on: h).rows.first?.connection)
        expectEqual(direct, QueryConnection(type: "wire", from: QueryEnd(id: id(3), title: "Gamma"), to: QueryEnd(id: id(1), title: "Alpha")))
    },
    test("an end that was a stand-in: the first pair in file order, the stand-in it went through, and the others") {
        let proxied = CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), chore(id(2), caption: "Beta"), chore(id(3), caption: "Gamma"),
                                                               // Cited out of file order: the pairs are in the file's.
                                                               proxy(id(5), [id(2), id(1)]), link(id(7), id(3), id(5))]))
        let h = try relay(file: proxied)
        let connection = try require(try ran("#\(uuid(7))", on: h).rows.first?.connection)
        expectEqual(connection.from, QueryEnd(id: id(3), title: "Gamma"))
        expectEqual(connection.to, QueryEnd(id: id(1), title: "Alpha"), "the first in file order, not the first the proxy cites")
        expectEqual(connection.via, QueryVia(from: nil, to: QueryEnd(id: id(5))), "a stand-in has no title: its id alone")
        expectEqual(connection.more, [QueryPair(from: QueryEnd(id: id(3), title: "Gamma"), to: QueryEnd(id: id(2), title: "Beta"))])
        // Each pair's end is where the connection ends, in file order: both shapes, resolved; the stand-in, as drawn.
        expectEqual(try ran(":end-of(#\(uuid(7)))", on: h).rows.map(\.id), [id(1), id(2)])
        expectEqual(try ran(":start-of(#\(uuid(7)))", on: h).rows.map(\.id), [id(3)])
        expectEqual(try ran(":end-of(#\(uuid(7)))", edges: .literal, on: h).rows.map(\.id), [id(5)])
    },
    test("an end that was one and stood for one shape has a via and no more; both ends: a pair for each combination") {
        let h = try answeredRelay()
        let one = try require(try ran("#\(uuid(8))", on: h).rows.first?.connection)
        expectEqual(one, QueryConnection(type: "wire", from: QueryEnd(id: id(3), title: "Gamma"), to: QueryEnd(id: id(2), title: "Beta"),
                                         via: QueryVia(to: QueryEnd(id: id(6)))))
        // The wire 10 runs from the proxy (for Alpha) to the lens (for Beta).
        let both = try require(try ran("#\(uuid(10))", on: h).rows.first?.connection)
        expectEqual(both, QueryConnection(type: "wire", from: QueryEnd(id: id(1), title: "Alpha"), to: QueryEnd(id: id(2), title: "Beta"),
                                          via: QueryVia(from: QueryEnd(id: id(5)), to: QueryEnd(id: id(6)))))
    },
    test("the view decides what a connection went through: recorded leaves a lens's end at the lens, as a stand-in with nothing to stand for does") {
        let h = try answeredRelay()
        let recorded = try require(try ran("#\(uuid(8))", edges: .recorded, on: h).rows.first?.connection)
        expectEqual(recorded, QueryConnection(type: "wire", from: QueryEnd(id: id(3), title: "Gamma"), to: QueryEnd(id: id(6))))
        let pending = try relay()
        let waiting = try require(try ran("#\(uuid(8))", on: pending).rows.first?.connection)
        expectEqual(waiting, recorded, "as drawn: nothing was provided")
        let literal = try require(try ran("#\(uuid(7))", edges: .literal, on: h).rows.first?.connection)
        expectEqual(literal, QueryConnection(type: "wire", from: QueryEnd(id: id(3), title: "Gamma"), to: QueryEnd(id: id(5))))
    },
    test("pairs are in the file's order, whatever order what a stand-in stands for is answered in") {
        let h = try answeredRelay()
        try require(h.editor.topology).provide([id(6): provided("q", [id(3), id(2), id(1)], 2)])
        let connection = try require(try ran("#\(uuid(8))", on: h).rows.first?.connection)
        expectEqual(connection.to, QueryEnd(id: id(1), title: "Alpha"))
        expectEqual(connection.more?.map(\.to.id), [id(2), id(3)])
        expectEqual(connection.via?.to, QueryEnd(id: id(6)))
    },
])
