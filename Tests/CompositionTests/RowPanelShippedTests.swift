import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Engineering
import Find
import LineRows
import Mentions
import Neighbors
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// A row's panel and mentions of a row, shipped (K15): E6 panel 1, a selected endpoint's Endpoint tab and its Connections, which list
// what calls it, what it writes and reads and what mentions it, as E6 draws them, with no Issues tab; the list walked by keys in the
// app's window; and E5 panel 1, a note's mention of an endpoint following its path prefix retyped from /orders to /purchases.

/// E6: the orders API, refunds and payments right of it, the storefront subboard left of it calling its refunds endpoint.
private let e6 = #"""
    api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "GET /orders/{id}\nPOST /orders\nPOST /orders/{id}/refunds"
    table "refunds" right of "orders API" (gap: 140) columns: "id uuid pk\namount_cents int"
    table "payments" below "refunds" (gap: 40) columns: "id uuid pk\namount_cents int"
    subboard "storefront" left of "orders API" (gap: 140)
    edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
    edge "orders API"."POST /orders/{id}/refunds" -> "payments" channel: reads
    edge "storefront" -> "orders API"."POST /orders/{id}/refunds" channel: calls
    """#

@MainActor private func shape(_ editor: CanvasEditor, _ title: String) -> AnyShapeRecord? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }
}

@MainActor private func endpoint(_ editor: CanvasEditor, _ api: ShapeID, _ name: String) -> PartAddress? {
    guard let record = editor.document[api], let part = editor.registry.parts(of: record)?.first(where: { $0.name == name }) else { return nil }
    return PartAddress(api, part: part.id)
}

/// A note under the API mentioning a row, put down as the `@` picker's pick writes it.
@MainActor private func mentioningNote(_ editor: CanvasEditor, _ row: PartAddress, label: String) -> ShapeID {
    let note = ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 600, width: 240, height: 120),
                                      text: MentionText([.text("Partial refunds go through\n"), .mention(row, label: label)])))
    editor.transact("Add Note") { $0.insert(note) }
    return note.id
}

@MainActor let rowPanelShippedTests = Suite("A row's panel and mentions of a row, shipped", [
    test("E6 panel 1: the selected endpoint's panel is the row's, Endpoint then Connections, no Issues; its lists: Calls It, Writes, Reads, Mentioned By") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(e6, on: editor)
        let api = try require(shape(editor, "orders API")).id
        let row = try require(endpoint(editor, api, "POST /orders/{id}/refunds"))
        let note = mentioningNote(editor, row, label: "POST /orders/{id}/refunds")
        editor.selectedShapeIDs = [api]
        editor.selectItems([AnyHashable(try require(row.part))], of: api)
        expectEqual(editor.detailRow, row)
        let state = try require(editor.detailPanel)
        let layout = try require(state.rowLayout(for: try require(editor.document[api]), part: try require(row.part)))
        expectEqual(layout.tabs.map(\.title), ["Endpoint", "Connections"], "no Issues tab for a row (decided 23)")
        expectEqual(layout.header(as: DetailRowHeader.self)?.title, "/orders/{id}/refunds")
        expect({ if case .chip("POST", _)? = layout.header(as: DetailRowHeader.self)?.part.lead { true } else { false } }(), "the method's chip leads it")
        let list = try require(editor.neighborList)
        state.choose(.of(NeighborsTab.self), for: ShapeKind(rawValue: API.kind.rawValue + "#row"))
        w.window.spin { list.subject == row && list.hasLanded && !list.isAsking }
        let lists = list.settled()
        expectEqual(lists.map(\.title), ["Calls It", "Writes", "Reads", "Mentioned By"], "E6's order")
        expectEqual(lists.map { $0.rows.map(\.name) }, [["storefront"], ["refunds"], ["payments"], ["Partial refunds go through @POST /orders/{id}/refunds"]])
        expectEqual(lists.last?.rows.first?.id, note)
        expectEqual(lists.last?.rows.first?.caption, "…go through @POST /orders/{id}/refunds", "the note around its mention, short enough for its line")
        // Another endpoint lists nothing of these; the API as a whole keeps the shipped lists.
        editor.selectItems([AnyHashable(try require(endpoint(editor, api, "POST /orders")?.part))], of: api)
        w.window.spin { list.subject?.part != row.part && list.hasLanded && !list.isAsking }
        expectEqual(list.settled().map(\.title), [])
        let whole = try editor.connections(of: api)
        expect(whole.allSatisfy { !["Calls It", "Writes", "Reads"].contains($0.title) }, "a whole API keeps the shipped lists: \(whole.map(\.title))")
    },
    test("W-evolve-7: a closed path prefix's Connections are its endpoints', under the same lights, never No Connections beside its bundles; Mentioned By quotes each row's own mention") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(#"""
            api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "GET /health\n/orders\nGET /orders/{id}\nPOST /orders\nPOST /orders/{id}/refunds"
            table "refunds" right of "orders API" (gap: 140) columns: "id uuid pk\namount_cents int"
            table "payments" below "refunds" (gap: 40) columns: "id uuid pk\namount_cents int"
            subboard "storefront" left of "orders API" (gap: 140)
            edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
            edge "orders API"."POST /orders" -> "payments" channel: reads
            edge "storefront" -> "orders API"."POST /orders" channel: calls
            """#, on: editor)
        let api = try require(shape(editor, "orders API")).id
        let record = try require(editor.document[api]?.typed(as: API.self))
        let header = try require(record.props.endpoints.first { $0.header?.prefix == "/orders" }).id
        editor.rowFolds?.setClosed(true, header: header, of: api)
        editor.selectedShapeIDs = [api]
        editor.selectItems([AnyHashable(header)], of: api)
        expectEqual(editor.detailRow, PartAddress(api, part: header))
        let state = try require(editor.detailPanel)
        let list = try require(editor.neighborList)
        state.choose(.of(NeighborsTab.self), for: ShapeKind(rawValue: API.kind.rawValue + "#row"))
        w.window.spin { list.subject == PartAddress(api, part: header) && list.hasLanded && !list.isAsking }
        let lists = list.settled()
        expectEqual(lists.map(\.title), ["Calls It", "Writes", "Reads"], "its rows' lights")
        expectEqual(lists.map { $0.rows.map(\.name) }, [["storefront"], ["refunds"], ["payments"]])
        // Two mentions in one note: each row's quote shows its own, in what a caption line holds.
        let refunds = try require(endpoint(editor, api, "POST /orders/{id}/refunds")), post = try require(endpoint(editor, api, "POST /orders"))
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 600, width: 240, height: 120),
                                          text: MentionText([.text("Partial refunds go through "), .mention(refunds, label: "POST /orders/{id}/refunds"),
                                                             .text(" Checkout posts to "), .mention(post, label: "POST /orders")])))
        editor.transact("Add Note") { $0.insert(note) }
        let quote = try require(editor.mentions?.quote(of: note.id, around: post))
        expect(quote.hasSuffix("@POST /orders") && quote.count <= 44, "the quote ends on the row's own mention, short enough for a caption line: \(quote)")
        // The header's own list: the note under Mentioned By, its caption around the mention of the header's row, the other's left out.
        w.window.spin { list.settled().contains { $0.title == "Mentioned By" } }
        let mentioned = try require(list.settled().first { $0.title == "Mentioned By" }, "the note mentions rows of the header: \(list.settled().map(\.title))")
        expectEqual(mentioned.rows.count, 1)
        let caption = try require(mentioned.rows[0].caption, "the row has its quote")
        expect(caption.contains("@POST /orders") && !caption.contains("refunds"), "around the header's row's mention, not the other's: \(caption)")
    },
    test("W-connect-1: a key's pill and the table it stands for are one row of Connections, counted once") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(#"""
            subboard "billing"
            table "customers" right of "billing" (gap: 140) columns: "id uuid pk"
            """#, on: editor)
        _ = try drawnInProcess(#"table "statements" in "billing" columns: "id uuid pk\ncustomer_id uuid → customers.id""#, on: editor)
        let billing = try require(shape(editor, "billing"))
        expect(editor.showBoard(BoardID(owner: billing.id)))
        let statements = try require(shape(editor, "statements")).id
        let listed = try editor.connections(of: statements)
        let pointsTo = try require(listed.first { $0.title == "Points To" })
        expectEqual(pointsTo.rows.map(\.name), ["customers"], "the pill is the table's way, no row of its own")
        expectEqual(pointsTo.count, 1)
    },
    test("W-evolve-3, W-evolve-4 in the window: ⌥Tab into a folded API's rows, ↓ to a closed header, → opens it said with its count; Return on a row edits it, Home to the first row, Escape back on the row") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"api "shop API" endpoints: "GET /health\n/purchases\nGET /purchases/{id}\nPOST /purchases\n/customers\nGET /customers/{id}""#)
        let api = try require(shape(editor, "shop API"))
        let rows = try require(api.typed(as: API.self)).props.endpoints
        editor.rowFolds?.fold([api.id])
        editor.selectedShapeIDs = [api.id]
        w.window.makeFirstResponder(w.canvas)
        w.window.settle()
        let walk = KeyWalk(w.window, editor: editor, readers: [.canvas(w.canvas, editor: editor, names: [api.id: "shop API"])], settle: .runLoop)
        walk.driver.send(.optionTab)
        expectEqual(editor.selectedItems?.ids, [AnyHashable(rows[0].id)], "⌥Tab: the first row, an item")
        expect(!editor.hasFocusedPart, "not a resize handle")
        walk.driver.send(.down)
        let purchases = rows[1].id
        expectEqual(editor.selectedItems?.ids, [AnyHashable(purchases)], "↓: the closed header")
        let before = editor.document[api.id]?.box
        walk.driver.send(.right)
        w.window.settle()
        expectEqual(editor.rowFolds?.fold(of: api.id)?.closed.contains(purchases), false, "→ opened it")
        expectEqual(editor.announcements.last, "/purchases opened, 2 endpoints")
        expectEqual(editor.document[api.id]?.box, before, "nothing nudged")
        walk.driver.send(.down)
        walk.driver.send(.down)
        expectEqual(editor.selectedItems?.ids, [AnyHashable(rows[3].id)], "↓ ↓: POST /purchases")
        walk.driver.send(.return)
        w.window.settle()
        let view = try require(w.lineRows)
        expectEqual(view.focus, .row(rows[3].id), "Return edits that row")
        walk.driver.send(Chord(Key.home))
        expectEqual(view.focus, .row(rows[0].id), "Home: the first row")
        walk.driver.send(Chord(Key.end))
        expectEqual(view.focus, .row(rows[rows.count - 1].id), "End: the last")
        walk.driver.send(.escape)
        w.window.settle()
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.selectedItems?.acting, [AnyHashable(rows[rows.count - 1].id)],
                    "Escape: one level out, the row the caret was on selected (shown as /customers, closed again, standing for it)")
    },
    test("R5: deleting an API with its arrows says what went once, as the command runs from the key or Edit ▸ Delete: \"Delete API and 3 Arrows\"") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(e6, on: editor)
        let api = try require(shape(editor, "orders API")).id
        editor.selectedShapeIDs = [api]
        let before = editor.announcements.count
        expect(editor.perform(.delete))
        let said = Array(editor.announcements.dropFirst(before))
        expectEqual(said.count, 1, "once: \(said)")
        expect(said.first?.hasPrefix("Delete API and ") == true && said.first?.hasSuffix(" Arrows") == true, said.joined(separator: " | "))
        expectEqual(editor.undoHistory.undoName, said.first, "what VoiceOver heard is the step's name")
    },
    test("R7: ⌘↑ with a table's rows selected lets the rows go first, the table still selected and the Go item named for it, and only then climbs, one level a key") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(#"database "store" size: 900x500"#, on: editor)
        _ = try drawnInProcess(#"table "orders" in "store" columns: "id uuid pk\ntotal int""#, on: editor)
        let table = try require(shape(editor, "orders")).id, store = try require(shape(editor, "store")).id
        let rows = try require(editor.document[table]?.typed(as: DatabaseTable.self)).props.columns
        editor.selectedShapeIDs = [table]
        editor.selectItems([AnyHashable(rows[1].id)], of: table)
        expect(editor.selectedItems != nil)
        expect(editor.canPerform(.enclosingBoard), "enabled with rows selected")
        expectEqual(editor.menuTitle(of: .enclosingBoard), "Enclosing Table")
        w.window.makeFirstResponder(w.canvas)
        let driver = KeyDriver(w.window)
        expect(driver.send(Chord(Key.up, .command)).isKeyEquivalent)
        expectEqual(editor.selectedItems == nil, true, "the rows let go")
        expectEqual(editor.selectedShapeIDs, [table], "one level only: the table is still the selection")
        expectEqual(editor.menuTitle(of: .enclosingBoard), "Enclosing Database", "the next step is the container's")
        expect(driver.send(Chord(Key.up, .command)).isKeyEquivalent)
        expectEqual(editor.selectedShapeIDs, [store], "the second key climbs")
    },
    test("R47: Find's step in a table names the table, and says the words around the hit stepped to, not the table's first hit's again") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(#"table "products" columns: "id uuid pk\nprice_cents int\nlist_price int""#, on: editor)
        let id = try require(shape(editor, "products")).id
        let find = try require(editor.find)
        find.open()
        find.query = "price"
        w.window.spin { !find.isIndexing && find.isSettled }
        _ = try awaitResult { await find.settled() }
        expectEqual(find.results.map(\.id), [id])
        let first = try require(find.announcement)
        expect(first.hasPrefix("Hit 1 of 2, products, Table, ") && first.contains("price_cents"), first)
        find.step(forward: true)
        let second = try require(find.announcement)
        expect(second.hasPrefix("Hit 2 of 2, products, Table, ") && second.contains("list_price") && !second.contains("price_cents"), second)
        find.close()
    },
    test("R47: where a table's name is hit too, a step to its column still names the table, and a step to the name doesn't say it twice") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(#"table "orders" columns: "id uuid pk\norder_id uuid""#, on: editor)
        let id = try require(shape(editor, "orders")).id
        let find = try require(editor.find)
        find.open()
        find.query = "order"
        w.window.spin { !find.isIndexing && find.isSettled }
        _ = try awaitResult { await find.settled() }
        expectEqual(find.results.map(\.id), [id])
        let total = find.total
        expectEqual(total, 2, "the name and the column are both hit")
        var said: [String] = []
        for _ in 0..<total {
            said.append(try require(find.announcement))
            find.step(forward: true)
        }
        let column = try require(said.first { $0.contains("order_id") }, "\(said)")
        expect(column.contains(", orders, Table, "), "the column's hit names the table: \(column)")
        let name = try require(said.first { !$0.contains("order_id") }, "\(said)")
        expect(name.hasSuffix(", Table, orders"), "the name's own hit is the snippet alone, not the name and then the snippet: \(name)")
        find.close()
    },
    test("in the app's window a row's Connections list is one Tab stop the arrows walk: the line lights its shape, Return goes to it") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(e6, on: editor)
        let api = try require(shape(editor, "orders API")).id, storefront = try require(shape(editor, "storefront")).id
        let refunds = try require(shape(editor, "refunds")).id
        let row = try require(endpoint(editor, api, "POST /orders/{id}/refunds"))
        let list = try require(editor.neighborList)
        try require(editor.detailPanel).choose(.of(NeighborsTab.self), for: ShapeKind(rawValue: API.kind.rawValue + "#row"))
        editor.selectedShapeIDs = [api]
        editor.selectItems([AnyHashable(try require(row.part))], of: api)
        w.window.spin { list.subject == row && list.hasLanded && !list.isAsking }
        w.window.spin { w.connectionRows.count == 3 }
        let table = try require(w.connectionTable)
        let driver = KeyDriver(w.window)
        w.window.makeFirstResponder(table)
        w.window.spin { w.window.firstResponder === table }
        w.window.settle()
        driver.send(.down)
        w.window.spin { editor.hovered == storefront }
        expectEqual(editor.hovered, storefront, "Calls It's line lights the storefront")
        driver.send(.down)
        driver.send(.down)
        w.window.spin { editor.hovered == refunds }
        expectEqual(editor.hovered, refunds, "and Writes' the table it writes")
        driver.send(.up)
        driver.send(.up)
        w.window.spin { editor.hovered == storefront }
        expectEqual(editor.hovered, storefront, "Up undoes Down")
        driver.send(.return)
        w.window.spin { editor.selection == storefront }
        expectEqual(editor.selection, storefront, "Return goes to the shape")
    },
    test("deleting the row whose Connections list has the keys hands them to the canvas: the row's panel is replaced under the focus") {
        let w = try InspectorWindow()
        let editor = w.editor
        _ = try drawnInProcess(e6, on: editor)
        let api = try require(shape(editor, "orders API")).id
        let row = try require(endpoint(editor, api, "POST /orders/{id}/refunds"))
        let list = try require(editor.neighborList)
        try require(editor.detailPanel).choose(.of(NeighborsTab.self), for: ShapeKind(rawValue: API.kind.rawValue + "#row"))
        editor.selectedShapeIDs = [api]
        editor.selectItems([AnyHashable(try require(row.part))], of: api)
        w.window.spin { list.subject == row && list.hasLanded && !list.isAsking }
        w.window.spin { w.connectionRows.count == 3 }
        let table = try require(w.connectionTable)
        w.window.makeFirstResponder(table)
        w.window.spin { w.window.firstResponder === table }
        expect(w.window.firstResponder === table, "the list has the keys")
        editor.transact("Delete Endpoint") { tx in
            tx.update(api, as: API.self) { $0.props.endpoints.removeAll { $0.id == row.part } }
            tx.removeParts([row])
        }
        w.window.spin { editor.detailRow == nil }
        expectEqual(editor.detailRow, nil, "the row is gone, and the panel is the API's")
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "the keys are the canvas's, not the window's")
    },
    test("E5 panel 1: a note's mention of an endpoint follows its path prefix retyped from /orders to /purchases, drawn as the row's chip and path") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "/orders\nGET /orders/{id}\nPOST /orders/{id}/refunds""#)
        let api = try require(shape(editor, "orders API")).id
        let row = try require(endpoint(editor, api, "POST /orders/{id}/refunds"))
        let note = mentioningNote(editor, row, label: "POST /orders/{id}/refunds")
        let mentions = try require(editor.mentions)
        expectEqual(mentions.resolve(row).appearance?.label, "POST /orders/{id}/refunds")
        expect({ if case .chip("POST", _)? = mentions.resolve(row).appearance?.lead { true } else { false } }(), "its pill leads with the method's chip")
        let header = try require(editor.registry.parts(of: try require(editor.document[api]))?.first { $0.name == "/orders" }).id
        let walk = w.walk()
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .row(header))
        w.window.settle()
        w.retype("/purchases", with: walk)
        walk.press(.down)
        w.window.settle()
        expectEqual(editor.registry.parts(of: try require(editor.document[api]))?.first { $0.id == row.part }?.name, "POST /purchases/{id}/refunds")
        expectEqual(mentions.resolve(row).appearance?.label, "POST /purchases/{id}/refunds", "the note's pill follows")
        expectEqual(mentions.plainText(try require(editor.document[note]?.typed(as: StickyNote.self)).props.text),
                    "Partial refunds go through\n@POST /purchases/{id}/refunds")
        expectEqual(editor.mentionPills(of: note).map(\.target), [row])
        expect(editor.mentionPills(of: note).allSatisfy(\.isLive))
    },
    test("a note measured from its words alone gives an endpoint's pill the width it is drawn with, its chip's, not a symbol's and the method's letters") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "POST /orders/{id}/refunds\nDELETE /orders/{id}\nGET /orders""#)
        let editor = w.editor
        let api = try require(shape(editor, "orders API"))
        let style = MentionTextStyle(font: .systemFont(ofSize: 15), color: .black, lineHeight: 19)
        let rows = try require(editor.registry.parts(of: api))
        expectEqual(rows.count, 3)
        for part in rows {
            let address = PartAddress(api.id, part: part.id)
            let live = try require(editor.mentions?.resolve(address).appearance)
            let text = MentionText([.mention(address, label: live.label)])
            let drawn = style.attributedString(text) { _ in .live(live) }.size().width
            expectEqual(style.measuredString(text, width: nil).size().width, drawn, live.label)
            expect(drawn > 0)
        }
    },
    test("a note measured from its words alone gives a column of a table titled with a word in capitals the width it is drawn with: no chip, which only an endpoint's path takes") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            table "API Keys" columns: "id uuid pk\nowner_id uuid"
            table "US States" below "API Keys" columns: "code text pk"
            api "orders API" below "US States" endpoints: "GET /orders"
            """#)
        let editor = w.editor
        let style = MentionTextStyle(font: .systemFont(ofSize: 15), color: .black, lineHeight: 19)
        for title in ["API Keys", "US States", "orders API"] {
            let record = try require(shape(editor, title))
            for part in try require(editor.registry.parts(of: record)) {
                let address = PartAddress(record.id, part: part.id)
                let live = try require(editor.mentions?.resolve(address).appearance)
                let text = MentionText([.mention(address, label: live.label)])
                let drawn = style.attributedString(text) { _ in .live(live) }.size().width
                expectEqual(style.measuredString(text, width: nil).size().width, drawn, live.label)
            }
        }
    },
    test("the @ picker lists an endpoint taken out of its API once: the shape where its name is found, its row only where its path alone is") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let unnamed = editor.add(StandaloneEndpoint(frame: CGRect(x: 0, y: 0, width: 420, height: 44), endpoint: Endpoint(method: "DELETE", path: "/orders/{id}")))
        let named = editor.add(StandaloneEndpoint(frame: CGRect(x: 0, y: 200, width: 420, height: 44),
                                                  endpoint: Endpoint(method: "POST", path: "/orders/{id}/refunds", name: "createRefund")))
        let mentions = try require(editor.mentions)
        @MainActor func listed(_ query: String) -> [PartAddress] {
            mentions.candidates(matching: query, in: AnyMentionable.self, for: nil, listingParts: { _ in true }, ownRows: .shape).matches.map(\.address)
        }
        expectEqual(listed("DELETE /orders"), [PartAddress(unnamed)], "the shape, called by its method and path, and not its row as well")
        expectEqual(listed("createRefund"), [PartAddress(named)], "by its name: the shape")
        let row = try require(editor.document[named]?.typed(as: StandaloneEndpoint.self)?.props.endpoint.id)
        expectEqual(listed("POST /orders/{id}/refunds"), [PartAddress(named, part: row)], "by its path alone: its row, the shape not found")
    },
])
