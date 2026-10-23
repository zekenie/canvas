import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import JumpTo
import LanguageModels
import Mentions
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles

// Jump To's budgets: a keystroke in the palette over 10,000 shapes (one piece, the titles alone, and
// several, ranked by their paths), the catalog's build in slices, and what a commit costs with the
// plugin in the list, before the first ⌘K, with the catalog read and with it being kept. `./build.sh
// bench` holds them; `./test.sh` runs them small, in debug, and only reports.

extension Budget {
    /// A keystroke in the palette with one piece, the `@` picker's workload: the titles alone, over
    /// 10,000 shapes on the main actor (the thread's CPU).
    static let jumpToKeystroke = pickerKeystroke
    /// A keystroke with several pieces, over a file nested ten boards deep: the last piece against
    /// every title, then the shapes it matches by their paths, a container's row made once.
    static let jumpToPathKeystroke = 4.0
    /// The longest slice of reading the catalog on the main actor, whatever the file: it goes on in
    /// the next turn.
    static let jumpToSlice = 3.0
    /// What a commit costs a file with the plugin in its list, over what it costs without it, before
    /// the first ⌘K and, the catalog read, for a drag's event (a move reads nothing) and a rename (a
    /// title read): one test.
    static let jumpToUpkeep = 0.1
}

/// A palette over `file`, the shipped list, its catalog read: a view of 1000 × 700 for what's nearby.
@MainActor private func readPalette(_ file: CanvasFile) throws -> EditorHarness {
    let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
    let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
    let state = try require(h.editor.jumpTo)
    state.open()
    while !state.isReady { h.wait(1) }
    return h
}

/// A file as nested as a project: 10 subboards "Alpha n", each holding 10 "Beta n", each holding 10
/// "Gamma n", each holding notes called "Checkout n", `size` of them in all, none of the shapes alone
/// much to find: every title is a name, and every note has three named containers.
@MainActor func titledTree(notes size: Int) -> CanvasFile {
    var children: [ShapeID: CanvasDocument] = [:]
    func card(_ title: String, _ i: Int) -> AnyShapeRecord {
        var record = AnyShapeRecord(ShapeRecord(Subboard(frame: CGRect(x: CGFloat(i) * 300, y: 0, width: 240, height: 160))))
        record[TitleProperty.self] = title
        return record
    }
    var gammas: [AnyShapeRecord] = []
    var alphas: [AnyShapeRecord] = []
    for a in 0..<10 {
        let alpha = card("Alpha \(a)", a)
        alphas.append(alpha)
        var betas: [AnyShapeRecord] = []
        for b in 0..<10 {
            let beta = card("Beta \(b)", b)
            betas.append(beta)
            var inner: [AnyShapeRecord] = []
            for g in 0..<10 {
                let gamma = card("Gamma \(g)", g)
                inner.append(gamma)
                gammas.append(gamma)
            }
            children[beta.id] = CanvasDocument(shapes: inner)
        }
        children[alpha.id] = CanvasDocument(shapes: betas)
    }
    // The notes, spread over the gammas' boards.
    var next = 0
    var perGamma: [ShapeID: [AnyShapeRecord]] = [:]
    for n in 0..<size {
        var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(n % 20) * 260, y: 300 + CGFloat(n / 20) * 260, width: 200, height: 200),
                                                         text: MentionText(plain: "Note \(n)"))))
        note[TitleProperty.self] = "Checkout \(n)"
        perGamma[gammas[next % gammas.count].id, default: []].append(note)
        next += 1
    }
    for gamma in gammas { children[gamma.id] = CanvasDocument(shapes: (children[gamma.id]?.shapes ?? []) + (perGamma[gamma.id] ?? [])) }
    return CanvasFile(root: CanvasDocument(shapes: alphas), children: children)
}

/// Each query typed after what it follows (the palette told the prefix first): the slowest of them,
/// by the thread's CPU, and its query.
@MainActor private func slowest(_ h: EditorHarness, _ queries: [String]) throws -> (query: String, ms: Double) {
    let state = try require(h.editor.jumpTo)
    var worst = (query: "", ms: 0.0)
    for query in queries {
        let before = String(query.dropLast())
        let ms = median(runs: 21, prepare: { state.setQuery(before) }, onThread: true) { state.setQuery(query) }
        if ms > worst.ms { worst = (query, ms) }
    }
    return worst
}

