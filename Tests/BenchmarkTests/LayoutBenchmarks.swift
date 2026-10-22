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
import Titles
import Types

// Laying shapes out larger than they store (`LaidOutBox`, `LayoutBenchmarks.swift`): stretches that
// name gauges, standing in for typed notes. The first frame asks each shape's kind once and keeps the
// size, a changed gauge has them laid out again at the next frame, and a drag asks nobody. And notes
// with rows, through Types: every sixth note, or every note, an instance of a type of four fields.

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
    /// What rows on every sixth note add to the first frame of the 10,000-shape board, over the same
    /// board with none typed: each typed note's words measured once, at the width its rows give it, and
    /// the provider asked for each (some 7,000 notes). Release, the thread's CPU, three runs alone at a
    /// load average of 5.5 to 7: +72, +45 and +52 ms; three times the median, about.
    static let typedBoardFirstFrame = 150.0
    /// The same with every note typed, the worst board there is: held so that measuring twice, or laying
    /// out twice, shows. +299, +283 and +277 ms (the words measured once is nearly all of it, some 40
    /// microseconds a note).
    static let allTypedBoardFirstFrame = 850.0
    /// A field added to the type every sixth note is an instance of: the commit (the index, the
    /// announcement) and the frame after, over the same edit on a board where no note is one. The words
    /// are kept. +16, +10 and +10 ms.
    static let typeEditReach = 30.0
    /// The same with every note an instance of it: +66, +63 and +51 ms.
    static let typeEditReachAll = 190.0
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
    test("notes with rows, through Types: the board first shown, and the frame after a field is added to their type") {
        let context = try bitmapContext(viewport)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            // Every sixth note, every note (the worst case), and none (the control): each run a board of
            // its own, with words nobody has measured, zoomed to fit it, where it is skeletons and every
            // shape's geometry is worked out, the notes' with their words measured.
            var results: [(name: String, first: Double, edit: Double)] = []
            for (name, every) in [("no note", 0), ("every sixth note", 6), ("every note", 1)] {
                var firsts: [Double] = [], edits: [Double] = []
                for run in 0..<5 {
                    var document = notesBoard(size, token: "\(name) \(run) \(UUID().uuidString.prefix(8))")
                    let notes = document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id)
                    let type = typeNote(fields: 4)
                    let typed = every == 0 ? [] : notes.enumerated().filter { $0.offset % every == 0 }.map(\.element)
                    let instances = Set(typed)
                    document = CanvasDocument(shapes: document.shapes.map { record in
                        guard instances.contains(record.id), var note = record.typed(as: StickyNote.self) else { return record }
                        note[IsAProperty.self] = [TypeLink(type.id)]
                        return AnyShapeRecord(note)
                    } + [type])
                    let registry = try Registry(plugins: shippedPlugins(pasteboard))
                    let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
                    h.editor.viewportDidResize(to: viewport)
                    h.editor.camera = fit(document)
                    #if DEBUG
                    let measured = NoteWordsCounts.measured
                    // The notes that have rows and words: the board's own types (a hundred or so) and their instances.
                    let withRows = document.shapes.filter { record in
                        guard let note = record.typed(as: StickyNote.self), !note.props.text.stored.isEmpty else { return false }
                        return record[TypeSchemaProperty.self] != nil || !(record[IsAProperty.self] ?? []).isEmpty
                    }.count
                    #endif
                    firsts.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
                    if let first = typed.first { expect(h.editor.shapeContext.layoutInput(TypeRows.extent, for: first) != nil, "laid out with its rows") }
                    #if DEBUG
                    expectEqual(NoteWordsCounts.measured - measured, withRows, "each note's with rows words measured once, and no other note's")
                    draw(h.editor, into: context, size: viewport)
                    expectEqual(NoteWordsCounts.measured - measured, withRows, "the second frame measures nothing")
                    #endif
                    // A field added to their type: their rows are another height, their words kept.
                    edits.append(threadCPUTime {
                        h.editor.transact("Add Field") { $0.update(type.id) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.wide(5).schema) } }
                        draw(h.editor, into: context, size: viewport)
                    }.milliseconds)
                    #if DEBUG
                    expectEqual(NoteWordsCounts.measured - measured, withRows, "the rows changed, the words were not measured again")
                    #endif
                }
                results.append((name, firsts.sorted()[2], edits.sorted()[2]))
            }
            for result in results {
                report(String(format: "%6d shapes, rows on %@: the first frame %6.1f ms (%+6.1f over no rows), the commit and frame after a field is added to their type %6.1f (%+6.1f)",
                              size, result.name, result.first, result.first - results[0].first, result.edit, result.edit - results[0].edit))
            }
            if holdsToBudgets, size >= 10_000 {
                expect(results[1].first - results[0].first < Budget.typedBoardFirstFrame, "rows on every sixth note of \(size) shapes added \(results[1].first - results[0].first) ms to the first frame")
                expect(results[2].first - results[0].first < Budget.allTypedBoardFirstFrame, "rows on every note of \(size) shapes added \(results[2].first - results[0].first) ms to the first frame")
                expect(results[1].edit - results[0].edit < Budget.typeEditReach, "a field added to a type every sixth note is an instance of took \(results[1].edit - results[0].edit) ms more")
                expect(results[2].edit - results[0].edit < Budget.typeEditReachAll, "a field added to a type every note is an instance of took \(results[2].edit - results[0].edit) ms more")
            }
        }
    },
])

/// A type note of four text fields.
@MainActor private func typeNote(fields count: Int) -> AnyShapeRecord {
    var note = ShapeRecord(StickyNote(frame: CGRect(x: -400, y: -400, width: 200, height: 200)))
    note[TypeSchemaProperty.self] = SchemaText(FieldFixtures.wide(count).schema)
    note[TitleProperty.self] = "Wide"
    return AnyShapeRecord(note)
}
