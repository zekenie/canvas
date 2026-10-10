import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import Selection
import StickyNotes
import TestKit
import Types

// Laying shapes out larger than they store (`LaidOutBox`, `LayoutBenchmarks.swift`): stretches that
// name gauges, standing in for typed notes. The first frame asks each shape's kind once and keeps the
// size, a changed gauge has them laid out again at the next frame, and a drag asks nobody. And notes
// with rows (a test provider standing in for Types'), reported.

extension Budget {
    /// What 10,000 stretches laid out by a hundred gauges add to their board's first frame, over the
    /// same board with no gauge named: each asked once, with its provider (a gauge looked up in the
    /// file, a value made of it) and its size kept. The thread's CPU, release: some 5 ms at a load
    /// average of 12 (three runs alone: 5.3, 4.8 and 4.5), three times that.
    static let laidOutFirstFrame = 15.0
    /// A gauge 10,000 stretches name, changed: the commit, the announcement and the frame after. Every
    /// shape's geometry is worked out again, as it is after any commit that changes them all (the
    /// frame after a label is changed on every stretch costs as much, reported beside it), so the
    /// frame is held to a multiple of that too (`layoutChangeOverRewrite`). Three runs alone: 47.6 (a busier
    /// moment), 28.1 and 29.0 ms at a load average of 12, three times the median.
    static let layoutChange = 90.0
    /// And how many times the frame after every stretch is rewritten the frame after the change may cost.
    static let layoutChangeOverRewrite = 2.0
    /// A drag event's input (the commit, the services hearing it) with 1,000 grown stretches dragged
    /// together, on the shipped list: what dragging that many shapes costs, grown or not (the same board
    /// with no gauge named is reported beside it and holds it too). Three runs alone: 3.6, 2.9 and 2.9
    /// ms at a load average of 12, three times the median.
    static let layoutDragInput = 9.0
}

private let viewport = CGSize(width: 1200, height: 800)

/// `count` stretches 100 × 60 in a grid, each naming one of `gauges` gauges (160 × 100, so each is
/// laid out larger than it stores) in a row above them, or none with `naming` false.
@MainActor private func stretchBoard(_ count: Int, gauges: Int, naming: Bool = true) -> (document: CanvasDocument, gauges: [ShapeID], stretches: [ShapeID]) {
    let columns = Int(Double(count).squareRoot().rounded(.up))
    let named = (0..<gauges).map { i in
        ShapeRecord(Gauge(CGRect(x: CGFloat(i) * 70, y: -200, width: 60, height: 40), width: 160, height: 100))
    }
    let stretches = (0..<count).map { i in
        ShapeRecord(Stretch(CGRect(x: CGFloat(i % columns) * 260, y: CGFloat(i / columns) * 260, width: 100, height: 60),
                            gauge: naming ? named[i % gauges].id : nil))
    }
    return (CanvasDocument(shapes: named.map(AnyShapeRecord.init) + stretches.map(AnyShapeRecord.init)), named.map(\.id), stretches.map(\.id))
}

/// The camera that fits a board of stretches into the viewport, from their stored boxes, so that
/// working it out asks for no geometry.
private func fit(_ document: CanvasDocument) -> Camera {
    let bounds = document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }
    return Camera(fitting: bounds, in: viewport, inset: 0)
}

/// Gives rows to the notes it is told of, as Types will to the notes that are instances: the same
/// extent for each, until it is changed.
@MainActor private final class BenchRows {
    var ids: Set<ShapeID> = []
    var extent = RowsExtent(minimumWidth: 320, height: 96)
}

private struct BenchRowsPlugin: CanvasPlugin {
    let rows: BenchRows
    var id: PluginID { "bench-note-rows" }
    func register(into registrar: inout PluginRegistrar) {
        let rows = rows
        registrar.layoutInput(TypeRows.extent) { record, _ in rows.ids.contains(record.id) ? rows.extent : nil }
    }
}

/// The generated board with a token ahead of every note's words, so no words were measured before in
/// this process: a board first shown measures every typed note's words.
@MainActor private func notesBoard(_ count: Int, token: String) -> CanvasDocument {
    CanvasDocument(shapes: generatedBoard(shapes: count).shapes.map { record in
        guard var note = record.typed(as: StickyNote.self) else { return record }
        note.props.text = MentionText([.text("\(token) ")] + note.props.text.runs)
        return AnyShapeRecord(note)
    })
}

