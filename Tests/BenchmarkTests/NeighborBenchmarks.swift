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
import Titles
import Types

// Neighbors' budgets, for the whole reach, the only hover (`ReachBenchmarks.swift` measures a hover on a shape with arrows
// between it and a hub, and the lights' landing; this file holds what the reach's own lights cost, by kind): a hover on a type with
// 10,000 instances (Types' lights, found through `:is-a`), what the main actor spends from the hover to the reach landed; and what
// the lights add to a frame, with all 10,000 lit notes out of view, at 100% and at 10%, selected too (⌘A) or not in view, and on the
// minimap. The lit notes mention the hub (the shipped lights' lavender, shown with ⌃⌥ held), so what the engine finds is every one of
// them. `./build.sh bench` holds them; `./test.sh` runs them small, in debug, and only reports.

extension Budget {
    /// The main actor's time from a hover to the reach landed, on a type with 1,000 or 10,000 instances (Types' lights:
    /// the type's `:is-a` reach, one hop, every instance lit): the look at the hover, the reach's answers taken up and
    /// landed (the rings, each match placed where it's drawn). The engine's answer is off the main actor. The thread's
    /// CPU time. It was the one-hop hover's before the whole reach replaced it (some 0.2 ms at 1,000, 0.8 at 10,000).
    static let neighborHover = SizedBudget(thousand: 0.5, tenThousand: 2)
    /// The same from an instance, which the type's lights don't reach: what matches, never the board (some 0.14 ms).
    static let neighborHoverFew = 0.5
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
@MainActor func hubBoard(shapes count: Int, mentioning: Int) -> (document: CanvasDocument, hub: ShapeID) {
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

/// The hub board's grid with a type first and every other note of it: a type with `count - 1` instances, which Types'
/// lights find through `:is-a` (however far), each tested to be no type. `instance` is one of them.
@MainActor func typeHubBoard(shapes count: Int) -> (document: CanvasDocument, type: ShapeID, instance: ShapeID) {
    let type = ShapeID()
    var shapes: [AnyShapeRecord] = []
    shapes.reserveCapacity(count)
    for i in 0..<count {
        let origin = CGPoint(x: CGFloat(i % 120) * 95, y: CGFloat(i / 120) * 95)
        var record = AnyShapeRecord(ShapeRecord(id: i == 0 ? type : ShapeID(), StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 80, height: 80)), text: MentionText(plain: "Note \(i)"))))
        if i == 0 {
            record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
            record[TitleProperty.self] = "Kind"
        } else {
            record[IsAProperty.self] = [TypeLink(type)]
        }
        shapes.append(record)
    }
    return (CanvasDocument(shapes: shapes), type, shapes[1].id)
}

private let viewport = CGSize(width: 1200, height: 800)

/// `held`: the keys held, as the hover's are (⌃⌥ shows what mentions the hub).
@MainActor func hubEditor(shapes count: Int, mentioning: Int, held: Modifiers = [], pasteboard: NSPasteboard) throws -> (h: EditorHarness, hub: ShapeID) {
    let (document, hub) = hubBoard(shapes: count, mentioning: mentioning)
    let registry = try Registry(plugins: shippedPlugins(pasteboard))
    let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
    h.editor.viewportDidResize(to: viewport)
    h.hold(held)
    return (h, hub)
}

/// The shipped lights, in the order the plugins that own the edges give them: arrows' two
/// (Arrows'), then mentions' two (Mentions'), then types' two (Types', one pink: told apart by place).
private enum Light: Int {
    case pointsTo, pointedToBy, mentions, mentionedBy, instances, subtypes
}

/// How many shapes the canvas outlines in a light's color, whatever the ring.
@MainActor private func lit(_ editor: CanvasEditor, in light: Light) -> Int {
    let lights = editor.registry.neighborLights
    guard lights.indices.contains(light.rawValue) else { return 0 }
    return editor.outlines.tinted.filter { $0.color == lights[light.rawValue].color }.reduce(0) { $0 + $1.shapes.count }
}