@MainActor let jumpToBenchmarks = Suite("Jump To benchmarks", [
    test("a keystroke in the palette over a board's titles, one piece, costs what matches, not the board") {
        for size in sizes {
            let flat = try readPalette(CanvasFile(root: generatedBoard(shapes: size)))
            let one = try slowest(flat, ["p", "pl", "pla", "plan", "plan1", "pn11", "title", "recor", "paln", "zzzzq", "a", "e"])
            // The same shapes nested ten boards deep: one piece never reads the tree.
            let nested = try readPalette(generatedFile(root: 0, children: [size], depth: 10))
            let deep = try slowest(nested, ["p", "pl", "plan", "pn11", "zzzzq", "e"])
            report(String(format: "%6d shapes, Jump To, one piece: the slowest keystroke %6.3f ms (\"%@\"); ten boards deep %6.3f (\"%@\") (budget %.0f)",
                          size, one.ms, one.query, deep.ms, deep.query, Budget.jumpToKeystroke))
            if holdsToBudgets {
                expect(one.ms < Budget.jumpToKeystroke, "a keystroke in Jump To (\(one.query)) over \(size) shapes took \(one.ms) ms")
                expect(deep.ms < Budget.jumpToKeystroke, "a keystroke in Jump To (\(deep.query)) over \(size) shapes ten boards deep took \(deep.ms) ms")
            }
        }
    },
    test("a keystroke with several pieces ranks the shapes it matches by their paths, a container's row made once, in what two keystrokes' worth costs") {
        for size in sizes {
            // The generated file ten boards deep: its titles ("Plan n", "Title n", "Record n") and a chain of untitled boards.
            let nested = try readPalette(generatedFile(root: 0, children: [size], depth: 10))
            let generated = try slowest(nested, ["plan note", "p t 40", "p t 4", "plan 11", "paln 11", "title 40", "p r 1", "a e"])
            // Every shape under three named containers, each by its own title, a thousand containers in all.
            let tree = try readPalette(titledTree(notes: size))
            let named = try slowest(tree, ["alpha gamma checkout", "alpha gamma checkout 5", "a b c 7", "a g c", "al ga ch 99", "alpha 3 beta 4 checkout 1234", "a c", "x y z"])
            report(String(format: "%6d shapes, Jump To, several pieces: the slowest keystroke on the generated file ten boards deep %6.3f ms (\"%@\"); under three named containers each %6.3f (\"%@\") (budget %.0f)",
                          size, generated.ms, generated.query, named.ms, named.query, Budget.jumpToPathKeystroke))
            if holdsToBudgets {
                expect(generated.ms < Budget.jumpToPathKeystroke, "a keystroke in Jump To (\(generated.query)) over \(size) shapes ten boards deep took \(generated.ms) ms")
                expect(named.ms < Budget.jumpToPathKeystroke, "a keystroke in Jump To (\(named.query)) over \(size) shapes in named containers took \(named.ms) ms")
            }
            let state = try require(tree.editor.jumpTo)
            state.setQuery("alpha 2 gamma 3 checkout 99")
            let rows = state.rows.compactMap(\.candidate)
            expect(!rows.isEmpty, "the named containers are found")
            expect(rows.allSatisfy { $0.path.count == 3 }, "each under three containers")
        }
    },
    test("the catalog is read in slices of a few milliseconds on the main actor, whatever the file, and a pick's rows are built after") {
        for size in sizes {
            for (what, file) in [("a board", CanvasFile(root: generatedBoard(shapes: size))),
                                 ("two boards", generatedFile(root: size / 2, children: [size / 2])),
                                 ("ten boards deep", generatedFile(root: 0, children: [size], depth: 10)),
                                 ("named containers", titledTree(notes: size))] {
                let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
                let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
                let state = try require(h.editor.jumpTo)
                let wall = ContinuousClock().measure {
                    state.open()
                    while !state.isReady { h.wait(1) }
                }
                let longest = state.longestBuildSlice.milliseconds, total = state.buildTime.milliseconds
                report(String(format: "%6d shapes, %@, Jump To's catalog: %5d titled shapes read in %3d slices, the longest %6.3f ms (budget %.0f), %6.1f ms in all (reported; %6.1f by the clock)",
                              size, what, state.catalogCount, state.buildSlices, longest, Budget.jumpToSlice, total, wall.milliseconds))
                if holdsToBudgets { expect(longest < Budget.jumpToSlice, "the longest slice of Jump To's catalog of \(size) shapes (\(what)) took \(longest) ms") }
            }
        }
    },
    test("with the plugin in the list a commit costs what it did: before the first ⌘K one test, the catalog read a move reads nothing and a rename a title") {
        for size in sizes {
            let file = CanvasFile(root: generatedBoard(shapes: size))
            let with = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let without = try Registry(plugins: ShippedPlugins.plugins(model: ScriptedLanguageModel()).filter { $0.id != .jumpTo })
            let a = EditorHarness { CanvasEditor(registry: with, file: file, scheduler: $0) }
            let b = EditorHarness { CanvasEditor(registry: without, file: file, scheduler: $0) }
            let note = try require(file.root.shapes.first { $0.kind == StickyNote.kind }?.id)
            let origin = try require(file.root[note]?.box?.origin)
            @MainActor func move(_ h: EditorHarness) -> Double {
                var x: CGFloat = 0
                return median(runs: 101, onThread: true) {
                    x += 1
                    h.editor.transact { $0.moveBox(note, to: CGPoint(x: origin.x + x, y: origin.y)) }
                }
            }
            @MainActor func rename(_ h: EditorHarness) -> Double {
                var n = 0
                return median(runs: 101, onThread: true) {
                    n += 1
                    h.editor.transact("Rename") { $0.update(note) { $0[TitleProperty.self] = "Renamed \(n)" } }
                }
            }
            // Before the first ⌘K.
            let beforeMove = move(a) - move(b)
            let beforeRename = rename(a) - rename(b)
            // The catalog read.
            let state = try require(a.editor.jumpTo)
            state.open()
            while !state.isReady { a.wait(1) }
            state.close()
            #if DEBUG
            let read = state.entriesRead
            #endif
            let afterMove = move(a) - move(b)
            #if DEBUG
            expectEqual(state.entriesRead, read, "a move reads nothing")
            #endif
            let afterRename = rename(a) - rename(b)
            #if DEBUG
            expectEqual(state.entriesRead, read + 101, "a rename reads the one shape")
            #endif
            report(String(format: "%6d shapes, a commit with Jump To over without: a move before ⌘K %6.3f ms, read %6.3f; a rename before %6.3f, read %6.3f (budget %.1f)",
                          size, beforeMove, afterMove, beforeRename, afterRename, Budget.jumpToUpkeep))
            if holdsToBudgets {
                for (what, delta) in [("a move before ⌘K", beforeMove), ("a move", afterMove), ("a rename before ⌘K", beforeRename), ("a rename", afterRename)] {
                    expect(delta < Budget.jumpToUpkeep, "\(what) cost \(delta) ms more with Jump To in the list, on \(size) shapes")
                }
            }
        }
    },
])
