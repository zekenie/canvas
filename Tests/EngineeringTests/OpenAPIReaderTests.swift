import Canvas
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
    test("a type pasted again joins what it holds: its properties by name in place, the paste's new ones after, required for a property only it has kept, what else only it says kept") {
        let held = try json(#"{"type": "object", "description": "mine", "$color": "green", "properties": {"id": {"type": "integer"}, "memo": {"type": "string"}}, "required": ["memo"]}"#)
        let written = try json(#"{"type": "object", "properties": {"id": {"type": "string"}, "period": {"type": "string"}}, "required": ["id"]}"#)
        let joined = OpenAPIPaste.joined(written, onto: held)
        expectEqual(joined.members?.map(\.key), ["type", "properties", "required", "description", "$color"])
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
])
