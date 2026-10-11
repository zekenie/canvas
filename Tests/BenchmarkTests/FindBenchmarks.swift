import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import Find
import Geometry
import Mentions
import StickyNotes
import TestKit
import Titles
import Types

// Find's budgets, on the generated boards: a keystroke (what it costs the main actor, and the search
// off it), the index's first build (its longest slice of the main actor), what Find costs a commit
// before the first ⌘F and a drag event with Find open (against the shipped list without Find), the
// first frame after a keystroke with hundreds of hits in view, and a frame zoomed out to 10% with
// every note a hit. Main-actor budgets are the thread's CPU (`cpu`, `threadCPUTime`); the search's
// is every other thread's while it runs (`cpu`). `./build.sh bench` holds them; `./test.sh` runs
// them small, in debug, and only reports.

extension Budget {
    /// A keystroke in Find's field, on the main actor: the query folded and handed off, the answer
    /// taken (its places and counts worked out off it) and the current hit picked.
    static let findKeystrokeMain = 0.5
    /// And the search off it: every text of the scope matched, ordered, counted.
    static let findKeystrokeOffMain = 10.0
    /// The index's build on the first ⌘F: each slice of the main actor (2 ms, `FindStyle.buildSlice`,
    /// and the shape that crosses it). The whole build is reported.
    static let findIndexSlice = 3.0
    /// What Find costs a commit before the first ⌘F, and a drag event with Find open, over the
    /// shipped list without it: a revision noted; nothing for a move.
    static let findUpkeep = 0.01
    /// A frame at 10% with every note a hit, the whole of it.
    static let findFrame = frame
    /// What Find adds to the first frame after a keystroke with some 500 hits in view: its layouts,
    /// within `FindStyle.layoutBudget` (2 ms), the rest tinted meanwhile, and its marks. At 36%, just
    /// above where shapes are skeletons, which is what puts that many hits in full in view, the
    /// generated board's frame alone takes more than 16 ms (reported, as the frame benchmarks report
    /// it), so the frame is reported and what Find adds is held. (The plan held the whole frame to
    /// 16 ms, which the board without Find already misses there.)
    static let findFrameAdded = 5.0
}

/// The shipped list without Find and what contributes to it.
@MainActor func pluginsWithoutFind(_ pasteboard: NSPasteboard) -> [any CanvasPlugin] {
    shippedPlugins(pasteboard).filter { ![PluginID.findInBoards, .findPanel, .boardFind, .titleFind, .mentionFind, .fieldFind].contains($0.id) }
}

/// Opens Find on a harness and builds its index to the end, a scheduler turn a slice.
@MainActor func openFind(_ h: EditorHarness) throws -> FindState {
    let find = try require(h.editor.find)
    find.open()
    while find.isIndexing { h.wait(0) }
    return find
}

