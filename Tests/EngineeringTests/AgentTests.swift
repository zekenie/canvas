import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Engineering
import Queries
import TestKit
import Titles

// What agents read of the kit (K18): `:route("…")`, the APIs with an endpoint of that method and whole path (a parameter is any
// parameter, no method any method), each row with the endpoints it matched; tests inside its kinds' list attributes and the values
// that read as one of their members (a column's type its words, an enum's value its text); and `--ask`'s `<tables>` and `<apis>`.
// No connector here: a key's `→` on a table's line, an endpoint's relations and the rows at a connection's ends are CompositionTests'
// (`queryKitBoardTests`).

/// The kit's plugins with the query engine, titles' names for it, and the kit's words for agents.
@MainActor private func agentHarness() throws -> EditorHarness {
    let h = try EditorHarness(plugins: kitPlugins() + [QueriesPlugin(), TitleQueriesPlugin(), EngineeringAgentsPlugin()])
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    return h
}

extension EditorHarness {
    /// A table titled `name` with columns written as lines, and an API with its rows written as lines.
    @discardableResult
    fileprivate func table(_ name: String, _ lines: [String], at y: CGFloat = 100) -> ShapeID {
        add(DatabaseTable(frame: CGRect(x: 100, y: y, width: 300, height: 100), columns: lines.compactMap { ColumnGrammar.read($0) }), titled: name)
    }

    @discardableResult
    fileprivate func api(_ name: String, _ lines: [String], server: APIServer = APIServer(), at y: CGFloat = 400) -> ShapeID {
        add(API(frame: CGRect(x: 500, y: y, width: 400, height: 100), server: server, endpoints: lines.compactMap { EndpointGrammar.read($0) }), titled: name)
    }

    /// What a query matches, by id, and its rows.
    fileprivate func ask(_ query: String) throws -> QueryResult {
        let queries = try require(editor.queries)
        return try awaitResult { try await queries.run(QueryRequest(query, limit: QueryRequest.every, properties: .none)) }
    }

    /// `--ask`'s block of `tag` for `question`.
    fileprivate func fact(_ tag: String, _ question: String = "") throws -> String {
        let fact = try require(editor.registry.contributions(to: QueryAskFacts.self).first { $0.value.tag == tag }, "the fact \(tag)")
        return fact.value.text(for: editor, question: question)
    }
}