@MainActor let layoutBenchmarks = Suite("Layout benchmarks", [
    test("10,000 stretches laid out by a hundred gauges add little to the first frame over the same board with no gauge named, and the second frame asks nobody") {
        let context = try bitmapContext(viewport)
        for size in sizes {
            var withGauges: [Double] = [], without: [Double] = []
            var asked = 0
            for run in 0..<5 {
                for naming in [true, false] {
                    let board = stretchBoard(size, gauges: min(100, size), naming: naming)
                    let log = StretchLog()
                    let h = try EditorHarness(plugins: [FixturesPlugin(), StretchesPlugin(log: log)], document: board.document)
                    h.editor.viewportDidResize(to: viewport)
                    h.editor.camera = fit(board.document)
                    let first = threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds
                    if naming {
                        withGauges.append(first)
                        if run == 0 {
                            asked = log.sizes.count
                            draw(h.editor, into: context, size: viewport)
                            expectEqual(log.sizes.count, asked, "the second frame asks no kind")
                            expectEqual(asked, size, "each asked once")
                        }
                    } else {
                        without.append(first)
                        expectEqual(log.provided.count, 0, "no gauge named: no provider asked")
                    }
                }
            }
            let added = withGauges.sorted()[2] - without.sorted()[2]
            report(String(format: "%6d stretches by %d gauges: the first frame %5.1f ms, %5.1f more than with no gauge named (budget %.0f)",
                          size, min(100, size), withGauges.sorted()[2], added, Budget.laidOutFirstFrame))
            if holdsToBudgets, size >= 10_000 { expect(added < Budget.laidOutFirstFrame, "laying out \(size) stretches added \(added) ms to the first frame") }
        }
    },
    test("a gauge 10,000 stretches name, changed: the commit, the announcement and the frame after fit in a frame") {
        let context = try bitmapContext(viewport)
        for size in sizes {
            let board = stretchBoard(size, gauges: 1)
            let log = StretchLog()
            let h = try EditorHarness(plugins: [FixturesPlugin(), StretchesPlugin(log: log)], document: board.document)
            // At 100% at the board's top left, as the hover and drag benchmarks are: the frame after is the
            // geometry of every shape worked out again, and the few in view drawn.
            h.editor.viewportDidResize(to: viewport)
            h.editor.camera = Camera()
            draw(h.editor, into: context, size: viewport)
            var width: CGFloat = 160
            var commits: [Double] = [], frames: [Double] = []
            for _ in 0..<7 {
                width += 10
                commits.append(threadCPUTime {
                    h.editor.transact("Gauge") { $0.update(board.gauges[0], as: Gauge.self) { $0.props.width = width } }
                }.milliseconds)
                frames.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
            }
            let commit = commits.sorted()[3], next = frames.sorted()[3], change = zip(commits, frames).map { $0 + $1 }.sorted()[3]
            expectEqual(h.editor.shapeContext.frame(of: board.stretches[0])?.width, width, "laid out again")
            // The control: every stretch rewritten (a label), and the frame after, which works out every
            // shape's geometry again as the gauge's change does.
            var rewrites: [Double] = []
            for run in 0..<7 {
                h.editor.transact("Rewrite") { transaction in
                    for id in board.stretches { transaction.update(id, as: Stretch.self) { $0.props.label = "\(run)" } }
                }
                rewrites.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
            }
            let rewrite = rewrites.sorted()[3]
            report(String(format: "%6d stretches name the gauge: the commit and the frame after %5.1f ms (budget %.0f): the commit %5.1f, the frame %5.1f; the frame after every stretch is rewritten %5.1f",
                          size, change, Budget.layoutChange, commit, next, rewrite))
            if holdsToBudgets {
                expect(change < Budget.layoutChange, "changing a gauge \(size) stretches name took \(change) ms")
                expect(next < Budget.layoutChangeOverRewrite * rewrite, "the frame after changing a gauge \(size) stretches name took \(next) ms, after rewriting them \(rewrite)")
            }
        }
    },
    test("a drag of 1,000 grown stretches asks no kind and no provider: each event's input fits its budget, and the frame after it") {
        let context = try bitmapContext(viewport)
        let count = holdsToBudgets ? 1_000 : 300
        // The shipped list, for the select tool and its keyboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // The same board with no gauge named is the control: what dragging that many shapes costs.
        var results: [(input: Double, frame: Double)] = []
        for naming in [true, false] {
            let board = stretchBoard(count, gauges: 50, naming: naming)
            let log = StretchLog()
            let registry = try Registry(plugins: shippedPlugins(pasteboard) + [StretchesPlugin(log: log)])
            let h = EditorHarness { CanvasEditor(registry: registry, document: board.document, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            h.editor.camera = fit(board.document)
            draw(h.editor, into: context, size: viewport)
            h.editor.selectedShapeIDs = board.stretches
            let grabbed = try require(h.editor.document[board.stretches[0]]?.box)
            let framed = try require(h.editor.shapeContext.frame(of: board.stretches[0]))
            expect(naming == (framed.width > grabbed.width && framed.height > grabbed.height), "grown, or not")
            let start = h.view(CGPoint(x: framed.midX, y: framed.midY))
            let asked = (log.sizes.count, log.provided.count)
            h.move(to: start)
            h.press(at: start)
            var step = 0
            let input = median(runs: 21, onThread: true) {
                step += 1
                h.drag(to: start + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
            }
            let frame = median(runs: 21, prepare: {
                step += 1
                h.drag(to: start + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
            }, onThread: true) { draw(h.editor, into: context, size: viewport) }
            h.release()
            expect(h.editor.document[board.stretches[0]]?.box?.origin != grabbed.origin, "dragged")
            expectEqual(log.sizes.count, asked.0, "no kind asked over the drag")
            expectEqual(log.provided.count, asked.1, "no provider asked over the drag")
            results.append((input, frame))
        }
        report(String(format: "%6d grown stretches dragged: an event's input %5.2f ms (budget %.0f; %5.2f with no gauge named), the frame after %5.1f ms (budget %.0f; %5.1f)",
                      count, results[0].input, Budget.layoutDragInput, results[1].input, results[0].frame, Budget.frame, results[1].frame))
        if holdsToBudgets {
            expect(results[0].input < Budget.layoutDragInput, "a drag event of \(count) grown stretches took \(results[0].input) ms")
            expect(results[0].input < 1.5 * results[1].input + Budget.dragInputSlack, "a drag event of grown stretches took \(results[0].input) ms, of the same with no gauge named \(results[1].input)")
            expect(results[0].frame < Budget.frame, "the frame after a drag event of \(count) grown stretches took \(results[0].frame) ms")
        }
    },
    test("notes with rows, through a test provider: the board first shown, and the frame after the rows of all of them change (reported)") {
        let context = try bitmapContext(viewport)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            // Every sixth note, every note (the worst case), and none (the control): each run a board of
            // its own, with words nobody has measured, zoomed to fit it, where it is skeletons and every
            // shape's geometry is worked out, the notes' with their words measured.
            var results: [(name: String, first: Double, change: Double, remeasured: Double)] = []
            for (name, every) in [("no note", 0), ("every sixth note", 6), ("every note", 1)] {
                var firsts: [Double] = [], changes: [Double] = [], remeasures: [Double] = []
                for run in 0..<5 {
                    let rows = BenchRows()
                    let document = notesBoard(size, token: "\(name) \(run) \(UUID().uuidString.prefix(8))")
                    let notes = document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id)
                    if every > 0 { rows.ids = Set(notes.enumerated().filter { $0.offset % every == 0 }.map(\.element)) }
                    let registry = try Registry(plugins: shippedPlugins(pasteboard) + [BenchRowsPlugin(rows: rows)])
                    let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
                    h.editor.viewportDidResize(to: viewport)
                    h.editor.camera = fit(document)
                    firsts.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
                    if every > 0 { expect(h.editor.shapeContext.frame(of: rows.ids.first!)?.width ?? 0 >= 320, "laid out with its rows") }
                    // A type edit reaches them all: their rows are another height (the words kept), then
                    // another width (the words measured again).
                    rows.extent = RowsExtent(minimumWidth: 320, height: 144)
                    changes.append(threadCPUTime {
                        h.editor.shapesDidChangeLayout(rows.ids)
                        draw(h.editor, into: context, size: viewport)
                    }.milliseconds)
                    rows.extent = RowsExtent(minimumWidth: 360, height: 144)
                    remeasures.append(threadCPUTime {
                        h.editor.shapesDidChangeLayout(rows.ids)
                        draw(h.editor, into: context, size: viewport)
                    }.milliseconds)
                }
                results.append((name, firsts.sorted()[2], changes.sorted()[2], remeasures.sorted()[2]))
            }
            for result in results {
                report(String(format: "%6d shapes, rows on %@: the first frame %6.1f ms (%+6.1f over no rows), the frame after their rows change %6.1f, after their width changes %6.1f (reported)",
                              size, result.name, result.first, result.first - results[0].first, result.change, result.remeasured))
            }
        }
    },
])
