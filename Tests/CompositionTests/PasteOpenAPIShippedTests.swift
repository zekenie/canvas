import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Engineering
import Foundation
import Selection
import ShippedTesting
import TestKit
import Titles
import Types
import Validation

// ⌘V of OpenAPI as shipped, on a pasteboard of the test's own (ShippedPlugins'), by real ⌘V presses in a new board's window: E1
// panel 4 as a file, billing.openapi.yaml, the API and its two type notes landing at once, selected, the API above, its bodies
// bound to the notes, with no issue on any, and one Undo, "Undo Paste OpenAPI"; a 3.0 file whose schemas refer to each other
// (`$ref` pointing at the note's id) and build on one another (`allOf` as `is`); the same file pasted again updating the API and
// the types in place (endpoints by method and full path, their ids kept; properties joined by name; what the person added kept);
// a plain note of a type's name left alone; and the kit off, where ⌘V does nothing.

/// E1 panel 4's file: three endpoints under three segments, two types, bearer auth.
private let billing = """
    openapi: 3.1.0
    info:
      title: billing API
      version: 1.0.0
    servers:
      - url: https://billing.shop.dev
    security:
      - bearerAuth: []
    paths:
      /webhooks/stripe:
        post:
          operationId: receiveStripeEvent
          security: []
          requestBody:
            content:
              application/json:
                schema:
                  $ref: '#/components/schemas/StripeEvent'
          responses:
            '200':
              description: received
      /statements/{id}:
        get:
          operationId: getStatement
          parameters:
            - {name: id, in: path, required: true, schema: {type: string, format: uuid}}
          responses:
            '200':
              description: the statement
              content:
                application/json:
                  schema:
                    $ref: '#/components/schemas/Statement'
      /customers/{id}/statements:
        get:
          operationId: listCustomerStatements
          parameters:
            - {name: id, in: path, required: true, schema: {type: string, format: uuid}}
          responses:
            '200':
              description: the customer's statements
              content:
                application/json:
                  schema:
                    type: array
                    items:
                      $ref: '#/components/schemas/Statement'
    components:
      securitySchemes:
        bearerAuth: {type: http, scheme: bearer}
      schemas:
        StripeEvent:
          type: object
          required: [id, type]
          properties:
            id: {type: string}
            type: {type: string}
            data: {type: object}
        Statement:
          type: object
          properties:
            id: {type: string}
            period: {type: string}
            total_cents: {type: integer}
    """

/// A 3.0 file whose types refer to each other and build on one another.
private let refunds = """
    openapi: 3.0.3
    info: {title: refunds API, version: '1'}
    paths:
      /refunds:
        post:
          operationId: createRefund
          requestBody:
            content:
              application/json:
                schema: {$ref: '#/components/schemas/Refund'}
          responses:
            '201':
              description: made
              content:
                application/json:
                  schema:
                    type: object
                    properties:
                      id: {type: string, format: uuid}
    components:
      schemas:
        Money:
          type: integer
          minimum: 0
          exclusiveMinimum: true
          example: 1250
        Base:
          type: object
          required: [id]
          properties:
            id: {type: string, format: uuid, nullable: true}
        Refund:
          allOf:
            - $ref: '#/components/schemas/Base'
            - type: object
              required: [amount, id]
              properties:
                amount: {$ref: '#/components/schemas/Money'}
                reason: {type: string, nullable: true, enum: [fraud, duplicate]}
          discriminator: {propertyName: kind}
    """

@MainActor private func pasteboardHolds(_ text: String) {
    let pasteboard = ShippedPlugins.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// ⌘V, pressed in the window.
@MainActor private func commandV(_ w: EmptyBoardWindow) -> Bool {
    w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command]))
}

@MainActor private func api(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<API>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title && $0.kind == API.kind }?.typed(as: API.self)
}

/// The note that is the type called `title`.
@MainActor private func type(_ editor: CanvasEditor, _ title: String) -> AnyShapeRecord? {
    editor.document.shapes.first { $0[TitleProperty.self] == title && $0[TypeSchemaProperty.self] != nil }
}

/// A type's schema, read.
@MainActor private func schema(_ editor: CanvasEditor, _ title: String) throws -> SchemaValue {
    let text = try require(type(editor, title)?[TypeSchemaProperty.self]?.text, "\(title)'s schema")
    return SchemaValue(try JSONReader.read(text))
}

