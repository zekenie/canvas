import Canvas
import Draw
import Engineering
import Foundation
import TestKit
import Types

// The OpenAPI reader (`OpenAPIReader`), pure: 3.0 and 3.1, YAML and JSON, into an API (title, version, server, rows grouped by
// the kit's one rule) and its types (components' schemas, then inline objects named for their operations) in JSON Schema 2020-12;
// and the paste's two pure pieces, a component's `$ref` pointed at its note and a type pasted again joined onto what it holds
// (`OpenAPIPaste`). E1 panel 4's billing.openapi.yaml is the first case.

/// E1 panel 4's file: three endpoints under three segments, two types, bearer auth.
let billingOpenAPI = """
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
          summary: Stripe calls this with each event
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
            - name: id
              in: path
              required: true
              schema:
                type: string
                format: uuid
          responses:
            '200':
              description: the statement
              content:
                application/json:
                  schema:
                    $ref: '#/components/schemas/Statement'
            '404':
              description: no such statement
      /customers/{id}/statements:
        get:
          operationId: listCustomerStatements
          parameters:
            - $ref: '#/components/parameters/CustomerId'
            - name: limit
              in: query
              schema:
                type: integer
          responses:
            '200':
              description: the customer's statements, newest first
              content:
                application/json:
                  schema:
                    type: array
                    items:
                      $ref: '#/components/schemas/Statement'
    components:
      parameters:
        CustomerId:
          name: id
          in: path
          required: true
          schema: {type: string, format: uuid}
      securitySchemes:
        bearerAuth:
          type: http
          scheme: bearer
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

/// A 3.0 file in JSON: what 3.0 says that 2020-12 says otherwise, `allOf`, inline types, and what's lost.
private let refundsJSON = #"""
    {
      "openapi": "3.0.3",
      "info": {"title": "", "version": "2"},
      "servers": [{"url": "https://{region}.api.shop.dev/{base}/", "variables": {"region": {"default": "eu"}, "base": {"default": "v1"}}}],
      "security": [{"key": []}],
      "x-internal": true,
      "tags": [{"name": "refunds"}],
      "paths": {
        "/orders/{id}/refunds": {
          "parameters": [{"name": "id", "in": "path", "schema": {"type": "string"}}, {"name": "X-Trace", "in": "header", "schema": {"type": "string"}}],
          "post": {
            "operationId": "createRefund",
            "deprecated": true,
            "security": [{"oauth": ["refunds:write", "orders:read"]}],
            "parameters": [{"name": "id", "in": "path", "schema": {"type": "string", "format": "uuid"}}, {"name": "dryRun", "in": "query", "schema": {"type": "boolean"}}, {"name": "session", "in": "cookie"}],
            "requestBody": {"$ref": "#/components/requestBodies/NewRefund"},
            "responses": {
              "201": {"description": "made", "content": {"application/json": {"schema": {"type": "object", "properties": {"id": {"type": "string"}}}}}},
              "409": {"description": "a conflict", "content": {"application/problem+json": {"schema": {"type": "object", "properties": {"detail": {"type": "string"}}}}}},
              "default": {"$ref": "#/components/responses/Problem"}
            },
            "callbacks": {"done": {}}
          }
        },
        "/orders": {
          "get": {
            "security": [{"basic": []}],
            "parameters": [{"name": "tags", "in": "query", "schema": {"type": "array", "items": {"type": "string"}}}],
            "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "array", "items": {"type": "object", "properties": {"n": {"type": "integer"}}}}}}}}
          }
        }
      },
      "components": {
        "securitySchemes": {
          "key": {"type": "apiKey", "in": "header", "name": "X-API-Key"},
          "oauth": {"type": "oauth2", "flows": {}},
          "basic": {"type": "http", "scheme": "basic"}
        },
        "requestBodies": {"NewRefund": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/Refund"}}}}},
        "responses": {"Problem": {"description": "a problem", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Problem"}}}}},
        "schemas": {
          "Money": {
            "title": "Money in cents",
            "type": "integer",
            "minimum": 0,
            "exclusiveMinimum": true,
            "example": 1250,
            "x-unit": "cents"
          },
          "Refund": {
            "allOf": [
              {"$ref": "#/components/schemas/Base"},
              {"type": "object", "required": ["amount", "reason", "id"], "properties": {"amount": {"$ref": "#/components/schemas/Money"}, "reason": {"type": "string", "nullable": true, "enum": ["fraud", "duplicate"]}}}
            ],
            "discriminator": {"propertyName": "kind"},
            "xml": {"name": "refund"},
            "externalDocs": {"url": "https://docs"}
          },
          "Base": {"type": "object", "required": ["id"], "properties": {"id": {"type": "string", "format": "uuid"}, "note": {"$ref": "other.yaml#/Note"}, "part": {"$ref": "#/components/schemas/Refund/properties/amount"}}},
          "Problem": {"type": "object", "properties": {"title": {"type": "string"}}},
          "CreateRefundResponse201": {"type": "object"}
        }
      }
    }
    """#

private func endpoints(_ document: OpenAPIDocument) -> [Endpoint] { document.rows.compactMap(\.endpoint) }

@MainActor private func type(_ name: String, _ document: OpenAPIDocument) throws -> OpenAPIType {
    try require(document.types.first { $0.name == name }, "a type \(name)")
}

private func json(_ text: String) throws -> SchemaValue { SchemaValue(try JSONReader.read(text)) }

@MainActor let openAPIReaderTests = Suite("OpenAPI read into an API and its types", [
    test("E1 panel 4: billing.openapi.yaml, 3.1 in YAML: the API titled from info, its server and bearer auth; three endpoints under three segments, ungrouped, in the file's order") {
        let document = try require(OpenAPIReader.read(billingOpenAPI, fileName: "billing.openapi.yaml"))
        expectEqual(document.title, "billing API")
        expectEqual(document.version, "1.0.0")
        expectEqual(document.server, APIServer(host: "billing.shop.dev", auth: "bearer"), "the scheme dropped")
        expect(document.rows.allSatisfy { $0.header == nil }, "no segment shared: no header")
        expectEqual(document.rows.map(EndpointGrammar.print), [
            "POST /webhooks/stripe (StripeEvent) → 200",
            "GET /statements/{id} → 200 Statement",
            "GET /customers/{id}/statements → 200 Statement",
        ])
        let all = endpoints(document)
        expectEqual(all.map(\.name), ["receiveStripeEvent", "getStatement", "listCustomerStatements"])
        expectEqual(all[0].summary, "Stripe calls this with each event")
        expectEqual(all[0].authScope, "none", "security: [] is none")
        expectEqual(all[1].authScope, "", "the API's own")
        expectEqual(all[1].parameters, [PathParameter(name: "id", type: "uuid")], "format: uuid is uuid")
        expectEqual(all[1].responses.map(\.status), ["200", "404"])
        expectEqual(all[2].parameters, [PathParameter(name: "id", type: "uuid"), PathParameter(name: "limit", type: "integer")], "a $ref'd path parameter, then the query's")
        expectEqual(document.types.map(\.name), ["StripeEvent", "Statement"])
        expectEqual(try type("StripeEvent", document).schema.pretty, """
            {
              "type": "object",
              "required": ["id", "type"],
              "properties": {
                "id": {
                  "type": "string"
                },
                "type": {
                  "type": "string"
                },
                "data": {
                  "type": "object"
                }
              }
            }
            """)
    },
    test("the same file as JSON reads the same; Swagger 2.0, a file with no paths and text that isn't either aren't read; the sniff looks for openapi as a key") {
        let yaml = try require(OpenAPIReader.read(billingOpenAPI))
        let tree = try require(try YAMLReader.read(billingOpenAPI))
        let asJSON = tree.pretty
        let fromJSON = try require(OpenAPIReader.read(asJSON))
        expectEqual(fromJSON.rows.map(EndpointGrammar.print), yaml.rows.map(EndpointGrammar.print))
        expectEqual(fromJSON.types, yaml.types)
        expectEqual(fromJSON.server, yaml.server)
        expectEqual(fromJSON.title, yaml.title)
        expectEqual(OpenAPIReader.read("swagger: '2.0'\npaths: {}\n"), nil)
        expectEqual(OpenAPIReader.read("openapi: 3.0.0\ninfo: {title: x}\n"), nil)
        expectEqual(OpenAPIReader.read("CREATE TABLE x (id int);"), nil)
        expect(OpenAPIReader.read("openapi: 3.1\npaths: {}\n") != nil, "3.1 read as a number is 3.x")
        expect(OpenAPIReader.sniffs(billingOpenAPI))
        expect(OpenAPIReader.sniffs(asJSON))
        expect(!OpenAPIReader.sniffs("We use OpenAPI for our docs."))
    },
    test("3.0 in JSON: the server's variables' defaults, the API's name from the file with no title, an API key's header name") {
        let document = try require(OpenAPIReader.read(refundsJSON, fileName: "refunds.openapi.json"))
        expectEqual(document.title, "refunds", "no title: the file's name less its extensions")
        expectEqual(document.version, "2")
        expectEqual(document.server, APIServer(host: "eu.api.shop.dev/v1", auth: "apikey X-API-Key"))
    },
    test("endpoints: scopes, another scheme's word, deprecated; path and query parameters with their types, the operation's over the path item's, header and cookie ones lost") {
        let document = try require(OpenAPIReader.read(refundsJSON))
        let refund = try require(endpoints(document).first { $0.method == "POST" })
        expectEqual(document.rows.map(EndpointGrammar.print), ["/orders", "POST /{id}/refunds (Refund) → 201 CreateRefundResponse2012", "GET / → 200 GetOrdersResponse"],
                    "/orders/{id}/refunds and /orders share their first segment: a group")
        expect(refund.deprecated)
        expectEqual(refund.authScope, "refunds:write orders:read")
        expectEqual(refund.parameters, [PathParameter(name: "id", type: "uuid"), PathParameter(name: "dryRun", type: "boolean")],
                    "the operation's id over the path item's; X-Trace and session lost")
        let list = try require(endpoints(document).first { $0.method == "GET" })
        expectEqual(list.authScope, "basic", "another scheme than the API's, with no scopes: its word")
        expectEqual(list.parameters, [PathParameter(name: "tags", type: "string[]")])
    },
    test("bodies and responses: a $ref'd request body and response followed; inline objects made types named for their operation, the status added when several are inline, a name taken made unique; no operationId: the method and path's words") {
        let document = try require(OpenAPIReader.read(refundsJSON))
        let refund = try require(endpoints(document).first { $0.method == "POST" })
        expectEqual(refund.body?.words, "Refund")
        expectEqual(refund.responses.map(\.status), ["201", "409", "default"])
        expectEqual(refund.responses.map { $0.type?.words }, ["CreateRefundResponse2012", "CreateRefundResponse409", "Problem"],
                    "two inline: the status added; CreateRefundResponse201 is a component's, so 2 after it")
        let list = try require(endpoints(document).first { $0.method == "GET" })
        expectEqual(list.responses.first?.type?.words, "GetOrdersResponse", "an array of an inline object: the object's type")
        expectEqual(document.types.map(\.name), ["Money", "Refund", "Base", "Problem", "CreateRefundResponse201", "CreateRefundResponse2012",
                                                 "CreateRefundResponse409", "GetOrdersResponse"], "components, then the inline ones in order")
        expectEqual(try type("CreateRefundResponse409", document).schema, try json(#"{"type": "object", "properties": {"detail": {"type": "string"}}}"#),
                    "application/problem+json when no application/json")
    },
    test("conversion to 2020-12: a boolean exclusiveMinimum a number, example examples, the root title and x- extensions dropped") {
        let document = try require(OpenAPIReader.read(refundsJSON))
        expectEqual(try type("Money", document).schema, try json(#"{"type": "integer", "exclusiveMinimum": 0, "examples": [1250]}"#))
    },
    test("allOf of a $ref and an object: the type builds on Base and has its own properties; nullable a null type and enum value; required only its own; discriminator, xml and externalDocs lost") {
        let document = try require(OpenAPIReader.read(refundsJSON))
        let refund = try type("Refund", document)
        expectEqual(refund.isA, ["Base"])
        expectEqual(refund.schema, try json(#"""
            {"type": "object", "properties": {
              "amount": {"$ref": "#/components/schemas/Money"},
              "reason": {"type": ["string", "null"], "enum": ["fraud", "duplicate", null]}
            }, "required": ["amount", "reason"]}
            """#), "id is Base's to require")
    },
    test("a $ref out of the document is {}; one into a component's part stays, for the paste to point at its note with the fragment") {
        let document = try require(OpenAPIReader.read(refundsJSON))
        let base = try type("Base", document)
        expectEqual(base.schema["properties"]?["note"], .object([]))
        expectEqual(base.schema["properties"]?["part"], try json(##"{"$ref": "#/components/schemas/Refund/properties/amount"}"##))
        let id = ShapeID()
        let pointed = OpenAPIPaste.pointed(base.schema) { $0 == "Refund" ? id : nil }
        expectEqual(pointed["properties"]?["part"]?["$ref"], .string(SchemaReferences.uri(of: id) + "#/properties/amount"))
        let unknown = OpenAPIPaste.pointed(try json(##"{"properties": {"a": {"$ref": "#/components/schemas/Gone", "description": "x"}}}"##)) { _ in nil }
        expectEqual(unknown["properties"]?["a"], .object([]), "a component no note stands for: {}")
    },
    test("titled: each property is titled as keyed, at any depth, where it has none; an example, a default, a const, an enum and an extension are data, left as written") {
        let schema = try json(##"""
            {"properties": {"payment_id": {"type": "string"}, "kept": {"title": "Kept words"}, "nested": {"properties": {"inner_key": {"type": "integer"}}},
                            "flag": true},
             "example": {"properties": {"a": {"type": "x"}}}, "default": {"properties": {"b": 1}}, "const": {"properties": {"c": 1}},
             "enum": [{"properties": {"d": 1}}], "x-sample": {"properties": {"e": 1}}}
            """##)
        let titled = OpenAPIPaste.titled(schema)
        expectEqual(titled["properties"]?["payment_id"]?["title"], .string("payment_id"))
        expectEqual(titled["properties"]?["kept"]?["title"], .string("Kept words"), "a title of its own stays")
        expectEqual(titled["properties"]?["nested"]?["properties"]?["inner_key"]?["title"], .string("inner_key"))
        expectEqual(titled["properties"]?["flag"], .bool(true), "a boolean property is left as it is")
        for key in ["example", "default", "const", "enum", "x-sample"] { expectEqual(titled[key], schema[key], "\(key) is data") }
    },
    test("a type pasted again joins what it holds: its properties by name in place, the paste's new ones after, required for a property only it has kept, what else only it says kept") {
        let held = try json(#"{"type": "object", "description": "mine", "$color": "green", "properties": {"id": {"type": "integer"}, "memo": {"type": "string"}}, "required": ["memo"]}"#)
        let written = try json(#"{"type": "object", "properties": {"id": {"type": "string"}, "period": {"type": "string"}}, "required": ["id"]}"#)
        let joined = OpenAPIPaste.joined(written, onto: held)
        expectEqual(joined.members?.map(\.key), ["type", "description", "$color", "properties", "required"], "each held member where it is")
        expectEqual(joined["properties"]?.members?.map(\.key), ["id", "memo", "period"])
        expectEqual(joined["properties"]?["id"], try json(#"{"type": "string"}"#), "the paste's id")
        expectEqual(joined["required"], .array([.string("id"), .string("memo")]))
    },
    test("groups: the kit's one rule, a header for each first segment two or more endpoints share, in the order met, their paths under it; the rest first, whole (E8's seven groups, E1's none)") {
        let paths = ["/orders", "/orders/{id}", "/health", "/customers/{id}", "/orders/{id}/refunds", "/customers", "/", "/admin/users"]
        let rows = APIGroups.byPrefix(paths.map { Endpoint(method: "GET", path: $0) })
        expectEqual(rows.map(EndpointGrammar.print), ["GET /health", "GET /", "GET /admin/users", "/orders", "GET /", "GET /{id}", "GET /{id}/refunds",
                                                      "/customers", "GET /{id}", "GET /"])
        expectEqual(Set(rows.indices.filter { rows[$0].endpoint != nil }.map { APIGroups.fullName(of: $0, in: rows) }), Set(paths.map { "GET " + $0 }),
                    "every full path kept")
        let sixty = ["orders", "customers", "products", "payments", "refunds", "webhooks", "admin"].flatMap { segment in
            (0..<8).map { Endpoint(method: "GET", path: "/\(segment)/\($0)") }
        }
        expectEqual(APIGroups.byPrefix(sixty).compactMap(\.header).map(\.prefix), ["/orders", "/customers", "/products", "/payments", "/refunds", "/webhooks", "/admin"])
    },
    test("a type pasted again with what it already says is what it holds, in its order (a paste of the same file is no change)") {
        let written = try json(#"{"type": "object", "required": ["id"], "properties": {"id": {"type": "string"}, "data": {"type": "object"}}}"#)
        expectEqual(OpenAPIPaste.joined(written, onto: written), written)
        let colored = try json(#"{"$color": "green", "type": "object", "required": ["id"], "properties": {"id": {"type": "string"}, "data": {"type": "object"}}}"#)
        let joined = OpenAPIPaste.joined(written, onto: colored)
        expectEqual(joined, colored, "a color put first stays first")
        expectEqual(joined.members?.map(\.key), ["$color", "type", "required", "properties"])
    },
    test("a $ref outside the components that leads back to itself reads, as a parameter's type with no name (no endless walk)") {
        let loop = #"""
            {"openapi": "3.0.0", "paths": {"/a": {"get": {
              "parameters": [{"name": "p", "in": "query", "schema": {"$ref": "#/paths/~1a/get/parameters/0/schema"}},
                             {"name": "q", "in": "query", "schema": {"$ref": "#/paths/~1a/get/parameters/2/schema"}},
                             {"name": "r", "in": "query", "schema": {"$ref": "#/paths/~1a/get/parameters/1/schema"}}],
              "responses": {}}}}}
            """#
        let document = try require(OpenAPIReader.read(loop))
        expectEqual(endpoints(document)[0].parameters.map(\.type), ["", "", ""])
    },
    test("a version, title, summary or operationId written as a number or a word keeps the words it was written in (1.0, 1.10, 404)") {
        let text = """
            openapi: 3.0.0
            info:
              title: 404
              version: 1.10
            paths:
              /a:
                get:
                  operationId: 12
                  summary: 1.0
                  responses: {}
            """
        let document = try require(OpenAPIReader.read(text))
        expectEqual(document.title, "404")
        expectEqual(document.version, "1.10")
        expectEqual(endpoints(document)[0].name, "12")
        expectEqual(endpoints(document)[0].summary, "1.0")
        let plain = try require(OpenAPIReader.read(text.replacingOccurrences(of: "version: 1.10", with: "version: 1.0")))
        expectEqual(plain.version, "1.0")
        let asJSON = try require(OpenAPIReader.read(#"{"openapi": "3.0.0", "info": {"title": 7, "version": "1.0"}, "paths": {}}"#))
        expectEqual(asJSON.title, "7", "JSON's number in a title is its text too")
    },
    test("a query parameter a path parameter has the name of is left out: the card's field for the path's is the only one") {
        let text = """
            openapi: 3.0.0
            paths:
              /things/{id}:
                get:
                  parameters:
                    - {name: id, in: query, schema: {type: string}}
                    - {name: id, in: path, schema: {type: string, format: uuid}}
                    - {name: limit, in: query, schema: {type: integer}}
                  responses: {}
            """
        let document = try require(OpenAPIReader.read(text))
        expectEqual(endpoints(document)[0].parameters, [PathParameter(name: "id", type: "uuid"), PathParameter(name: "limit", type: "integer")])
    },
    test("a 3.0 nullable beside a $ref or an allOf with no type is that schema or null; a folded root's own type allows it") {
        let text = """
            openapi: 3.0.0
            paths: {}
            components:
              schemas:
                Money: {type: object, properties: {cents: {type: integer}}}
                Owner:
                  type: object
                  properties:
                    spare: {$ref: '#/components/schemas/Money', nullable: true}
                    price: {allOf: [{$ref: '#/components/schemas/Money'}], nullable: true}
                    note: {type: string, nullable: true}
                Maybe:
                  nullable: true
                  allOf:
                    - $ref: '#/components/schemas/Money'
                    - properties: {extra: {type: string}}
            """
        let document = try require(OpenAPIReader.read(text))
        let owner = try type("Owner", document).schema
        let null = #"{"type": "null"}"#
        let ref = ##"{"$ref": "#/components/schemas/Money"}"##
        expectEqual(owner["properties"]?["spare"], try json("{\"anyOf\": [" + ref + ", " + null + "]}"))
        expectEqual(owner["properties"]?["price"], try json("{\"anyOf\": [{\"allOf\": [" + ref + "]}, " + null + "]}"))
        expectEqual(owner["properties"]?["note"], try json(#"{"type": ["string", "null"]}"#))
        let maybe = try type("Maybe", document)
        expectEqual(maybe.isA, ["Money"])
        expectEqual(maybe.schema["type"], .array([.string("object"), .string("null")]))
    },
    test("a $ref into a component's allOf part follows the folded type: a part that is a $ref is its target, a part's properties the component's own, any other pointer leads nowhere") {
        let text = """
            openapi: 3.0.0
            paths: {}
            components:
              schemas:
                Base: {type: object, properties: {id: {type: string}}}
                Refund:
                  allOf:
                    - $ref: '#/components/schemas/Base'
                    - type: object
                      properties: {amount: {type: integer}}
                User:
                  type: object
                  properties:
                    a: {$ref: '#/components/schemas/Refund/allOf/1/properties/amount'}
                    b: {$ref: '#/components/schemas/Refund/allOf/0/properties/id'}
                    c: {$ref: '#/components/schemas/Refund/allOf/1/required'}
                    d: {$ref: '#/components/schemas/Refund/allOf/7/properties/id'}
            """
        let document = try require(OpenAPIReader.read(text))
        let user = try type("User", document).schema["properties"]
        expectEqual(user?["a"], try json(##"{"$ref": "#/components/schemas/Refund/properties/amount"}"##))
        expectEqual(user?["b"], try json(##"{"$ref": "#/components/schemas/Base/properties/id"}"##))
        expectEqual(user?["c"], .object([]))
        expectEqual(user?["d"], .object([]))
    },
    test("components whose names differ only by case are two types, and an inline type takes a name no component has") {
        let text = """
            openapi: 3.0.0
            paths:
              /m:
                post:
                  operationId: money
                  requestBody: {content: {application/json: {schema: {type: object, properties: {a: {type: string}}}}}}
                  responses: {}
            components:
              schemas:
                Money: {type: object, properties: {cents: {type: integer}}}
                money: {type: object, properties: {units: {type: integer}}}
            """
        let document = try require(OpenAPIReader.read(text))
        expectEqual(document.types.map(\.name), ["Money", "money", "MoneyRequest"])
    },
    test("an API is made wide enough for its widest row to show whole: never narrower than a new one (420) nor wider than the most (760); a body, a status, a type and a group's indent take room") {
        @MainActor func width(_ paths: [(path: String, extra: String)]) throws -> CGFloat {
            let operations = paths.map { "  \($0.path):\n    get:\n      operationId: x\n\($0.extra)      responses:\n        '200': {description: ok}\n" }.joined()
            let program = try require(OpenAPIPaste.program(of: "openapi: 3.0.0\ninfo: {title: t, version: '1'}\npaths:\n" + operations, typeKind: nil))
            let size = try require(program.sizes[1])
            return size.width
        }
        expectEqual(try width([("/a", "")]), 420, "a new API's width at least")
        let long = "/" + String(repeating: "abcdefghij/", count: 8) + "{id}"
        expectEqual(try width([(long, "")]), 760, "clamped at the most a pasted API is made")
        let mid = "/" + String(repeating: "abcdefghij/", count: 3) + "{id}"
        let bare = try width([(mid, "")])
        expect(bare > 420 && bare < 760, "a path of its own length: \(bare)")
        // A body takes room, and so does a second segment's group (a header's indent and count).
        let withBody = try width([(mid, "      requestBody:\n        content:\n          application/json:\n            schema: {\"$ref\": '#/components/schemas/Request'}\n")])
        expect(withBody > bare, "a body: \(withBody) over \(bare)")
        // A group's member is drawn by the path under its header, indented: wider than the same path ungrouped.
        let grouped = try width([("/orders" + mid, ""), ("/orders/{id}", "")])
        expect(grouped > bare, "a member's indent takes room: \(grouped) over \(bare)")
    },
    test("a response's status is left to its type when it is the plain success one (E1's `→ Statement`), and shown for any other, or beside none") {
        @MainActor func width(status: String, typed: Bool) throws -> CGFloat {
            let schema = typed ? "content: {application/json: {schema: {\"$ref\": '#/components/schemas/S'}}}" : "description: ok"
            let text = "openapi: 3.0.0\ninfo: {title: t, version: '1'}\npaths:\n  /\(String(repeating: "abcdefghij/", count: 4))x:\n    get:\n      responses:\n        '\(status)': {\(schema)}\n"
            let program = try require(OpenAPIPaste.program(of: text, typeKind: nil))
            let size = try require(program.sizes[1])
            return size.width
        }
        let plain = try width(status: "200", typed: true), other = try width(status: "201", typed: true), none = try width(status: "200", typed: false)
        expect(other > plain, "a 201 is on its row, a 200 with a type is not: \(other) over \(plain)")
        expect(none > 420, "a response with none shows its 200")
    },
    test("a big spec reads in a step: 500 endpoints and 300 schemas of eight properties, YAML read, converted and made a program, within 900 milliseconds of the main thread's time") {
        var text = "openapi: 3.0.3\ninfo:\n  title: big\n  version: 2.0\nservers:\n  - url: https://big.example.com/v2\npaths:\n"
        for n in 0..<500 {
            text += "  /group\(n % 25)/items\(n)/{id}:\n    get:\n      operationId: getItem\(n)\n      summary: Gets item \(n)\n"
            text += "      parameters:\n        - {name: id, in: path, required: true, schema: {type: string, format: uuid}}\n        - {name: limit, in: query, schema: {type: integer}}\n"
            text += "      responses:\n        '200':\n          description: ok\n          content:\n            application/json:\n              schema:\n                $ref: '#/components/schemas/Schema\(n % 300)'\n"
            text += "        '404':\n          description: missing\n"
        }
        text += "components:\n  schemas:\n"
        for n in 0..<300 {
            text += "    Schema\(n):\n      type: object\n      required: [p0, p1]\n      properties:\n"
            for p in 0..<8 { text += "        p\(p): {type: string, nullable: true, description: 'property \(p) of schema \(n)'}\n" }
        }
        let size = text.utf8.count
        var program: DrawPut?
        let took = threadCPUTime { program = OpenAPIPaste.program(of: text, typeKind: "note") }
        expect(program != nil, "it reads")
        expectEqual(program?.late.count, 301, "the API and its 300 types, each with its late values")
        expect(took < .milliseconds(900), "\(size / 1024) KB took \(took)")
    },
])
