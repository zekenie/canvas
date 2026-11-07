import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import LanguageModels
import Mentions
import References
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import Titles

// Moving 100 notes onto a subboard's board, 100 arrows crossing the edge: 50 arrows that start at a note that moves and end at one
// that stays (the arrow goes with its start, ending at a pill for the note that stays, placed beside it where it lands), and 50
// that start at a note that stays and end at one that moves (the arrow stays, ending at a pill for the note that moved, beside its
// start), each to a note of its own, so a hundred pills are made, landed and put down. Against the same move with no arrow among
// them.

extension Budget {
    /// `/move-to` for 100 notes with 100 crossing arrows kept through reference pills, over a board of 10,000 shapes: the commit and
    /// the going there, the thread's CPU time. Never measured before the pills: set to what a release build did, 2026-11-07, 37 ms
    /// at 10,000 shapes (23 at 1,000) against 9 (5) for the same move with no arrow among them: some 0.3 ms a pill, which is
    /// its landing among the board's solids (see the report line).
    static let moveCrossingArrows = 50.0
}

/// A board of `size` generated shapes, and, far from them: an "Archive" subboard, 100 notes to move, 100 notes that stay and the 100
/// arrows between them (50 each way); the ids of the notes to move, and the subboard.
@MainActor private func crossingBoard(shapes size: Int, arrows: Bool) -> (file: CanvasFile, moving: [ShapeID], archive: ShapeID) {
    var shapes = Array(generatedBoard(shapes: size).shapes)
    let far = CGFloat(Int(Double(size).squareRoot().rounded(.up)) + 4) * 260
    var archive = AnyShapeRecord(ShapeRecord(Subboard(frame: CGRect(x: far, y: 0, width: 240, height: 160))))
    archive[TitleProperty.self] = "Archive"
    shapes.append(archive)
    var moving: [ShapeID] = []
    let bound = { (id: ShapeID) in ArrowTerminal.bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
    for index in 0..<100 {
        let column = CGFloat(index % 10), row = CGFloat(index / 10)
        func note(_ title: String, at origin: CGPoint) -> AnyShapeRecord {
            var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 160, height: 120)), text: "")))
            note[TitleProperty.self] = title
            return note
        }
        let mover = note("Move \(index)", at: CGPoint(x: far + column * 200, y: 400 + row * 400))
        let stayer = note("Stay \(index)", at: CGPoint(x: far + column * 200, y: 600 + row * 400))
        shapes += [mover, stayer]
        moving.append(mover.id)
        if arrows {
            // Even: the mover is the start; odd: the stayer is.
            shapes.append(AnyShapeRecord(ShapeRecord(index % 2 == 0 ? Arrow(start: bound(mover.id), end: bound(stayer.id)) : Arrow(start: bound(stayer.id), end: bound(mover.id)))))
        }
    }
    return (CanvasFile(root: CanvasDocument(shapes: shapes), children: [archive.id: CanvasDocument()]), moving, archive.id)
}

@MainActor let moveBenchmarks = Suite("Move benchmarks", [
    test("a move of 100 notes with 100 arrows crossing the edge, kept through pills, costs what the pills do: 10,000 shapes") {
        for size in sizes {
            var measured: [Bool: Double] = [:]
            for arrows in [false, true] {
                let board = crossingBoard(shapes: size, arrows: arrows)
                let editor = CanvasEditor(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel()), file: board.file, scheduler: ManualScheduler())
                editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
                let argument = SlashArguments([.shape(board.archive, label: "Archive")])
                var moved = false
                measured[arrows] = median(runs: 5, debugRuns: 1, prepare: {
                    if moved { editor.undo() }
                    editor.showBoard(.root)
                    editor.selectedShapeIDs = board.moving
                }, onThread: true) {
                    expect(editor.slashCommands?.run("move-to", for: .selection(board.moving), with: argument) ?? false, "the move")
                    moved = true
                }
                let archived = editor.file[BoardID(owner: board.archive)]
                let pills = archived.shapes.filter { $0.kind == Reference.kind }.count + editor.file[.root].shapes.filter { $0.kind == Reference.kind }.count
                expectEqual(pills, arrows ? 100 : 0, arrows ? "a pill for each arrow" : "no pill without an arrow")
                if arrows {
                    expectEqual(archived.shapes.filter { $0.kind == Arrow.kind }.count, 50, "the arrows that start at a note that moved went with it")
                }
                expectEqual(editor.undoHistory.undoName, "Move")
            }
            let with = measured[true] ?? 0, without = measured[false] ?? 0
            report(String(format: "%6d shapes, 100 notes moved onto a subboard's board: %7.3f ms with 100 crossing arrows kept through pills, %7.3f ms with none (budget %.0f)",
                          size, with, without, Budget.moveCrossingArrows))
            if holdsToBudgets { expect(with < Budget.moveCrossingArrows, "moving 100 notes with 100 crossing arrows over \(size) shapes took \(with) ms") }
        }
    },
])
