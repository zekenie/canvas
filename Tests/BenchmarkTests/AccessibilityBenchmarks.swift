import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Geometry
import ShippedTesting
import StickyNotes
import TestKit

// What VoiceOver costs the canvas, on the generated boards: the shapes it sees as the canvas's children
// (`accessibilityChildren`, at most 500 of some 1,000 in view), worked out cold (a canvas that has made
// no element yet) and after a commit that added a note, once its frame has drawn. Nothing of it runs unless an assistive app
// asks, so no frame pays for it. The main thread's CPU time. `./build.sh bench` holds them; `./test.sh`
// runs them small, in debug, and only reports.

extension Budget {
    /// The canvas's children for VoiceOver on 10,000 shapes, some 1,000 in view: the 500 nearest the
    /// selection found and their elements made, cold (the Tab stops' order kept). Release measured 7.3 ms
    /// quiet (2026-10-22), 7 to 12 on a busy machine: ranking every stop of the board by its distance from
    /// the selection.
    static let accessibleChildren = 12.0
    /// The same after a commit, which also puts the scope's Tab stops in reading order again (every stop
    /// of the board): release measured 21.8 ms quiet, 19 to 36 busy. Only when an assistive app asks.
    static let accessibleChildrenAfterCommit = 32.0
}

@MainActor let accessibilityBenchmarks = Suite("Accessibility benchmarks", [
    test("the canvas's children for VoiceOver, some 1,000 shapes in view: cold, and after a commit") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let size = CGSize(width: 1200, height: 800)
        for count in sizes {
            let h = EditorHarness { CanvasEditor(registry: registry, document: generatedBoard(shapes: count), scheduler: $0) }
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            var canvas = CanvasView(editor: h.editor)
            window.contentView = canvas
            // Some 1,000 shapes in view, at the middle of the board (shapes are 260 apart).
            let bounds = try require(h.editor.shapeContext.bounds(of: h.editor.document.shapes.map(\.id)))
            h.editor.camera = camera(centering: bounds, at: size.width / (260 * CGFloat(1_500).squareRoot()), in: size)
            let inView = h.editor.paintOrder(in: h.editor.camera.toWorld(CGRect(origin: .zero, size: size))).count
            let cold = median(runs: 9, prepare: {
                canvas = CanvasView(editor: h.editor)
                window.contentView = canvas
            }, onThread: true) { _ = canvas.accessibilityChildren() }
            // The commit's frame comes first, as on screen: what it keeps (the paint list) is a frame's cost.
            var added = 0
            let view = h.editor.camera.toWorld(CGRect(origin: .zero, size: size))
            let afterCommit = median(runs: 9, prepare: {
                _ = h.add(StickyNote(frame: CGRect(x: bounds.midX + CGFloat(added) * 10, y: bounds.midY, width: 160, height: 120)))
                _ = h.editor.paintOrder(in: view)
                added += 1
            }, onThread: true) { _ = canvas.accessibilityChildren() }
            let shown = canvas.accessibilityChildren()?.count ?? 0
            report(String(format: "%6d shapes, %4d in view, VoiceOver's %d children: cold %5.2f ms (budget %.0f), after a commit %5.2f (budget %.0f)",
                          count, inView, shown, cold, Budget.accessibleChildren, afterCommit, Budget.accessibleChildrenAfterCommit))
            if holdsToBudgets {
                expect(cold < Budget.accessibleChildren, "the children cold on \(count) shapes took \(cold) ms")
                expect(afterCommit < Budget.accessibleChildrenAfterCommit, "the children after a commit on \(count) shapes took \(afterCommit) ms")
            }
        }
    },
])
