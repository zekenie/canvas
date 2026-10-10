import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Foundation
import Geometry
import Mentions
import Neighbors
import Selection
import StickyNotes
import TestKit

// Neighbors' budgets: hovering a shape with 10,000 neighbors (and one with ten), what the main actor
// spends from the hover to the lights landing; and what the lights add to a frame, with all 10,000 in
// view zoomed out to 10% (each one a skeleton, its outline a ring, selected too or not) and with every
// one out of view, on the canvas and in the minimap. The neighbors are notes that mention the hub (the shipped lights'
// purple), so what the engine finds is every one of them. `./build.sh bench` holds them; `./test.sh`
// runs them small, in debug, and only reports.

extension Budget {
    /// The main actor's time from a hover to the lights landing, on a shape with 1,000 or 10,000
    /// neighbors: the look at the hover and the batch's reading and resolving of four queries (the one
    /// view: nothing here stands in), the turn that takes up the file, and the landing (the answers
    /// joined, the set of what matched made, each match placed where it's drawn, the rings); the
    /// engine's answer is off the main actor (some 10 ms at 10,000 neighbors). The thread's CPU time;
    /// release, some 0.2 ms at 1,000 and 0.8 at 10,000.
    static let neighborHover = SizedBudget(thousand: 0.5, tenThousand: 2)
    /// The same with ten neighbors, on a board of 1,000 or 10,000 shapes: what matches, never the
    /// board (some 0.14 ms).
    static let neighborHoverFew = 0.5
    /// What the lights add to a frame over the same frame unlit, 10,000 of them in view zoomed out to
    /// 10%, where each is a skeleton and its outline a ring (some 7 ms: the rings' paths and a look at
    /// each one's kept extent, as ⌘A's outlines cost at that zoom; the unlit frame is some 16 ms).
    /// The thread's CPU time.
    static let neighborFrameInView = 12.0
    /// What they add with all of them out of view, at 100% and at 10%: a look at each one's kept
    /// extent (some 0.35 ms), as ⌘A's outlines cost (`offscreenBoard`).
    static let neighborFrameOffscreen = offscreenBoard
    /// What they add to a frame with every shape selected too (⌘A) over the same frame with the
    /// selection and no lights, 10,000 in view at 10%: each one's tint is a ring further out, which
    /// the frame looks up among the selected through one set made once (some 6 ms, as unselected).
    /// The thread's CPU time.
    static let neighborFrameSelected = 12.0
    /// What 10,000 lit shapes add to the minimap's drawing over the same minimap unlit: each
    /// silhouette in its color (some 4 ms, which every frame of the canvas draws while the hover
    /// lasts, as it does for ⌘A's selection).
    static let neighborMinimap = 6.0
}

/// `count` small notes in a tight grid, 120 to a row at 95 units (all of them in view zoomed out to
/// 10% in a 1200 × 800 view), the first the hub, and the next `mentioning` each mentioning the hub: a
/// shape with `mentioning` neighbors, among shapes that have none.
@MainActor private func hubBoard(shapes count: Int, mentioning: Int) -> (document: CanvasDocument, hub: ShapeID) {
    let hub = ShapeID()
    var shapes: [AnyShapeRecord] = []
    shapes.reserveCapacity(count)
    for i in 0..<count {
        let origin = CGPoint(x: CGFloat(i % 120) * 95, y: CGFloat(i / 120) * 95)
        let text = i > 0 && i <= mentioning ? MentionText([.text("Note \(i): see "), .mention(hub, label: "Hub")]) : MentionText(plain: "Note \(i)")
        shapes.append(AnyShapeRecord(ShapeRecord(id: i == 0 ? hub : ShapeID(), StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 80, height: 80)), text: text))))
    }
    return (CanvasDocument(shapes: shapes), hub)
}

private let viewport = CGSize(width: 1200, height: 800)

@MainActor private func hubEditor(shapes count: Int, mentioning: Int, pasteboard: NSPasteboard) throws -> (h: EditorHarness, hub: ShapeID) {
    let (document, hub) = hubBoard(shapes: count, mentioning: mentioning)
    let registry = try Registry(plugins: shippedPlugins(pasteboard))
    let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
    h.editor.viewportDidResize(to: viewport)
    return (h, hub)
}

/// The shipped lights, in the order the plugins that own the edges give them: arrows' two
/// (Connections'), then mentions' two (Mentions').
private enum Light: Int {
    case pointsTo, pointedToBy, mentions, mentionedBy
}

