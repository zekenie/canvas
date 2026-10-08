import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import Foundation
import Queries
import QueryLanguage
import StickyNotes
import TestKit
import Topology

// Queries on the shipped list, on the story file (`QueryStory`): every construct the language has,
// as the design's table answers it, row for row (the skill's reference/query.md runs each of them
// through `canvas` as built too), and what a row says of the shape it lists.

/// A row of the design's table of every construct: its number, the query, and its answer, the
/// shapes it lists in file order (by the story's letters) or the reason it's refused.
struct StoryQuery {
    enum Answer {
        /// The story's letters, "" for none.
        case shapes(String)
        case refused(QueryError.Reason)
    }

    let number: Int
    let query: String
    let answer: Answer

    init(_ number: Int, _ query: String, _ answer: Answer) {
        self.number = number
        self.query = query
        self.answer = answer
    }

    /// Every row; a row with several queries once for each.
    static let table: [StoryQuery] = [
        StoryQuery(1, "sticky-note", .shapes("C, Y, N2, A, U, N1, L")),
        StoryQuery(2, "*", .shapes("P, C, F, Y, N2, A, U, N1, W, S, V, R1, R2, L")),
        StoryQuery(3, "subboard, schema-card", .shapes("P, F, W, S, V")),
        StoryQuery(4, #""Checkout""#, .shapes("C")),
        StoryQuery(4, #"sticky-note"Checkout""#, .shapes("C")),
        StoryQuery(5, #""Order""#, .shapes("S")),
        StoryQuery(5, #"schema-card"Order""#, .shapes("S")),
        StoryQuery(6, #"[title="checkout" i]"#, .shapes("C")),
        StoryQuery(7, #"[title^="API"]"#, .shapes("A")),
        StoryQuery(8, "sticky-note[title]", .shapes("C, Y, A, U, L")),
        StoryQuery(9, "sticky-note:not([title])", .shapes("N2, N1")),
        StoryQuery(9, #"sticky-note[title=""]"#, .shapes("N2, N1")),
        StoryQuery(10, "#00000000-0000-4000-8000-000000000011", .shapes("C")),
        StoryQuery(11, "[locked]", .shapes("Y, S")),
        StoryQuery(12, "[locked=false]", .shapes("P, C, F, N2, A, U, N1, W, V, R1, R2, L")),
        StoryQuery(13, #"sticky-note[text*="TODO"]"#, .shapes("N1")),
        StoryQuery(14, #"sticky-note[text*="@API gateway"]"#, .shapes("C")),
        StoryQuery(15, "arrow[channel]", .shapes("R1")),
        StoryQuery(15, "arrow:not([channel])", .shapes("R2")),
        StoryQuery(15, #"arrow[channel=""]"#, .shapes("R2")),
        StoryQuery(16, "arrow[channel=note-link]", .shapes("R1")),
        StoryQuery(17, #":contains("auth")"#, .shapes("A, U")),
        StoryQuery(18, #""Payments" > *"#, .shapes("C, F, N2")),
        StoryQuery(19, #""Payments" *"#, .shapes("C, F, Y, N2")),
        StoryQuery(20, #"sticky-note:inside("Payments")"#, .shapes("C, Y, N2")),
        StoryQuery(21, #""Refund policy":inside("Payments")"#, .shapes("Y")),
        StoryQuery(22, #""Checkout":inside("Refunds")"#, .shapes("")),
        StoryQuery(23, #"subboard:has("Refund policy")"#, .shapes("P, F")),
        StoryQuery(24, #":has(> "Refund policy")"#, .shapes("F")),
        StoryQuery(25, #""Payments":has(> "Refund policy")"#, .shapes("")),
        StoryQuery(26, "sticky-note:top-level", .shapes("A, U, N1, L")),
        StoryQuery(27, ":current-board", .shapes("P, A, U, N1, W, S, V, R1, R2, L")),
        StoryQuery(28, #"sticky-note:mentions("API gateway")"#, .shapes("C")),
        StoryQuery(29, #""Checkout":mentioned-by("API gateway")"#, .shapes("C")),
        StoryQuery(30, ":mentioned-by(*)", .shapes("C, A")),
        StoryQuery(31, "sticky-note:not(:mentions(*))", .shapes("Y, N2, U, N1, L")),
        StoryQuery(32, ":dangling", .shapes("L")),
        StoryQuery(32, "sticky-note:dangling(mention)", .shapes("L")),
        StoryQuery(33, #":edge-to("Auth")"#, .shapes("A")),
        StoryQuery(34, #":edge-from("API gateway")"#, .shapes("C, U")),
        StoryQuery(35, #":edge-from("API gateway", arrow)"#, .shapes("U")),
        StoryQuery(36, #":edge-from("API gateway", only arrow)"#, .shapes("")),
        StoryQuery(37, #":edge-to("Payments", only arrow)"#, .shapes("W")),
        StoryQuery(38, #":edge-from("API gateway", note-link|mention)"#, .shapes("C, U")),
        StoryQuery(39, #":connected-to("Checkout")"#, .shapes("A")),
        StoryQuery(40, #":downstream-of("Checkout")"#, .shapes("C, A, U")),
        StoryQuery(41, #":upstream-of("Auth")"#, .shapes("C, A")),
        StoryQuery(42, #":component-of("Warehouse")"#, .shapes("P")),
        StoryQuery(43, #"arrow:starts-at("Warehouse")"#, .shapes("R2")),
        StoryQuery(43, #"arrow:ends-at("Auth")"#, .shapes("R1")),
        StoryQuery(44, #"arrow:between("Auth", "API gateway")"#, .shapes("R1")),
        StoryQuery(45, ":selected", .shapes("U")),
        StoryQuery(46, ":invalid", .shapes("V")),
        StoryQuery(46, ":warned", .shapes("")),
        StoryQuery(47, #""Payments" sticky-note[locked]"#, .shapes("Y")),
        StoryQuery(48, ":is(subboard, schema-card):edge-from(*)", .shapes("P")),
        StoryQuery(49, "sticky-note:edge-to(*, note-link)", .shapes("A")),
        StoryQuery(50, #"[title="Chekout"]"#, .shapes("")),
        StoryQuery(51, "sticky-note :selected", .refused(.straySpace)),
        StoryQuery(52, #":inside("Warehouse")"#, .refused(.cannotContain)),
        StoryQuery(53, #":mentions("Old ledger")"#, .refused(.unknownTitle)),
        StoryQuery(54, "note", .refused(.unknownKind)),
        StoryQuery(55, #":end-of(arrow:starts-at("Warehouse"))"#, .shapes("P")),
        StoryQuery(55, #":start-of(arrow:ends-at("Auth"))"#, .shapes("A")),
    ]
}

/// A query's answer on `queries`, every row listed, with no properties; or why it's refused.
@MainActor func storyAnswer(_ query: String, on queries: QueryState, properties: QueryRequest.Properties = .none) throws -> Result<QueryResult, QueryError> {
    try awaitResult { () async -> Result<QueryResult, QueryError> in
        do throws(QueryError) {
            return .success(try await queries.run(QueryRequest(query, limit: QueryBudget.maxRows, properties: properties)))
        } catch {
            return .failure(error)
        }
    }
}

/// The story's letters for shapes, in their order: "C, A".
@MainActor func storyLetters(_ ids: [ShapeID]) -> String {
    let names = Dictionary(uniqueKeysWithValues: QueryStory.letters.map { ($1, $0) })
    return ids.map { names[$0] ?? $0.description }.joined(separator: ", ")
}

@MainActor let queryShippedTests = Suite("Queries, as shipped", [
    test("every construct answers on the story file as the design's table says, row for row, each answer in file order") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryStory.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)
        let before = h.file
        expectEqual(Set(StoryQuery.table.map(\.number)), Set(1...55), "every row of the table")
        for row in StoryQuery.table {
            let said = "row \(row.number), \(row.query)"
            switch (row.answer, try storyAnswer(row.query, on: queries)) {
            case (.shapes(let letters), .success(let result)):
                let expected = letters.isEmpty ? [] : QueryStory.ids(letters)
                expectEqual(storyLetters(result.rows.map(\.id)), storyLetters(expected), said)
                expectEqual(result.count, expected.count, said)
                // Each answer lists its shapes in file order, and says the query as the language writes it.
                expectEqual(result.rows.map(\.id), QueryStory.fileOrder.filter(Set(expected).contains), "\(said): in file order")
                expectEqual(result.query, row.query, "\(said): as written, it's the canonical form")
            case (.refused(let reason), .failure(let error)):
                expectEqual(error.reason, reason, "\(said): \(error)")
            case (_, let outcome):
                expect(false, "\(said) answered \(outcome), not \(row.answer)")
            }
        }
        expectEqual(h.file, before, "no query changes the file")
        expect(!h.editor.undoHistory.canUndo, "nor makes a step")
    },
    test("what the table's answers say besides their shapes: a yes by its count, a connection's ends, a near title, and each refusal's hint") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryStory.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)

        // Rows 21 and 22: a yes/no question is a query that lists the shape it asks about, or nothing.
        expectEqual(try storyAnswer(#""Refund policy":inside("Payments")"#, on: queries).get().count, 1)
        expectEqual(try storyAnswer(#""Checkout":inside("Refunds")"#, on: queries).get().count, 0)

        // Row 16: a connection's row says where it runs.
        let link = try require(try storyAnswer("arrow[channel=note-link]", on: queries).get().rows.first)
        expectEqual(link.connection, QueryConnection(type: EdgeTypeID(rawValue: NoteLink.id.rawValue), from: QueryEnd(id: QueryStory.gateway, title: "API gateway"),
                                                     to: QueryEnd(id: QueryStory.auth, title: "Auth")))
        expectEqual(try storyAnswer(#"arrow:starts-at("Warehouse")"#, on: queries).get().rows.first?.connection,
                    QueryConnection(type: EdgeTypeID(rawValue: Arrow.kind.rawValue), from: QueryEnd(id: QueryStory.warehouse, title: "Warehouse"),
                                    to: QueryEnd(id: QueryStory.payments, title: "Payments")))
        // Row 55: the ends of that connection are what its row says it runs from and to.
        expectEqual(try storyAnswer(#":start-of(arrow:starts-at("Warehouse"))"#, on: queries).get().rows.map(\.id), [QueryStory.warehouse])
        expectEqual(try storyAnswer(#":end-of(arrow:starts-at("Warehouse"))"#, on: queries).get().rows.map(\.id), [QueryStory.payments])
        // Mentions are edges in a note's text, not connections: only the two arrows have ends.
        expectEqual(try storyAnswer(":end-of(sticky-note)", on: queries).get().count, 0)
        expectEqual(try storyAnswer(":start-of(*)", on: queries).get().rows.map(\.id), QueryStory.ids("A, W"))
        expectEqual(try storyAnswer(":end-of(*)", on: queries).get().rows.map(\.id), QueryStory.ids("P, U"))

        // Row 50: a name tested for that no shape has is a warning, with the titles like it.
        let near = try storyAnswer(#"[title="Chekout"]"#, on: queries).get()
        expectEqual(near.warnings.map(\.reason), [.noTitleMatch])
        expect(near.warnings.first?.message.contains(#""Checkout""#) == true, "\(near.warnings)")

        /// A refusal's error, if the query is refused.
        @MainActor func refusal(_ query: String) throws -> QueryError? {
            guard case .failure(let error) = try storyAnswer(query, on: queries) else { return nil }
            return error
        }
        // Rows 51 to 54, and their hints.
        let stray = try require(try refusal("sticky-note :selected"))
        expectEqual(stray.hint, "Write them together for one shape: sticky-note:selected.", "a note holds no shapes: nothing is inside one")
        expectEqual(try refusal("subboard :selected")?.hint,
                    "Write them together for one shape: subboard:selected; for a shape inside it: subboard *:selected.")
        let spatial = try require(try refusal(#":inside("Warehouse")"#))
        expect(spatial.message.hasPrefix("Warehouse is a schema-card, which holds no shapes"), "\(spatial)")
        expectEqual(spatial.hint, "The kinds that hold shapes: subboard, frame.")
        // Beside the title like it, that mentions point at shapes that aren't there, which :dangling finds.
        let gone = try require(try refusal(#":mentions("Old ledger")"#))
        expectEqual(gone.message, "No shape is titled Old ledger.")
        expectEqual(gone.hint, #"Did you mean "Ledger"? Some mention edges point at shapes that aren't there: :dangling(mention) finds what carries them."#)
        expectEqual(try refusal(":mentions(Checkout)")?.hint, #""Checkout" is the shape titled so."#, "a title without its quotes")
        expectEqual(try refusal("note")?.hint, "Did you mean sticky-note (a Note)?")
        expectEqual(try refusal("note")?.message, "note isn't a kind.")
    },
    test("a row says what the shape is, where, and what it says: its board and the boards it's inside by their names, mention text as it reads, a derived title") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryStory.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)
        let rows = try storyAnswer("*", on: queries, properties: .all).get().rows
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        let checkout = try require(byID[QueryStory.checkout])
        expectEqual(checkout.kind, StickyNote.kind)
        expectEqual(checkout.title, "Checkout")
        expectEqual(checkout.board, BoardID(owner: QueryStory.payments))
        expectEqual(checkout.inside, ["Payments"])
        expectEqual(checkout.properties, ["text": "Calls @API gateway for tokens"], "the mention as it reads, never its stored form")

        let policy = try require(byID[QueryStory.refundPolicy])
        expectEqual(policy.board, BoardID(owner: QueryStory.refunds))
        expectEqual(policy.inside, ["Payments", "Refunds"], "outermost first")
        expectEqual(policy.properties, ["locked": true, "text": "30 days"])

        let gateway = try require(byID[QueryStory.gateway])
        expectEqual(gateway.board, .root)
        expectEqual(gateway.inside, [], "the top board is inside nothing")
        expectEqual(gateway.properties, ["text": "Owns auth. See @Checkout"])
        expectEqual(byID[QueryStory.ledger]?.properties, ["text": "Moved to @Old ledger"], "a mention of a shape that's gone reads as the name it holds")

        let order = try require(byID[QueryStory.order])
        expectEqual(order.title, "Order", "a schema card's title is its schema's")
        expectEqual(order.properties?["schema"], .string(QueryStory.orderSchema))
        expectEqual(byID[QueryStory.invoice]?.title, nil, "a card whose text isn't JSON has none")
        expectEqual(byID[QueryStory.todo]?.title, nil)

        let link = try require(byID[QueryStory.gatewayToAuth])
        expectEqual(link.title, nil)
        expectEqual(link.properties, ["bend": 0, "channel": "note-link", "endArrowhead": true, "labelPosition": 0.5,
                                         "startArrowhead": false, "text": ""],
                    "no attribute that says where it is")
        expectEqual(byID[QueryStory.warehouseToPayments]?.properties?["channel"], nil, "an arrow drawn on no channel has none")
        expect(rows.allSatisfy { $0.editing == nil }, "nothing is being typed into")
    },
    test("what each shipped word reads: the structure, attributes, kinds, names, edges and mention text the file; the selection, the board shown and validity the editor") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryStory.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)
        let file = ["sticky-note", #""Checkout""#, #"sticky-note[title^="API"]"#, "[locked]", "arrow[channel=note-link]", "sticky-note:top-level",
                    #""Payments" *"#, #"sticky-note:inside("Payments")"#, #"subboard:has("Refund policy")"#, #"sticky-note:mentions("API gateway")"#,
                    #"sticky-note:mentioned-by("Checkout")"#, #":edge-to("Checkout")"#, #":downstream-of("Checkout")"#, "arrow:dangling",
                    // Mention text reads through the names Mentions keeps, a fact of the file.
                    #"sticky-note[text*="TODO"]"#, #":contains("auth")"#]
        for query in file {
            let planned = try queries.check(query)
            expect(planned.readsOnlyTheFile, "\(query) reads only the file: \(planned.editorWords)")
        }
        let editor: [(query: String, words: [String])] = [
            (":selected", [":selected"]), (":current-board", [":current-board"]), (":invalid", [":invalid"]), (":warned", [":warned"]),
            ("sticky-note:invalid:selected", [":invalid", ":selected"]), (#"sticky-note[text*="TODO"]:selected"#, [":selected"]),
        ]
        for (query, words) in editor {
            let planned = try queries.check(query)
            expectEqual(planned.editorWords, words, query)
            expect(!planned.readsOnlyTheFile, query)
        }
        expect(try queries.check(#":edge-to("Checkout")"#).readsEdges)
        expect(!(try queries.check("sticky-note[locked]").readsEdges))
    },
    test("a note being typed into is read as of its last keystroke, and the answer says it may still change; typing goes on") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryStory.harness(pasteboard: pasteboard)
        let queries = try require(h.editor.queries)
        expect(h.editor.beginEditing(QueryStory.auth))
        // Typed into the note's own editor, which writes each keystroke to the board.
        let editing = try require(h.editor.makeEditingView())
        let text = try require(editing.firstResponder as? NSTextView)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText(", rotate keys", replacementRange: text.selectedRange())
        expectEqual(h.editor.editingShapeID, QueryStory.auth)
        let result = try storyAnswer(#"sticky-note[text*="rotate"]"#, on: queries).get()
        expectEqual(result.rows.map(\.id), [QueryStory.auth], "what's typed so far is read")
        expectEqual(result.rows.first?.editing, true)
        expectEqual(result.warnings.map(\.reason), [.editing])
        expectEqual(result.warnings.first?.message, "“Auth” is being typed into; its text may still change.")
        expectEqual(h.editor.editingShapeID, QueryStory.auth, "a query never ends typing")
        let elsewhere = try storyAnswer(#""Checkout""#, on: queries).get()
        expectEqual(elsewhere.warnings, [], "a query that reads nothing being typed into says nothing of it")
    },
])
