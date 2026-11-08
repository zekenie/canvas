import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Engineering
import Foundation
import Geometry
import LanguageModels
import ShippedTesting
import TestKit
import Titles

// The engineering kit's tables zoomed out: a bar a name and a bar a type for every row in view, in a card with its title a bar
// above it (Titles' bars). A table draws no more than a note's skeleton would; what's measured is what a board of thousands of
// them, and a few of hundreds of columns, cost a frame when many are in view, where each row is a fraction of a pixel.

extension Budget {
    /// A frame of a board of 10,000 titled tables of four columns and 20 of 300, zoomed out to fit it (10%) and at 6%, where
    /// some 4,000 of them are in view, within what a frame zoomed out may cost. Never measured before the tables: a release
    /// build did on 2026-11-07 8 ms fitted and 10 at 6%, where a row is under 2 points and its bars aren't drawn; with them it
    /// was 20 ms at 6% (some 5 µs a table in view), which is why they aren't.
    static let tablesZoomedOut = zoomedOut
}

@MainActor let tableBenchmarks = Suite("Table benchmarks", [
    test("a frame zoomed out over 10,000 titled tables, 20 of them 300 columns long, costs the cards in view, no bar a row once a row is under 2 points") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let columns = ["id uuid pk", "customer_id uuid", "status text", "placed_at timestamptz?"].compactMap { ColumnGrammar.read($0) }
        var added: [AnyShapeRecord] = []
        for index in 0..<10_000 {
            var table = ShapeRecord(DatabaseTable(frame: CGRect(x: CGFloat(index % 100) * 340, y: CGFloat(index / 100) * 220, width: 300, height: 116), columns: columns))
            table[TitleProperty.self] = "table_\(index)"
            added.append(AnyShapeRecord(table))
        }
        let long = (0..<300).map { Column(name: "column_\($0)", type: TypeRef("text")) }
        for index in 0..<20 {
            var table = ShapeRecord(DatabaseTable(frame: CGRect(x: CGFloat(index) * 340, y: -8_000, width: 300, height: 7_000), columns: long))
            table[TitleProperty.self] = "long_\(index)"
            added.append(AnyShapeRecord(table))
        }
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: added), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        var lines: [String] = [], worst = 0.0
        for (name, camera) in [("fitted", Camera(fitting: h.editor.shapeBounds, in: viewport, inset: 0)),
                               ("at 6%", camera(centering: h.editor.shapeBounds, at: 0.06, in: viewport))] {
            h.editor.camera = camera
            expect(h.editor.drawsSkeletons, "\(name): skeletons")
            draw(h.editor, into: context, size: viewport)
            let frame = median(runs: 11, onThread: true) {
                h.editor.camera.origin.x += 0.5
                draw(h.editor, into: context, size: viewport)
            }
            worst = max(worst, frame)
            lines.append(String(format: "%@ (%.1f%%) %5.1f ms", name, camera.zoom * 100, frame))
        }
        report(String(format: "10,020 titled tables zoomed out: a frame %@ (budget %.0f)", lines.joined(separator: "; "), Budget.tablesZoomedOut))
        if holdsToBudgets { expect(worst < Budget.tablesZoomedOut, "a frame zoomed out over 10,020 titled tables took \(worst) ms") }
    },
])