/// How many shapes the canvas outlines in a light's color, whatever the ring.
@MainActor private func lit(_ editor: CanvasEditor, in light: Light) -> Int {
    let lights = editor.registry.neighborLights
    guard lights.indices.contains(light.rawValue) else { return 0 }
    return editor.outlines.tinted.filter { $0.color == lights[light.rawValue].color }.reduce(0) { $0 + $1.shapes.count }
}

@MainActor let neighborBenchmarks = Suite("Neighbor benchmarks", [
    test("a hover on a shape with 10,000 neighbors costs the main actor a few milliseconds from the hover to the lights landing; with ten neighbors, what matches") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            for (what, mentioning) in [("\(size - 1) neighbors", size - 1), ("10 neighbors", 10)] {
                let (h, hub) = try hubEditor(shapes: size, mentioning: mentioning, pasteboard: pasteboard)
                let neighbors = try require(h.editor.neighbors)
                @MainActor func hover() throws -> (main: Double, offMain: Double) {
                    let (_, main, offMain) = try cpu {
                        h.editor.hovered = hub
                        h.wait(0)                          // the look at the hover, which asks
                        await neighbors.landed()           // the engine answers off the main actor, and the lights land
                    }
                    return (main, offMain)
                }
                @MainActor func unhover() {
                    h.editor.hovered = nil
                    h.wait(0)
                }
                // The first hover makes the engine's vocabulary (a millisecond), and every later one is what a hover costs.
                let first = try hover()
                expectEqual(lit(h.editor, in: .mentionedBy), mentioning, "the notes that mention the hub are lit")
                expectEqual(lit(h.editor, in: .pointsTo) + lit(h.editor, in: .pointedToBy) + lit(h.editor, in: .mentions), 0)
                var mains: [Double] = [], offs: [Double] = []
                for _ in 0..<11 {
                    unhover()
                    let (main, off) = try hover()
                    mains.append(main)
                    offs.append(off)
                }
                let main = middle(mains)
                let budget = mentioning > 10 ? Budget.neighborHover.at(size) : Budget.neighborHoverFew
                report(String(format: "%6d shapes, a hover on a shape with %@: main %6.3f ms (the first %6.3f; budget %.1f), the engine's answer off the main actor %6.1f ms",
                              size, what, main, first.main, budget, middle(offs)))
                if holdsToBudgets { expect(main < budget, "a hover on a shape with \(what), among \(size) shapes, took \(main) ms of the main actor") }
            }
        }
    },
    test("10,000 lit shapes add little to a frame: in view zoomed out to 10%, or all out of view, on the canvas") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let context = try bitmapContext(viewport)
        for size in sizes {
            let (h, hub) = try hubEditor(shapes: size, mentioning: size - 1, pasteboard: pasteboard)
            let neighbors = try require(h.editor.neighbors)
            let board = h.editor.shapeBounds
            @MainActor func place(_ zoom: CGFloat, atBoard: Bool) -> Camera {
                atBoard ? camera(centering: board, at: zoom, in: viewport)
                    : Camera(origin: CGPoint(x: board.maxX + 100_000, y: board.maxY + 100_000), zoom: zoom)
            }
            // A frame drawn again with the camera a point from the last one's, as a pan's is.
            @MainActor func frame(_ camera: Camera) -> Double {
                var step = 0.0
                let pan = {
                    step = step == 0 ? 1 : 0
                    h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step / camera.zoom, y: camera.origin.y), zoom: camera.zoom)
                }
                h.editor.camera = camera
                draw(h.editor, into: context, size: viewport)
                return median(runs: 11, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
            }
            var lines: [String] = []
            var worstInView = 0.0, worstOffscreen = 0.0
            for (what, camera, isInView) in [("in view at 10%", place(0.1, atBoard: true), true), ("out of view at 100%", place(1, atBoard: false), false),
                                             ("out of view at 10%", place(0.1, atBoard: false), false)] {
                h.editor.hovered = nil
                h.wait(0)
                let unlit = frame(camera)
                h.editor.hovered = hub
                h.wait(0)
                try awaitResult(timeout: 60) { await neighbors.landed() }
                expectEqual(lit(h.editor, in: .mentionedBy), size - 1)
                let drawn = frame(camera)
                let added = drawn - unlit
                lines.append(String(format: "%@: %6.2f ms over %6.2f unlit", what, added, unlit))
                if isInView { worstInView = max(worstInView, added) } else { worstOffscreen = max(worstOffscreen, added) }
            }
            report(String(format: "%6d shapes, %d lit: what they add to a frame, %@ (budgets %.0f in view, %.0f out of it)",
                          size, size - 1, lines.joined(separator: "; "), Budget.neighborFrameInView, Budget.neighborFrameOffscreen))
            if holdsToBudgets {
                expect(worstInView < Budget.neighborFrameInView, "\(size - 1) lit shapes in view added \(worstInView) ms to a frame")
                expect(worstOffscreen < Budget.neighborFrameOffscreen, "\(size - 1) lit shapes out of view added \(worstOffscreen) ms to a frame")
            }
        }
    },
    test("10,000 lit shapes that are all selected too (⌘A) add little to a frame: each one's tint a ring further out, looked up in one set") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let context = try bitmapContext(viewport)
        for size in sizes {
            let (h, hub) = try hubEditor(shapes: size, mentioning: size - 1, pasteboard: pasteboard)
            let neighbors = try require(h.editor.neighbors)
            let board = h.editor.shapeBounds
            let camera = camera(centering: board, at: 0.1, in: viewport)
            // A frame drawn again with the camera a point from the last one's, as a pan's is.
            @MainActor func frame() -> Double {
                var step = 0.0
                let pan = {
                    step = step == 0 ? 1 : 0
                    h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step / camera.zoom, y: camera.origin.y), zoom: camera.zoom)
                }
                h.editor.camera = camera
                draw(h.editor, into: context, size: viewport)
                return median(runs: 11, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
            }
            h.editor.selectAll()
            expectEqual(h.editor.selectedShapeIDs.count, size)
            h.editor.hovered = nil
            h.wait(0)
            let unlit = frame()
            h.editor.hovered = hub
            h.wait(0)
            try awaitResult(timeout: 60) { await neighbors.landed() }
            expectEqual(lit(h.editor, in: .mentionedBy), size - 1)
            let added = frame() - unlit
            report(String(format: "%6d shapes, %d lit and all selected: what they add to a frame at 10%%: %6.2f ms over %6.2f selected and unlit (budget %.0f)",
                          size, size - 1, added, unlit, Budget.neighborFrameSelected))
            if holdsToBudgets { expect(added < Budget.neighborFrameSelected, "\(size - 1) lit shapes, all selected, added \(added) ms to a frame") }
        }
    },
    test("10,000 lit shapes add little to the minimap's drawing: each a silhouette") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let context = try bitmapContext(viewport)
        for size in sizes {
            let (h, hub) = try hubEditor(shapes: size, mentioning: size - 1, pasteboard: pasteboard)
            let neighbors = try require(h.editor.neighbors)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.titled], backing: .buffered, defer: false)
            let canvas = CanvasView(editor: h.editor)
            window.contentView = canvas
            canvas.showsMinimap = true
            let minimap = try require(canvas.minimap)
            let minimapContext = try bitmapContext(minimap.bounds.size, scale: window.backingScaleFactor)
            draw(h.editor, into: context, size: viewport)
            // The picture of the board drawn, so what's timed is the silhouettes over it.
            for _ in 0..<1000 {
                display(minimap, into: minimapContext)
                guard h.scheduler.pendingCount > 0 else { break }
                h.wait(0)
            }
            let unlit = median(runs: 11, onThread: true) { display(minimap, into: minimapContext) }
            h.editor.hovered = hub
            h.wait(0)
            try awaitResult(timeout: 60) { await neighbors.landed() }
            let drawn = median(runs: 11, onThread: true) { display(minimap, into: minimapContext) }
            report(String(format: "%6d shapes, %d lit: the minimap's drawing %6.2f ms over %6.2f unlit (budget %.0f)", size, size - 1, drawn - unlit, unlit, Budget.neighborMinimap))
            if holdsToBudgets { expect(drawn - unlit < Budget.neighborMinimap, "\(size - 1) lit shapes added \(drawn - unlit) ms to the minimap's drawing") }
            // The same with every shape selected too (⌘A): each one's fill for the selection is inset inside its tint.
            h.editor.hovered = nil
            h.wait(0)
            h.editor.selectAll()
            let selectedUnlit = median(runs: 11, onThread: true) { display(minimap, into: minimapContext) }
            h.editor.hovered = hub
            h.wait(0)
            try awaitResult(timeout: 60) { await neighbors.landed() }
            let selectedLit = median(runs: 11, onThread: true) { display(minimap, into: minimapContext) }
            report(String(format: "%6d shapes, %d lit and all selected: the minimap's drawing %6.2f ms over %6.2f selected and unlit", size, size - 1, selectedLit - selectedUnlit, selectedUnlit))
        }
    },
])
