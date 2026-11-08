import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import Engineering
import LanguageModels
import LineRows
import Selection
import ShippedTesting
import TestKit
import TextEditing
import Titles
import Types

// An API as shipped (K12), on a board's window with real presses: E7 panels 1 to 3 (`/api orders API ↩`, two endpoints each
// "Add Endpoint", ↑, ⌘L on the row), the first minute (Insert ▸ API, the name typed in its pill, Return to its empty row), E2
// panel 2 (`(New` offering the file's types, "New type New" last), E3 panels 2 and 3 (the card's `409 Problem` a dashed pill,
// "New type Problem" making the note beside Refund with the caret kept, one step "New Type"), a body's pill reading its type's
// name now, and `canvas draw`'s `server:` and `endpoints:` (whole paths under the longest header, joined by method and full
// path, a run again unchanged, the types bound).

@MainActor private func apis(_ editor: CanvasEditor) -> [ShapeRecord<API>] {
    editor.document.shapes.compactMap { $0.typed(as: API.self) }
}

@MainActor private func titled(_ editor: CanvasEditor, _ title: String) -> AnyShapeRecord? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }
}

/// The API's lines as the endpoint grammar prints its rows.
@MainActor private func lines(_ editor: CanvasEditor) -> [String] {
    apis(editor).first?.props.endpoints.map(EndpointGrammar.print) ?? []
}