@MainActor let findBenchmarks = Suite("Find benchmarks", [
    test("the index builds in slices of the main actor on the first ⌘F") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let h = EditorHarness { CanvasEditor(registry: registry, document: generatedBoard(shapes: size), scheduler: $0) }
            let find = try openFind(h)
            let slices = find.indexSlices
            report(String(format: "%6d shapes, Find's index: %d shapes read in %d slices, %6.2f ms in all, the longest %5.2f ms (budget %.0f)",
                          size, find.indexedShapes, slices.count, slices.total.milliseconds, slices.longest.milliseconds, Budget.findIndexSlice))
            if holdsToBudgets { expect(slices.longest.milliseconds < Budget.findIndexSlice, "a slice of Find's index on \(size) shapes took \(slices.longest.milliseconds) ms") }
        }
    },
    test("a keystroke costs the main actor a fold and a handover, and the search runs off it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let h = EditorHarness { CanvasEditor(registry: registry, document: generatedBoard(shapes: size), scheduler: $0) }
            h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
            let find = try openFind(h)
            var lines: [String] = []
            // Many hits ("n"), a phrase, a typo that hits every note, and nothing, which tries a typo
            // at every word.
            for query in ["n", "note 5", "somthing", "zzzzq"] {
                var mains: [Double] = [], offs: [Double] = []
                for _ in 0..<9 {
                    find.query = ""
                    let run = try cpu { () async -> Int in
                        find.query = query
                        await find.settled()
                        return find.total
                    }
                    mains.append(run.main)
                    offs.append(run.offMain)
                }
                let main = middle(mains), off = middle(offs)
                lines.append(String(format: "“%@” %d hits in %d shapes: main %5.3f ms, off %5.2f", query, find.total, find.results.count, main, off))
                if holdsToBudgets {
                    expect(main < Budget.findKeystrokeMain, "“\(query)” on \(size) shapes took \(main) ms on the main actor")
                    expect(off < Budget.findKeystrokeOffMain, "“\(query)” on \(size) shapes took \(off) ms off it")
                }
            }
            report(String(format: "%6d shapes, a keystroke in Find (budgets: main %.1f, off %.0f): ", size, Budget.findKeystrokeMain,
                          Budget.findKeystrokeOffMain) + lines.joined(separator: "; "))
        }
    },
    test("Find costs a commit nothing before the first ⌘F, and a drag event nothing while it's open") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let shipped = try Registry(plugins: shippedPlugins(pasteboard)), without = try Registry(plugins: pluginsWithoutFind(pasteboard))
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            let with = EditorHarness { CanvasEditor(registry: shipped, document: document, scheduler: $0) }
            let alone = EditorHarness { CanvasEditor(registry: without, document: document, scheduler: $0) }
            // Before ⌘F: a commit adding a note on each, in turn.
            var withCommits: [Double] = [], aloneCommits: [Double] = []
            for i in 0..<41 {
                let frame = CGRect(x: -400, y: CGFloat(i) * 300, width: 200, height: 200)
                withCommits.append(threadCPUTime { _ = with.add(StickyNote(frame: frame, text: MentionText(plain: "Added \(i)"))) }.milliseconds)
                aloneCommits.append(threadCPUTime { _ = alone.add(StickyNote(frame: frame, text: MentionText(plain: "Added \(i)"))) }.milliseconds)
            }
            // Open, searching, then a drag.
            let find = try openFind(with)
            find.query = "note"
            _ = try awaitResult(timeout: 60) { await find.settled() }
            with.press(at: center)
            alone.press(at: center)
            var withDrags: [Double] = [], aloneDrags: [Double] = []
            for step in 1...201 {
                let to = center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2)
                withDrags.append(threadCPUTime { with.drag(to: to) }.milliseconds)
                aloneDrags.append(threadCPUTime { alone.drag(to: to) }.milliseconds)
            }
            with.release()
            alone.release()
            #if DEBUG
            expectEqual(find.shapesPatched, 0, "a drag patches nothing")
            #endif
            let commit = middle(withCommits) - middle(aloneCommits), drag = middle(withDrags) - middle(aloneDrags)
            report(String(format: "%6d shapes, what Find adds: a commit before ⌘F %+6.4f ms (of %6.4f), a drag event while it's open %+6.4f ms (of %6.4f) (budget %.2f)",
                          size, commit, middle(withCommits), drag, middle(withDrags), Budget.findUpkeep))
            if holdsToBudgets {
                expect(commit < Budget.findUpkeep, "a commit on \(size) shapes before ⌘F cost \(commit) ms more with Find")
                expect(drag < Budget.findUpkeep, "a drag event on \(size) shapes with Find open cost \(drag) ms more")
            }
        }
    },
    test("the first frame after a keystroke, hundreds of hits in view, and a frame at 10% with every note a hit") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let viewport = CGSize(width: 1600, height: 1000)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            // Just above where shapes are skeletons: as many in full as a frame shows.
            h.editor.camera = Camera(origin: CGPoint(x: 0, y: 0), zoom: 0.36)
            draw(h.editor, into: context, size: viewport)
            draw(h.editor, into: context, size: viewport)
            let plain = median(runs: 5, onThread: true) { draw(h.editor, into: context, size: viewport) }
            let find = try openFind(h)
            var firsts: [Double] = [], frames: [Int] = [], inView = 0
            for (i, query) in ["n", "no", "not", "note", "o"].enumerated() {
                find.query = query
                _ = try awaitResult(timeout: 60) { await find.settled() }
                let visible = h.editor.camera.toWorld(CGRect(origin: .zero, size: viewport))
                if i == 0 {
                    inView = find.results.filter { find.hasHits($0.id) && (h.editor.shapeContext.bounds(of: [$0.id])?.intersects(visible) ?? false) }
                        .reduce(0) { $0 + $1.hitCount }
                }
                firsts.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
                // The frames it asks for, until every shape in view is laid out.
                var asked = 1
                while find.awaitsFrame, asked < 50 {
                    h.wait(0)
                    draw(h.editor, into: context, size: viewport)
                    asked += 1
                }
                frames.append(asked)
            }
            let laidOut = median(runs: 5, onThread: true) { draw(h.editor, into: context, size: viewport) }
            let first = middle(firsts), worst = firsts.max() ?? 0
            report(String(format: "%6d shapes, a frame at 36%% with %d hits of “n” in view: without Find %5.2f ms; the first after each of five keystrokes %5.2f (the median; %+5.2f, budget %.0f more), at most %5.2f, then %d frames at most to lay them all out, and each after %5.2f",
                          size, inView, plain, first, first - plain, Budget.findFrameAdded, worst, frames.max() ?? 0, laidOut))
            if holdsToBudgets {
                expect(first - plain < Budget.findFrameAdded, "the first frame after a keystroke on \(size) shapes took \(first) ms, \(plain) without Find")
            }

            // Zoomed out as far as the board needs, every note a hit.
            find.query = "note"
            _ = try awaitResult(timeout: 60) { await find.settled() }
            h.editor.camera = camera(centering: h.editor.shapeBounds, at: 0.1, in: viewport)
            draw(h.editor, into: context, size: viewport)
            let lit = median(runs: 5, onThread: true) { draw(h.editor, into: context, size: viewport) }
            find.close()
            draw(h.editor, into: context, size: viewport)
            let closed = median(runs: 5, onThread: true) { draw(h.editor, into: context, size: viewport) }
            report(String(format: "%6d shapes, a frame at 10%% with every note a hit (%d shapes, %d hits): %5.2f ms (budget %.0f); with Find closed %5.2f",
                          size, find.results.count, find.total, lit, Budget.findFrame, closed))
            if holdsToBudgets { expect(lit < Budget.findFrame, "a frame at 10% on \(size) shapes, every note a hit, took \(lit) ms") }
        }
    },
])
