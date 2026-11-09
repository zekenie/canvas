import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Engineering
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
        expectEqual(lists.last?.rows.first?.caption, "Partial refunds go through @POST /orders/{id}/refunds", "the note around its mention")
        // Another endpoint lists nothing of these; the API as a whole keeps the shipped lists.
        editor.selectItems([AnyHashable(try require(endpoint(editor, api, "POST /orders")?.part))], of: api)
        w.window.spin { list.subject?.part != row.part && list.hasLanded && !list.isAsking }
        expectEqual(list.settled().map(\.title), [])
        let whole = try editor.connections(of: api)
        expect(whole.allSatisfy { !["Calls It", "Writes", "Reads"].contains($0.title) }, "a whole API keeps the shipped lists: \(whole.map(\.title))")
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
            mentions.candidates(matching: query, in: AnyMentionable.self, for: nil, listingParts: { _ in true }).matches.map(\.address)
        }
        expectEqual(listed("DELETE /orders"), [PartAddress(unnamed)], "the shape, called by its method and path, and not its row as well")
        expectEqual(listed("createRefund"), [PartAddress(named)], "by its name: the shape")
        let row = try require(editor.document[named]?.typed(as: StandaloneEndpoint.self)?.props.endpoint.id)
        expectEqual(listed("POST /orders/{id}/refunds"), [PartAddress(named, part: row)], "by its path alone: its row, the shape not found")
    },
])
