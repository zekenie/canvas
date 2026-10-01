import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Foundation
import Frames
import Geometry
import LanguageModels
import Mentions
import Selection
import StickyNotes
import TestKit

// Frames on a board of the board's worth of generated shapes: a note dropped across a frame's edge,
// settled in on the release (the in-or-out rule looks at every container on the board once); a frame
// resized over the board's shapes, settled on the release; and a frame dragged, which carries what it
// holds every event: holding a row of the board's shapes, within a drag event's input budget, and
// holding every box shape on it, reported (moving thousands of shapes an event costs what it costs
// with them selected, as ⌘A and a drag do).

extension Budget {
    /// A drop's release on a board of 10,000 shapes with a frame: the last move, and settling what
    /// was put down in or out of the containers on the board (each looked at once), with the commit
    /// every service hears (some 1.2 ms).
    static let settle = 2.0
    /// A resize's release that takes in shapes from below the frame: they're raised above it, a
    /// commit that restacks shapes, which every service that keeps the stack's order follows (some
    /// 5.8 ms at 10,000): half a frame, since a release is one event, never a run of them.
    static let settleResize = frame / 2
}

/// The generated board, a frame `right` of it and an editor over the shipped list.
@MainActor private func frameHarness(shapes size: Int) throws -> (h: EditorHarness, document: CanvasDocument, right: CGFloat) {
    let document = generatedBoard(shapes: size)
    let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
    let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
    let right = document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }.maxX + 400
    return (h, document, right)
}

@MainActor let frameBenchmarks = Suite("Frame benchmarks", [
    test("a note dropped across a frame's edge settles in on the release, in what a gesture's end may cost, whatever the board") {
        for size in sizes {
            let (h, _, right) = try frameHarness(shapes: size)
            let frame = h.add(Frame(frame: CGRect(x: right, y: 0, width: 640, height: 400)))
            let note = h.add(StickyNote(frame: CGRect(x: right - 400, y: 100, width: 200, height: 200), text: "Dropped"))
            // Dropped hanging 40 over the frame's left edge: in, nudged 56 right.
            let from = CGPoint(x: right - 300, y: 200), to = CGPoint(x: right + 60, y: 200)
            var dropped = false
            let release = median(runs: 11, prepare: {
                if dropped { h.editor.undo() }
                h.move(to: h.view(from))
                h.press(at: h.view(from))
                h.drag(to: h.view(CGPoint(x: (from.x + to.x) / 2, y: from.y)))
                h.drag(to: h.view(to))
                dropped = true
            }, onThread: true) {
                h.release()
            }
            expectEqual(h.editor.document.container(of: note, containingKinds: h.editor.registry.containingKinds), frame, "dropped in")
            expectEqual(h.editor.document[note]?.box?.minX, right + 16, "nudged to the gap inside the edge")
            report(String(format: "%6d shapes: a note dropped across a frame's edge, the release %5.2f ms (budget %.0f)", size, release, Budget.settle))
            if holdsToBudgets { expect(release < Budget.settle, "a drop into a frame beside \(size) shapes took \(release) ms") }
        }
    },
    test("a frame resized over the board's shapes settles them in or out on the release, in what a gesture's end may cost") {
        for size in sizes {
            let (h, _, right) = try frameHarness(shapes: size)
            let frame = h.add(Frame(frame: CGRect(x: right, y: 0, width: 640, height: 400)))
            // Its left side pulled over the board's last two columns: what's mostly inside goes in, the
            // rest is nudged out.
            let side = CGPoint(x: right, y: 200), over = CGPoint(x: right - 900, y: 200)
            var resized = false
            let release = median(runs: 11, prepare: {
                if resized { h.editor.undo() }
                h.editor.selection = frame
                h.move(to: h.view(side))
                h.press(at: h.view(side))
                h.drag(to: h.view(CGPoint(x: (side.x + over.x) / 2, y: side.y)))
                h.drag(to: h.view(over))
                resized = true
            }, onThread: true) {
                h.release()
            }
            let kinds = h.editor.registry.containingKinds
            expectEqual(h.editor.document[frame]?.box?.minX, over.x, "resized")
            expect(!h.editor.document.contents(of: frame, containingKinds: kinds).isEmpty, "it took in what it was pulled over")
            report(String(format: "%6d shapes: a frame resized over the board's shapes, the release %5.2f ms (budget %.0f)", size, release, Budget.settleResize))
            if holdsToBudgets { expect(release < Budget.settleResize, "a frame's resize beside \(size) shapes took \(release) ms") }
        }
    },
    test("a frame dragged carries what it holds: a row of the board's shapes within a drag event's input budget, every box shape on the board reported") {
        for size in sizes {
            let (h, document, _) = try frameHarness(shapes: size)
            let bounds = document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }
            var lines: [String] = []
            for (name, region) in [("its first row", CGRect(x: bounds.minX - 20, y: bounds.minY - 20, width: bounds.width + 40, height: 250)),
                                   ("every box shape", bounds.insetBy(dx: -20, dy: -20))] {
                let frame = h.add(Frame(frame: region))
                let held = h.editor.document.shapes.filter { $0.id != frame && $0.box.map(region.contains) == true && !h.editor.isReadOnly($0.id) }.map(\.id)
                h.editor.transact { $0.setContainer(held, to: frame) }
                let kinds = h.editor.registry.containingKinds
                expectEqual(h.editor.document.descendants(of: frame, containingKinds: kinds).count, held.count, "\(name): held")
                // Pressed on its top border, which grabs a frame that holds shapes, where no shape in it
                // has a port's dot (a note's on its left would take the press).
                let border = CGPoint(x: region.midX + 130, y: region.minY)
                h.editor.selection = nil
                h.move(to: h.view(border))
                h.press(at: h.view(border))
                expectEqual(h.editor.selectableShape(at: border), frame, "\(name): its border grabs it")
                var step = 0
                let input = median(runs: 21, onThread: true) {
                    step += 1
                    h.drag(to: h.view(border + CGPoint(x: CGFloat(10 + step), y: CGFloat(step) / 2)))
                }
                let frameMoved = (h.editor.document[frame]?.box?.minX ?? .nan) - region.minX
                let heldMoved = (h.editor.document[held[0]]?.box?.minX ?? .nan) - (document[held[0]]?.box?.minX ?? .nan)
                expect(frameMoved > 0 && heldMoved == frameMoved, "\(name): carried with it, \(heldMoved) as it moved \(frameMoved)")
                h.editor.cancel()
                h.release()
                h.editor.transact { $0.delete([frame]) }
                lines.append(String(format: "%@, %d shapes, %.2f ms", name, held.count, input))
                if holdsToBudgets, name == "its first row" {
                    expect(input < Budget.dragInput, "a drag event of a frame holding \(held.count) shapes on \(size) took \(input) ms")
                }
            }
            report(String(format: "%6d shapes: a frame dragged, a drag event's input: holding %@ (budget %.0f for the row; the rest reported)",
                          size, lines.joined(separator: "; holding "), Budget.dragInput))
        }
    },
])