@MainActor let neighborBenchmarks = Suite("Neighbor benchmarks", [
    test("a hover on a type with 10,000 instances costs the main actor what any hover with that many lit does, and a hover on one of them, what matches") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let (document, type, instance) = typeHubBoard(shapes: size)
            let registry = try Registry(plugins: shippedPlugins(pasteboard))
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            h.hold(.option)                                // what is of a type is shown with ⌥
            let reach = try require(h.editor.reach)
            for (what, subject, lights) in [("a type with \(size - 1) instances", type, size - 1), ("one of its instances", instance, 0)] {
                @MainActor func hover() throws -> (main: Double, offMain: Double) {
                    let (_, main, offMain) = try cpu {
                        h.editor.hovered = subject
                        h.wait(0)
                        await reach.landed()
                    }
                    return (main, offMain)
                }
                let first = try hover()
                let tints = h.editor.outlines.tinted.reduce(0) { $0 + $1.shapes.count }
                expectEqual(tints, lights, "what is of the type, and nothing from an instance: its chips say what it is")
                var mains: [Double] = [], offs: [Double] = []
                for _ in 0..<measuredRuns(11) {
                    h.editor.hovered = nil
                    h.wait(200)                            // the release passes: the next hover starts from nothing shown
                    let (main, off) = try hover()
                    mains.append(main)
                    offs.append(off)
                }
                let main = middle(mains)
                let budget = lights > 10 ? Budget.neighborHover.at(size) : Budget.neighborHoverFew
                report(String(format: "%6d shapes, a hover on %@: main %6.3f ms (the first %6.3f; budget %.1f), the engine's answer off the main actor %6.1f ms",
                              size, what, main, first.main, budget, middle(offs)))
                if holdsToBudgets { expect(main < budget, "a hover on \(what), among \(size) shapes, took \(main) ms of the main actor") }
            }
        }
    },
    test("10,000 lit shapes add little to a frame all out of view, at 100% and at 10%, on the canvas") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let context = try bitmapContext(viewport)
        for size in sizes {
            let (h, hub) = try hubEditor(shapes: size, mentioning: size - 1, held: [.control, .option], pasteboard: pasteboard)
            let reach = try require(h.editor.reach)
            let board = h.editor.shapeBounds
            // Out of view, past the board's corner: a look at each one's kept extent, and nothing drawn.
            @MainActor func place(_ zoom: CGFloat) -> Camera {
                Camera(origin: CGPoint(x: board.maxX + 100_000, y: board.maxY + 100_000), zoom: zoom)
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
            var worstOffscreen = 0.0
            for (what, camera) in [("out of view at 100%", place(1)), ("out of view at 10%", place(0.1))] {
                h.editor.hovered = nil
                h.wait(200)
                let unlit = frame(camera)
                h.editor.hovered = hub
                h.wait(0)
                try awaitResult(timeout: 60) { await reach.landed() }
                expectEqual(lit(h.editor, in: .mentionedBy), size - 1)
                let added = frame(camera) - unlit
                lines.append(String(format: "%@: %6.2f ms over %6.2f unlit", what, added, unlit))
                worstOffscreen = max(worstOffscreen, added)
            }
            report(String(format: "%6d shapes, %d lit: what they add to a frame, %@ (budget %.0f)",
                          size, size - 1, lines.joined(separator: "; "), Budget.neighborFrameOffscreen))
            if holdsToBudgets { expect(worstOffscreen < Budget.neighborFrameOffscreen, "\(size - 1) lit shapes out of view added \(worstOffscreen) ms to a frame") }
        }
    },
    test("10,000 lit shapes that are all selected too (⌘A) add little to a frame: each one's tint a ring further out, looked up in one set") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let context = try bitmapContext(viewport)
        for size in sizes {
            let (h, hub) = try hubEditor(shapes: size, mentioning: size - 1, held: [.control, .option], pasteboard: pasteboard)
            let reach = try require(h.editor.reach)
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
            try awaitResult(timeout: 60) { await reach.landed() }
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
            let (h, hub) = try hubEditor(shapes: size, mentioning: size - 1, held: [.control, .option], pasteboard: pasteboard)
            let reach = try require(h.editor.reach)
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
            try awaitResult(timeout: 60) { await reach.landed() }
            let drawn = median(runs: 11, onThread: true) { display(minimap, into: minimapContext) }
            report(String(format: "%6d shapes, %d lit: the minimap's drawing %6.2f ms over %6.2f unlit (budget %.0f)", size, size - 1, drawn - unlit, unlit, Budget.neighborMinimap))
            if holdsToBudgets { expect(drawn - unlit < Budget.neighborMinimap, "\(size - 1) lit shapes added \(drawn - unlit) ms to the minimap's drawing") }
            // The same with every shape selected too (⌘A): each one's fill for the selection is inset inside its tint.
            h.editor.hovered = nil
            h.wait(200)
            h.editor.selectAll()
            let selectedUnlit = median(runs: 11, onThread: true) { display(minimap, into: minimapContext) }
            h.editor.hovered = hub
            h.wait(0)
            try awaitResult(timeout: 60) { await reach.landed() }
            let selectedLit = median(runs: 11, onThread: true) { display(minimap, into: minimapContext) }
            report(String(format: "%6d shapes, %d lit and all selected: the minimap's drawing %6.2f ms over %6.2f selected and unlit", size, size - 1, selectedLit - selectedUnlit, selectedUnlit))
        }
    },
])