@MainActor let agentTests = Suite("What agents read", [
    test("a route: its method in any case or none, its path with or without its slash, a query string and a trailing slash no part of it") {
        let route = try require(RoutePattern("post /orders/{id}/refunds"))
        expectEqual(route.method, "POST")
        expectEqual(route.segments, [.word("orders"), .parameter, .word("refunds")])
        expect(route.matches(method: "POST", path: "/orders/{order_id}/refunds"), "a parameter is any parameter")
        expect(route.matches(method: "post", path: "/orders/{id}/refunds/"), "the method in any case, and a trailing slash")
        expect(!route.matches(method: "GET", path: "/orders/{id}/refunds"), "another method")
        expect(!route.matches(method: "POST", path: "/orders/42/refunds"), "a parameter is no word")
        expect(!route.matches(method: "POST", path: "/orders/{id}"), "a shorter path")
        let any = try require(RoutePattern("orders/{id}?expand=lines"))
        expectEqual(any.method, nil, "no method: any")
        expect(any.matches(method: "GET", path: "/orders/{id}") && any.matches(method: "DELETE", path: "/orders/{x}"))
        expectEqual(RoutePattern(""), nil)
        expectEqual(RoutePattern("POST"), nil, "a method alone says no path")
        expectEqual(RoutePattern("POST /a /b"), nil, "two paths")
        let root = try require(RoutePattern("GET /"))
        expect(root.matches(method: "GET", path: "/") && !root.matches(method: "GET", path: "/orders"))
        expect(!root.matches(method: "GET", path: ""), "an endpoint with no path yet is no route")
        // A parameter inside a segment is anonymous too, the rest of the segment as written.
        let inside = try require(RoutePattern("GET /files/{n}.json"))
        expect(inside.matches(method: "GET", path: "/files/{name}.json") && !inside.matches(method: "GET", path: "/files/{name}.xml"))
        expect(try require(RoutePattern("/reports/{y}-{m}")).matches(method: "GET", path: "/reports/{year}-{month}"))
        expect(!inside.matches(method: "GET", path: "/files/report.json"), "a word is no parameter")
        expect(!inside.matches(method: "GET", path: "/files/{name}"), "nor a whole parameter one inside a segment")
        expectEqual(RoutePattern.refusal(of: "POST /orders"), nil)
        expectEqual(RoutePattern.refusal(of: "/orders"), nil)
        expectEqual(RoutePattern.refusal(of: "POST"), "POST says no path.")
        expect(RoutePattern.refusal(of: "") != nil && RoutePattern.refusal(of: "GET /a /b") != nil && RoutePattern.refusal(of: "a b") != nil)
    },
    test(":route finds the APIs with that endpoint, by whole path under its header; each row says the endpoints it matched") {
        let h = try agentHarness()
        let orders = h.api("orders API", ["/orders", "GET /{id}", "POST /{id}/refunds (NewRefund) → 201 Refund", "GET /"])
        let billing = h.api("billing API", ["POST /v1/refunds", "GET /v1/orders/{invoice}"], at: 600)
        h.table("orders", ["id uuid pk"])
        expectEqual(try h.ask(#":route("POST /orders/{id}/refunds")"#).rows.map(\.id), [orders])
        let any = try h.ask(#":route("/orders/{order_id}")"#)
        expectEqual(any.rows.map(\.id), [orders], "a parameter by another name, and no method")
        expectEqual(any.rows.first?.members, ["routes": ["GET /orders/{id}"]])
        expectEqual(try h.ask(#":route("GET /orders")"#).rows.first?.members, ["routes": ["GET /orders"]], "the header's own path, GET / under it")
        expectEqual(try h.ask(#"api:route("/v1/orders/{id}"), :route("GET /orders/{id}")"#).rows.map(\.id), [orders, billing])
        expectEqual(try h.ask(#":route("DELETE /orders/{id}")"#).count, 0)
        for text in ["POST", "GET /a /b", "", "nothing at all"] {
            do {
                _ = try h.ask(#":route("\#(text)")"#)
                expect(false, "\(text) says no route, and is answered")
            } catch {
                let said = String(describing: error)
                expect(said.contains("bad_argument") && said.contains(#":route("POST /orders/{id}/refunds")"#), "\(text): \(said)")
            }
        }
        h.add(API(frame: CGRect(x: 500, y: 700, width: 400, height: 100), endpoints: [.endpoint(Endpoint(id: PartID(), method: "GET", path: ""))]), titled: "blank API")
        expectEqual(try h.ask(#":route("GET /")"#).count, 0, "a row with no path yet is no route")
        h.api("files API", ["GET /files/{name}.json"], at: 800)
        expectEqual(try h.ask(#":route("/files/{n}.json")"#).count, 1, "a parameter inside a segment is any parameter")
        // A file's words: what it reads is the file alone, so a stored query may hold it.
        let plan = try require(h.editor.queries).check(#":route("GET /")"#)
        expect(plan.readsOnlyTheFile, "it reads the file")
        let word = try require(h.editor.queries?.vocabulary.words.first { $0.word == "route" })
        expectEqual(word.form, #":route("…")"#)
        expectEqual(word.from, .engineeringAgents)
    },
    test(":route finds an endpoint taken out of an API by its method and whole path, and <apis> lists it as an API of one route") {
        let h = try agentHarness()
        let orders = h.api("orders API", ["/orders", "GET /{id}"])
        let alone = h.add(StandaloneEndpoint(frame: CGRect(x: 100, y: 700, width: 420, height: 44),
                                             endpoint: Endpoint(method: "POST", path: "/orders/{id}/refunds", name: "createRefund", body: TypeRef("NewRefund"),
                                                                responses: [EndpointResponse(status: "201", type: TypeRef("Refund"))])))
        let unnamed = h.add(StandaloneEndpoint(frame: CGRect(x: 100, y: 900, width: 420, height: 44), endpoint: Endpoint(method: "DELETE", path: "/orders/{id}")))
        let found = try h.ask(#":route("POST /orders/{order_id}/refunds")"#)
        expectEqual(found.rows.map(\.id), [alone], "by its whole path, a parameter any parameter")
        expectEqual(found.rows.first?.members, ["routes": ["POST /orders/{id}/refunds"]])
        expectEqual(try h.ask(#":route("/orders/{id}")"#).rows.map(\.id), [orders, unnamed], "a path alone: any method, the API's row and the endpoint's own")
        expectEqual(try h.ask(#":route("GET /orders/{id}/refunds")"#).count, 0, "another method")
        expectEqual(try h.ask(#"endpoint:route("/orders/{id}/refunds")"#).rows.map(\.id), [alone])
        h.add(StandaloneEndpoint(frame: CGRect(x: 100, y: 1100, width: 420, height: 44), endpoint: Endpoint(method: "GET", path: "")))
        expectEqual(try h.ask(#":route("GET /")"#).count, 0, "one with no path yet is no route")
        expectEqual(try h.fact("apis").split(separator: "\n").map(String.init), [
            "orders API",
            "- GET /orders/{id}",
            "createRefund (endpoint)",
            "- POST /orders/{id}/refunds (NewRefund) → 201 Refund",
            "DELETE /orders/{id} (endpoint)",
            "- DELETE /orders/{id}",
            "GET (endpoint)",
        ], "one with no path yet: its name alone")
        expect(try h.fact("apis", "what does createRefund do?").hasPrefix("createRefund (endpoint)\n"), "the endpoints the question names first")
    },
    test("a test inside a list attribute holds when any item holds; a column's type reads as its words, an enum's value as its text") {
        let h = try agentHarness()
        let customers = h.table("customers", ["id uuid pk", "email text unique"])
        let orders = h.table("orders", ["id uuid pk", "customer_id uuid", "status order_status"], at: 300)
        let status = h.add(DatabaseEnum(frame: CGRect(x: 100, y: 600, width: 200, height: 80), values: ["pending", "paid"].map { EnumValue(text: $0) }),
                           titled: "order_status")
        let api = h.api("orders API", ["POST /orders/{id}/refunds (NewRefund) → 201 Refund"])
        expectEqual(try h.ask(#"table[columns.name="email"]"#).rows.map(\.id), [customers])
        expectEqual(try h.ask(#"table[columns.name^="customer"]"#).rows.map(\.id), [orders])
        expectEqual(try h.ask(#"table[columns.type="uuid"]"#).rows.map(\.id), [customers, orders], "a type, read as its words")
        expectEqual(try h.ask(#"table[columns.type.words="order_status"]"#).rows.map(\.id), [orders], "or by its member")
        expectEqual(try h.ask(#"table[columns.unique=true]"#).rows.map(\.id), [customers])
        expectEqual(try h.ask(#"table[columns="customer_id"]"#).rows.map(\.id), [orders], "a column, read as its name")
        expectEqual(try h.ask(#"enum-type[values="paid"]"#).rows.map(\.id), [status], "an enum's value, read as its text")
        expectEqual(try h.ask(#"[values="shipped"]"#).count, 0)
        expectEqual(try h.ask(#"api[endpoints.body="NewRefund"]"#).rows.map(\.id), [api], "a body, read as its type's words")
        expectEqual(try h.ask(#"api[endpoints.responses.status="201"]"#).rows.map(\.id), [api])
        expectEqual(try h.ask(#"api[endpoints.method="GET"]"#).count, 0)
        expectEqual(try h.ask(#"[columns.name.first="x"]"#).count, 0, "a member past a string is no value: answered, none")
    },
    test("a column's type reads as the enum's name now: a rename changes what a test finds, and the words only where it names no enum") {
        let h = try agentHarness()
        let status = h.add(DatabaseEnum(frame: CGRect(x: 100, y: 600, width: 200, height: 80), values: ["pending", "paid"].map { EnumValue(text: $0) }),
                           titled: "order_status")
        let orders = h.table("orders", ["id uuid pk", "status order_status", "kind ghost"], at: 300)
        h.editor.transact("Bind") { tx in
            tx.update(orders, as: DatabaseTable.self) { $0.props.columns[1].type.shape = status; $0.props.columns[2].type.shape = ShapeID() }
        }
        expectEqual(try h.ask(#"table[columns.type="order_status"]"#).rows.map(\.id), [orders])
        expectEqual(try h.ask(#"table[columns.type="ghost"]"#).rows.map(\.id), [orders], "a type that names nothing now is read as written")
        h.editor.transact("Rename") { $0.update(status) { $0[TitleProperty.self] = "order_state" } }
        expectEqual(try h.ask(#"table[columns.type="order_state"]"#).rows.map(\.id), [orders], "the new name finds it, as the card and <tables> say it")
        expectEqual(try h.ask(#"table[columns.type="order_status"]"#).count, 0, "the old one no longer does")
        expectEqual(try h.ask(#"table[columns.type^="order_"]"#).rows.map(\.id), [orders])
        let block = try h.fact("tables")
        expect(block.contains("status order_state"), block)
        // Not a rename the words kept: the enum gone, the words are what is left.
        h.editor.transact("Delete") { $0.delete([status]) }
        expectEqual(try h.ask(#"table[columns.type="order_status"]"#).rows.map(\.id), [orders])
    },
    test("<tables>: a table a line, its columns in their grammar, the database it's in; an enum a line; the question's tables first") {
        let h = try agentHarness()
        expectEqual(try h.fact("tables"), "", "no tables, no block")
        let shop = h.add(Database(frame: CGRect(x: 0, y: 0, width: 900, height: 900)), titled: "shop")
        h.table("customers", ["id uuid pk", "email text unique"])
        let orders = h.table("orders", ["id uuid pk", "placed_at timestamptz null"], at: 300)
        h.editor.transact { $0.setContainer(orders, to: shop) }
        h.add(DatabaseEnum(frame: CGRect(x: 1000, y: 600, width: 200, height: 80), values: ["pending", "paid"].map { EnumValue(text: $0) }), titled: "order_status")
        h.add(DatabaseTable(frame: CGRect(x: 1000, y: 100, width: 300, height: 100), columns: []), titled: nil)
        let text = try h.fact("tables")
        let untitled = try require(h.shapes(DatabaseTable.kind).first { h.editor.registry.title(of: $0) == nil }).id
        // In file order: the database followed by what it holds.
        expectEqual(text.split(separator: "\n").map(String.init), [
            #"orders (in "shop"): id uuid pk; placed_at timestamptz null"#,
            "customers: id uuid pk; email text unique",
            "order_status (enum-type): pending, paid",
            "#\(untitled)",
        ])
        expect(try h.fact("tables", "which customers have an email?").hasPrefix("customers: "), "the tables the question names first")
    },
    test("<tables> says a column's default as the word and not its value, and neither block says a word a row kept unread") {
        let h = try agentHarness()
        h.table("people", ["id uuid pk", "token text default 'sk_live_abc' extra words kept"], at: 300)
        let text = try h.fact("tables")
        expectEqual(text, "people: id uuid pk; token text default")
        expect(!text.contains("sk_live") && !text.contains("extra"))
        h.api("notes API", ["GET /notes secret words kept"])
        expect(try require(EndpointGrammar.read("GET /notes secret words kept")?.endpoint).unread.contains("secret"), "the row did keep them")
        expectEqual(try h.fact("apis"), "notes API\n- GET /notes", "an endpoint's unread words stay out")
    },
    test("<apis>: an API a line with its server, its routes a line each by whole path; a deprecated one says so; none, no block") {
        let h = try agentHarness()
        expectEqual(try h.fact("apis"), "")
        h.api("orders API", ["/orders", "GET /{id} → 200 Order", "POST /{id}/refunds (NewRefund) → 201 Refund"], server: APIServer(host: "api.shop.dev/v1", auth: "bearer"))
        h.add(API(frame: CGRect(x: 500, y: 700, width: 400, height: 100), deprecated: true, endpoints: ["GET /v0/orders"].compactMap { EndpointGrammar.read($0) }),
              titled: "old API")
        expectEqual(try h.fact("apis").split(separator: "\n").map(String.init), [
            "orders API (api.shop.dev/v1 bearer)",
            "- GET /orders/{id} → 200 Order",
            "- POST /orders/{id}/refunds (NewRefund) → 201 Refund",
            "old API (deprecated)",
            "- GET /v0/orders",
        ])
    },
    test("full paths in one pass are each row's own: under a header, under none, a header itself, and a row found by its id") {
        let rows = ["GET /top", "/orders", "GET /{id}", "POST /{id}/refunds", "/", "GET /", "/customers/", "GET /{n}/orders"].compactMap { EndpointGrammar.read($0) }
        expectEqual(APIGroups.fullPaths(in: rows), rows.indices.map { APIGroups.fullPath(of: $0, in: rows) })
        for (index, row) in rows.enumerated() {
            let id = row.header?.id ?? row.endpoint?.id
            expectEqual(APIGroups.fullName(ofRow: try require(id), in: rows), APIGroups.fullName(of: index, in: rows), "row \(index)")
        }
        expectEqual(APIGroups.fullName(ofRow: PartID(), in: rows), nil)
        expectEqual(APIGroups.fullPaths(in: []), [])
    },
    test("a block past its limit keeps whole shapes while they fit, then names the rest; one shape too long keeps the lines that fit") {
        let h = try agentHarness()
        for index in 0..<400 { h.table("table_\(index)", ["id uuid pk", "name text", "created_at timestamptz"], at: CGFloat(index) * 120) }
        let text = try h.fact("tables")
        expect(text.count <= 8_000, "at most 8,000 characters: \(text.count)")
        let last = try require(text.split(separator: "\n").last)
        expect(last.hasPrefix("and ") && last.contains("more tables: "), "the rest named: \(last.prefix(60))")
        let wide = h.table("zebra_ledger", (0..<600).map { "column_number_\($0) text" }, at: 100_000)
        let one = try h.fact("tables", "what is in zebra_ledger?")
        expect(one.count <= 8_000, "\(one.count)")
        expect(one.hasPrefix("zebra_ledger: column_number_0 text; column_number_1 text"), "its name kept, though one line is too long: \(one.prefix(80))")
        expect(one.contains("; and ") && one.contains(" more"), "the columns left out said: \(one.suffix(60))")
        _ = wide
        let routes = (0..<600).map { "GET /items/\($0)/children/{id}" }
        h.api("big API", routes)
        let apis = try h.fact("apis")
        expect(apis.count <= 8_000, "\(apis.count)")
        expect(apis.hasPrefix("big API\n- GET /items/0/children/{id}"), String(apis.prefix(80)))
        expect(apis.split(separator: "\n").last?.hasPrefix("- and ") == true && apis.hasSuffix(" more"), String(apis.suffix(40)))
    },
])
