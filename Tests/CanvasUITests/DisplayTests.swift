import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import TestKit

/// The bits to a component of each context a frame was drawn into: 0 for a display list's, more
/// for a bitmap's.
@MainActor final class ContextLog {
    var bitsPerComponent: [Int] = []
}

struct ContextProbeOverlay: CanvasOverlay {
    let log: ContextLog
    var space: OverlaySpace { .view }
    func draw(in context: OverlayContext) { log.bitsPerComponent.append(context.cg.bitsPerComponent) }
}

// AppKit gives a view's `draw(_:)` a context that records a display list, not the bitmap every
// benchmark and most tests draw into. Core Animation renders the list on the GPU while the window is
// on screen and the display awake, and replays it on the CPU otherwise. What costs little into a
// bitmap can cost a great deal there, and only the app on screen shows it (the grid's clip of a rect
// per dot, made into a region again for every copy of a tile, kept the main thread waiting some
// 400 ms a frame), so a test holds what a canvas does with the context it's given.
@MainActor let displayTests = Suite("Display", [
    test("a canvas the window displays draws its grid's copies unclipped, as AppKit's context isn't a bitmap; drawn into a bitmap, it clips them") {
        let log = ContextLog()
        let h = try EditorHarness(plugins: [Contributor(id: "context-probe") { $0.overlay(ContextProbeOverlay(log: log)) }])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        // Layer-backed, as SwiftUI makes the app's, so that `display()` draws it now.
        canvas.wantsLayer = true
        let (clipped, unclipped) = (h.editor.gridFramesClipped, h.editor.gridFramesUnclipped)
        canvas.display()
        let displayed = log.bitsPerComponent
        expect(!displayed.isEmpty, "AppKit drew the canvas")
        expect(displayed.allSatisfy { $0 == 0 }, "into a context that isn't a bitmap (a display list's): \(displayed)")
        expectEqual(h.editor.gridFramesUnclipped - unclipped, displayed.count, "every frame it drew, its grid's copies were drawn unclipped")
        expectEqual(h.editor.gridFramesClipped, clipped, "and none through the clip")
        // As every benchmark and `renderBitmap` draw it.
        _ = renderBitmap(h.editor, size: canvas.bounds.size, scale: 2)
        expect(log.bitsPerComponent.last.map { $0 > 0 } ?? false, "a bitmap has bits to a component")
        expectEqual(h.editor.gridFramesClipped - clipped, 1, "into it the grid's copies are clipped")
        expectEqual(h.editor.gridFramesUnclipped - unclipped, displayed.count, "and none drawn unclipped")
    },
])
