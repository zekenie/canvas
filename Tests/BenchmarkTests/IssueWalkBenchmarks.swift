import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import LanguageModels
import Mentions
import Queries
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import SwiftUI
import Validation

// The issue walk's budgets (`IssueWalk`, Validation's), on the generated board with a tenth of its notes titled past the
// schema's 80 characters, each of them a warning (so a board of 10,000 has some 500 stops): All Issues gathered (the query for
// every shape with an issue, then each one's issues read, the main actor's time in all), and a step from stop to stop (the
// shape selected, its Issues tab chosen, the stop announced), and what the walk adds to each commit while it runs. `./build.sh bench` holds them; `./test.sh` runs them small, in
// debug, and only reports.

extension Budget {
    /// All Issues gathered on the board shown, validation having read it: the main actor's thread CPU from the call that
    /// begins the walk to its first stop, the rows made and sorted in board order. Measured 1.8 ms at 1,000 shapes (34 stops)
    /// and 17.8 at 10,000 (347), release, on a busy machine (2026-10-30), the query's answer 15 ms off the main actor.
    static let issueWalkGather10k = SizedBudget(thousand: 6, tenThousand: 50)
    /// A step: the next stop's row found, its shape selected and revealed, its Issues tab chosen, VoiceOver told. Measured
    /// 0.015 to 0.02 ms at either size, a stop on the board shown (one on another board shows that board first).
    static let issueWalkStep = 0.2
    /// What a running walk adds to a commit of one note's title, over the same commit with no walk: the walk hears every commit
    /// (the shapes it changed, what its rules affect, the rows of those that are stops).
    static let issueWalkCommit = 0.3
    /// What a running walk adds to a commit that may have shifted the board order (a note added: every row's key is taken again from
    /// one snapshot, and the rows sorted again if that put them in another order), over the same commit with no walk. Measured +0.02 ms
    /// at 1,000 shapes (34 stops) and +0.08 at 10,000 (347), release, 2026-10-31: some 0.2 µs a row.
    static let issueWalkReorder = SizedBudget(thousand: 0.5, tenThousand: 1)
    /// A step with the list open over the panel (the issue walk's list, in a window, the run loop's turns that draw it included):
    /// the walk's step and the panel's update, the current board's rows and the heads of the others built and nothing else.
    /// Measured 7.7 to 8.3 ms with the list open and as much with it closed (the settle is most of it) on the board of 1,000 and
    /// of 10,000 shapes in three boards (293 stops with 141 lines, 2,953 with 176), release, 2026-10-31.
    static let issueListStep = SizedBudget(thousand: 16, tenThousand: 20)
    /// A step across a board with the list open, over a seam between two neighbouring boards of the walk, one the board of the most
    /// stops (138 of 141 lines at 1,000 shapes, 1,390 of 1,393 at 10,000, beside a board of 17 and of 173): each step folds the board it
    /// leaves and builds the rows of the one it reaches, whose table is then laid out, the run loop's turns that draw it counted. Each
    /// direction is held apart, its own median of 21, to this budget. Measured (release, 2026-10-31, three runs, load 2.5 to 3): onto the
    /// board of the most stops 27.3 to 27.8 ms at 1,000 (the slowest of 21, 31 to 33) and 47.3 to 48.4 at 10,000 (74 to 76); off it, onto
    /// the small board, 24.2 to 24.5 (25 to 26) and 108.4 to 109.9 (111), against 10 within a board: leaving a board of 1,390 rows costs
    /// more than entering it (the table drops them all), so the budget at 10,000 is the dearer direction's with half again.
    static let issueListCrossing = SizedBudget(thousand: 50, tenThousand: 170)
    /// What a commit of one note's title adds with the list open on the board of the most stops, over the same commit with the
    /// walk running and the list closed: `textRevision` makes the items of the board shown again (a head for each board and the row
    /// of each stop of it) and draws the rows in view again, the run loop's turns that draw them counted. Measured +4.8 ms at 1,000
    /// shapes (141 lines) and +8.3 at 10,000 (1,393), release, 2026-10-31, over 2 ms with the list closed: the breadth of
    /// `textRevision` (a bump for each commit that writes more than moves) with the rows themselves reading nothing observed.
    static let issueListCommit = SizedBudget(thousand: 10, tenThousand: 16)
}