/// Type notes by `canvas draw`: NewRefund, Refund, NewOrder and Order.
private let models = #"""
    sticky-note "NewRefund" schema: "{\"type\": \"object\", \"properties\": {\"amount_cents\": {\"type\": \"number\"}}}" color: pink
    sticky-note "Refund" below "NewRefund" (gap: 40) schema: "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}}" color: purple
    sticky-note "NewOrder" below "Refund" (gap: 40) schema: "{\"type\": \"object\"}"
    sticky-note "Order" below "NewOrder" (gap: 40) schema: "{\"type\": \"object\"}"
    """#

@MainActor let apiShippedTests = Suite("APIs, shipped", [
    test("E7, panels 1 to 3, by the keys alone: /api orders API ↩, two endpoints each Add Endpoint and its Undo, ↑ to the second, ⌘L on its row") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        // The types E7 panel 2 draws its pills of.
        try w.draw(models + #"\#ntable "refunds" right of "NewRefund" (gap: 700) columns: "id uuid pk\namount_cents int""#)
        let walk = w.walk()
        walk.press(Chord("/"))
        w.type("api orders API", with: walk)
        walk.press(.return)
        let api = try require(apis(editor).first)
        expectEqual(api[TitleProperty.self], "orders API")
        expectEqual(editor.editingShapeID, api.id)
        expectEqual(w.lineRows?.focus, .waiting, "the caret on its empty row, under the faint server (E7 panel 1)")
        expectEqual(undoTitle(w.window), "Undo Add API")
        w.type("POST /orders (NewOrder) -> 201 Order", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo Add Endpoint")
        w.type("POST /orders/{id}/refunds (NewRefund) -> 201 Refund", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo Add Endpoint")
        expectEqual(lines(editor), ["POST /orders (NewOrder) → 201 Order", "POST /orders/{id}/refunds (NewRefund) → 201 Refund"])
        walk.press(.up)
        let second = try require(apis(editor).first?.props.endpoints.last?.id)
        expectEqual(w.lineRows?.focus, .row(second), "↑: the second endpoint (E7 panel 3)")
        walk.press(Chord("l", .command))
        let picker = try require(editor.connectPicker)
        expect(picker.isOpen, "⌘L on the row: the picker")
        expectEqual(picker.picker?.sourceEnd, ConnectEnd(api.id, part: second))
        w.type("ref", with: walk)
        let listed = (picker.picker?.list.rows ?? []).compactMap(\.item).map(\.title)
        expect(listed.contains("refunds"), "the refunds table: \(listed)")
        walk.press(.escape)
        expect(!picker.isOpen)
        walk.press(.escape)
        expectEqual(editor.editingShapeID, nil)
        expectEqual(undoTitle(w.window), "Undo Add Endpoint")
    },
    test("the first minute (E1): Insert ▸ API puts one down with the caret in its name; typed, Return goes on to its empty row; one step, Add API") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        let walk = w.walk()
        let tool = ToolID(placing: API.kind)
        expectEqual(editor.registry.tools.filter { editor.registry.kit(ofTool: $0.id) == EngineeringKit.id }.map(\.label), ["Table", "Enum", "API", "Database"])
        expect(editor.perform(.insert(tool)), "Insert ▸ Engineering ▸ API")
        w.window.settle()
        let api = try require(apis(editor).first)
        expectEqual(w.lineRows?.focus, .title, "the caret in its name (E1 panel 2)")
        w.type("orders", with: walk)
        walk.press(.return)
        expectEqual(w.lineRows?.focus, .waiting, "Return in the name: its empty row")
        expectEqual(w.lineRows?.stops, [.title, .fixed, .waiting])
        walk.press(.up)
        expectEqual(w.lineRows?.focus, .fixed, "↑: the server line")
        walk.press(.escape)
        expectEqual(editor.document[api.id]?[TitleProperty.self], "orders")
        expectEqual(undoTitle(w.window), "Undo Add API")
        expectEqual(editor.menuTitle(of: .insertBeside), "New API Beside")
        walk.press(Chord(Key.return, .shift))
        expectEqual(apis(editor).count, 2, "⇧↩: an API beside it")
        expectEqual(w.lineRows?.focus, .title, "its name typed at once")
        expectEqual(undoTitle(w.window), "Undo Add API")
        walk.press(.escape)
    },
    test("E2 panel 2: (New offers the file's types and New type New last, an action; Tab takes NewRefund, its pill solid; a type named by nothing is dashed") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(models + #"\#napi "orders API" right of "NewRefund" (gap: 80) server: "api.shop.dev/v1 bearer" endpoints: "GET /orders/{id}""#)
        let api = try require(apis(editor).first)
        let walk = w.walk()
        editor.selectedShapeIDs = [api.id]
        editor.beginEditing(api.id)
        w.window.settle()
        w.type("POST /orders/{id}/refunds (New", with: walk)
        let field = try require(w.line)
        expectEqual(Set(field.listedOffers.dropLast()), ["NewRefund", "NewOrder"])
        expectEqual(field.listedOffers.last, "New type New", "the action last")
        let first = try require(field.listedOffers.first)
        expectEqual(first, "NewRefund", "a path that speaks of refunds: the type with its word in it first (E2 panel 2)")
        walk.press(.tab)
        expectEqual(field.string, "POST /orders/{id}/refunds (\(first)")
        let picked = try require(titled(editor, first)).id
        expectEqual(field.line.references.map(\.target), [PartAddress(picked)], "the pick stands for its note")
        field.selectAll(nil)
        w.type("POST /orders/{id}/refunds (NewRefund) -> 201 Refund", with: walk)
        let refund = try require(titled(editor, "Refund")).id, newRefund = try require(titled(editor, "NewRefund")).id
        expect(field.highlights.allSatisfy { !$0.isDashed }, "both name type notes: no dashed pill")
        walk.press(.return)
        let row = try require(apis(editor).first?.props.endpoints.last?.endpoint)
        expectEqual(row.body, TypeRef("NewRefund", shape: newRefund))
        expectEqual(row.responses, [EndpointResponse(status: "201", type: TypeRef("Refund", shape: refund))])
        w.type("GET /x -> 200 Nothing", with: walk)
        expectEqual(field.highlights.filter(\.isDashed).count, 1, "Nothing names no type: dashed (E3 panel 2)")
        walk.press(.escape)
        // The pill reads its type's name now.
        editor.transact { $0.update(refund) { $0[TitleProperty.self] = "RefundView" } }
        editor.selectedShapeIDs = [api.id]
        editor.beginEditing(api.id)
        w.window.settle()
        w.lineRows?.go(to: .row(try require(apis(editor).first?.props.endpoints.dropFirst().first?.id)))
        expectEqual(w.line?.string, "POST /orders/{id}/refunds (NewRefund) → 201 RefundView", "a rename followed, nothing written")
        walk.press(.escape)
    },
    test("E3 panels 2 and 3: in the card, 409 Problem is a dashed pill offering New type Problem last; Return makes the note beside Refund, the words bound, the caret kept; one step, New Type") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(models + #"\#napi "orders API" right of "NewRefund" (gap: 80) server: "api.shop.dev/v1 bearer" endpoints: "GET /orders/{id}\nPOST /orders/{id}/refunds (NewRefund) → 201 Refund""#)
        let api = try require(apis(editor).first)
        let refundsRow = try require(api.props.endpoints.last?.id)
        let walk = w.walk()
        editor.selectedShapeIDs = [api.id]
        editor.beginEditing(api.id)
        w.window.settle()
        w.lineRows?.go(to: .row(refundsRow))
        w.window.settle()
        walk.press(Chord(Key.down, .command))
        let card = try require(w.canvas.cardView as? LineCardView)
        expectEqual(card.stopNames, ["name", "summary", "auth", "{id}", "body", "responses 1", "deprecated", "relations 1"])
        card.go(to: "responses 1")
        w.window.settle()
        walk.press(.return)
        w.type("404", with: walk)
        walk.press(.return)
        w.type("409 Problem", with: walk)
        let field = try require(card.field(of: "responses 3"))
        expect(field.highlights.contains(where: \.isDashed), "Problem names no type: a dashed pill")
        expectEqual(field.listedOffers.last, "New type Problem")
        expectEqual(field.highlightedOffer, "New type Problem", "nothing else is called so: the action highlighted")
        let before = Set(editor.document.shapes.map(\.id))
        walk.press(.return)
        let made = try require(editor.document.shapes.first { !before.contains($0.id) })
        expectEqual(made[TitleProperty.self], "Problem")
        expect(editor.types?.isType(made.id) == true, "a type note")
        expect(editor.types?.links(of: api.id).isEmpty ?? true, "the API is no instance of it")
        let responses = try require(apis(editor).first?.props.endpoints.last?.endpoint?.responses)
        expectEqual(responses.map(\.status), ["201", "404", "409"])
        expectEqual(responses.last?.type, TypeRef("Problem", shape: made.id))
        expectEqual(undoTitle(w.window), "Undo New Type")
        expect(w.window.firstResponder === card.field(of: "responses 3"), "the caret stays in the card: \(String(describing: w.window.firstResponder))")
        expectEqual(editor.editingShapeID, api.id)
        expectEqual(editor.selectedShapeIDs, [api.id], "the note is put down settled, nothing selected")
        let refund = try require(titled(editor, "Refund")).id
        let besides = try require(editor.document[refund]?.box), note = try require(made.box)
        expect(!besides.intersects(note), "beside Refund, the type the API names: \(besides) \(note)")
        walk.press(.escape)
        walk.press(.escape)
        editor.undo()
        expect(editor.document[made.id] == nil, "one undo takes the note")
        expectEqual(apis(editor).first?.props.endpoints.last?.endpoint?.responses.map(\.status), ["201", "404"], "and the words that named it")
    },
    test("a type named in several words: a body in brackets and a response quoted bind to the one note, through a line, the card and a reprint, and the picks stand for it") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(models + #"\#nsticky-note "Refund Request" below "Order" (gap: 40) schema: "{\"type\": \"object\"}"\#napi "orders API" right of "NewRefund" (gap: 80) endpoints: "GET /orders/{id}""#)
        let api = try require(apis(editor).first)
        let note = try require(titled(editor, "Refund Request")).id
        let walk = w.walk()
        editor.selectedShapeIDs = [api.id]
        editor.beginEditing(api.id)
        w.window.settle()
        w.type(#"POST /refunds (Refund Request) -> 201 "Refund Request""#, with: walk)
        let field = try require(w.line)
        expect(field.highlights.allSatisfy { !$0.isDashed }, "both name the note: no dashed pill")
        walk.press(.return)
        let row = try require(apis(editor).first?.props.endpoints.last?.endpoint)
        expectEqual(row.body, TypeRef("Refund Request", shape: note))
        expectEqual(row.responses, [EndpointResponse(status: "201", type: TypeRef("Refund Request", shape: note))])
        // A pick of the name's offers, in a bracket and quoted after the status, each standing for the note.
        w.type("PUT /refunds (Refund Re", with: walk)
        expect(field.listedOffers.contains("Refund Request"), "\(field.listedOffers)")
        w.type("quest) -> 200 Ref", with: walk)
        expect(field.listedOffers.contains("Refund Request"), "\(field.listedOffers)")
        let offers = field.listedOffers
        expectEqual(offers.firstIndex(of: "Refund Request").map { $0 < offers.count - 1 }, true)
        for _ in offers where field.highlightedOffer != "Refund Request" { walk.press(.down) }
        expectEqual(field.highlightedOffer, "Refund Request")
        walk.press(.tab)
        expectEqual(field.string, #"PUT /refunds (Refund Request) → 200 "Refund Request""#, "the name quoted where it's words")
        expect(field.line.references.contains { $0.target == PartAddress(note) }, "the pick stands for its note")
        walk.press(.return)
        let put = try require(apis(editor).first?.props.endpoints.last?.endpoint)
        expectEqual(put.responses.first?.type, TypeRef("Refund Request", shape: note))
        // The card prints the body with its arrow and the whole name, and reads it back whole.
        walk.press(.up)
        walk.press(Chord(Key.down, .command))
        let card = try require(w.canvas.cardView as? LineCardView)
        expectEqual(card.value(of: "body"), "→ Refund Request")
        expectEqual(card.value(of: "responses 1"), "200 → Refund Request")
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(apis(editor).first?.props.endpoints.last?.endpoint?.body, TypeRef("Refund Request", shape: note), "left as it was")
    },
    test("words written before their type: an endpoint drawn naming Later, and the note made afterwards, is bound at rest: its line carries the note, a pill not dashed") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"api "orders API" endpoints: "GET /x (Later) → 200 Later""#)
        let api = try require(apis(editor).first)
        expectEqual(api.props.endpoints.last?.endpoint?.body, TypeRef("Later"), "no type of that name yet")
        try w.draw(#"sticky-note "Later" schema: "{\"type\": \"object\"}""#)
        let note = try require(titled(editor, "Later")).id
        let walk = w.walk()
        editor.selectedShapeIDs = [api.id]
        editor.beginEditing(api.id)
        w.window.settle()
        w.lineRows?.go(to: .row(try require(api.props.endpoints.last?.id)))
        w.window.settle()
        let field = try require(w.line)
        expectEqual(field.line.references.map(\.target), [PartAddress(note), PartAddress(note)], "the body's and the response's, stood for at rest")
        expect(field.highlights.allSatisfy { !$0.isDashed })
        walk.press(.escape)
        expectEqual(editor.undoHistory.undoName, "Draw", "nothing written by looking at it")
    },
    test("a response's status typed (2, 20, 201) offers no type and no New type 2; a type alone after the arrow (→ Order) is offered types") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(models + #"\#napi "orders API" right of "NewRefund" (gap: 80) endpoints: "GET /orders/{id}""#)
        let api = try require(apis(editor).first)
        let walk = w.walk()
        editor.selectedShapeIDs = [api.id]
        editor.beginEditing(api.id)
        w.window.settle()
        let field = try require(w.line)
        w.type("GET /x -> ", with: walk)
        expect(field.listedOffers.contains("Order"), "after the arrow, a type alone")
        for digit in ["2", "0", "1"] {
            w.type(digit, with: walk)
            expectEqual(field.listedOffers, [], "the status so far, \(field.string): nothing to offer")
        }
        w.type(" Or", with: walk)
        expect(field.listedOffers.contains("Order"), "past the status, types: \(field.listedOffers)")
        walk.press(.escape)
    },
    test("New type in a row's line: GET /x -> 200 Problem, Return does the action, the type made and the row written with it, the caret kept in the line; Undo New Type takes both") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(models + #"\#napi "orders API" right of "NewRefund" (gap: 80) endpoints: "GET /orders/{id}""#)
        let api = try require(apis(editor).first)
        let walk = w.walk()
        editor.selectedShapeIDs = [api.id]
        editor.beginEditing(api.id)
        w.window.settle()
        w.type("GET /x -> 200 Problem", with: walk)
        let field = try require(w.line)
        expectEqual(field.highlightedOffer, "New type Problem")
        let before = Set(editor.document.shapes.map(\.id))
        walk.press(.return)
        let made = try require(editor.document.shapes.first { !before.contains($0.id) })
        expectEqual(made[TitleProperty.self], "Problem")
        let row = try require(apis(editor).first?.props.endpoints.last?.endpoint)
        expectEqual(row.responses, [EndpointResponse(status: "200", type: TypeRef("Problem", shape: made.id))])
        expectEqual(field.string, "GET /x → 200 Problem", "the caret stays in the line")
        expect(w.window.firstResponder === field)
        expectEqual(w.lineRows?.focus, .row(row.id), "the line is the row now")
        expectEqual(undoTitle(w.window), "Undo New Type", "Undo is the board's, not the typing's")
        expect(!field.highlights.contains(where: \.isDashed), "its pill solid now")
        walk.press(.return)
        expectEqual(w.lineRows?.focus, .waiting, "Return again: a new row")
        walk.press(.escape)
        editor.undo()
        expect(editor.document[made.id] == nil)
        expectEqual(apis(editor).first?.props.endpoints.count, 1, "one undo takes the note and the row")
    },
    test("draw: server: a line, endpoints: whole paths under the longest header, joined by method and full path; a run again unchanged; a type named is bound, a pill, no arrow") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess(models, on: editor)
        let arrows = editor.document.shapes.count
        let script = #"api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "/orders\nGET /orders/{id} → Order\nPOST /orders/{id}/refunds (NewRefund) → 201 Refund\nGET /health""#
        let first = try drawnInProcess(script, on: editor)
        expectEqual(first["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["created"])
        let api = try require(apis(editor).first)
        expectEqual(api.props.server, APIServer(host: "api.shop.dev/v1", auth: "bearer"))
        expectEqual(api.props.endpoints.map(EndpointGrammar.print), ["GET /health", "/orders", "GET /{id} → Order", "POST /{id}/refunds (NewRefund) → 201 Refund"],
                    "under the longest header, else at the top")
        expectEqual(api.props.endpoints[3].endpoint?.body?.shape, titled(editor, "NewRefund")?.id, "bound to the type note")
        expectEqual(editor.document.shapes.count, arrows + 1, "a pill, no arrow (decided 24)")
        let again = try drawnInProcess(script, on: editor)
        expectEqual(again["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["unchanged"])
        let ids = api.props.endpoints.map(\.id)
        _ = try drawnInProcess(#"api "orders API" endpoints: "GET /orders/{id} → 200 Order\nDELETE /orders/{id}""#, on: editor)
        let changed = try require(apis(editor).first)
        expectEqual(changed.props.endpoints.map(EndpointGrammar.print),
                    ["GET /health", "/orders", "GET /{id} → 200 Order", "POST /{id}/refunds (NewRefund) → 201 Refund", "DELETE /{id}"])
        expectEqual(Array(changed.props.endpoints.map(\.id).prefix(4)), ids, "what it had keeps its ids")
        _ = try drawnInProcess(#"api "orders API" endpoints: [{"header": "/customers"}, {"method": "get", "path": "/customers/{id}", "name": "getCustomer", "body": "Order"}]"#, on: editor)
        let json = try require(apis(editor).first)
        expectEqual(json.props.endpoints.suffix(2).map(EndpointGrammar.print), ["/customers", "GET /{id} (Order)"])
        expectEqual(json.props.endpoints.last?.endpoint?.name, "getCustomer")
    },
])