/// What Validation says of a shape (Types' rules among the rest).
@MainActor private func issues(of id: ShapeID, in editor: CanvasEditor) -> [String] {
    _ = editor.validation?.results
    return editor.validation?.result(for: id)?.issues.map(\.message) ?? []
}

/// A new board's window with the kit on and nothing selected.
@MainActor private func kitWindow() throws -> EmptyBoardWindow {
    let w = try EmptyBoardWindow()
    try w.turnKitOn()
    w.editor.undoHistory.seal()
    w.window.makeFirstResponder(w.canvas)
    return w
}

@MainActor let pasteOpenAPIShippedTests = Suite("Paste OpenAPI, shipped", [
    test("E1 panel 4: ⌘V of billing.openapi.yaml, a file, lands the API and its two types at once, selected, the API above them, its bodies bound to the notes, nothing to warn of; Undo Paste OpenAPI takes it whole") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-openapi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("billing.openapi.yaml")
        try billing.write(to: file, atomically: true, encoding: .utf8)
        let pasteboard = ShippedPlugins.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString("billing.openapi.yaml", forType: .string)
        expect(editor.canPaste, "Edit › Paste is on for an OpenAPI file")
        let before = editor.document
        expect(commandV(w), "the canvas's ⌘V takes it")
        let landed = try require(api(editor, "billing API"))
        let event = try require(type(editor, "StripeEvent")), statement = try require(type(editor, "Statement"))
        expectEqual(editor.selectedShapeIDs, [landed.id, event.id, statement.id], "all three selected")
        expectEqual(editor.document.shapes.count, 3, "nothing else")
        expectEqual(event.kind, editor.newTypeKind(), "a note, the kind New Type makes")
        expectEqual(landed.props.server, APIServer(host: "billing.shop.dev", auth: "bearer"))
        expect(landed.props.frame.width >= 420, "at least a new API's width, the 200 left to its type: \(landed.props.frame.width)")
        expectEqual(landed.props.version, "1.0.0")
        expectEqual(landed.props.endpoints.map(EndpointGrammar.print), [
            "POST /webhooks/stripe (StripeEvent) → 200", "GET /statements/{id} → 200 Statement", "GET /customers/{id}/statements → 200 Statement",
        ])
        let endpoints = landed.props.endpoints.compactMap(\.endpoint)
        expectEqual(endpoints[0].body?.shape, event.id, "the body bound to its note: a pill, no arrow")
        expectEqual(endpoints[1].responses.first?.type?.shape, statement.id)
        expectEqual(endpoints[2].responses.first?.type?.shape, statement.id, "an array of Statement: Statement")
        expectEqual(endpoints[1].parameters, [PathParameter(name: "id", type: "uuid")])
        expectEqual(try schema(editor, "StripeEvent")["properties"]?.members?.map(\.key), ["id", "type", "data"], "the file's order")
        let apiBox = try require(editor.document[landed.id]?.box), eventBox = try require(event.box), statementBox = try require(statement.box)
        expect(eventBox.minY > apiBox.maxY && statementBox.minY > apiBox.maxY, "the types below the API")
        expect(eventBox.maxX <= statementBox.minX, "side by side, in the file's order")
        for id in [landed.id, event.id, statement.id] { expectEqual(issues(of: id, in: editor), [], "nothing to warn of") }
        expectEqual(undoTitle(w.window), "Undo Paste OpenAPI")
        editor.undo()
        expectEqual(editor.document, before, "one Undo takes the API and its types")
    },
    test("a 3.0 file: a $ref points at its type's note by id, allOf makes the type build on its base, inline types named for their operation; Types warns of nothing") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds(refunds)
        expect(commandV(w))
        let money = try require(type(editor, "Money")), base = try require(type(editor, "Base")), refund = try require(type(editor, "Refund"))
        let response = try require(type(editor, "CreateRefundResponse"))
        let landed = try require(api(editor, "refunds API"))
        expectEqual(editor.selectedShapeIDs.count, 5, "the API and four types")
        // paste 02 for types: each after the one that refers to it most, so Refund sits between Money and Base, which it's built of.
        let row = [money, refund, base, response].sorted { ($0.box?.minX ?? 0) < ($1.box?.minX ?? 0) }.compactMap { $0[TitleProperty.self] }
        expectEqual(row, ["Money", "Refund", "Base", "CreateRefundResponse"], "laid out by their references")
        expectEqual(Set([money, refund, base, response].compactMap { $0.box?.minY }).count, 1, "one row of four")
        expectEqual(try schema(editor, "Refund")["properties"]?["amount"], .object([SchemaMember(key: "title", value: .string("amount")),
                                                                                     SchemaMember(key: "$ref", value: .string(SchemaReferences.uri(of: money.id)))]))
        // paste 06 and 07: each field titled as the file keys it, so it reads as written (E1 panel 4's `total_cents`).
        for property in try schema(editor, "Refund")["properties"]?.members ?? [] {
            expectEqual(FieldName.words(of: ChainField(name: property.key, schema: property.value)), property.key, "\(property.key) reads as written")
        }
        expectEqual(refund[IsAProperty.self]?.map(\.shape), [base.id], "Refund builds on Base")
        expectEqual(try schema(editor, "Refund")["required"], .array([.string("amount")]), "id is Base's to require")
        expectEqual(try schema(editor, "Money"), SchemaValue(try JSONReader.read(#"{"type": "integer", "exclusiveMinimum": 0, "examples": [1250]}"#)))
        expectEqual(try schema(editor, "Base")["properties"]?["id"]?["type"], .array([.string("string"), .string("null")]))
        expectEqual(landed.props.endpoints.first?.endpoint?.responses.first?.type?.shape, response.id)
        for id in [landed.id, money.id, base.id, refund.id, response.id] { expectEqual(issues(of: id, in: editor), [], "nothing to warn of") }
    },
    test("pasted again: the API and its types updated in place, endpoints by method and full path keeping their ids, one the file leaves out kept; a type's properties joined by name, what the person added kept") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds(billing)
        expect(commandV(w))
        let first = try require(api(editor, "billing API"))
        let statement = try require(type(editor, "Statement"))
        // Since: an endpoint typed in by hand, and a field and a color given to Statement in its schema.
        _ = try drawnInProcess(#"api "billing API" endpoints: "DELETE /statements/{id}""#, on: editor)
        var held = try schema(editor, "Statement")
        if case .object(var members) = held {
            members.append(SchemaMember(key: "$color", value: .string("green")))
            if let at = members.firstIndex(where: { $0.key == "properties" }), case .object(var properties) = members[at].value {
                properties.append(SchemaMember(key: "memo", value: .object([SchemaMember(key: "type", value: .string("string"))])))
                members[at].value = .object(properties)
            }
            held = .object(members)
        }
        editor.transact("Edit Schema") { $0.update(statement.id) { $0[TypeSchemaProperty.self] = SchemaText(held.pretty) } }
        // And the API made narrower by hand, which a paste again leaves as it is.
        editor.transact("Resize") { $0.update(first.id, as: API.self) { $0.props.frame.size.width = 500 } }
        let shapes = editor.document.shapes.count
        let changed = billing
            .replacingOccurrences(of: "        total_cents: {type: integer}", with: "        total_cents: {type: integer}\n        currency: {type: string}")
            .replacingOccurrences(of: "      operationId: getStatement", with: "      operationId: getStatement\n      summary: One statement")
        pasteboardHolds(changed)
        expect(commandV(w))
        expectEqual(editor.document.shapes.count, shapes, "nothing made: restated")
        let again = try require(api(editor, "billing API"))
        expectEqual(again.id, first.id)
        expectEqual(again.props.frame.width, 500, "the width the person gave it")
        for endpoint in first.props.endpoints.compactMap(\.endpoint) {
            expectEqual(again.props.endpoints.first { $0.endpoint?.method == endpoint.method && $0.endpoint?.path == endpoint.path }?.id, endpoint.id,
                        "\(endpoint.method) \(endpoint.path) keeps its id")
        }
        expectEqual(again.props.endpoints.compactMap(\.endpoint).map { "\($0.method) \($0.path)" }.last, "DELETE /statements/{id}", "one the file doesn't say kept")
        expectEqual(again.props.endpoints.compactMap(\.endpoint).first { $0.name == "getStatement" }?.summary, "One statement")
        expectEqual(type(editor, "Statement")?.id, statement.id)
        let joined = try schema(editor, "Statement")
        expectEqual(joined["properties"]?.members?.map(\.key), ["id", "period", "total_cents", "memo", "currency"], "held in place, the new after")
        expectEqual(joined["$color"], .string("green"), "the type's color kept")
        let cents = try require(joined["properties"]?["total_cents"])
        expectEqual(FieldName.words(of: ChainField(name: "total_cents", schema: cents)), "total_cents", "paste 06: as the wire says it, never \"total cents\"")
        let memo = try require(joined["properties"]?["memo"])
        expectEqual(memo["title"], nil, "a field the person added is left as they wrote it")
        // StripeEvent pasted as it was: neither said nor selected (paste 04).
        expectEqual(editor.selectedShapeIDs, [again.id, statement.id], "what the paste changed")
        expectEqual(editor.announcements.last, "Updated API and Type")
        expectEqual(undoTitle(w.window), "Undo Paste OpenAPI")
    },
    test("a plain note called as a type is left alone: the type is made beside it, and the body binds to the type") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        _ = try drawnInProcess(#"sticky-note "Statement" text: "the monthly statement, as the customer sees it""#, on: editor)
        let note = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Statement" })
        pasteboardHolds(billing)
        expect(commandV(w))
        expectEqual(editor.document[note.id]?[TypeSchemaProperty.self], nil, "the note stays a note")
        let statement = try require(type(editor, "Statement"))
        expect(statement.id != note.id)
        expectEqual(api(editor, "billing API")?.props.endpoints[1].endpoint?.responses.first?.type?.shape, statement.id)
    },
    test("the kit off: ⌘V of OpenAPI does nothing and Paste is off; on, it pastes; prose that names OpenAPI isn't it") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds(billing)
        expect(!editor.canPaste, "no reader of OpenAPI in a file with the kit off")
        let revision = editor.revision
        _ = commandV(w)
        expectEqual(editor.revision, revision, "nothing pasted")
        try w.turnKitOn()
        expect(editor.canPaste)
        expect(commandV(w))
        expect(api(editor, "billing API") != nil)
        pasteboardHolds("Our API is described with OpenAPI.")
        expect(!editor.canPaste, "prose: no reader sniffs it")
    },
    test("pasted again with the same file: nothing changes, no step, and the schemas keep their order, a color put first stays first") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds(billing)
        expect(commandV(w))
        let event = try require(type(editor, "StripeEvent"))
        var held = try schema(editor, "StripeEvent")
        if case .object(let members) = held { held = .object([SchemaMember(key: "$color", value: .string("green"))] + members) }
        editor.transact("Edit Schema") { $0.update(event.id) { $0[TypeSchemaProperty.self] = SchemaText(held.pretty) } }
        editor.undoHistory.seal()
        let document = editor.document, revision = editor.revision
        pasteboardHolds(billing)
        expect(commandV(w))
        expectEqual(editor.document, document, "the same file says nothing new")
        expectEqual(editor.revision, revision, "no step")
        expectEqual(undoTitle(w.window), "Undo Edit Schema", "the last step is still the person's")
        expectEqual(try schema(editor, "StripeEvent").members?.map(\.key), ["$color", "type", "required", "properties"])
    },
    test("Undo and Redo of a paste, and of a paste again, are exact: the held schema with the person's field and color, the endpoints and their ids, the width") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        let blank = editor.document
        pasteboardHolds(billing)
        expect(commandV(w))
        let first = editor.document
        editor.undo()
        expectEqual(editor.document, blank, "Undo takes the first paste whole")
        editor.redo()
        expectEqual(editor.document, first, "Redo puts it back as it was, ids and all")
        let landed = try require(api(editor, "billing API")), statement = try require(type(editor, "Statement"))
        var held = try schema(editor, "Statement")
        if case .object(var members) = held {
            members.append(SchemaMember(key: "$color", value: .string("green")))
            if let at = members.firstIndex(where: { $0.key == "properties" }), case .object(var properties) = members[at].value {
                properties.append(SchemaMember(key: "memo", value: .object([SchemaMember(key: "type", value: .string("string"))])))
                members[at].value = .object(properties)
            }
            held = .object(members)
        }
        editor.transact("Edit Schema") { $0.update(statement.id) { $0[TypeSchemaProperty.self] = SchemaText(held.pretty) } }
        editor.transact("Resize") { $0.update(landed.id, as: API.self) { $0.props.frame.size.width = 500 } }
        editor.undoHistory.seal()
        let edited = editor.document
        pasteboardHolds(billing.replacingOccurrences(of: "        total_cents: {type: integer}", with: "        total_cents: {type: integer}\n        currency: {type: string}"))
        expect(commandV(w))
        let merged = editor.document
        expect(merged != edited, "the paste changed the Statement")
        expectEqual(undoTitle(w.window), "Undo Paste OpenAPI")
        editor.undo()
        expectEqual(editor.document, edited, "Undo of the paste again restores the held schema, the width and the endpoints exactly")
        editor.redo()
        expectEqual(editor.document, merged, "Redo puts the merged state back")
    },
    test("pasted again, a response the file no longer has is gone from the endpoint") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        // Two responses first (a 200 and a 404), then one.
        let doubled = billing.replacingOccurrences(of: "      responses:\n        '200':\n          description: received\n",
                                                   with: "      responses:\n        '200':\n          description: received\n        '404':\n          description: missing\n")
        pasteboardHolds(doubled)
        expect(commandV(w))
        expectEqual(try require(api(editor, "billing API")).props.endpoints.first?.endpoint?.responses.map(\.status), ["200", "404"])
        pasteboardHolds(billing)
        expect(commandV(w))
        let again = try require(api(editor, "billing API"))
        expectEqual(again.props.endpoints.first?.endpoint?.responses.map(\.status), ["200"], "the 404 the file dropped is dropped")
    },
    test("two files at once are two APIs, a type the files share one note, the first file's schema; they land together, selected, announced as APIs and Types") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-openapi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func spec(_ title: String, _ field: String) -> String {
            """
            openapi: 3.0.0
            info: {title: \(title), version: '1'}
            paths:
              /\(title):
                get:
                  responses:
                    '200':
                      description: ok
                      content: {application/json: {schema: {$ref: '#/components/schemas/Error'}}}
            components:
              schemas:
                Error:
                  allOf:
                    - $ref: '#/components/schemas/Base'
                    - type: object
                      properties: {\(field): {type: string}}
                Base: {type: object, properties: {code: {type: string}}}
            """
        }
        let one = folder.appendingPathComponent("one.yaml"), two = folder.appendingPathComponent("two.yml")
        try spec("one", "alpha").write(to: one, atomically: true, encoding: .utf8)
        try spec("two", "beta").write(to: two, atomically: true, encoding: .utf8)
        let pasteboard = ShippedPlugins.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([one as NSURL, two as NSURL])
        expect(commandV(w))
        let apis = editor.document.shapes.filter { $0.kind == API.kind }
        expectEqual(apis.compactMap { $0[TitleProperty.self] }.sorted(), ["one", "two"])
        expectEqual(editor.document.shapes.filter { $0[TitleProperty.self] == "Error" }.count, 1, "one note for the shared name")
        expectEqual(try schema(editor, "Error")["properties"]?.members?.map(\.key), ["alpha"], "the first file's schema")
        let error = try require(type(editor, "Error")), base = try require(type(editor, "Base"))
        expectEqual(error[IsAProperty.self]?.map(\.shape), [base.id])
        for api in apis { expectEqual(api.typed(as: API.self)?.props.endpoints.first?.endpoint?.responses.first?.type?.shape, error.id, "both bound to it") }
        expectEqual(editor.selectedShapeIDs.count, 4)
        expectEqual(editor.announcements.last, "Pasted 2 APIs and 2 Types")
    },
    test("it lands beside the selection, what lands is selected and the shape it landed beside no longer is; Tab walks it by keys and Shift-Tab comes back") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        _ = try drawnInProcess(#"sticky-note "Anchor" text: "here""#, on: editor)
        let anchor = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Anchor" })
        editor.selectedShapeIDs = [anchor.id]
        pasteboardHolds(billing)
        expect(commandV(w))
        let landed = try require(api(editor, "billing API")), event = try require(type(editor, "StripeEvent"))
        expectEqual(editor.selectedShapeIDs.count, 3)
        expect(!editor.selectedShapeIDs.contains(anchor.id), "the anchor isn't selected")
        let anchorBox = try require(editor.document[anchor.id]?.box)
        for id in editor.selectedShapeIDs {
            expect(!anchorBox.intersects(try require(editor.document[id]?.box)), "clear of the anchor")
        }
        expectEqual(editor.announcements.last, "Pasted API and 2 Types", "VoiceOver hears types, not notes")
        // The keys: from the API alone, Tab goes on to the shapes after it in reading order, and Shift-Tab back.
        editor.selectedShapeIDs = [landed.id]
        w.window.press("\t", code: 48)
        let next = editor.selectedShapeIDs
        expectEqual(next.count, 1)
        expect(next != [landed.id], "Tab moved on")
        expect(next.first.map { [event.id, try! require(type(editor, "Statement")).id].contains($0) } ?? false, "to a type it landed")
        w.window.press("\t", code: 48, modifiers: .shift)
        expectEqual(editor.selectedShapeIDs, [landed.id], "Shift-Tab is the way back")
    },
    test("an API titled as one of its types: its bodies, responses and is still bind to the type notes, not the API") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds("""
            openapi: 3.0.0
            info: {title: Pet, version: '1'}
            paths:
              /pets:
                post:
                  requestBody: {content: {application/json: {schema: {$ref: '#/components/schemas/Pet'}}}}
                  responses:
                    '201': {description: made, content: {application/json: {schema: {$ref: '#/components/schemas/Dog'}}}}
            components:
              schemas:
                Pet: {type: object, properties: {name: {type: string}}}
                Dog:
                  allOf:
                    - $ref: '#/components/schemas/Pet'
                    - type: object
                      properties: {bark: {type: string}}
            """)
        expect(commandV(w))
        let landed = try require(api(editor, "Pet")), pet = try require(type(editor, "Pet")), dog = try require(type(editor, "Dog"))
        expect(landed.id != pet.id)
        let endpoint = try require(landed.props.endpoints.first?.endpoint)
        expectEqual(endpoint.body?.shape, pet.id, "the body is the type, not the API")
        expectEqual(endpoint.responses.first?.type?.shape, dog.id)
        expectEqual(dog[IsAProperty.self]?.map(\.shape), [pet.id], "Dog builds on the type Pet")
    },
    test("text with no title (and no file) pasted is an API called API; pasted again it is that API; types named only by case are two notes") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        let text = """
            openapi: 3.0.0
            paths:
              /m:
                get:
                  responses:
                    '200': {description: ok, content: {application/json: {schema: {$ref: '#/components/schemas/Money'}}}}
            components:
              schemas:
                Money: {type: object, properties: {cents: {type: integer}}}
                money: {type: object, properties: {units: {type: integer}}}
            """
        pasteboardHolds(text)
        expect(commandV(w))
        expectEqual(editor.document.shapes.filter { $0.kind == API.kind }.compactMap { $0[TitleProperty.self] }, ["API"])
        expectEqual(editor.document.shapes.filter { $0[TypeSchemaProperty.self] != nil }.compactMap { $0[TitleProperty.self] }.sorted(), ["Money", "money"])
        expectEqual(try schema(editor, "Money")["properties"]?.members?.map(\.key), ["cents"])
        expectEqual(try schema(editor, "money")["properties"]?.members?.map(\.key), ["units"])
        let shapes = editor.document.shapes.count
        pasteboardHolds(text)
        expect(commandV(w))
        expectEqual(editor.document.shapes.count, shapes, "the API is found again by its title")
    },
    test("the type notes a paste makes are as tall as their rows, not the note's default; one the file has keeps its own size") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds(billing)
        expect(commandV(w))
        let event = try require(type(editor, "StripeEvent")), statement = try require(type(editor, "Statement"))
        let box = try require(event.box)
        expect(box.height < 120 && box.height > 40, "three rows: \(box.height)")
        expectEqual(try require(statement.box).height, box.height, "three rows each")
        editor.transact("Resize") { $0.update(event.id) { $0.box = CGRect(x: box.minX, y: box.minY, width: 400, height: 300) } }
        pasteboardHolds(billing)
        expect(commandV(w))
        expectEqual(editor.document[event.id]?.box?.size, CGSize(width: 400, height: 300), "the size the person gave it")
    },
])
