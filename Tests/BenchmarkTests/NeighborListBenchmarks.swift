import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Neighbors
import Selection
import TestKit

// The budgets of the lists in a shape's panel (Neighbors' Connections tab): what the main actor spends
// from a shape's lists being asked for to their landing, on a shape with 10,000 neighbors (and one
// with ten), every list open and every list folded; and a keystroke in the search field over them.
// The neighbors are notes that mention the hub, untitled, so the engine names none of them (its rows
// are made off the main actor) and each is called what the table of contents calls it: read as a row
// is drawn, and for every row by the first keystroke of a search. `./build.sh bench` holds them;
// `./test.sh` runs them small, in debug, and only reports.

extension Budget {
    /// The main actor's time from a shape's lists being asked for to their landing, every list open,
    /// on a shape with 1,000 or 10,000 neighbors: six queries read and resolved, the turns that take
    /// up the file, and the landing of every row (none is cut, so it grows with the neighbors; the
    /// rows themselves are made off the main actor, some 4 and 50 ms). The thread's CPU time;
    /// release, some 0.5 ms at 1,000 and 1.7 at 10,000.
    static let neighborList = SizedBudget(thousand: 1.5, tenThousand: 5)
    /// The same with ten neighbors, on a board of 1,000 or 10,000 shapes: what matches, never the
    /// board (some 0.35 ms).
    static let neighborListFew = 1.0
    /// The same with every list folded, so each is only counted (one batch of ids, no row made;
    /// some 0.3 and 0.85 ms).
    static let neighborListFolded = SizedBudget(thousand: 1, tenThousand: 3)
    /// A keystroke in the search field over a list of 1,000 or 10,000 rows, once their names are
    /// read: every name folded and matched, the matches ranked (some 0.8 and 7.8 ms: within a frame).
    static let neighborListSearch = SizedBudget(thousand: 2.5, tenThousand: 16)
}

/// The shipped lists' places, with the shipped lights: arrows' two, mentions' two, then the two every
/// list has.
private enum Listed {
    static let mentionedBy = 3
}

@MainActor let neighborListBenchmarks = Suite("Neighbor list benchmarks", [
    test("a shape's lists land in a few milliseconds of the main actor with ten neighbors, and grow with them: 10,000 rows, none cut; folded, a count") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            for (what, mentioning) in [("\(size - 1) neighbors", size - 1), ("10 neighbors", 10)] {
                let (h, hub) = try hubEditor(shapes: size, mentioning: mentioning, pasteboard: pasteboard)
                let list = try require(h.editor.neighborList)
                @MainActor func watch() throws -> (main: Double, offMain: Double) {
                    let (_, main, offMain) = try cpu {
                        list.watch(hub)
                        await list.landed()
                    }
                    return (main, offMain)
                }
                // The first ask makes the engine's vocabulary (a millisecond), and every later one is what a selection costs.
                let first = try watch()
                expectEqual(list.shown(in: Listed.mentionedBy).rows.count, mentioning, "every note that mentions the hub is listed, none cut")
                expectEqual(list.total, mentioning)
                var mains: [Double] = [], offs: [Double] = []
                for _ in 0..<7 {
                    list.unwatch(hub)
                    let (main, off) = try watch()
                    mains.append(main)
                    offs.append(off)
                }
                let main = middle(mains)
                let budget = mentioning > 10 ? Budget.neighborList.at(size) : Budget.neighborListFew
                report(String(format: "%6d shapes, the lists of a shape with %@: main %7.3f ms (the first %7.3f; budget %.1f), the engine's answers off the main actor %6.1f ms",
                              size, what, main, first.main, budget, middle(offs)))
                if holdsToBudgets { expect(main < budget, "the lists of a shape with \(what), among \(size) shapes, took \(main) ms of the main actor") }

                guard mentioning > 10 else { continue }
                // Folded: counted, no row made.
                for group in list.groups.indices { list.setFolded(group, true) }
                var folded: [Double] = []
                for _ in 0..<7 {
                    list.unwatch(hub)
                    folded.append(try watch().main)
                }
                expectEqual(list.shown(in: Listed.mentionedBy).count, mentioning)
                expectEqual(list.listing?.groups[Listed.mentionedBy].rows, nil, "a folded list's rows aren't read")
                report(String(format: "%6d shapes, the same with every list folded: main %7.3f ms (budget %.1f)", size, middle(folded), Budget.neighborListFolded.at(size)))
                if holdsToBudgets { expect(middle(folded) < Budget.neighborListFolded.at(size), "the folded lists of a shape with \(what) took \(middle(folded)) ms of the main actor") }
                for group in list.groups.indices { list.setFolded(group, false) }
            }
        }
    },
    test("a keystroke in the search field ranks 10,000 rows in a frame") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (h, hub) = try hubEditor(shapes: size, mentioning: size - 1, pasteboard: pasteboard)
            let list = try require(h.editor.neighborList)
            _ = try cpu {
                list.watch(hub)
                await list.landed()
            }
            var found = 0
            // The first keystroke reads every untitled row's name from the table of contents, once for the answer.
            let first = median(runs: 1, onThread: true) {
                list.setSearch("s")
                found = list.shown(in: Listed.mentionedBy).count
            }
            var typed = ["n", "no", "not", "note", "note 1", "note 12"].makeIterator()
            let keystroke = median(runs: 6, onThread: true) {
                list.setSearch(typed.next() ?? "")
                found = list.shown(in: Listed.mentionedBy).count
            }
            expect(found > 0 && found < size, "\"note 12\" matched \(found) of \(size)")
            report(String(format: "%6d shapes, a keystroke searching %d rows: %6.3f ms (budget %.1f); the first, which reads their names, %6.1f ms",
                          size, size - 1, keystroke, Budget.neighborListSearch.at(size), first))
            if holdsToBudgets { expect(keystroke < Budget.neighborListSearch.at(size), "a keystroke searching \(size - 1) rows took \(keystroke) ms") }
        }
    },
])
