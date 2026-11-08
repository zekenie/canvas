import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import Engineering
import LineRows
import Palette
import TestKit
import TextEditing
import Titles

// What an API does (K14): the kit's three relations as channels, with titles and tints (decided 25: white words at 4.5, and the
// Connections tab lights' rules: 3:1 on both canvases, clear of Find's orange and the accent), its endpoint rows' ports (both ends of
// a row, never a header's) and a table's (taken whole, no dots), and an endpoint's connection line as its card reads and prints it.
// No connector here (no Arrows): the arrows a line makes, a drag, ⌘L and a far endpoint's pill are CompositionTests' (`apiConnectShippedTests`).

@MainActor let relationTests = Suite("What an API does", [
    test("writes, reads and calls are channels the kit declares, each titled, its tint its dots', each an edge type under no connector here") {
        let h = try kitHarness()
        let registry = h.editor.registry
        for (channel, title) in [(Writes.id, "writes"), (Reads.id, "reads"), (Calls.id, "calls")] {
            expect(registry.declares(channel), "\(channel) declared")
            expectEqual(registry.channelTitle(channel), title)
            expect(registry.channelTint(channel) != nil)
        }
        expectEqual(registry.channelTitle(ForeignKey.id), nil, "a key has no pill")
        expect(!Writes.isOnEveryChannel && !Reads.isOnEveryChannel, "only tables take writes and reads: a subboard is no table")
        expect(!Calls.isOnEveryChannel && Calls.anyKindMayStart, "anything with dots calls, and only an endpoint's row is called: a subboard is no endpoint")
    },
    test("an endpoint's row has a dot at each end, calls first, writes and reads after; a table takes writes and reads whole, with no dot") {
        let h = try kitHarness()
        let registry = h.editor.registry
        expectEqual(registry.partDotChannels(of: API.kind), [Calls.id, Writes.id, Reads.id])
        expect(registry.takesOnParts(API.kind, Calls.id, as: .target), "an endpoint is called at its row")
        expect(!registry.takesOnParts(API.kind, Writes.id, as: .target), "an endpoint isn't written")
        expect(registry.takes(DatabaseTable.kind, Writes.id, as: .target) && !registry.takesOnParts(DatabaseTable.kind, Writes.id, as: .target))
        expect(registry.takes(DatabaseTable.kind, Reads.id, as: .target))
        expect(!registry.takes(DatabaseTable.kind, Writes.id, as: .source), "a table writes nothing")
        expectEqual(registry.dotChannels(of: DatabaseTable.kind), [], "no dots on a table's sides")
        expect(!registry.takes(DatabaseEnum.kind, Writes.id, as: .target), "an enum is no table")
    },
    test("a path prefix's header is no end: its frame says so, and the nearest row an end let go on it meets is an endpoint") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /health", "/orders", "POST /{id}/refunds"])
        let geometry = try require(b.editor.shapeContext.geometry(of: api))
        let rows = b.rows(api)
        expectEqual(geometry.parts.map(\.isConnectable), [true, false, true])
        let header = try require(geometry.parts.frame(rows[1].id))
        expectEqual(geometry.parts.frame(nearestY: header.rect.midY)?.isConnectable, true, "a drop on the header binds a row beside it")
    },
    test("the relations' tints: white words read at 4.5 on each, each reads at 3 on both canvases, and keeps clear of the accent's hue and Find's orange") {
        let accent = OKLCH(KitStyle.accentBlue).hue, orange = OKLCH(RGB(hex: 0xFF9500)).hue
        func apart(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
            return min(d, 2 * .pi - d) * 180 / .pi
        }
        for (name, tint, frame) in [("reads", KitStyle.readsTint, RGB(hex: 0x3A9E4F)), ("writes", KitStyle.writesTint, RGB(hex: 0xD23D86)),
                                    ("calls", KitStyle.callsTint, RGB(hex: 0x2C72DB))] {
            expect(RGB.white.contrast(with: tint) >= Swatch.textContrast, "\(name): white on it at \(RGB.white.contrast(with: tint))")
            for ground in [Swatch.canvas.light, Swatch.canvas.dark] {
                expect(tint.contrast(with: ground) >= Swatch.lineContrast, "\(name) on \(ground.hexString): \(tint.contrast(with: ground))")
            }
            expect(apart(OKLCH(tint).hue, accent) >= 15, "\(name) is \(apart(OKLCH(tint).hue, accent))° from the accent")
            expect(apart(OKLCH(tint).hue, orange) >= 30, "\(name) is clear of Find's orange")
            expect(apart(OKLCH(tint).hue, OKLCH(frame).hue) <= 20, "\(name) keeps the frames' hue near: \(apart(OKLCH(tint).hue, OKLCH(frame).hue))°")
        }
        expect(apart(OKLCH(RGB(hex: 0x2C72DB)).hue, accent) < 15, "the frames' calls blue was the accent's own hue: why it turned")
    },
    test("an endpoint's connection line: the relation, then a table's name or an endpoint's API and full name; read, printed, read back the same") {
        let b = try KitBench()
        let refunds = b.h.add(DatabaseTable(frame: CGRect(x: 700, y: 100, width: 200, height: 80), columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true)]),
                              titled: "refunds")
        let stripe = b.api("Stripe API", ["POST /v1/refunds"], at: CGPoint(x: 100, y: 500))
        let orders = b.api("orders API", ["POST /orders/{id}/refunds"])
        let endpoint = b.rows(orders)[0].id, far = b.rows(stripe)[0].id
        let context = LineContext(editor: b.editor, shape: orders, row: endpoint)
        let grammar = EngineeringAPILines.links
        expectEqual(grammar.read(LineText("writes refunds"), id: endpoint, in: context).row, EndpointLink(channel: Writes.id, target: PartAddress(refunds)))
        expectEqual(grammar.read(LineText("reads refunds"), id: endpoint, in: context).row, EndpointLink(channel: Reads.id, target: PartAddress(refunds)))
        let call = EndpointLink(channel: Calls.id, target: PartAddress(stripe, part: far))
        expectEqual(grammar.read(LineText("calls Stripe API.POST /v1/refunds"), id: endpoint, in: context).row, call)
        expectEqual(grammar.read(LineText("calls POST /v1/refunds"), id: endpoint, in: context).row, call, "its full name alone, where one has it")
        expect(grammar.read(LineText("writes nowhere"), id: endpoint, in: context).row == nil, "words that name no table make no connection")
        expect(grammar.read(LineText("calls refunds"), id: endpoint, in: context).row == nil, "a call goes to an endpoint, never a table")
        expect(grammar.read(LineText("owns refunds"), id: endpoint, in: context).row == nil, "no relation")
        let printed = grammar.print(call, in: context)
        expectEqual(printed.string, "calls Stripe API.POST /v1/refunds")
        expectEqual(printed.references.map(\.target), [call.target], "standing for the endpoint")
        expectEqual(grammar.read(printed, id: endpoint, in: context).row, call)
        // Renamed: the line prints the live name, and its reference still reads it.
        b.editor.transact("Rename") { $0.update(stripe) { $0[TitleProperty.self] = "Payments" } }
        expectEqual(grammar.print(call, in: context).string, "calls Payments.POST /v1/refunds")
        expectEqual(grammar.read(printed, id: endpoint, in: context).row, call, "the reference reads it whatever its words")
        expectEqual(grammar.spoken(call, in: context), "calls POST /v1/refunds")
    },
    test("what a connection line offers: the three relations at its start, the file's tables after writes and reads, its endpoints after calls, each lit") {
        let b = try KitBench()
        let refunds = b.h.add(DatabaseTable(frame: CGRect(x: 700, y: 100, width: 200, height: 80), columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true)]),
                              titled: "refunds")
        let stripe = b.api("Stripe API", ["POST /v1/refunds"], at: CGPoint(x: 100, y: 500))
        let orders = b.api("orders API", ["POST /orders/{id}/refunds"])
        let endpoint = b.rows(orders)[0].id
        let context = LineContext(editor: b.editor, shape: orders, row: endpoint)
        let grammar = EngineeringAPILines.links
        @MainActor func offers(_ text: String) -> LineOffers? {
            let line = LineText(text)
            return grammar.offers(at: (text as NSString).length, in: line, reading: grammar.read(line, id: endpoint, in: context), context: context)
        }
        expectEqual(offers("")?.items.map(\.completion.label), ["writes", "reads", "calls"])
        expect(offers("wr")?.items.allSatisfy { $0.completion.chip != nil } == true, "each in its pill's color")
        let tables = try require(offers("writes ref"))
        expectEqual(tables.query, "ref")
        expectEqual(tables.items.map(\.completion.label), ["refunds"])
        expectEqual(tables.items.first?.light, PartAddress(refunds))
        expect(tables.items.first?.completion.detail.isEmpty == false, "each table says its board, the one shown too (E4 panel 1: `refunds  shop`)")
        let calls = try require(offers("calls ref"))
        expectEqual(calls.items.map(\.completion.label), ["POST /v1/refunds"], "the endpoint itself is never offered")
        expectEqual(calls.items.first?.completion.detail, "Stripe API")
        expectEqual(calls.items.first?.completion.insert, "Stripe API.POST /v1/refunds")
        expectEqual(calls.items.first?.light, PartAddress(stripe, part: b.rows(stripe)[0].id))
    },
])
