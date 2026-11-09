import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Engineering
import Foundation
import Geometry
import LanguageModels
import LineRows
import ShippedTesting
import TestKit
import Titles

// Sixty endpoints (K17): a group of 60 endpoints, each writing one table, closed (its arrows bundled under one lead, the bundles
// worked out for the API and the table and the 60 arrows laid out again) and opened again, over a board of 4,000 shapes; and a
// board of 200 APIs of 30 endpoints each, five groups of six, drawn at 100% and 30% (each API's rows in view only; zoomed out a
// bar a row, the methods' bars one fill a color).

extension Budget {
    /// Closing a group of 60 endpoints whose arrows all write one table, and laying the 60 out again: the plan's, 5 ms. Never
    /// measured before bundles.
    static let bundleFold = 5.0
    /// A frame of 200 thirty-endpoint APIs at 100% and at 30%: a frame, as any. Never measured before.
    static let apiFrame = frame
}

/// An API of `groups` groups of `each` endpoints at `origin`, a header before each.
@MainActor func groupedAPI(at origin: CGPoint, groups: Int, each: Int, title: String) -> ShapeRecord<API> {
    let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    var rows: [APIRow] = []
    for group in 0..<groups {
        rows.append(.header(PathHeader(prefix: "/group_\(group)")))
        for index in 0..<each { rows.append(.endpoint(Endpoint(method: methods[index % methods.count], path: "/{id}/item_\(index)"))) }
    }
    var api = ShapeRecord(API(frame: CGRect(origin: origin, size: CGSize(width: 360, height: 0)), endpoints: rows))
    // Laid out from its rows (its height its rows'), whatever it stores.
    api.props.frame.size.height = KitStyle.height(rows: rows.count)
    api[TitleProperty.self] = title
    return api
}

@MainActor let bundleBenchmarks = Suite("Bundle benchmarks", [
    test("bundleFold: closing a group of 60 endpoints that each write one table bundles the 60 arrows and lays them out again, within 5 ms") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let api = groupedAPI(at: CGPoint(x: -3000, y: -3000), groups: 1, each: 60, title: "big API")
        var table = ShapeRecord(DatabaseTable(frame: CGRect(x: -2400, y: -3000, width: 300, height: KitStyle.height(rows: 3)),
                                              columns: (0..<3).map { Column(name: "column_\($0)", type: TypeRef("text"), primaryKey: $0 == 0) }))
        table[TitleProperty.self] = "orders"
        let arrows: [AnyShapeRecord] = api.props.endpoints.compactMap(\.endpoint).map { endpoint in
            var arrow = ShapeRecord(Arrow(start: .bound(ArrowBinding(shapeID: api.id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: endpoint.id)),
                                          end: .bound(ArrowBinding(shapeID: table.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))))
            arrow[ChannelProperty.self] = Writes.id
            return AnyShapeRecord(arrow)
        }
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: rowsBoard(4_000) + [AnyShapeRecord(api), AnyShapeRecord(table)] + arrows), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        h.editor.camera = camera(centering: CGRect(x: -3000, y: -3000, width: 1000, height: 600), at: 1, in: viewport)
        draw(h.editor, into: context, size: viewport)
        let folds = try require(h.editor.rowFolds)
        let header = try require(api.props.endpoints.first?.id)
        @MainActor func laidOut() { for arrow in arrows { _ = h.editor.shapeContext.geometry(of: arrow.id) } }
        var closing = Double.infinity, opening = Double.infinity
        for _ in 0..<measuredRuns(9) {
            closing = min(closing, threadCPUTime { folds.setClosed(true, header: header, of: api.id); laidOut() }.milliseconds)
            let hidden = arrows.filter { h.editor.shapeContext.geometry(of: $0.id)?.isHidden == true }.count
            expectEqual(hidden, 59, "the group's arrows drawn as one")
            opening = min(opening, threadCPUTime { folds.setClosed(false, header: header, of: api.id); laidOut() }.milliseconds)
        }
        report(String(format: "a group of 60 endpoints writing one table, over 4,000 shapes: closed and its 60 arrows bundled and laid out %.2f ms, opened %.2f ms (budget %.0f)",
                      closing, opening, Budget.bundleFold))
        if holdsToBudgets {
            expect(closing < Budget.bundleFold, "closing a 60-arrow group took \(closing) ms")
            expect(opening < Budget.bundleFold, "opening a 60-arrow group took \(opening) ms")
        }
    },
    test("apiFrame: a frame of 200 APIs of 30 endpoints, five groups of six, at 100% and 30%, within a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let apis = (0..<200).map { index in
            AnyShapeRecord(groupedAPI(at: CGPoint(x: CGFloat(index % 20) * 420, y: CGFloat(index / 20) * 960), groups: 5, each: 6, title: "api_\(index)"))
        }
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: apis), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        var lines: [String] = [], worst = 0.0
        for zoom in [1.0, 0.3] {
            h.editor.camera = camera(centering: CGRect(x: 0, y: 0, width: 20 * 420, height: 10 * 960), at: zoom, in: viewport)
            draw(h.editor, into: context, size: viewport)
            let frame = median(runs: 11, onThread: true) {
                h.editor.camera.origin.x += 0.5
                draw(h.editor, into: context, size: viewport)
            }
            worst = max(worst, frame)
            lines.append(String(format: "%.0f%% %5.1f ms", zoom * 100, frame))
        }
        report(String(format: "200 thirty-endpoint APIs: a frame %@ (budget %.0f)", lines.joined(separator: "; "), Budget.apiFrame))
        if holdsToBudgets { expect(worst < Budget.apiFrame, "a frame of 200 APIs took \(worst) ms") }
    },
])
