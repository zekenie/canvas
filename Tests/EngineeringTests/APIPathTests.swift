import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Engineering
import LineRows
import Selection
import TestKit
import TextEditing
import Titles

// Paths under headers keep their shape (the whole-branch review): an endpoint's card has a line for each parameter of its full
// path, its header's too, kept in that order; a header says back every full path under it, so a trailing slash and a path with
// no leading one stay what they were through Group by Prefix and a paste of OpenAPI; a response type a status would read is
// quoted; and a block of path prefixes is named for path prefixes.

/// `paths` (method GET) as endpoints with their paths whole.
private func endpoints(_ paths: [String]) -> [Endpoint] { paths.map { Endpoint(method: "GET", path: $0) } }

/// Every row's full path, in order.
private func fullPaths(_ rows: [APIRow]) -> [String] { APIGroups.fullPaths(in: rows) }

@MainActor let apiPathTests = Suite("Paths under headers keep their shape", [
    test("an endpoint's card has a line for each parameter of its full path, its header's first; a type set keeps that order") {
        let b = try KitBench()
        let api = b.api("projects API", ["/{workspace}", "GET /projects/{id}"])
        b.begin(api)
        b.press(.up)
        expectEqual(b.field.string, "GET /projects/{id}")
        b.press(Chord(Key.down, .command))
        let card = try require(b.canvas.cardView as? LineCardView)
        expectEqual(card.stopNames, ["name", "summary", "auth", "{workspace}", "{id}", "body", "responses 1", "method", "deprecated", "relations 1"])
        card.go(to: "{id}")
        b.type("uuid")
        b.press(.tab)
        card.go(to: "{workspace}")
        b.type("slug")
        b.press(.tab)
        expectEqual(b.rows(api)[1].endpoint?.parameters.map(\.name), ["workspace", "id"], "the full path's order, not the header's last")
        expectEqual(card.value(of: "{workspace}"), "slug")
        b.press(.escape)
    },
    test("Group by Prefix says back every full path: /orders/ beside /orders stays whole, Django's slashes head /orders/, a path with no slash stays") {
        let mixed = APIGroups.byPrefix(endpoints(["/orders", "/orders/", "/orders/{id}"]))
        expectEqual(fullPaths(mixed).sorted(), ["/orders", "/orders", "/orders/", "/orders/{id}"], "the header, and each path as it was")
        expectEqual(mixed.map(EndpointGrammar.print), ["GET /orders/", "/orders", "GET /", "GET /{id}"])
        let django = APIGroups.byPrefix(endpoints(["/orders/", "/orders/{id}/", "/items/", "/items/{id}/"]))
        expectEqual(django.map(EndpointGrammar.print), ["/orders/", "GET /", "GET /{id}/", "/items/", "GET /", "GET /{id}/"])
        expectEqual(fullPaths(django), ["/orders/", "/orders/", "/orders/{id}/", "/items/", "/items/", "/items/{id}/"])
        let bare = APIGroups.byPrefix(endpoints(["orders", "orders/{id}", "/orders/{id}/items"]))
        expectEqual(fullPaths(bare), ["orders", "orders/{id}", "/orders/{id}/items"], "no full path changes")
        expect(!APIGroups.fits("/orders/", under: "/orders") && APIGroups.fits("/orders/", under: "/orders/") && !APIGroups.fits("orders", under: "/orders"))
        // A full path pasted goes under a header only where it reads back there.
        let rows = [APIRow.header(PathHeader(prefix: "/orders")), .endpoint(Endpoint(method: "GET", path: "/{id}"))]
        expectEqual(APIGroups.place("/orders/", in: rows).path, "/orders/", "whole, under none")
        expectEqual(APIGroups.place("/orders/{id}/items", in: rows).path, "/{id}/items")
    },
    test("a paste of OpenAPI with /orders and /orders/ on one method keeps both, each its own endpoint") {
        let document = try require(OpenAPIReader.read("""
            openapi: 3.0.0
            info:
              title: Shop
              version: "1"
            paths:
              /orders:
                get:
                  responses:
                    "200":
                      description: ok
              /orders/:
                get:
                  responses:
                    "200":
                      description: ok
              /orders/{id}:
                get:
                  responses:
                    "200":
                      description: ok
            """))
        let names = document.rows.indices.compactMap { index in document.rows[index].endpoint.map { _ in APIGroups.fullName(of: index, in: document.rows) } }
        expectEqual(names.sorted(), ["GET /orders", "GET /orders/", "GET /orders/{id}"])
    },
    test("a response type named Default or 404 is quoted where a status would read it, and reads back as the type") {
        for name in ["Default", "default", "404"] {
            let endpoint = Endpoint(method: "GET", path: "/x", responses: [EndpointResponse(status: "", type: TypeRef(name))])
            let line = EndpointGrammar.print(endpoint)
            expectEqual(line, "GET /x → \"\(name)\"")
            let read = try require(EndpointGrammar.read(line)?.endpoint)
            expectEqual(read.responses.first?.status, "", line)
            expectEqual(read.responses.first?.type?.words, name, line)
        }
        expectEqual(EndpointGrammar.print(Endpoint(method: "GET", path: "/x", responses: [EndpointResponse(status: "200", type: TypeRef("Default"))])),
                    "GET /x → 200 \"Default\"")
    },
    test("a block of path prefixes pasted is Paste Path Prefixes, and two deleted as items Delete Path Prefixes") {
        let b = try KitBench()
        let api = b.api("shop API", ["GET /health"])
        b.begin(api)
        b.field.paste(text: "/orders\n/customers")
        expectEqual(b.undoName, "Paste Path Prefixes")
        b.press(.escape)
        let headers = b.rows(api).filter { $0.header != nil }.map(\.id)
        expectEqual(headers.count, 2)
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems(headers.map { AnyHashable($0) }, of: api)
        b.window.settle()
        b.press(.delete)
        expectEqual(b.undoName, "Delete Path Prefixes")
        expectEqual(b.rows(api).count, 1)
    },
])
