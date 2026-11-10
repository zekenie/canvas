import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import DetailPanel
import Engineering
import LineRows
import Neighbors
import Palette
import Selection
import TestKit
import Titles

// A row of the kit's as the panel's subject (K15, E6 panel 1): an endpoint's Endpoint tab and a column's Column tab hold what their
// cards hold, a path prefix has none; and the kit's lights, a row's alone, each in its relation's tint, written from the channels'
// edge type ids. What a selected row's Connections tab lists, through the app, is CompositionTests' (`rowPanelShippedTests`).

@MainActor let rowPanelTests = Suite("A row's panel in the kit", [
    test("the kit's lights serve rows alone: Calls It, Writes and Reads for an endpoint, Keys To and Keyed By for a column") {
        let registry = try Registry(plugins: kitPlugins() + [NeighborsPlugin(), EngineeringLightsPlugin()])
        let lights = registry.neighborLights
        expectEqual(lights.map(\.title), ["Calls It", "Writes", "Reads", "Keys To", "Keyed By"])
        expect(lights.allSatisfy { $0.serves == .rows }, "a row's alone: hovering asks none of them")
        let row = "#S::part(R)"
        expectEqual(lights.map { $0.query(row) }, [":edge-to(#S::part(R), calls)", ":edge-from(#S::part(R), writes)", ":edge-from(#S::part(R), reads)",
                                                  ":edge-from(#S::part(R), foreign-key)", ":edge-to(#S::part(R), foreign-key)"])
        expectEqual(lights.map(\.color), [NSColor(KitStyle.callsTint), NSColor(KitStyle.writesTint), NSColor(KitStyle.readsTint),
                                          NSColor(KitStyle.linkBlue), NSColor(KitStyle.linkBlue)])
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .engineeringLights)) {
            _ = try Registry(plugins: kitPlugins() + [EngineeringLightsPlugin()])
        }
    },
    test("an endpoint's Endpoint tab holds what its card does, a path prefix has none; a column's Column tab, its card's lines") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "POST /{id}/refunds (NewRefund) → 201 Refund"])
        let rows = b.rows(api)
        let state = try require(b.editor.detailPanel)
        let record = try require(b.editor.document[api])
        let endpoint = try require(state.rowLayout(for: record, part: rows[1].id))
        expectEqual(endpoint.tabs.map(\.title), ["Endpoint"])
        expectEqual(endpoint.header(as: DetailRowHeader.self)?.title, "/orders/{id}/refunds", "the chip's word apart from its path")
        let card = try require(b.editor.lineRowCard(of: PartAddress(api, part: rows[1].id)))
        expectEqual(card.name, "POST /orders/{id}/refunds")
        expectEqual(card.lines.map(\.label), ["name", "summary", "auth", "{id}", "body", "responses", "method", "deprecated", "relations"])
        expectEqual(card.lines.first { $0.label == "method" }?.value, "POST", "the method line K16 added to the card, which the tab shows as the card does")
        expectEqual(card.lines.first { $0.label == "body" }?.value, "→ NewRefund", "as the card prints it")
        expectEqual(card.lines.first { $0.label == "responses" }?.value, "201 → Refund")
        expectEqual(card.lines.first { $0.label == "deprecated" }?.value, "no")
        expect(state.rowLayout(for: record, part: rows[0].id)?.tabs.contains { $0.title == "Endpoint" } != true, "a path prefix has no Endpoint tab")
        expectEqual(b.editor.lineRowCard(of: PartAddress(api, part: rows[0].id)), nil)

        let table = b.h.add(orders(), titled: "orders")
        let columns = try require(b.editor.document[table]?.typed(as: DatabaseTable.self)).props.columns
        let column = try require(state.rowLayout(for: try require(b.editor.document[table]), part: columns[1].id))
        expectEqual(column.tabs.map(\.title), ["Column"])
        let lines = try require(b.editor.lineRowCard(of: PartAddress(table, part: columns[1].id))).lines
        expectEqual(lines.first { $0.label == "type" }?.value, "uuid")
        expectEqual(lines.first { $0.label == "unique" }?.value, "yes")
    },
    test("a row selected as an item, or edited with the caret on it, is the panel's subject") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /health", "POST /orders"])
        let rows = b.rows(api)
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems([AnyHashable(rows[1].id)], of: api)
        expectEqual(b.editor.detailRow, PartAddress(api, part: rows[1].id))
        b.begin(api)
        b.view?.go(to: .row(rows[0].id))
        b.window.settle()
        expectEqual(b.editor.editingPart, rows[0].id, "the caret's row")
        expectEqual(b.editor.detailRow, PartAddress(api, part: rows[0].id))
        b.view?.go(to: .title)
        b.window.settle()
        expectEqual(b.editor.editingPart, nil, "the title is no row")
        b.editor.endEditing()
        expectEqual(b.editor.editingPart, nil)
    },
])
