import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import ShippedTesting
import StickyNotes
import TestKit

// Finding the shapes in a rect and under a point (`editor.paintOrder(in:)`, `editor.shape(at:where:)`: what drawing, every
// overlay and every hover go by) costs the cells they reach and the shapes found there, not the board's shapes, and a
// commit that adds a note on top of the stack puts it on the end of the paint list instead of building the list again. On
// the generated board (`generatedBoard`), at the sizes the benchmarks run at (`BENCH_SIZES` runs others, reporting only).

extension Budget {
    /// What the search of a 10,000-shape board costs over a 1,000-shape board's, as many times: the cells a view reaches
    /// and what's in them are the same however many shapes lie beyond them (a pass over every extent costs ten times).
    static let searchGrowth = 3.0
    /// And more, in milliseconds, for a search too short to hold to a ratio (a few microseconds of the thread's CPU).
    static let searchSlack = 0.01
    /// The first search after a commit that added a note on top of the stack: its extent worked out and filed, not the
    /// paint list built again, in milliseconds (building it, and the grid, costs some 4 at 10,000).
    static let searchAfterAdd = 0.25
}

@MainActor let spatialBenchmarks = Suite("Spatial index benchmarks", [
    test("the shapes in a view's rect and under a point are found in the cells they reach, whatever the board holds; a note added on top joins the paint list") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        var searches: [(size: Int, rect: Double, point: Double)] = []
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let editor = h.editor
            // The board's bounds build the paint list (its geometries worked out): the first search after that makes the grid.
            let middle = editor.shapeBounds
            // A view's worth of rect, 1200 × 800 world units, in the middle of the board, moved a hair each time so no call repeats
            // the one before (the camera at 100%).
            let rect = { (step: Int) in
                CGRect(x: middle.midX - 600 + CGFloat(step % 17), y: middle.midY - 400 + CGFloat(step % 13), width: 1200, height: 800)
            }
            let first = threadCPUTime { _ = editor.paintOrder(in: rect(0)) }.milliseconds
            var found = 0
            var step = 0
            let view = median(runs: 101, onThread: true) {
                step += 1
                found = editor.paintOrder(in: rect(step)).count
            }
            // Points over shapes and between them.
            let point = median(runs: 101, onThread: true) {
                step += 1
                _ = editor.shape(at: CGPoint(x: middle.midX + CGFloat(step * 37 % 400), y: middle.midY + CGFloat(step * 53 % 300)))
            }
            searches.append((size, view, point))
            // A note added on top: the first search after it works out its extent and files it.
            let afterAdd = median(runs: 21, prepare: {
                h.editor.add(StickyNote(frame: CGRect(x: middle.midX + CGFloat(step % 29), y: middle.midY + 2_000, width: 160, height: 120), text: "Added"))
            }, onThread: true) {
                step += 1
                _ = editor.paintOrder(in: rect(step))
            }
            // And after a deletion, which builds the list again, and the grid: reported.
            let afterDelete = median(runs: 5, prepare: {
                let added = editor.add(StickyNote(frame: CGRect(x: middle.midX, y: middle.midY + 3_000, width: 160, height: 120), text: "Gone"))
                _ = editor.paintOrder(in: rect(0))
                editor.transact("Delete") { $0.delete([added]) }
            }, onThread: true) {
                step += 1
                _ = editor.paintOrder(in: rect(step))
            }
            report(String(format: "%6d shapes: a view's rect (%d found) %.3f ms, a point %.3f ms; the first search, making the grid, %.1f ms; the first after adding a note %.3f ms (budget %.2f), after deleting one, building them again, %.1f ms",
                          size, found, view, point, first, afterAdd, Budget.searchAfterAdd, afterDelete))
            if holdsToBudgets { expect(afterAdd < Budget.searchAfterAdd, "the first search after adding a note, over \(size) shapes, took \(afterAdd) ms") }
        }
        if holdsToBudgets, let small = searches.first, let large = searches.last, small.size < large.size {
            expect(large.rect < small.rect * Budget.searchGrowth + Budget.searchSlack,
                   "a view's rect over \(large.size) shapes took \(large.rect) ms, over \(small.size) \(small.rect)")
            expect(large.point < small.point * Budget.searchGrowth + Budget.searchSlack,
                   "a point over \(large.size) shapes took \(large.point) ms, over \(small.size) \(small.point)")
        }
    },
])
