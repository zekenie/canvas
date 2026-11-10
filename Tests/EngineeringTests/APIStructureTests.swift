import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
@_spi(Host) import CanvasUI
import Engineering
import LineRows
import Selection
import TestKit
import TextEditing
import Titles

// What an API's rows keep as their neighbors change (K12's review): a header taken out (by ⌫ or by draw's delete) leaves its
// endpoints their full paths, one moved takes its group, an endpoint that leaves every group takes its prefix with it, a
// full path pasted goes under its header, a response of a type alone and a type of several words go through a card and a line
// whole, what VoiceOver says of each row, and the steps' names.

/// An API's rows with their full names.
@MainActor private func names(_ b: KitBench, _ api: ShapeID) -> [String] {
    let rows = b.rows(api)
    return rows.indices.map { rows[$0].header?.prefix ?? APIGroups.fullName(of: $0, in: rows) }
}

/// The API's lines as written.
private let grouped = ["GET /health", "/users", "GET /{id}", "/orders", "GET /{id}", "POST /{id}/refunds (NewRefund) → 201 Refund", "/customers", "GET /{id}/orders"]

@MainActor let apiStructureTests = Suite("API rows and their neighbors", [
    test("a header taken out alone, by ⌘⌫ ⌫ on its emptied line, leaves its endpoints their full paths: they take its prefix back, or go where a whole path goes; one Delete Path Prefix, and one Undo") {
        let b = try KitBench()
        let api = b.api("orders API", grouped)
        let full = Set(b.fullNames(api))
        let before = b.rows(api)
        let ids = before.map(\.id)
        b.begin(api)
        b.view?.go(to: .row(ids[3]))
        expectEqual(b.field.string, "/orders")
        b.press(Chord(Key.delete, .command))
        b.press(.delete)
        expectEqual(b.undoName, "Delete Path Prefix")
        expectEqual(Set(b.fullNames(api)), full, "every endpoint's full path is what it was")
        expect(b.rows(api).allSatisfy { $0.header?.prefix != "/orders" })
        expectEqual(b.rows(api).first?.endpoint.map { APIGroups.fullName(method: $0.method, path: $0.path) }, "GET /health")
        expect(b.rows(api).prefix(3).allSatisfy { $0.header == nil }, "/orders's two went to the top, where a whole path goes, under no header")
        b.press(.escape)
        b.editor.undo()
        expectEqual(b.rows(api), before, "one Undo puts every row back exactly")
    },
    test("draw's delete of a header's part (the registry's removing) does the same: the endpoints keep their full paths, the header gone; a header taken with its endpoints takes them") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "GET /{id}", "/customers", "GET /{id}/orders", "POST /"])
        let before = Set(b.fullNames(api))
        let rows = b.rows(api)
        @MainActor func without(_ ids: Set<PartID>) throws -> [APIRow] {
            let record = try require(b.editor.registry.removing(ids, from: try require(b.editor.document[api])))
            return record.typed(as: API.self)?.props.endpoints ?? []
        }
        let alone = try without([rows[0].id])
        expectEqual(alone.count, 4)
        expectEqual(alone.first?.endpoint?.path, "/orders/{id}", "under no header, its whole path")
        var fulls = Set<String>()
        for index in alone.indices where alone[index].endpoint != nil { fulls.insert(APIGroups.fullName(of: index, in: alone)) }
        expectEqual(fulls, before)
        let both = try without([rows[0].id, rows[1].id])
        expectEqual(both.map(EndpointGrammar.print), ["/customers", "GET /{id}/orders", "POST /"])
    },
    test("a header moved by ⌥↓ takes its group past the next, and ⌥↑ brings it back; no full path changes; one Move Path Prefix") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "GET /{id}", "POST /", "/customers", "GET /{id}/orders"])
        let ids = b.rows(api).map(\.id)
        let full = b.fullNames(api)
        b.begin(api)
        b.view?.go(to: .row(ids[0]))
        b.press(Chord(Key.down, .option))
        expectEqual(b.undoName, "Move Path Prefix")
        expectEqual(b.rows(api).map(\.id), [ids[3], ids[4], ids[0], ids[1], ids[2]], "its two went with it")
        expectEqual(Set(b.fullNames(api)), Set(full))
        b.press(Chord(Key.up, .option))
        expectEqual(b.rows(api).map(\.id), ids)
        b.press(Chord(Key.up, .option))
        expectEqual(b.rows(api).map(\.id), ids, "nothing above the first group")
        b.press(.escape)
        expectEqual(Set(b.fullNames(api)), Set(full))
    },
    test("an endpoint moved above the first header leaves every group and takes its prefix with it; back under a header that covers it, its full path kept; across headers it keeps its own path, as a file moved between folders") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "GET /{id}", "/customers", "GET /{id}/orders"])
        let ids = b.rows(api).map(\.id)
        b.begin(api)
        b.view?.go(to: .row(ids[1]))
        b.press(Chord(Key.up, .option))
        expectEqual(b.undoName, "Move Endpoint")
        expectEqual(b.rows(api).map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        expectEqual(b.rows(api).first?.endpoint?.path, "/orders/{id}", "under no header now: its whole path")
        expectEqual(b.fullNames(api).first, "GET /orders/{id}")
        b.press(Chord(Key.down, .option))
        expectEqual(b.rows(api).map(\.id), ids, "back under /orders")
        expectEqual(b.rows(api)[1].endpoint?.path, "/{id}", "a header that covers its full path takes it back: the move back is exact")
        b.press(Chord(Key.down, .option))
        expectEqual(b.rows(api).map(\.id), [ids[0], ids[2], ids[1], ids[3]])
        expectEqual(b.fullNames(api).suffix(2), ["GET /customers/{id}", "GET /customers/{id}/orders"], "under /customers: its own path kept, its full path follows its group")
        b.press(.escape)
    },
    test("a full path pasted into an API with headers goes under the longest header it starts with, its path as written under it, else at the top; one Paste Endpoints") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /health", "/orders", "GET /{id}", "/customers", "GET /{id}/orders"])
        b.begin(api)
        b.field.paste(text: "POST /orders/{id}/refunds\nDELETE /customers/{id}\nGET /status")
        expectEqual(b.undoName, "Paste Endpoints")
        expectEqual(b.apiLines(api), ["GET /health", "GET /status", "/orders", "GET /{id}", "POST /{id}/refunds", "/customers", "GET /{id}/orders", "DELETE /{id}"])
        expectEqual(Set(b.fullNames(api)), ["GET /health", "GET /status", "GET /orders/{id}", "POST /orders/{id}/refunds", "GET /customers/{id}/orders", "DELETE /customers/{id}"])
        b.press(.escape)
        b.editor.undo()
        expectEqual(b.apiLines(api).count, 5, "one step")
    },
    test("a response of a type alone (→ Order) goes through the card whole: its arrow printed, a second response added there leaves it a type, no status") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /orders/{id} → Order"])
        b.begin(api)
        b.press(.up)
        b.press(Chord(Key.down, .command))
        let card = try require(b.canvas.cardView as? LineCardView)
        expectEqual(card.value(of: "responses 1"), "→ Order")
        card.go(to: "responses 1")
        b.window.settle()
        b.press(.return)
        b.type("404")
        b.press(.tab)
        expectEqual(b.rows(api)[0].endpoint?.responses, [EndpointResponse(status: "", type: TypeRef("Order")), EndpointResponse(status: "404")])
        b.press(.escape)
        b.press(.escape)
    },
    test("a type of several words: quoted after a response's status, in a bracket whole, held to the no-loss law, and read from the card as one name") {
        let line = #"POST /refunds (Refund Request) → 201 "Refund Result" tail"#
        let endpoint = try require(EndpointGrammar.read(line)?.endpoint)
        expectEqual(endpoint.body, TypeRef("Refund Request"))
        expectEqual(endpoint.responses, [EndpointResponse(status: "201", type: TypeRef("Refund Result"))])
        expectEqual(endpoint.unread, "tail")
        expectEqual(EndpointGrammar.print(endpoint), line, "printed with the name quoted, so it reads back whole")
        let open = try require(EndpointGrammar.read("POST /refunds (Refund Req → 201")?.endpoint)
        expectEqual(open.body, TypeRef("Refund Req"), "a bracket left open runs to the arrow: the name so far")
        expectEqual(open.responses, [EndpointResponse(status: "201")])
        let scan = EndpointGrammar.scan(line)
        let response = try require(scan.words.first { $0.role == .response })
        expectEqual((line as NSString).substring(with: response.range), "Refund Result", "its pill is the name, not its quotes")
        let b = try KitBench()
        let api = b.api("orders API", ["POST /refunds (Refund Request) → 201 Result"])
        b.begin(api)
        b.press(.up)
        b.press(Chord(Key.down, .command))
        let card = try require(b.canvas.cardView as? LineCardView)
        expectEqual(card.value(of: "body"), "→ Refund Request")
        card.go(to: "responses 1")
        b.window.settle()
        try require(card.field(of: "responses 1")).selectAll(nil)
        b.type("201 → Refund Result")
        b.press(.escape)
        expectEqual(b.rows(api)[0].endpoint?.responses.first?.type, TypeRef("Refund Result"), "all its words")
        b.press(.escape)
    },
    test("VoiceOver: a header is \"Path Prefix 1 of 2\" and an endpoint \"Endpoint 3 of 7\", each among its own; an endpoint row's help is its full name and its operation; the server is a stop") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /health", "/orders", "GET /{id}", "POST /{id}/refunds", "/customers", "GET /{id}/orders"], server: APIServer(host: "api.shop.dev/v1", auth: "bearer"))
        var rows = b.rows(api)
        if case .endpoint(var refunds) = rows[3] {
            refunds.name = "createRefund"
            rows[3] = .endpoint(refunds)
        }
        b.editor.transact("Name") { $0.update(api, as: API.self) { $0.props.endpoints = rows } }
        let ids = rows.map(\.id)
        b.begin(api)
        let view = try require(b.view)
        view.go(to: .row(ids[1]))
        expectEqual(b.field.accessibilityLabel(), "Path Prefix 1 of 2")
        view.go(to: .row(ids[4]))
        expectEqual(b.field.accessibilityLabel(), "Path Prefix 2 of 2")
        view.go(to: .row(ids[3]))
        expectEqual(b.field.accessibilityLabel(), "Endpoint 3 of 4")
        view.go(to: .row(ids[2]))
        let elements = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        let help = elements.compactMap { $0.accessibilityHelp() }
        expect(help.contains("POST /orders/{id}/refunds, createRefund"), "\(help)")
        expect(help.contains("/customers, path prefix, 1 endpoint"), "\(help)")
        let server = try require(elements.first { $0.accessibilityLabel() == "Server" })
        expectEqual(server.accessibilityValue() as? String, "api.shop.dev/v1 bearer")
        b.press(.escape)
    },
    test("each step is named for what a person did: Move Endpoint, Delete Endpoint, Delete Path Prefix; and Undo says each") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "GET /{id}", "POST /"])
        let ids = b.rows(api).map(\.id)
        b.begin(api)
        b.view?.go(to: .row(ids[2]))
        b.press(Chord(Key.up, .option))
        expectEqual(b.undoName, "Move Endpoint")
        b.press(Chord(Key.delete, .command))
        b.press(.delete)
        expectEqual(b.undoName, "Delete Endpoint")
        b.view?.go(to: .row(ids[0]))
        b.press(Chord(Key.delete, .command))
        b.press(.delete)
        expectEqual(b.undoName, "Delete Path Prefix")
        expectEqual(b.rows(api).map(\.id), [ids[1]], "the header and the endpoint went, the other kept")
        b.press(.escape)
    },
    test("a header's chevron and count show through the band while its prefix is typed (E5 panel 1)") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "GET /{id}", "POST /{id}/refunds"], at: CGPoint(x: 40, y: 40))
        let ids = b.rows(api).map(\.id)
        b.begin(api)
        let view = try require(b.view)
        view.go(to: .row(ids[0]))
        let row = try require(view.rect(of: .row(ids[0])))
        let area = view.convert(row, to: b.canvas)
        let rep = try require(b.canvas.bitmapImageRepForCachingDisplay(in: area))
        b.canvas.cacheDisplay(in: area, to: rep)
        // The band's flat color, out in the row where nothing is drawn; the chevron's room, left of the prefix, differs from it.
        let band = pixel(rep, at: CGPoint(x: area.width / 2, y: area.height / 2))
        var most = 0
        for x in stride(from: CGFloat(12), to: 28, by: 1) {
            for y in stride(from: CGFloat(0), to: area.height, by: 1) {
                let found = pixel(rep, at: CGPoint(x: x, y: y))
                most = max(most, zip(found.prefix(3), band.prefix(3)).map { abs($0 - $1) }.max() ?? 0)
            }
        }
        expect(most > 12, "the chevron shows through the band: its room differs from it by \(most)")
        b.press(.escape)
    },
    test("an endpoint's card is wide enough to read, and a field without the keyboard shows its text from its start: a long summary isn't clipped at its front") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /{id}"])
        b.editor.transact("Summary") { transaction in
            transaction.update(api, as: API.self) { record in
                if case .endpoint(var endpoint) = record.props.endpoints[0] {
                    endpoint.summary = "Refund part or all of a paid order, in full or in part, with a reason given."
                    record.props.endpoints[0] = .endpoint(endpoint)
                }
            }
        }
        b.begin(api)
        b.press(.up)
        b.press(Chord(Key.down, .command))
        let card = try require(b.canvas.cardView as? LineCardView)
        b.window.settle()
        expect(card.frame.width >= 350, "wide: \(card.frame.width)")
        let summary = try require(card.field(of: "summary"))
        expectEqual(summary.frame.minX, 0, "from its start")
        expectEqual(card.focusedStop, "name")
        b.press(.escape)
    },
    test("the method in the row with the caret is laid out as its chip is at rest: the chip as wide, the path starting as far from the glyphs, for a short method and a long one") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /orders/{id}", "DELETE /orders/{id}", "/orders", "PATCH /{id}"])
        let ids = b.rows(api).map(\.id)
        b.begin(api)
        for (index, method) in [(0, "GET"), (1, "DELETE"), (3, "PATCH")] {
            b.view?.go(to: .row(ids[index]))
            let field = b.field
            let text = field.string as NSString
            let width = (method as NSString).size(withAttributes: [.font: KitStyle.chipFont]).width
            let chip = max(APIStyleTest.chipLeast, width + 2 * APIStyleTest.chipPadding)
            let glyphs = field.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            // The path's first glyph: the one after its slash, less the slash's advance (the kern before the slash is split between the two
            // segments, so the slash's own start isn't where its glyph is).
            let slash = text.range(of: "/").location
            let after = field.firstRect(forCharacterRange: NSRange(location: slash + 1, length: 1), actualRange: nil)
            let advance = ("/" as NSString).size(withAttributes: [.font: KitStyle.codeFont]).width
            let path = CGRect(x: after.minX - advance, y: after.minY, width: advance, height: after.height)
            let drawn = try require(field.highlights.first { $0.range == NSRange(location: 0, length: method.count) })
            let frame = try require(field.frames(of: drawn).first)
            // The path starts the chip's width and the gap from where the chip starts, which is the glyphs, in by the chip's padding.
            let pathAt = path.minX - glyphs.minX
            let chipWidth = frame.width
            expect(abs(pathAt - (chip + APIStyleTest.gap - APIStyleTest.chipPadding)) < 1, "\(method): the path starts as it does at rest: \(pathAt)")
            expect(abs(chipWidth - chip) < 1.5, "\(method): the chip as wide: \(chipWidth)")
            // Where the chip at rest starts (the line's left, the kind's inset, a member's indent), with its left end drawn whole: the
            // field leaves the chip's padding before its text, inside the clip (UX walk 4 apis-4-1, connect-7).
            let view = try require(b.view), line = try require(view.rect(of: .row(ids[index])))
            let rest = line.minX + APIStyleTest.inset + (index == 3 ? APIStyleTest.memberIndent : 0)
            let left = field.convert(frame, to: view).minX
            expect(abs(left - rest) < 1, "\(method): the chip starts where it does at rest: \(left), at rest \(rest)")
            let clip = try require(field.superview)
            expect(field.convert(frame, to: clip).minX >= -0.5, "\(method): its left end inside the clip, never cut")
        }
        b.press(.escape)
    },
])

/// The API's look constants the test reads.
@MainActor enum APIStyleTest {
    static let chipLeast: CGFloat = 38
    static let chipPadding: CGFloat = 6
    static let gap: CGFloat = 8
    static let inset: CGFloat = 14
    static let memberIndent: CGFloat = 18
}