/// The generated board with a title too long for the schema on one note in ten of those that have one: a warning each.
@MainActor private func warnedBoard(shapes size: Int) -> CanvasDocument { warned(generatedBoard(shapes: size)) }

/// The same for any board.
@MainActor private func warned(_ board: CanvasDocument) -> CanvasDocument {
    let long = String(repeating: "Long title ", count: 9)
    var titled = 0
    let shapes = board.shapes.map { record -> AnyShapeRecord in
        guard record.kind == StickyNote.kind, record[TitleProperty.self] != nil else { return record }
        titled += 1
        guard titled % 10 == 0 else { return record }
        var changed = record
        changed[TitleProperty.self] = long + "\(titled)"
        return changed
    }
    return CanvasDocument(shapes: shapes)
}

@MainActor let issueWalkBenchmarks = Suite("Issue walk benchmarks", [
    test("All Issues is gathered in the main actor's time of a query's answer and the rows' read; a step costs its stop's selection") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let document = warnedBoard(shapes: size)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
            _ = h.editor.validation?.results
            _ = try require(h.editor.queries).vocabulary
            let walk = try require(h.editor.issueWalk)
            var mains: [Double] = [], offs: [Double] = []
            for _ in 0..<5 {
                walk.end()
                let run = try cpu { () async -> Int in
                    walk.begin(.all, at: .first)
                    while walk.isGathering { await Task.yield() }
                    return walk.total
                }
                mains.append(run.main)
                offs.append(run.offMain)
            }
            let stops = walk.total
            expect(stops > size / 40, "\(stops) stops among \(size) shapes")
            expect(walk.isRunning, "the walk has begun")
            let gather = middle(mains), off = middle(offs)
            report(String(format: "%6d shapes, All Issues gathered (%d stops): main %6.2f ms, off it %6.2f ms (budget %.0f)", size, stops, gather, off,
                          Budget.issueWalkGather10k.at(size)))
            if holdsToBudgets { expect(gather < Budget.issueWalkGather10k.at(size), "All Issues on \(size) shapes took \(gather) ms on the main actor") }

            var steps: [Double] = []
            for _ in 0..<41 { steps.append(threadCPUTime { walk.step(forward: true) }.milliseconds) }
            let step = middle(steps)
            report(String(format: "%6d shapes, a step of the issue walk: %6.3f ms (budget %.1f)", size, step, Budget.issueWalkStep))
            if holdsToBudgets { expect(step < Budget.issueWalkStep, "a step on \(size) shapes took \(step) ms") }

            // A commit of one note's title, the walk running and not: the walk is a service on every edit for as long as it runs.
            let target = try require(document.shapes.first { $0.kind == StickyNote.kind && ($0[TitleProperty.self]?.count ?? 80) < 40 }).id
            @MainActor func edit(_ n: Int) -> Double {
                threadCPUTime { h.editor.transact("Edit") { $0.update(target) { $0[TitleProperty.self] = "Edit \(n)" } } }.milliseconds
            }
            var counter = 0
            @MainActor func commits() -> Double {
                var times: [Double] = []
                for _ in 0..<21 {
                    counter += 1
                    times.append(edit(counter))
                }
                return middle(times)
            }
            let with = commits()
            walk.end()
            let without = commits()
            report(String(format: "%6d shapes, a commit of one title with the walk running: %6.3f ms, without it %6.3f (budget +%.1f)", size, with, without,
                          Budget.issueWalkCommit))
            if holdsToBudgets { expect(with - without < Budget.issueWalkCommit, "a commit on \(size) shapes took \(with - without) ms more with the walk running") }

            // A commit that adds a note may shift the place of every row's shape in the stack: the walk takes the keys again.
            let template = try require(document.shapes.first { $0.kind == StickyNote.kind })
            @MainActor func additions() -> Double {
                var times: [Double] = []
                for _ in 0..<21 {
                    times.append(threadCPUTime { h.editor.transact("Add") { $0.insert(template.copy(as: ShapeID(), container: nil)) } }.milliseconds)
                }
                return middle(times)
            }
            walk.begin(.all, at: .first)
            while walk.isGathering { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
            let withAdd = additions()
            walk.end()
            let withoutAdd = additions()
            report(String(format: "%6d shapes, a commit that adds a note with the walk running (%d stops): %6.3f ms, without it %6.3f (budget +%.1f)", size, stops, withAdd,
                          withoutAdd, Budget.issueWalkReorder.at(size)))
            if holdsToBudgets { expect(withAdd - withoutAdd < Budget.issueWalkReorder.at(size), "an added note on \(size) shapes took \(withAdd - withoutAdd) ms more with the walk running") }
            walk.end()
        }
    },
    test("a step with the issue list open costs the rows of the board shown and the heads of the others, in a window") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            // The file's shapes in three boards, a warning on one note in ten: the stops are on all three.
            let generated = generatedFile(root: size / 2, children: [size / 4, size / 4])
            let file = CanvasFile(root: warned(generated.root), children: generated.children.mapValues(warned))
            let editor = CanvasEditor(registry: registry, file: file, scheduler: TaskScheduler())
            editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
            _ = editor.validation?.results
            _ = try require(editor.queries).vocabulary
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: {}))
            hosting.frame = CGRect(x: 0, y: 0, width: 260, height: 700)
            window.contentView = hosting
            let walk = try require(editor.issueWalk)
            walk.begin(.all, at: .first)
            window.spin { !walk.isGathering }
            expect(walk.boards.count > 1, "stops on \(walk.boards.count) boards")
            @MainActor func steps(_ n: Int) -> Double {
                var times: [Double] = []
                for _ in 0..<n { times.append(threadCPUTime { walk.step(forward: true); window.settle() }.milliseconds) }
                return middle(times)
            }
            window.settle()
            let closed = steps(21)
            walk.toggleList()
            window.spin { (hosting.descendants(NSTableView.self).first?.numberOfRows ?? 0) > 0 }
            window.settle()
            let table = try require(hosting.descendants(NSTableView.self).first)
            let current = walk.boards.first { $0.board == walk.currentRow?.board }
            expectEqual(table.numberOfRows, walk.boards.count + (current?.rows.count ?? 0), "the heads and the rows of the board shown, no more")
            let open = steps(21)
            expect(table.numberOfRows <= walk.boards.count + (walk.boards.map(\.rows.count).max() ?? 0), "still only one board's rows and the heads: \(table.numberOfRows) lines")
            report(String(format: "%6d shapes, %d stops on %d boards, a step with the list closed: %6.3f ms, open (%d lines): %6.3f ms (budget %.0f)", size,
                          walk.total, walk.boards.count, closed, table.numberOfRows, open, Budget.issueListStep.at(size)))
            if holdsToBudgets { expect(open < Budget.issueListStep.at(size), "a step with the list open on \(size) shapes took \(open) ms") }

            // Across a board: a seam between two boards that are next to each other in the walk, one of them the board of the most stops.
            // Stepping forward over it enters the board after the seam and stepping back the board before it; each step folds the board
            // it leaves (the person unfolded none) and builds the rows of the one it reaches, so the file's boards are never all built,
            // whatever the walk has gone through. Each direction has its own samples and its own median, held apart.
            let biggest = try require(walk.boards.indices.max { walk.boards[$0].rows.count < walk.boards[$1].rows.count })
            let after = max(biggest, 1)
            let before = walk.boards[after - 1], reached = walk.boards[after]
            var guardSteps = 0
            let seam = walk.rows[try require(reached.firstOpen) - 1].shape
            while walk.currentRow?.shape != seam, guardSteps < walk.total + 2 {
                walk.step(forward: true)
                guardSteps += 1
            }
            window.settle()
            expect(walk.currentRow?.board == before.board, "the walk is at the last stop before the seam")
            var forward: [Double] = [], back: [Double] = []
            var lineCounts: [Int] = []
            for index in 0..<42 {
                let ahead = index % 2 == 0
                let time = threadCPUTime { walk.step(forward: ahead); window.settle() }.milliseconds
                if ahead { forward.append(time) } else { back.append(time) }
                expectEqual(walk.currentRow?.board, ahead ? reached.board : before.board, "the step crossed the seam")
                let shown = walk.boards.first { $0.board == walk.currentRow?.board }
                expectEqual(table.numberOfRows, walk.boards.count + (shown?.rows.count ?? 0), "after a step across a board: its heads and the rows of the board reached, no more")
                lineCounts.append(table.numberOfRows)
            }
            let into = middle(forward), out = middle(back), budget = Budget.issueListCrossing.at(size)
            report(String(format: "%6d shapes, a step across a board with the list open (%d to %d lines): onto the %d stops after the seam %6.3f ms (the slowest %6.3f), onto the %d before it %6.3f ms (%6.3f), against %6.3f within a board (budget %.0f each)", size,
                          lineCounts.min() ?? 0, lineCounts.max() ?? 0, reached.rows.count, into, forward.max() ?? 0, before.rows.count, out, back.max() ?? 0, open, budget))
            if holdsToBudgets {
                expect(into < budget, "a step onto a board of \(reached.rows.count) stops with the list open on \(size) shapes took \(into) ms")
                expect(out < budget, "a step onto a board of \(before.rows.count) stops with the list open on \(size) shapes took \(out) ms")
            }
            walk.end()
        }
    },
    test("a commit with the issue list open makes the items of the board shown again and draws the rows in view, in a window") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let generated = generatedFile(root: size / 2, children: [size / 4, size / 4])
            let file = CanvasFile(root: warned(generated.root), children: generated.children.mapValues(warned))
            let editor = CanvasEditor(registry: registry, file: file, scheduler: TaskScheduler())
            editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
            _ = editor.validation?.results
            _ = try require(editor.queries).vocabulary
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: {}))
            hosting.frame = CGRect(x: 0, y: 0, width: 260, height: 700)
            window.contentView = hosting
            let walk = try require(editor.issueWalk)
            walk.begin(.all, at: .first)
            window.spin { !walk.isGathering }
            // The walk at a stop of the board with the most stops: its items are the most the list makes again.
            let biggest = try require(walk.boards.max { $0.rows.count < $1.rows.count })
            walk.begin(.all, at: .shape(walk.rows[try require(biggest.firstOpen)].shape))
            window.spin { !walk.isGathering }
            window.settle()
            // A note of the board the current stop is on, with a title of its own that no rule flags.
            let target = try require(editor.document.shapes.first { $0.kind == StickyNote.kind && ($0[TitleProperty.self]?.count ?? 80) < 40 }).id
            var counter = 0
            @MainActor func commits() -> Double {
                var times: [Double] = []
                for _ in 0..<21 {
                    counter += 1
                    let n = counter
                    times.append(threadCPUTime { editor.transact("Edit") { $0.update(target) { $0[TitleProperty.self] = "Edit \(n)" } }; window.settle() }.milliseconds)
                }
                return middle(times)
            }
            let closed = commits()
            walk.toggleList()
            let current = walk.boards.first { $0.board == walk.currentRow?.board }
            let expected = walk.boards.count + (current?.rows.count ?? 0)
            window.spin { hosting.descendants(NSTableView.self).first?.numberOfRows == expected }
            window.settle()
            let table = try require(hosting.descendants(NSTableView.self).first)
            expectEqual(table.numberOfRows, expected, "the heads and the rows of the board shown")
            let lines = table.numberOfRows
            let open = commits()
            expectEqual(table.numberOfRows, lines, "a commit of a title changes no line")
            report(String(format: "%6d shapes, %d stops, a commit of one title with the walk running: list closed %6.3f ms, open (%d lines) %6.3f (budget +%.0f)", size,
                          walk.total, closed, lines, open, Budget.issueListCommit.at(size)))
            if holdsToBudgets { expect(open - closed < Budget.issueListCommit.at(size), "a commit on \(size) shapes took \(open - closed) ms more with the list open") }
            walk.end()
        }
    },
])
