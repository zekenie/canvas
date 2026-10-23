import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Frames
import Geometry
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// Frames on a board of the board's worth of generated shapes: a note dropped across a frame's edge,
// settled in on the release (the in-or-out rule looks at every container on the board once); a frame
// resized over the board's shapes, settled on the release; and a frame dragged, which carries what it
// holds every event: holding a row of the board's shapes, within a drag event's input budget, and
// holding every box shape on it, reported (moving thousands of shapes an event costs what it costs
// with them selected, as ⌘A and a drag do). And titled frames zoomed out, each saying its title in a tab
// on its edge, three deep at shared corners, so their tabs give way to each other every frame.

extension Budget {
    /// A drop's release on a board of 10,000 shapes with a frame: the last move, and settling what
    /// was put down in or out of the containers on the board (each looked at once), with the commit
    /// every service hears (some 1.2 ms).
    static let settle = 2.0
    /// A resize's release that takes in shapes from below the frame: they're raised above it, a
    /// commit that restacks shapes, which every service that keeps the stack's order follows (some
    /// 5.8 ms at 10,000): half a frame, since a release is one event, never a run of them.
    static let settleResize = frame / 2
    /// A frame zoomed out over the generated board with sixty titled frames on it, three deep in twenty
    /// bands (fitted, and at 6%): their tabs placed together, each frame (a look at each shape in view and
    /// a sort of the frames with one), within what a frame zoomed out may cost.
    static let tabsZoomedOut = zoomedOut
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
    test("titled frames zoomed out say their titles in tabs, placed together every frame, within what a frame zoomed out may cost") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let (h, document, _) = try frameHarness(shapes: size)
            h.editor.viewportDidResize(to: viewport)
            let bounds = document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }
            // Twenty bands down the board, each a titled frame holding one over its left half, which holds
            // one over its first quarter: three deep at a shared corner, so the inner tabs slide past the outer.
            // Twenty on the board of 10,000; four on a small one, so each is tall enough at 6% for a tab.
            let bands = size >= 10_000 ? 20 : 4, height = bounds.height / CGFloat(bands)
            var ids: [ShapeID] = []
            h.editor.transact { transaction in
                for band in 0..<bands {
                    let rect = CGRect(x: bounds.minX - 40, y: bounds.minY + CGFloat(band) * height - 20, width: bounds.width + 80, height: height)
                    var chain: [ShapeID] = []
                    for (part, name) in [(1.0, "Band \(band)"), (0.5, "Left of band \(band)"), (0.25, "First of band \(band)")] {
                        var frame = ShapeRecord(Frame(frame: CGRect(x: rect.minX, y: rect.minY, width: rect.width * part, height: rect.height)))
                        frame[TitleProperty.self] = name
                        transaction.insert(frame)
                        if let outer = chain.last { transaction.setContainer([frame.id], to: outer) }
                        chain.append(frame.id)
                    }
                    ids += chain
                }
            }
            var lines: [String] = [], worst = 0.0
            for (name, camera) in [("fitted", Camera(fitting: h.editor.shapeBounds, in: viewport, inset: 0)),
                                   ("at 6%", camera(centering: bounds, at: 0.06, in: viewport))] {
                h.editor.camera = camera
                expect(h.editor.drawsSkeletons, "\(name): skeletons")
                draw(h.editor, into: context, size: viewport)
                let titled = median(runs: 21, onThread: true) {
                    // The camera a hair off the last frame's, so the tabs are placed again, as in a pan.
                    h.editor.camera.origin.x += 0.5
                    draw(h.editor, into: context, size: viewport)
                }
                let tabs = ids.filter { id in h.editor.adornmentFrames(of: id).contains { $0.adornment == .of(TitleTab.self) } }.count
                expect(tabs >= bands, "\(name): the bands' tabs, at least: \(tabs)")
                worst = max(worst, titled)
                lines.append(String(format: "%@ (%.0f%%) %5.1f ms, %d tabs", name, camera.zoom * 100, titled, tabs))
            }
            report(String(format: "%6d shapes, %d titled frames zoomed out: a frame %@ (budget %.0f)", size, ids.count, lines.joined(separator: "; "),
                          Budget.tabsZoomedOut))
            if holdsToBudgets { expect(worst < Budget.tabsZoomedOut, "a frame zoomed out with \(ids.count) titled frames over \(size) shapes took \(worst) ms") }
        }
    },
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
                // has a port's dot (a note's or a card's top dot, 12 above the middle of its top edge,
                // would take the press) or a title's pill. The grid's columns are 260 apart, and its
                // shapes' middles 80 to 120 into a column, so a point 200 into one is clear of both.
                let border = CGPoint(x: region.minX + 220, y: region.minY)
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
