import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import StickyNotes
import TestKit

// The card (`editor.card`, a plugin's view under a rect of the board): a frame with one open costs what
// laying it out does, one `camera.toView`, two calls of the plugin's `size` and a frame set if it
// moved, whatever the board.

extension Budget {
    /// A pan's frame of the 10,000-shape board with a card open (the camera moved, `CanvasView` told, the
    /// card laid out, the canvas drawn) over the same frame with none, the two alternating. The thread's
    /// CPU, release: 0.05, 0.00 and 0.16 ms in three runs alone at a load average of 15 (the frame
    /// itself 9 to 12 ms, whose noise is the floor), and the plan's 0.3.
    static let cardFrame = 0.3
}

@MainActor let cardBenchmarks = Suite("Card benchmarks", [
    test("a pan's frame of the board with a card open costs hardly more than the same frame with none") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.titled], backing: .buffered, defer: false)
            let canvas = CanvasView(editor: h.editor)
            window.contentView = canvas
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let box = try require(note.box)
            h.editor.camera = camera(centering: box, at: 0.5, in: viewport)
            draw(h.editor, into: context, size: viewport)      // the first frame works out every shape's geometry
            let probe = CardProbe(frame: .zero)
            let log = ClosingLog()
            let card = probeCard("bench", about: note.id, anchor: CGRect(x: box.minX + 10, y: box.minY + 10, width: 100, height: 22),
                                 probe: probe, closings: log)
            // Frames with and without the card alternate, so whatever else the machine does is in both; the
            // card is shown and taken down (untimed) between them.
            var without: [Double] = [], with: [Double] = []
            for run in 0..<200 {
                let open = run % 2 == 1
                if open { expect(h.editor.showCard(card)) }
                let time = threadCPUTime {
                    h.editor.camera.pan(by: CGSize(width: run % 4 < 2 ? 1 : -1, height: 0))
                    draw(h.editor, into: context, size: viewport)
                }.milliseconds
                if open { with.append(time) } else { without.append(time) }
                if open { h.editor.closeCard() }
            }
            expectEqual(log.closings.filter { $0 != .asked }, [], "the card stayed open through the pans")
            let added = with.sorted()[with.count / 2] - without.sorted()[without.count / 2]
            report(String(format: "%6d shapes: a pan's frame %5.2f ms, %5.2f more with a card open (budget %.1f)", size, without.sorted()[without.count / 2], added, Budget.cardFrame))
            if holdsToBudgets, size >= 10_000 { expect(added < Budget.cardFrame, "a card open added \(added) ms to a pan's frame over \(size) shapes") }
        }
    },
])
