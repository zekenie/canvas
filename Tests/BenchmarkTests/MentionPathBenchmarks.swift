import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import ShippedTesting
import TestKit

// The `@` picker's budget for a query of several words, which also finds a shape by its path: a keystroke over 10,000
// shapes under named containers. `./build.sh bench` holds it; `./test.sh` runs it small, in debug, and only reports.

extension Budget {
    /// A keystroke in the `@` picker with several words, over 10,000 notes each under three named containers (a thousand of
    /// them): the last word against every name in the same two passes as a word alone, then the shapes it matches scored by
    /// their paths, a container's row made once and a shape costing one match of each group of its name; the thread's CPU.
    /// The design's proposal, run alone on 2026-10-22 (three runs): some 3.4 to 3.8 ms at 10,000 ("alpha gamma checkout", which
    /// matches every note by its last word, costs the most; 1.8 to 2 at 1,000), over a word alone's `pickerKeystroke` (2) for
    /// what Jump To's several pieces cost over its one (`jumpToPathKeystroke`, some 3.3 against 4) and the picker's adjustments
    /// (a pick's bonus, nearness) after. The first query of several words reads what each shape is inside (Topology's
    /// `parent(of:)`, some 1.3 µs, 12 ms for 10,000 shapes) and keeps it in the catalog's entries, so it is reported, not held.
    static let pickerPathKeystroke = 5.0
}

@MainActor let mentionPathBenchmarks = Suite("@ picker benchmarks: paths", [
    test("a keystroke of several words in the @ picker finds the shapes by their paths, costs what the last word matches and the containers it passes through, not the board") {
        for size in sizes {
            let file = titledTree(notes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let editor = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
            let mentions = try require(editor.mentions)
            let owner = try require(editor.document.shapes.first?.id)
            let picker = MentionPicker(at: 0, mentions: mentions, scope: AnyMentionable.self, owner: owner)
            // The first query of several words reads what each shape the last word matches is inside (a commit that changes a shape
            // reads it again): once, and reported, not held.
            let first = "@a c" as NSString
            let cold = threadCPUTime { _ = picker.read(first, selection: NSRange(location: first.length, length: 0), isEdit: true) }.milliseconds
            // "alpha gamma checkout" matches every note's title by its last word, the most any query does; the others are
            // shorter pieces, a query that finds few, and one that finds none (the typo pass).
            var worst = (query: "", ms: 0.0)
            for query in ["alpha gamma checkout", "alpha gamma checkout 5", "a b c 7", "a g c", "al ga ch 99", "alpha 3 beta 4 checkout 1234", "a c", "x y z",
                          "gamma 3 check", "zzzz checkout"] {
                let typed = "@" + query as NSString, before = "@" + query.dropLast() as NSString
                let ms = median(runs: 21, prepare: {
                    _ = picker.read(before, selection: NSRange(location: before.length, length: 0), isEdit: true)
                }, onThread: true) {
                    _ = picker.read(typed, selection: NSRange(location: typed.length, length: 0), isEdit: true)
                }
                if ms > worst.ms { worst = (query, ms) }
            }
            // The path matches are the rows: the notes under Alpha 2 and Gamma 3 called Checkout 99.
            let last = "@alpha 2 gamma 3 checkout 99" as NSString
            _ = picker.read(last, selection: NSRange(location: last.length, length: 0), isEdit: true)
            let found = picker.rows.compactMap(\.candidate)
            expect(!found.isEmpty, "found by their containers")
            expect(found.allSatisfy { $0.place?.text.contains(" › ") == true }, "each says its path: \(found.map { $0.place?.text ?? "none" })")
            report(String(format: "%6d shapes, the @ picker, several words: the slowest keystroke %6.3f ms (\"%@\") (budget %.0f); the first, which reads every shape's container once, %6.3f",
                          size, worst.ms, worst.query, Budget.pickerPathKeystroke, cold))
            if holdsToBudgets {
                expect(worst.ms < Budget.pickerPathKeystroke, "a keystroke in the picker (\(worst.query)) over \(size) shapes in named containers took \(worst.ms) ms")
            }
        }
    },
])
